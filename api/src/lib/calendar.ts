// Reading an iCalendar (.ics) file for /v1/calendar/events.
//
// `parseCalendar` turns the text of a calendar into a compact list of the
// occurrences that fall near "now": repeating events expanded, EXDATEs and
// RECURRENCE-ID overrides applied, cancelled events dropped. That list is what
// gets cached. `upcomingEvents` then answers one request from it: it places
// floating and all-day times in the caller's time zone and keeps the next
// seven days.
//
// The file comes from an arbitrary URL, so everything here is bounded. ical.js
// reads the file and decodes values, but it never expands an event's repeat
// rule: one call to its recurrence iterator cannot be interrupted, and rules
// exist that make it search for a date that never comes. Occurrences are
// worked out here instead, period by period, in loops whose length is fixed
// by the calendar (see `expandRule`) and charged to a work budget.
//
// Nothing here imports `cloudflare:*`, so the spec writer can load it in Node.
import ICAL from "ical.js";
import { WINDOWS_ZONES } from "./windows-zones.ts";

type Time = InstanceType<typeof ICAL.Time>;
type Timezone = InstanceType<typeof ICAL.Timezone>;
type Component = InstanceType<typeof ICAL.Component>;
type Property = InstanceType<typeof ICAL.Property>;
type Recur = InstanceType<typeof ICAL.Recur>;

const DAY = 86400;

/** How far ahead a request looks. */
export const UPCOMING_DAYS = 7;
/**
 * What is kept at parse time, around the moment of parsing: everything that
 * ends after `now - 1 day` and starts before `now + 8 days`. The extra day on
 * each side covers the cache lifetime and any request time zone (floating and
 * all-day times are placed only when a request is answered).
 */
const KEEP_BEFORE = DAY;
const KEEP_AFTER = (UPCOMING_DAYS + 1) * DAY;

/**
 * Work allowed for one file. One unit is one event read, one period of a
 * repeat rule stepped over (a day, week, month or year), one occurrence
 * placed, or one listed date read; each is at most a few microseconds.
 */
const MAX_WORK_PER_FILE = 200_000;
/** Occurrences kept per calendar; a nine-day window with more than this is not a personal calendar. */
const MAX_KEPT = 500;
const MAX_TITLE_LENGTH = 200;
/** EXDATE and RDATE values one event may list. */
const MAX_LISTED_DATES = 2000;
/** Limits on one VTIMEZONE, and on all of a file's zones together. */
const MAX_ZONE_OBSERVANCES = 60;
const MAX_ZONE_RULES = 12;
const MAX_ZONE_DATES = 400;
const MAX_ZONE_RULES_PER_FILE = 40;
const MAX_ZONES_PER_FILE = 50;
/**
 * RRULE and EXRULE lines are renamed before ical.js reads the file, so that
 * it keeps their text as it is. Otherwise it decodes them while parsing, and
 * one malformed rule (`FREQ=FOO`) makes it reject the whole calendar.
 */
const RULE = "x-seasign-rrule";
const EXCLUSION_RULE = "x-seasign-exrule";
/** Zone maths is only done for times this close to the kept window, measured on the wall clock. */
const NEAR = 3 * DAY;

/**
 * One occurrence, as cached.
 * - `instant`: start and end are Unix seconds.
 * - `floating`: start and end are wall-clock seconds (the local date and time
 *   read as if it were UTC); the request's time zone decides the instant.
 * - `allDay`: start and end are wall-clock seconds at midnight of the first
 *   day and of the day after the last.
 */
export type StoredEvent = {
  kind: "instant" | "floating" | "allDay";
  title: string;
  start: number;
  end: number;
};

export type ParsedCalendar = {
  events: StoredEvent[];
  /** True when a limit was reached or an event was skipped as unsupported or unreadable. */
  partial: boolean;
};

export type UpcomingEvent = {
  title: string;
  /** UTC instant, second precision. */
  start: string;
  end: string;
  allDay: boolean;
  /** For all-day events, the local date it starts on. */
  date?: string;
};

/** The text is not an iCalendar file. */
export class CalendarParseError extends Error {}

// ───────────────────────── time zones ─────────────────────────

const formatters = new Map<string, Intl.DateTimeFormat | null>();

function formatter(timeZone: string): Intl.DateTimeFormat | null {
  let format = formatters.get(timeZone);
  if (format === undefined) {
    try {
      format = new Intl.DateTimeFormat("en-US", {
        timeZone,
        hourCycle: "h23",
        year: "numeric",
        month: "2-digit",
        day: "2-digit",
        hour: "2-digit",
        minute: "2-digit",
        second: "2-digit",
      });
    } catch {
      format = null;
    }
    // TZIDs come from untrusted files; do not let the cache grow without limit.
    if (formatters.size >= 300) formatters.clear();
    formatters.set(timeZone, format);
  }
  return format;
}

/** True when the runtime knows this IANA time zone name. */
export function isTimeZone(timeZone: string): boolean {
  return timeZone.length <= 64 && formatter(timeZone) !== null;
}

/** The zone's offset from UTC at an instant, in seconds. */
function offsetAt(epoch: number, timeZone: string): number {
  const parts = (formatter(timeZone) as Intl.DateTimeFormat).formatToParts(new Date(epoch * 1000));
  const part = (type: string) => Number(parts.find((p) => p.type === type)?.value);
  const wall = Date.UTC(part("year"), part("month") - 1, part("day"), part("hour"), part("minute"), part("second"));
  return wall / 1000 - epoch;
}

/** The instant at which the zone's clocks show the given wall-clock time. */
function wallToEpoch(wall: number, timeZone: string): number {
  const first = wall - offsetAt(wall, timeZone);
  const second = wall - offsetAt(first, timeZone);
  // Away from a clock change both agree. In the repeated hour of a fall-back
  // either answer is valid; in the skipped hour of a spring-forward neither
  // is, and the later instant is used, as calendar apps do.
  return second;
}

/** The date and time of an ical.js Time, read as if it were UTC. */
function wallSeconds(time: Time): number {
  return Date.UTC(time.year, time.month - 1, time.day, time.hour, time.minute, time.second) / 1000;
}

/** Where a time's zone comes from. */
type Zone =
  | { type: "date" }
  | { type: "utc" }
  /** A VTIMEZONE in the file. */
  | { type: "file"; zone: Timezone }
  /** No VTIMEZONE, but the TZID is an IANA name the runtime knows, or a Windows name for one. */
  | { type: "iana"; timeZone: string }
  /** No zone at all, or a TZID nobody can interpret: the request's time zone decides. */
  | { type: "floating" };

function zoneOf(property: Property, time: Time): Zone {
  if (time.isDate) return { type: "date" };
  const zone = time.zone;
  if (zone === ICAL.Timezone.utcTimezone) return { type: "utc" };
  if (zone && zone !== ICAL.Timezone.localTimezone && zone.component) return { type: "file", zone };
  const tzid = property.getParameter("tzid");
  if (typeof tzid !== "string") return { type: "floating" };
  if (isTimeZone(tzid)) return { type: "iana", timeZone: tzid };
  const mapped = Object.hasOwn(WINDOWS_ZONES, tzid.trim()) ? WINDOWS_ZONES[tzid.trim()] : undefined;
  if (mapped && isTimeZone(mapped)) return { type: "iana", timeZone: mapped };
  return { type: "floating" };
}

type Resolved = { kind: StoredEvent["kind"]; value: number };

/** Places a wall-clock time (seconds, read as if UTC) in a zone. */
function resolveWall(wall: number, zone: Zone): Resolved {
  switch (zone.type) {
    case "date":
      return { kind: "allDay", value: wall };
    case "utc":
      return { kind: "instant", value: wall };
    case "file": {
      const date = new Date(wall * 1000);
      const time = ICAL.Time.fromData({
        year: date.getUTCFullYear(),
        month: date.getUTCMonth() + 1,
        day: date.getUTCDate(),
        hour: date.getUTCHours(),
        minute: date.getUTCMinutes(),
        second: date.getUTCSeconds(),
      });
      return { kind: "instant", value: wall - zone.zone.utcOffset(time) };
    }
    case "iana":
      return { kind: "instant", value: wallToEpoch(wall, zone.timeZone) };
    case "floating":
      return { kind: "floating", value: wall };
  }
}

const resolve = (time: Time, zone: Zone): Resolved => resolveWall(wallSeconds(time), zone);

const key = (resolved: Resolved) => `${resolved.kind}:${resolved.value}`;

// ───────────────────────── repeat rules ─────────────────────────

/** Days since 1970-01-01 of a calendar date. */
const dayNumber = (year: number, month: number, day: number) => Date.UTC(year, month - 1, day) / 86_400_000;
/** 0 for Sunday … 6 for Saturday. 1970-01-01 was a Thursday. */
const weekdayOf = (day: number) => (((day + 4) % 7) + 7) % 7;
const daysInMonth = (year: number, month: number) => new Date(Date.UTC(year, month, 0)).getUTCDate();

const WEEKDAYS = ["SU", "MO", "TU", "WE", "TH", "FR", "SA"];

/** An RRULE of a shape `expandRule` implements. */
export type Rule = {
  freq: "DAILY" | "WEEKLY" | "MONTHLY" | "YEARLY";
  interval: number;
  count: number | null;
  until: Time | null;
  /** First day of the week, 0 for Sunday. Matters for weekly rules with an interval. */
  weekStart: number;
  /** `ordinal` 0 is every such weekday; 2 the second of the month, -1 the last. */
  byDay: { weekday: number; ordinal: number }[];
  /** The same by weekday (0 for Sunday): the ordinals asked for, or null when the weekday is not listed. */
  ordinalsByWeekday: (number[] | null)[];
  byMonthDay: number[];
  byMonth: number[];
  bySetPos: number[];
};

function integers(value: unknown, min: number, max: number): number[] | null {
  if (value === undefined) return [];
  if (!Array.isArray(value) || value.length > 62) return null;
  const ok = value.every((n) => typeof n === "number" && Number.isInteger(n) && n !== 0 && n >= min && n <= max);
  return ok ? [...new Set(value as number[])] : null;
}

/**
 * Reads the text of an RRULE. Returns null when it is malformed or is not a
 * shape this file expands, and the event is then skipped.
 *
 * Supported: daily, weekly, monthly and yearly rules with INTERVAL, COUNT,
 * UNTIL and WKST, filtered by BYDAY, BYMONTHDAY, BYMONTH and BYSETPOS, which
 * is everything Google, Apple and Outlook write. Not supported: rules finer
 * than a day, BYHOUR and finer, BYWEEKNO, BYYEARDAY, and a yearly rule that
 * names weekdays or days of the month without naming months.
 *
 * Nothing here is a safety check. `expandRule` is bounded for any `Rule`,
 * including ones that never match a date.
 */
export function readRule(text: string): Rule | null {
  let recur: Recur;
  try {
    recur = ICAL.Recur.fromString(text);
  } catch {
    return null;
  }
  const freq = recur.freq;
  if (freq !== "DAILY" && freq !== "WEEKLY" && freq !== "MONTHLY" && freq !== "YEARLY") return null;
  const interval = recur.interval ?? 1;
  if (!Number.isInteger(interval) || interval < 1 || interval > 1000) return null;
  const count = recur.count ?? null;
  if (count !== null && (!Number.isInteger(count) || count < 1)) return null;
  const until = recur.until ?? null;
  if (until !== null && !(until instanceof ICAL.Time)) return null;

  const parts = recur.parts as Record<string, unknown>;
  for (const name of Object.keys(parts)) {
    if (name !== "BYDAY" && name !== "BYMONTHDAY" && name !== "BYMONTH" && name !== "BYSETPOS") return null;
  }
  const rawDays = parts.BYDAY ?? [];
  if (!Array.isArray(rawDays) || rawDays.length > 62) return null;
  const byDay: Rule["byDay"] = [];
  for (const raw of rawDays) {
    const match = typeof raw === "string" ? /^([+-]?\d{1,2})?(SU|MO|TU|WE|TH|FR|SA)$/.exec(raw) : null;
    if (!match) return null;
    const ordinal = match[1] ? Number(match[1]) : 0;
    // A month has at most five of any weekday.
    if (match[1] && (ordinal === 0 || Math.abs(ordinal) > 5)) return null;
    const weekday = WEEKDAYS.indexOf(match[2] as string);
    if (!byDay.some((entry) => entry.weekday === weekday && entry.ordinal === ordinal)) byDay.push({ weekday, ordinal });
  }
  const ordinalsByWeekday: Rule["ordinalsByWeekday"] = [null, null, null, null, null, null, null];
  for (const entry of byDay) (ordinalsByWeekday[entry.weekday] ??= []).push(entry.ordinal);
  const byMonthDay = integers(parts.BYMONTHDAY, -31, 31);
  const byMonth = integers(parts.BYMONTH, 1, 12);
  const bySetPos = integers(parts.BYSETPOS, -366, 366);
  if (!byMonthDay || !byMonth || !bySetPos) return null;

  const hasOrdinal = byDay.some((entry) => entry.ordinal !== 0);
  if (freq === "DAILY" || freq === "WEEKLY") {
    // "2MO" and BYSETPOS only mean something within a month or a year.
    if (hasOrdinal || bySetPos.length > 0) return null;
    if (freq === "WEEKLY" && byMonthDay.length > 0) return null;
  } else {
    if (bySetPos.length > 0 && byDay.length === 0 && byMonthDay.length === 0) return null;
    // Without months, "the 20th Monday of the year" and "the 15th of every
    // month, yearly" are read differently by different apps.
    if (freq === "YEARLY" && (byDay.length > 0 || byMonthDay.length > 0) && byMonth.length === 0) return null;
  }
  // ical.js numbers weekdays from 1 for Sunday; Monday starts the week by default.
  const weekStart = Number.isInteger(recur.wkst) && recur.wkst >= 1 && recur.wkst <= 7 ? recur.wkst - 1 : 1;
  byMonth.sort((a, b) => a - b);
  return { freq, interval, count, until, weekStart, byDay, ordinalsByWeekday, byMonthDay, byMonth, bySetPos };
}

/**
 * The days of one month that BYDAY and BYMONTHDAY select, in order; or, when
 * the rule has neither, `fallbackDay` if the month has it.
 */
function monthDays(rule: Rule, year: number, month: number, fallbackDay: number): number[] {
  const length = daysInMonth(year, month);
  const first = dayNumber(year, month, 1);
  const weekdayMatches = (dayOfMonth: number) => {
    const ordinals = rule.ordinalsByWeekday[weekdayOf(first + dayOfMonth - 1)];
    if (!ordinals) return false;
    const fromStart = Math.floor((dayOfMonth - 1) / 7) + 1;
    const fromEnd = -(Math.floor((length - dayOfMonth) / 7) + 1);
    return ordinals.some((ordinal) => ordinal === 0 || ordinal === fromStart || ordinal === fromEnd);
  };
  const days: number[] = [];
  if (rule.byMonthDay.length > 0) {
    const chosen = new Set<number>();
    for (const value of rule.byMonthDay) {
      const dayOfMonth = value > 0 ? value : length + 1 + value;
      if (dayOfMonth >= 1 && dayOfMonth <= length) chosen.add(dayOfMonth);
    }
    for (const dayOfMonth of [...chosen].sort((a, b) => a - b)) {
      // With both, the weekday narrows the days of the month ("Friday the 13th").
      if (rule.byDay.length === 0 || weekdayMatches(dayOfMonth)) days.push(first + dayOfMonth - 1);
    }
  } else if (rule.byDay.length > 0) {
    for (let dayOfMonth = 1; dayOfMonth <= length; dayOfMonth++) {
      if (weekdayMatches(dayOfMonth)) days.push(first + dayOfMonth - 1);
    }
  } else if (fallbackDay <= length) {
    days.push(first + fallbackDay - 1);
  }
  return days;
}

/** BYSETPOS: the nth of a period's days, counted from the start or (negative) from the end. */
function pick(days: number[], positions: number[]): number[] {
  if (positions.length === 0) return days;
  const picked = new Set<number>();
  for (const position of positions) {
    const day = position > 0 ? days[position - 1] : days[days.length + position];
    if (day !== undefined) picked.add(day);
  }
  return [...picked].sort((a, b) => a - b);
}

type Period = { start: number; days: number[] };

/**
 * The rule's `index`-th period counted from the one DTSTART is in: the day it
 * begins and the days in it the rule selects, in order. A period is
 * `interval` days, weeks, months or years on from the last, so `start` grows
 * with `index`.
 */
function periodAt(rule: Rule, start: { year: number; month: number; day: number; dayNumber: number }, index: number): Period {
  const step = index * rule.interval;
  switch (rule.freq) {
    case "DAILY": {
      const day = start.dayNumber + step;
      const date = new Date(day * 86_400_000);
      const dayOfMonth = date.getUTCDate();
      const fromEnd = dayOfMonth - daysInMonth(date.getUTCFullYear(), date.getUTCMonth() + 1) - 1;
      const matches =
        (rule.byMonth.length === 0 || rule.byMonth.includes(date.getUTCMonth() + 1)) &&
        (rule.byDay.length === 0 || rule.ordinalsByWeekday[weekdayOf(day)] !== null) &&
        (rule.byMonthDay.length === 0 || rule.byMonthDay.includes(dayOfMonth) || rule.byMonthDay.includes(fromEnd));
      return { start: day, days: matches ? [day] : [] };
    }
    case "WEEKLY": {
      const firstWeek = start.dayNumber - ((weekdayOf(start.dayNumber) - rule.weekStart + 7) % 7);
      const week = firstWeek + step * 7;
      const weekdays = rule.byDay.length > 0 ? rule.byDay.map((entry) => entry.weekday) : [weekdayOf(start.dayNumber)];
      const days = [...new Set(weekdays.map((weekday) => week + ((weekday - rule.weekStart + 7) % 7)))]
        .filter((day) => rule.byMonth.length === 0 || rule.byMonth.includes(new Date(day * 86_400_000).getUTCMonth() + 1))
        .sort((a, b) => a - b);
      return { start: week, days };
    }
    case "MONTHLY": {
      const monthIndex = start.year * 12 + (start.month - 1) + step;
      const year = Math.floor(monthIndex / 12);
      const month = (monthIndex % 12) + 1;
      const wanted = rule.byMonth.length === 0 || rule.byMonth.includes(month);
      return {
        start: dayNumber(year, month, 1),
        days: wanted ? pick(monthDays(rule, year, month, start.day), rule.bySetPos) : [],
      };
    }
    case "YEARLY": {
      const year = start.year + step;
      const months = rule.byMonth.length > 0 ? rule.byMonth : [start.month];
      const days = months.flatMap((month) => monthDays(rule, year, month, start.day));
      return { start: dayNumber(year, 1, 1), days: pick(days, rule.bySetPos) };
    }
  }
}

/** The index of the last period that begins on or before `day` (at least 0). */
function periodIndexFor(rule: Rule, start: { year: number; month: number; dayNumber: number }, day: number): number {
  let periods: number;
  if (rule.freq === "DAILY") periods = day - start.dayNumber;
  else if (rule.freq === "WEEKLY") periods = Math.floor((day - start.dayNumber) / 7) - 1;
  else {
    const date = new Date(day * 86_400_000);
    const months = (date.getUTCFullYear() - start.year) * 12 + (date.getUTCMonth() + 1 - start.month);
    periods = rule.freq === "MONTHLY" ? months : Math.floor(months / 12) - 1;
  }
  return Math.max(0, Math.floor(periods / rule.interval));
}

/**
 * Calls `visit` for each day from `fromDay` to `toDay` (day numbers) on which
 * the rule has an occurrence after DTSTART's own day, in order. DTSTART is
 * always the first occurrence and counts towards COUNT; the caller places it.
 * `visit` returns false to stop.
 *
 * Why this ends, whatever the rule: the loop walks periods by index. Each
 * period begins at least a day after the one before, the loop stops at the
 * first period that begins after `toDay`, and working out one period is a
 * fixed amount of arithmetic (at most a year of days). A rule that matches
 * nothing just yields empty periods. Each period costs one unit of `budget`,
 * and the loop also stops when that runs out.
 *
 * Without COUNT the walk starts at the period holding `fromDay`, since
 * nothing before it is wanted. With COUNT it has to start at DTSTART to count.
 */
function expandRule(
  rule: Rule,
  start: { year: number; month: number; day: number; dayNumber: number },
  fromDay: number,
  toDay: number,
  budget: Budget,
  visit: (day: number) => boolean,
): void {
  // A day of slack: UNTIL is usually in UTC and the days here are local.
  const lastDay = rule.until ? Math.min(toDay, Math.floor(wallSeconds(rule.until) / DAY) + 1) : toDay;
  let produced = 1;
  if (rule.count !== null && produced >= rule.count) return;

  for (let index = rule.count === null ? periodIndexFor(rule, start, fromDay) : 0; ; index++) {
    if (budget.work <= 0) {
      budget.partial = true;
      return;
    }
    // A year of listed months is up to twelve months of work.
    budget.work -= rule.freq === "YEARLY" ? Math.max(1, rule.byMonth.length) : 1;
    const period = periodAt(rule, start, index);
    if (period.start > lastDay) return;
    for (const day of period.days) {
      if (day <= start.dayNumber) continue;
      if (day > lastDay) return;
      produced++;
      if (day >= fromDay && !visit(day)) return;
      if (rule.count !== null && produced >= rule.count) return;
    }
  }
}

// ───────────────────────── time zone definitions ─────────────────────────

/**
 * Whether a VTIMEZONE observance's rule names exactly one day in every year:
 * yearly, in one month, on one day picked by weekday ("the second Sunday",
 * "the last Sunday", "the Sunday on or after the 8th") or by date. ical.js
 * expands these itself, and such a rule gives its iterator one date to find
 * each year and nothing to search for.
 */
function isOneDayAYear(rule: Rule, start: Time): boolean {
  if (rule.freq !== "YEARLY" || rule.interval !== 1 || rule.bySetPos.length > 0) return false;
  if (rule.byMonth.length === 0) {
    return rule.byDay.length === 0 && rule.byMonthDay.length === 0 && !(start.month === 2 && start.day === 29);
  }
  if (rule.byMonth.length !== 1) return false;
  const [weekday] = rule.byDay;
  if (rule.byMonthDay.length === 0) {
    // The first to fourth, or last to fourth-from-last: every month has them.
    return rule.byDay.length === 1 && weekday !== undefined && weekday.ordinal !== 0 && Math.abs(weekday.ordinal) <= 4;
  }
  if (rule.byDay.length === 0) return rule.byMonthDay.length === 1 && Math.abs(rule.byMonthDay[0] as number) <= 28;
  // One weekday within seven days in a row that every month has, counted from
  // the start of the month. (Counted from the end, ical.js takes half a second
  // per rule and gets the date wrong.)
  const days = [...rule.byMonthDay].sort((a, b) => a - b);
  const inARow = days.length === 7 && days.every((day, i) => day === (days[0] as number) + i);
  return rule.byDay.length === 1 && weekday?.ordinal === 0 && inARow && (days[0] as number) >= 1 && (days[6] as number) <= 28;
}

/**
 * Checks a VTIMEZONE and gives its rules back to ical.js. Returns what the
 * zone costs to expand, as its number of repeating observances, or -1 when it
 * is not to be used.
 *
 * ical.js expands every observance's rule from its DTSTART (1601 in Outlook's
 * files) to five years past the latest date it is asked about, the first time
 * the zone is used: about 2.5 ms per repeating observance. Real zones change
 * clocks twice a year, sometimes with a few earlier rules and a list of
 * historical dates.
 */
function prepareTimezone(vtimezone: Component): number {
  const tzid = vtimezone.getFirstPropertyValue("tzid");
  if (typeof tzid !== "string" || tzid === "") return -1;
  const observances = [...vtimezone.getAllSubcomponents("standard"), ...vtimezone.getAllSubcomponents("daylight")];
  if (observances.length === 0 || observances.length > MAX_ZONE_OBSERVANCES) return -1;

  let repeating = 0;
  let listedDates = 0;
  for (const observance of observances) {
    const start = observance.getFirstPropertyValue("dtstart");
    if (!(start instanceof ICAL.Time) || start.year < 1600 || start.year > 2100) return -1;
    if (observance.hasProperty(EXCLUSION_RULE)) return -1;
    for (const property of observance.getAllProperties(RULE)) {
      const text = property.getFirstValue();
      const rule = typeof text === "string" ? readRule(text) : null;
      if (!rule || !isOneDayAYear(rule, start)) return -1;
      observance.addPropertyWithValue("rrule", ICAL.Recur.fromString(text as string));
      repeating++;
    }
    observance.removeAllProperties(RULE);
    for (const property of observance.getAllProperties("rdate")) {
      listedDates += property.getValues().length;
    }
  }
  if (repeating > MAX_ZONE_RULES || listedDates > MAX_ZONE_DATES) return -1;
  return repeating;
}

// ───────────────────────── parsing ─────────────────────────

/** `work` is what is left of `MAX_WORK_PER_FILE`. */
type Budget = { work: number; partial: boolean };

function titleOf(component: Component): string {
  const summary = component.getFirstPropertyValue("summary");
  const text = typeof summary === "string" ? summary : "";
  return text.replace(/\s+/g, " ").trim().slice(0, MAX_TITLE_LENGTH);
}

const isCancelled = (component: Component) =>
  String(component.getFirstPropertyValue("status") ?? "").toUpperCase() === "CANCELLED";

const plausible = (time: Time) => time.year >= 1900 && time.year <= 2200;

/**
 * True when a single (non-repeating) event clearly ended before the kept
 * window, judged on the wall clock alone. Most of a calendar is old events;
 * this spares them the time zone work.
 */
function isLongOver(component: Component, keepFrom: number): boolean {
  const start = component.getFirstPropertyValue("dtstart");
  if (!(start instanceof ICAL.Time)) return false;
  const startWall = wallSeconds(start);
  let endWall = startWall + (start.isDate ? DAY : 0);
  const end = component.getFirstPropertyValue("dtend");
  const duration = component.getFirstPropertyValue("duration");
  if (end instanceof ICAL.Time) endWall = Math.max(endWall, wallSeconds(end));
  else if (duration instanceof ICAL.Duration) endWall = Math.max(endWall, startWall + duration.toSeconds());
  return endWall + NEAR <= keepFrom;
}

/** The parts of an event that every one of its occurrences shares. */
type Shape = { title: string; start: Time; zone: Zone; first: Resolved; duration: number };

function shapeOf(component: Component): Shape | null {
  const startProperty = component.getFirstProperty("dtstart");
  if (!startProperty) return null;
  const start = startProperty.getFirstValue();
  if (!(start instanceof ICAL.Time) || !plausible(start)) return null;
  const zone = zoneOf(startProperty, start);
  const first = resolve(start, zone);

  let duration = 0;
  const endProperty = component.getFirstProperty("dtend");
  const durationValue = component.getFirstPropertyValue("duration");
  if (endProperty) {
    const end = endProperty.getFirstValue();
    if (end instanceof ICAL.Time && plausible(end)) {
      const resolvedEnd = resolve(end, zoneOf(endProperty, end));
      // A DTEND of another kind than DTSTART (a date against a date-time) is not usable.
      if (resolvedEnd.kind === first.kind) duration = resolvedEnd.value - first.value;
    }
  } else if (durationValue instanceof ICAL.Duration) {
    duration = durationValue.toSeconds();
  }
  if (!Number.isFinite(duration) || duration < 0) duration = 0;
  if (first.kind === "allDay") {
    // An all-day event covers whole days, and at least one: no DTEND, or a
    // DTEND equal to DTSTART, both mean a single day.
    duration = Math.max(DAY, Math.ceil(duration / DAY) * DAY);
  }
  return { title: titleOf(component), start, zone, first, duration };
}

type Window = { keepFrom: number; keepUntil: number };

/**
 * Adds one VEVENT's occurrences near the window to `out`.
 * `overridden` holds the instances of this event's series that other VEVENTs
 * replace. `single` is true for such a replacement: it never repeats.
 */
function expand(
  component: Component,
  overridden: Set<string> | undefined,
  single: boolean,
  { keepFrom, keepUntil }: Window,
  budget: Budget,
  out: StoredEvent[],
): void {
  // Judged on the wall clock, before any time zone work: an event or a
  // series that starts after the window, and a single event that ended before it.
  const startValue = component.getFirstPropertyValue("dtstart");
  if (startValue instanceof ICAL.Time && wallSeconds(startValue) - NEAR >= keepUntil) return;
  const ruleProperties = single ? [] : component.getAllProperties(RULE);
  const listedProperties = single ? [] : component.getAllProperties("rdate");
  const recurring = ruleProperties.length > 0 || listedProperties.length > 0;
  if (!recurring && isLongOver(component, keepFrom)) return;

  const shape = shapeOf(component);
  if (!shape) {
    budget.partial = true;
    return;
  }
  const { title, zone, duration, start } = shape;

  const emit = (occurrence: Resolved) => {
    if (occurrence.value >= keepUntil || occurrence.value + duration <= keepFrom) return;
    out.push({ kind: occurrence.kind, title, start: occurrence.value, end: occurrence.value + duration });
  };

  if (!recurring) {
    if (!overridden?.has(key(shape.first))) emit(shape.first);
    return;
  }

  // EXRULE was withdrawn from the standard long ago. Showing the series
  // without its exclusions would be wrong, so the event is skipped.
  if (component.hasProperty(EXCLUSION_RULE)) {
    budget.partial = true;
    return;
  }
  const rules: Rule[] = [];
  for (const property of ruleProperties) {
    const text = property.getFirstValue();
    const rule = typeof text === "string" ? readRule(text) : null;
    if (!rule) {
      budget.partial = true;
      return;
    }
    rules.push(rule);
  }
  // A series that ended long ago needs no steps at all.
  if (
    rules.length > 0 &&
    listedProperties.length === 0 &&
    rules.every((rule) => rule.until && wallSeconds(rule.until) + duration + NEAR < keepFrom)
  ) {
    return;
  }

  const exclusionProperties = component.getAllProperties("exdate");
  let listed = 0;
  for (const property of [...exclusionProperties, ...listedProperties]) listed += property.getValues().length;
  if (listed > MAX_LISTED_DATES) {
    budget.partial = true;
    return;
  }
  budget.work -= listed;

  /** Excluded instances by instant, and whole excluded local days (EXDATE;VALUE=DATE). */
  const excluded = new Set<string>();
  const excludedDays = new Set<number>();
  for (const property of exclusionProperties) {
    for (const value of property.getValues()) {
      if (!(value instanceof ICAL.Time)) continue;
      // Only an exclusion near the window can matter.
      const wall = wallSeconds(value);
      if (wall + NEAR <= keepFrom - duration || wall - NEAR >= keepUntil) continue;
      if (value.isDate) excludedDays.add(wall / DAY);
      else excluded.add(key(resolve(value, zoneOf(property, value))));
    }
  }

  const seen = new Set<string>();
  /** Adds an occurrence unless it was already added, is excluded, or is replaced by an override. */
  const offer = (occurrence: Resolved, wall: number) => {
    const id = key(occurrence);
    if (seen.has(id)) return;
    seen.add(id);
    if (excluded.has(id) || overridden?.has(id) || excludedDays.has(Math.floor(wall / DAY))) return;
    emit(occurrence);
  };

  const startWall = wallSeconds(start);
  offer(shape.first, startWall);

  for (const property of listedProperties) {
    for (const value of property.getValues()) {
      // A period, an implausible year, or a date listed for a timed event is not used.
      if (!(value instanceof ICAL.Time) || !plausible(value)) continue;
      const wall = wallSeconds(value);
      if (wall + NEAR <= keepFrom - duration || wall - NEAR >= keepUntil) continue;
      const occurrence = resolve(value, zoneOf(property, value));
      if (occurrence.kind === shape.first.kind) offer(occurrence, wall);
    }
  }

  const startDay = Math.floor(startWall / DAY);
  const secondsIntoDay = startWall - startDay * DAY;
  const anchor = { year: start.year, month: start.month, day: start.day, dayNumber: startDay };
  // Two days of slack around the window, for the distance between wall clocks.
  const fromDay = Math.floor((keepFrom - duration) / DAY) - 2;
  const toDay = Math.floor(keepUntil / DAY) + 2;
  for (const rule of rules) {
    const until = rule.until;
    expandRule(rule, anchor, fromDay, toDay, budget, (day) => {
      if (budget.work <= 0 || out.length >= 4 * MAX_KEPT) {
        budget.partial = true;
        return false;
      }
      budget.work--;
      const wall = day * DAY + secondsIntoDay;
      const occurrence = resolveWall(wall, zone);
      if (until) {
        // UNTIL is the last moment an occurrence may start: a date, a UTC
        // instant, or a local time like DTSTART's.
        const limit = wallSeconds(until);
        const utc = until.zone === ICAL.Timezone.utcTimezone && !until.isDate && occurrence.kind === "instant";
        const at = until.isDate ? day * DAY : utc ? occurrence.value : wall;
        if (at > limit) return false;
      }
      offer(occurrence, wall);
      return true;
    });
  }
}

/** The file as ical.js reads it (jCal): [name, properties, subcomponents]. */
type JCal = [string, unknown[], JCal[]];

/**
 * Parses the text of an .ics file and returns the occurrences near `now`.
 * Throws `CalendarParseError` when the text is not a calendar.
 *
 * Each of these leaves the calendar usable and sets `partial`:
 * - an event that cannot be read, or whose RRULE is malformed or is not a
 *   shape `readRule` supports, is skipped;
 * - an event listing more than 2,000 EXDATE and RDATE values is skipped;
 * - reading stops once the file has used its work budget (`MAX_WORK_PER_FILE`);
 * - at most 500 occurrences are kept.
 * A VTIMEZONE that is not a few plain yearly rules is ignored (and so are
 * those past 40 repeating observances or 50 zones in one file); times that
 * name it fall back to the IANA zone of the same name, or to floating.
 * `RANGE=THISANDFUTURE` on a RECURRENCE-ID is not applied: such an override
 * changes only its own instance.
 */
export function parseCalendar(text: string, now: Date): ParsedCalendar {
  const body = text.replace(/^﻿/, "").trimStart();
  if (!/^BEGIN:VCALENDAR/i.test(body)) throw new CalendarParseError("not a calendar");

  let parsed: JCal;
  try {
    // See RULE: repeat rules are kept as text for `readRule`.
    const readable = body.replace(/^(RRULE|EXRULE)(?=[;:])/gim, "X-SEASIGN-$1");
    const result = ICAL.parse(readable) as JCal | JCal[];
    // A file holding several calendars comes back as a list; the first is read.
    parsed = (Array.isArray(result[0]) ? result[0] : result) as JCal;
  } catch {
    // The parser's message can quote a line of the file; it is not passed on.
    throw new CalendarParseError("not a calendar");
  }
  if (!Array.isArray(parsed) || parsed[0] !== "vcalendar" || !Array.isArray(parsed[2])) {
    throw new CalendarParseError("not a calendar");
  }

  const budget: Budget = { work: MAX_WORK_PER_FILE, partial: false };

  // Choose the time zone definitions to keep before ical.js sees any of them:
  // it looks a TZID up in the file's VTIMEZONEs the first time a value is
  // decoded. Done on the parsed data, in one pass, so that a file of tens of
  // thousands of junk VTIMEZONEs costs no more than its size.
  const components: JCal[] = [];
  let zones = 0;
  let zoneRules = 0;
  for (const component of parsed[2]) {
    if (component[0] === "vevent") {
      components.push(component);
    } else if (component[0] === "vtimezone" && zones < MAX_ZONES_PER_FILE) {
      let cost = -1;
      try {
        cost = prepareTimezone(new ICAL.Component(component));
      } catch {
        cost = -1;
      }
      if (cost < 0 || zoneRules + cost > MAX_ZONE_RULES_PER_FILE) continue;
      zones++;
      zoneRules += cost;
      components.push(component);
    }
  }
  const calendar = new ICAL.Component(["vcalendar", parsed[1], components]);

  const nowSeconds = Math.floor(now.getTime() / 1000);
  const window: Window = { keepFrom: nowSeconds - KEEP_BEFORE, keepUntil: nowSeconds + KEEP_AFTER };

  // A repeating event and the VEVENTs that override single instances of it
  // share a UID; the overrides carry a RECURRENCE-ID.
  const masters: Component[] = [];
  const overrides: Component[] = [];
  const overridden = new Map<string, Set<string>>();
  for (const vevent of calendar.getAllSubcomponents("vevent")) {
    try {
      const idProperty = vevent.getFirstProperty("recurrence-id");
      if (!idProperty) {
        masters.push(vevent);
        continue;
      }
      overrides.push(vevent);
      const uid = vevent.getFirstPropertyValue("uid");
      const id = idProperty.getFirstValue();
      if (typeof uid === "string" && id instanceof ICAL.Time) {
        // Only an instance near the window needs suppressing.
        const wall = wallSeconds(id);
        if (wall + NEAR <= window.keepFrom || wall - NEAR >= window.keepUntil) continue;
        let keys = overridden.get(uid);
        if (!keys) overridden.set(uid, (keys = new Set()));
        keys.add(key(resolve(id, zoneOf(idProperty, id))));
      }
    } catch {
      budget.partial = true;
    }
  }

  const events: StoredEvent[] = [];
  const each = (component: Component, single: boolean) => {
    // Far more occurrences in nine days than will be kept: stop reading.
    if (budget.work <= 0 || events.length >= 4 * MAX_KEPT) {
      budget.partial = true;
      return;
    }
    budget.work--;
    try {
      if (isCancelled(component)) return;
      const uid = single ? undefined : component.getFirstPropertyValue("uid");
      // A cancelled override is still in `overridden`, so its instance is
      // removed, not handed back to the series.
      expand(component, typeof uid === "string" ? overridden.get(uid) : undefined, single, window, budget, events);
    } catch {
      // One unreadable event does not spoil the calendar.
      budget.partial = true;
    }
  };

  for (const master of masters) each(master, false);
  // An override stands as an event of its own at its own time.
  for (const override of overrides) each(override, true);

  events.sort((a, b) => a.start - b.start);
  if (events.length > MAX_KEPT) {
    events.length = MAX_KEPT;
    budget.partial = true;
  }
  return { events, partial: budget.partial };
}

// ───────────────────────── answering a request ─────────────────────────

const instant = (epoch: number) => new Date(epoch * 1000).toISOString().replace(/\.\d{3}Z$/, "Z");

/**
 * The stored occurrences that have not ended and start within the next seven
 * days, with floating and all-day times placed in `timeZone` (which must pass
 * `isTimeZone`). Unsorted.
 */
export function upcomingEvents(stored: StoredEvent[], now: Date, timeZone: string): UpcomingEvent[] {
  const nowSeconds = Math.floor(now.getTime() / 1000);
  const horizon = nowSeconds + UPCOMING_DAYS * DAY;
  const upcoming: UpcomingEvent[] = [];
  for (const event of stored) {
    const placed = event.kind !== "instant";
    const start = placed ? wallToEpoch(event.start, timeZone) : event.start;
    const end = placed ? wallToEpoch(event.end, timeZone) : event.end;
    if (start >= horizon) continue;
    // An event without a length (no DTEND) is over the moment it starts.
    if (end === start ? start < nowSeconds : end <= nowSeconds) continue;
    upcoming.push({
      title: event.title,
      start: instant(start),
      end: instant(end),
      allDay: event.kind === "allDay",
      ...(event.kind === "allDay" ? { date: instant(event.start).slice(0, 10) } : {}),
    });
  }
  return upcoming;
}
