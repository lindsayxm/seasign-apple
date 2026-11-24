// Reading an iCalendar (.ics) file for /v1/calendar/events.
//
// `parseCalendar` turns the text of a calendar into a compact list of the
// occurrences that fall near "now": repeating events expanded, EXDATEs and
// RECURRENCE-ID overrides applied, cancelled events dropped. That list is what
// gets cached. `upcomingEvents` then answers one request from it: it places
// floating and all-day times in the caller's time zone and keeps the next
// seven days; `dayEvents` keeps one whole day instead, ended events included.
//
// The file comes from an arbitrary URL, so everything here is bounded, and
// ical.js is used for two things only: turning the text into data
// (`ICAL.parse`) and decoding single values (a time, a duration, the parts of
// a rule). It never expands anything. One call to its recurrence iterator
// cannot be interrupted, and rules exist that make it search for a date that
// never comes; it runs that iterator for an event's RRULE and, the first time
// a zone is used, for a VTIMEZONE's rules. Three times a filter placed in
// front of it was got around. So nothing that repeats is left for it to find:
// - occurrences of events are worked out here (`expandRule`);
// - time zone definitions are read from the parsed data and their offsets
//   worked out here too (`readZone`, `zoneOffset`); no VTIMEZONE is ever given
//   to an ical.js object;
// - the events handed to ical.js are rebuilt from a short list of properties
//   with the value types expected of them (`cleanEvent`), so a rule cannot
//   arrive under another name, case, group, fold or nesting.
// Every loop here has a length fixed by the calendar and is charged to a work
// budget.
// Memory cannot be charged as it is used, since ical.js builds its whole tree
// at once; what it is handed is bounded before it parses (`readableLines`).
//
// Nothing here imports `cloudflare:*`, so the spec writer can load it in Node.
import ICAL from "ical.js";
import { WINDOWS_ZONES } from "./windows-zones.ts";

type Time = InstanceType<typeof ICAL.Time>;
type Component = InstanceType<typeof ICAL.Component>;
type Property = InstanceType<typeof ICAL.Property>;
type Recur = InstanceType<typeof ICAL.Recur>;

const DAY = 86400;

/** How far ahead a request looks. */
export const UPCOMING_DAYS = 7;
/**
 * What is kept at parse time, around the moment of parsing: everything that
 * ends after `now - keepBefore` and starts before `now + 8 days`. The extra
 * day ahead covers the cache lifetime and any request time zone (floating and
 * all-day times are placed only when a request is answered). `parseCalendar`
 * keeps one day back unless told otherwise, which is enough for events that
 * have not ended.
 */
const KEEP_BEFORE = DAY;
/**
 * What the route asks `parseCalendar` to keep back: two days, for a `day`
 * request (task 167), which wants all of today, ended events included. The
 * start of today is up to 25 hours back (a fall-back day), and a floating or
 * all-day time is kept by its wall clock, which in UTC-12 reads 12 hours
 * earlier than the instant it is placed at: 37 hours in all. The second day
 * back only fills room left under MAX_KEPT, so a plain request is answered
 * from the same occurrences as with one day (`parseCalendar`).
 */
export const CACHED_KEEP_BEFORE = 2 * DAY;
const KEEP_AFTER = (UPCOMING_DAYS + 1) * DAY;

/**
 * Work allowed for one file. One unit is one event read, one period of a
 * repeat rule stepped over (a day, week, month or year), one occurrence
 * placed, or one listed date read; each is at most a few microseconds.
 */
const MAX_WORK_PER_FILE = 200_000;
/** Occurrences kept per calendar; a nine- or ten-day window with more than this is not a personal calendar. */
const MAX_KEPT = 500;
const MAX_TITLE_LENGTH = 200;
/** EXDATE and RDATE values one event may list; more and the event is skipped. */
const MAX_LISTED_DATES = 2000;
/** RRULE and EXRULE lines one event may have; more and the event is skipped. Apps write one. */
const MAX_RULES_PER_EVENT = 8;

// What ical.js is given is bounded before it sees the file (`readableLines`),
// because memory, unlike CPU, cannot be charged as the work is done: ical.js
// builds about 0.5 KB of objects for every line it is handed, all at once
// (figures in memory/architecture.md). Over any of these limits the whole file
// is refused as too large. File order is not date order, so reading only the
// first part of a file would quietly lose events that are coming up.
//
// An ordinary busy calendar scaled to MAX_CALENDAR_BYTES holds about 4,400
// events, 31,000 lines to hand on and a few hundred listed dates (see the
// large calendar in api/test/calendar-parse.test.ts), so these leave about
// twice that or more. The costliest files measured sit at every limit at
// once (3,500 events of 17 lines handed on, eight of them rules, and 20,000
// EXDATE values; 1.7 MB, or 2 MB with an RDATE period, which is not handed
// on, filling the rest) and need 40 to 48 MB of old space, and up to 56 MB
// parsed ten times as one request of ten links does (shapes all-limits,
// all-limits-in-window and their -period forms in
// api/scripts/calendar-memory.ts; figures in memory/architecture.md). Before
// task 22 that period's pieces were handed on uncounted, and one such file
// needed 56 MB.
/** Characters of calendar text read; the route fetches at most this many bytes. */
export const MAX_CALENDAR_BYTES = 2 * 1024 * 1024;
/** VEVENTs in one file. */
export const MAX_EVENTS_PER_FILE = 12_000;
/** Lines handed to ical.js, BEGIN and END included. */
export const MAX_LINES_PER_FILE = 60_000;
/** EXDATE and RDATE values handed to ical.js. */
export const MAX_LISTED_PER_FILE = 20_000;
/** VTIMEZONEs handed to ical.js; later ones are not read. `readZone` uses 50. */
const MAX_ZONE_COMPONENTS = 100;
/** Limits on one VTIMEZONE, and on the zones and calendars of one file. */
const MAX_ZONE_OBSERVANCES = 60;
const MAX_ZONE_RULES = 12;
const MAX_ZONE_DATES = 400;
const MAX_ZONES_PER_FILE = 50;
const MAX_CALENDARS_PER_FILE = 20;
/** Distinct TZID names one file may use without defining them. */
const MAX_TZIDS_PER_FILE = 50;
/** What one time zone lookup costs in units of work. */
const ZONE_WORK = 10;
/**
 * The names repeat rules have in the events given to ical.js: plain text
 * under a name it has no meaning for. RRULE and EXRULE lines are also renamed
 * to these before `ICAL.parse` (see `readableLines`), which otherwise decodes
 * a rule as it reads it and rejects the whole file when one is malformed.
 * That renaming is a convenience, not the safeguard: `cleanEvent` does not
 * depend on it.
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

/** The text is longer, or holds more events, lines or listed dates, than a calendar is read with. */
export class CalendarTooLargeError extends CalendarParseError {}

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

/** A span of wall-clock times a zone's clocks skip (`from` up to `to`), and the instant they jump. */
type Gap = { from: number; to: number; at: number };

/** The last skipped span found in each zone, so that many times in one gap cost one search. */
const gaps = new Map<string, Gap>();

/**
 * The instant at which the zone's clocks show the given wall-clock time (in
 * the repeated hour of a fall-back either reading may be given), or, for a
 * time the clocks skip, its two readings, one either side of the jump: with
 * the offset after the gap (`earlier`) and with the offset before it (`later`).
 * Asks the zone at most three times.
 */
function readWall(wall: number, timeZone: string): number | { earlier: number; later: number } {
  const atWall = offsetAt(wall, timeZone);
  const first = wall - atWall;
  const atFirst = offsetAt(first, timeZone);
  if (atFirst === atWall) return first;
  const second = wall - atFirst;
  const atSecond = offsetAt(second, timeZone);
  if (atSecond === atFirst) return second;
  return { earlier: Math.min(second, wall - atSecond), later: Math.max(second, wall - atSecond) };
}

/**
 * A TZID time (an IANA zone the file does not define) as RFC 5545 section
 * 3.3.5 reads it: a time the clocks skip takes the offset from before the gap,
 * so Berlin 02:30 on the day the clocks go forward is 03:30 CEST. That is how
 * the same file with a VTIMEZONE is read (`zoneOffset`), and how an EXDATE or
 * RECURRENCE-ID written in UTC names such an instance. No search: this is on
 * the parse path, where every value is charged one ZONE_WORK. An end that
 * falls before its start this way leaves the event without a length (`shapeOf`).
 */
function tzidToEpoch(wall: number, timeZone: string): number {
  const read = readWall(wall, timeZone);
  return typeof read === "number" ? read : read.later;
}

/**
 * The instant at which the zone's clocks show the given wall-clock time, for
 * floating and all-day times and day bounds, placed when a request is answered.
 * In the repeated hour of a fall-back either reading may be given. A time in
 * the skipped hour of a spring-forward is never shown: it is placed at the
 * instant the clocks jump over it, so that a later time is never placed before
 * an earlier one (an event never ends before it starts) and a day whose
 * midnight is skipped begins where its date does.
 */
function wallToEpoch(wall: number, timeZone: string): number {
  const read = readWall(wall, timeZone);
  if (typeof read === "number") return read;
  // Each reading is one side of the jump; the jump is the first instant whose
  // clocks are past `wall`.
  const known = gaps.get(timeZone);
  if (known && wall >= known.from && wall < known.to) return known.at;
  let low = read.earlier;
  let high = read.later;
  const past = (epoch: number) => epoch + offsetAt(epoch, timeZone) > wall;
  if (past(low) || !past(high)) return read.later;
  while (high - low > 1) {
    const middle = Math.floor((low + high) / 2);
    if (past(middle)) high = middle;
    else low = middle;
  }
  if (gaps.size >= 300) gaps.clear();
  gaps.set(timeZone, { from: low + offsetAt(low, timeZone) + 1, to: high + offsetAt(high, timeZone), at: high });
  return high;
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
  | { type: "file"; zone: FileZone }
  /** No VTIMEZONE, but the TZID is an IANA name the runtime knows, or a Windows name for one. */
  | { type: "iana"; timeZone: string }
  /** No zone at all, or a TZID nobody can interpret: the request's time zone decides. */
  | { type: "floating" };

/**
 * What is left of a file's allowance while it is read: `work` of
 * `MAX_WORK_PER_FILE`, and the TZIDs looked up so far.
 */
type Budget = { work: number; partial: boolean; zones: Map<string, Zone>; fileZones: Map<string, FileZone> };

function zoneOf(property: Property, time: Time, budget: Budget): Zone {
  return zoneFor(time.isDate, time.zone === ICAL.Timezone.utcTimezone, property.getParameter("tzid"), budget);
}

/** `zoneOf` from plain values: whether the time is a date, whether it is in UTC, and its TZID parameter. */
function zoneFor(isDate: boolean, utc: boolean, tzid: unknown, budget: Budget): Zone {
  if (isDate) return { type: "date" };
  if (utc) return { type: "utc" };
  if (typeof tzid !== "string") return { type: "floating" };
  const defined = budget.fileZones.get(tzid);
  if (defined) return { type: "file", zone: defined };

  let named = budget.zones.get(tzid);
  if (!named) {
    // `Intl` takes a zone name in any mix of capitals, and each spelling
    // costs a new formatter (about 0.4 ms). A file gets a fixed number of names.
    if (budget.zones.size >= MAX_TZIDS_PER_FILE) {
      budget.partial = true;
      return { type: "floating" };
    }
    const mapped = Object.hasOwn(WINDOWS_ZONES, tzid.trim()) ? WINDOWS_ZONES[tzid.trim()] : undefined;
    if (isTimeZone(tzid)) named = { type: "iana", timeZone: tzid };
    else if (mapped && isTimeZone(mapped)) named = { type: "iana", timeZone: mapped };
    else {
      // A TZID nobody can interpret (no usable VTIMEZONE, not an IANA or
      // Windows name): the time is read in the request's zone, which may be
      // wrong, so the calendar is reported as partly read.
      named = { type: "floating" };
      budget.partial = true;
    }
    budget.zones.set(tzid, named);
  }
  return named;
}

type Resolved = { kind: StoredEvent["kind"]; value: number };

/**
 * Places a wall-clock time (seconds, read as if UTC) in a zone. Asking a zone
 * for its offset is the dearest thing done per value (about 20 µs), so it is
 * charged to the budget.
 */
function resolveWall(wall: number, zone: Zone, budget: Budget): Resolved {
  if (zone.type === "file" || zone.type === "iana") budget.work -= ZONE_WORK;
  switch (zone.type) {
    case "date":
      return { kind: "allDay", value: wall };
    case "utc":
      return { kind: "instant", value: wall };
    case "file":
      return { kind: "instant", value: wall - zoneOffset(zone.zone, wall, budget) };
    case "iana":
      return { kind: "instant", value: tzidToEpoch(wall, zone.timeZone) };
    case "floating":
      return { kind: "floating", value: wall };
  }
}

const resolve = (time: Time, zone: Zone, budget: Budget): Resolved => resolveWall(wallSeconds(time), zone, budget);

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
  // Names and keywords in a rule may be written in any case.
  const rule = text.trim().toUpperCase();
  // Only what a rule is made of. ical.js would read past a backslash or a quote.
  if (rule.length > 1000 || !/^[A-Z0-9=;,+-]+$/.test(rule)) return null;
  let recur: Recur;
  try {
    recur = ICAL.Recur.fromString(rule);
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

/** The file as ical.js parses it (jCal): [name, properties, subcomponents]. */
type JProperty = [string, Record<string, unknown>, string, ...unknown[]];
type JCal = [string, JProperty[], JCal[]];

/** A moment the zone's clocks change: from local time `at` on, they are `offset` seconds ahead of UTC. */
type Transition = { at: number; offset: number };

/** One STANDARD or DAYLIGHT block: an offset and when it comes into use. */
type Observance = {
  /** DTSTART on the clock in use before the change, as wall seconds. */
  start: number;
  anchor: { year: number; month: number; day: number; dayNumber: number };
  secondsIntoDay: number;
  from: number;
  to: number;
  rules: Rule[];
};

/** A VTIMEZONE, read into our own terms. */
type FileZone = {
  observances: Observance[];
  /** Changes that happen once: each DTSTART, each RDATE, and the last ones of rules that have an UNTIL. Sorted by `at`. */
  fixed: Transition[];
  /** The offset before the first change. */
  before: number;
  /** The yearly rules' changes, by year, worked out when first needed. */
  years: Map<number, Transition[]>;
};

/** "2026-11-01T02:00:00" or "2026-11-01", as wall seconds; null for anything else. */
function wallOf(value: unknown): number | null {
  const match = typeof value === "string" ? /^(\d{4})-(\d\d)-(\d\d)(?:T(\d\d):(\d\d):(\d\d)Z?)?$/.exec(value) : null;
  if (!match) return null;
  const [year, month, day, hour, minute, second] = match.slice(1).map((part) => Number(part ?? 0)) as [number, number, number, number, number, number];
  if (year < 1000 || month < 1 || month > 12 || day < 1 || day > 31 || hour > 23 || minute > 59 || second > 60) return null;
  return Date.UTC(year, month - 1, day, hour, minute, second) / 1000;
}

/** "-05:00" or "+05:53:28", in seconds; null for anything else. */
function offsetOf(value: unknown): number | null {
  const match = typeof value === "string" ? /^([+-])(\d\d):(\d\d)(?::(\d\d))?$/.exec(value) : null;
  if (!match) return null;
  const seconds = Number(match[2]) * 3600 + Number(match[3]) * 60 + Number(match[4] ?? 0);
  return seconds <= 26 * 3600 ? (match[1] === "-" ? -seconds : seconds) : null;
}

/** The property's name as ical.js gives it, in lower case. A group, if one is left, stays part of it ("a.rrule"). */
const plainName = (property: JProperty) => String(property[0]).toLowerCase();

/** True for any name that could be meant as a repeat rule, however it is dressed. */
const looksLikeRule = (name: string) => /rrule|exrule/.test(name.replace(/[^a-z]/g, ""));

/**
 * The text of a rule property. It is text already when the line was renamed
 * before parsing; when it was not, ical.js has decoded it into parts, and
 * they are written out again. Either way it is then read by `readRule`.
 */
function ruleText(property: JProperty): string | null {
  if (property.length !== 4) return null;
  const value = property[3];
  if (typeof value === "string") return value;
  if (value === null || typeof value !== "object") return null;
  try {
    const text: unknown = ICAL.design.icalendar.value.recur.toICAL(value);
    return typeof text === "string" ? text : null;
  } catch {
    return null;
  }
}

/** The changes a rule makes in one year, on the observance's own terms. */
function ruleTransitions(observance: Observance, rule: Rule, year: number, out: Transition[]): void {
  const index = year - observance.anchor.year;
  if (index < 0) return;
  for (const day of periodAt(rule, observance.anchor, index).days) {
    if (day <= observance.anchor.dayNumber) continue;
    const on = day * DAY + observance.secondsIntoDay;
    if (rule.until) {
      // UNTIL here is normally in UTC; the change happens at `on` on the old clock.
      const limit = wallSeconds(rule.until);
      const utc = rule.until.zone === ICAL.Timezone.utcTimezone && !rule.until.isDate;
      if ((rule.until.isDate ? day * DAY : utc ? on - observance.from : on) > limit) continue;
    }
    out.push({ at: on + observance.to - observance.from, offset: observance.to });
  }
}

/**
 * Reads a VTIMEZONE from the parsed data, or returns null when it cannot be
 * used. Nothing of it is handed to ical.js.
 *
 * Supported: STANDARD and DAYLIGHT blocks with DTSTART, TZOFFSETFROM,
 * TZOFFSETTO, RDATE, and yearly RRULEs without COUNT of any shape `readRule`
 * supports. That covers what Google, Apple and Outlook write.
 */
function readZone(vtimezone: JCal): { tzid: string; zone: FileZone } | null {
  const tzidProperty = vtimezone[1].find((property) => plainName(property) === "tzid");
  const tzid = tzidProperty?.[3];
  if (typeof tzid !== "string" || tzid === "") return null;

  const observances: Observance[] = [];
  const fixed: Transition[] = [];
  let repeating = 0;
  let listed = 0;
  for (const block of vtimezone[2]) {
    if (block[0] !== "standard" && block[0] !== "daylight") continue;
    if (observances.length >= MAX_ZONE_OBSERVANCES) return null;
    let start: number | null = null;
    let from: number | null = null;
    let to: number | null = null;
    const rules: Rule[] = [];
    const dates: number[] = [];
    for (const property of block[1]) {
      const name = plainName(property);
      if (name === "dtstart") start = property[2] === "date-time" ? wallOf(property[3]) : null;
      else if (name === "tzoffsetfrom") from = offsetOf(property[3]);
      else if (name === "tzoffsetto") to = offsetOf(property[3]);
      else if (name === "rdate") {
        for (const value of property.slice(3)) {
          const wall = wallOf(value);
          if (wall !== null) dates.push(wall);
        }
      } else if (name === RULE || name === "rrule") {
        const text = ruleText(property);
        const rule = text === null ? null : readRule(text);
        // Zones change yearly. Anything else, or a rule that cannot be read, spoils the zone.
        if (!rule || rule.freq !== "YEARLY" || rule.interval !== 1 || rule.count !== null) return null;
        rules.push(rule);
      } else if (looksLikeRule(name)) {
        return null;
      }
    }
    if (start === null || from === null || to === null) return null;
    repeating += rules.length;
    listed += dates.length;
    if (repeating > MAX_ZONE_RULES || listed > MAX_ZONE_DATES) return null;

    const date = new Date(start * 1000);
    const dayOfStart = Math.floor(start / DAY);
    const observance: Observance = {
      start,
      anchor: { year: date.getUTCFullYear(), month: date.getUTCMonth() + 1, day: date.getUTCDate(), dayNumber: dayOfStart },
      secondsIntoDay: start - dayOfStart * DAY,
      from,
      to,
      rules,
    };
    observances.push(observance);
    for (const on of [start, ...dates]) fixed.push({ at: on + to - from, offset: to });
    // A rule that has ended still decides the offset until something later
    // does, however long ago its last change was.
    for (const rule of rules) {
      if (!rule.until) continue;
      const lastYear = Math.min(9999, Math.max(1000, rule.until.year));
      ruleTransitions(observance, rule, lastYear - 1, fixed);
      ruleTransitions(observance, rule, lastYear, fixed);
    }
  }
  if (observances.length === 0) return null;
  fixed.sort((a, b) => a.at - b.at);
  const first = observances.reduce((earliest, observance) => (observance.start < earliest.start ? observance : earliest));
  return { tzid, zone: { observances, fixed, before: first.from, years: new Map() } };
}

/**
 * The zone's offset from UTC, in seconds, when its clocks show `wall`.
 *
 * The latest change at or before that time decides. Candidates are the
 * one-off changes and the yearly rules' changes of that year and the year
 * before; a year's changes are worked out once (one `periodAt` per rule,
 * which is a fixed amount of arithmetic) and charged to the budget. In the
 * hour that a change skips or repeats, the later instant is the answer.
 */
function zoneOffset(zone: FileZone, wall: number, budget: Budget): number {
  let latest: Transition | null = null;
  const consider = (transitions: Transition[]) => {
    for (const transition of transitions) {
      if (transition.at <= wall && (!latest || transition.at >= latest.at)) latest = transition;
    }
  };

  // The one-off changes are sorted: find the last at or before `wall`.
  let low = 0;
  let high = zone.fixed.length;
  while (low < high) {
    const middle = (low + high) >> 1;
    if ((zone.fixed[middle] as Transition).at <= wall) low = middle + 1;
    else high = middle;
  }
  if (low > 0) latest = zone.fixed[low - 1] as Transition;

  const year = new Date(wall * 1000).getUTCFullYear();
  for (const each of [year - 1, year]) {
    let transitions = zone.years.get(each);
    if (!transitions) {
      transitions = [];
      for (const observance of zone.observances) {
        for (const rule of observance.rules) {
          budget.work -= Math.max(1, rule.byMonth.length);
          ruleTransitions(observance, rule, each, transitions);
        }
      }
      if (zone.years.size >= 16) zone.years.clear();
      zone.years.set(each, transitions);
    }
    consider(transitions);
  }
  return (latest as Transition | null)?.offset ?? zone.before;
}

// ───────────────────────── parsing ─────────────────────────

function titleOf(component: Component): string {
  const summary = component.getFirstPropertyValue("summary");
  return cleanTitle(typeof summary === "string" ? summary : "");
}

/**
 * An event title as it is answered: white space collapsed, trimmed, at most
 * 200 characters. Also used for Google Calendar events (routes/google.ts).
 */
export function cleanTitle(text: string): string {
  const title = text.replace(/\s+/g, " ").trim().slice(0, MAX_TITLE_LENGTH);
  // A copy of its own: a slice can keep the whole string it was cut from
  // alive, and the titles are kept (and a request holds every link's) after
  // the file is gone. A summary can be 2 MB.
  return Array.from(title).join("");
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

/** The parts of an event that every one of its occurrences shares. `startWall` is DTSTART on its own clock. */
type Shape = { title: string; start: Time; startWall: number; zone: Zone; kind: StoredEvent["kind"]; duration: number };

const sameZone = (a: Zone, b: Zone) =>
  a.type === b.type &&
  (a.type !== "iana" || a.timeZone === (b as typeof a).timeZone) &&
  (a.type !== "file" || a.zone === (b as typeof a).zone);

function shapeOf(component: Component, recurring: boolean, budget: Budget): Shape | null {
  const startProperty = component.getFirstProperty("dtstart");
  if (!startProperty) return null;
  const start = startProperty.getFirstValue();
  if (!(start instanceof ICAL.Time) || !plausible(start)) return null;
  const zone = zoneOf(startProperty, start, budget);
  const startWall = wallSeconds(start);
  const kind = zone.type === "date" ? "allDay" : zone.type === "floating" ? "floating" : "instant";

  let duration = 0;
  const endProperty = component.getFirstProperty("dtend");
  const durationValue = component.getFirstPropertyValue("duration");
  if (endProperty) {
    const end = endProperty.getFirstValue();
    if (end instanceof ICAL.Time && plausible(end)) {
      const endZone = zoneOf(endProperty, end, budget);
      if (kind !== "instant" || (recurring && sameZone(zone, endZone))) {
        // On one clock the length is the difference on that clock. For a
        // series this also spares two zone lookups for a DTSTART years back.
        // A DTEND of another kind than DTSTART (a date against a date-time) is not usable.
        if (sameZone(zone, endZone)) duration = wallSeconds(end) - startWall;
      } else if (endZone.type !== "date" && endZone.type !== "floating") {
        duration = resolve(end, endZone, budget).value - resolve(start, zone, budget).value;
      }
    }
  } else if (durationValue instanceof ICAL.Duration) {
    duration = durationValue.toSeconds();
  }
  if (!Number.isFinite(duration) || duration < 0) duration = 0;
  if (kind === "allDay") {
    // An all-day event covers whole days, and at least one: no DTEND, or a
    // DTEND equal to DTSTART, both mean a single day.
    duration = Math.max(DAY, Math.ceil(duration / DAY) * DAY);
  }
  return { title: titleOf(component), start, startWall, zone, kind, duration };
}

/**
 * `keepFrom` and `keepUntil` bound what is kept. `countFrom` is `now - 1 day`
 * whatever `keepBefore` is: occurrences that end after it go to `events` and
 * are counted against the caps exactly as when one day back was all that was
 * kept; earlier ones go to `earlier` and only fill room left under MAX_KEPT
 * (`parseCalendar`), so that keeping more never changes which of the others
 * are kept.
 */
type Window = { keepFrom: number; keepUntil: number; countFrom: number };

/**
 * A RECURRENCE-ID as plain values (no ical.js objects are kept), placed only
 * once the length of the events it may replace is known: an instance far back
 * can still be running when it is long.
 */
type OverrideId = { wall: number; isDate: boolean; utc: boolean; tzid: unknown };

/**
 * The instances one UID's overrides replace. `ids` is sorted by wall clock;
 * those from `placedFrom` on have been placed, and their keys are in `keys`.
 * Each is placed at most once, however many events share the UID.
 */
type Overridden = { ids: OverrideId[]; placedFrom: number; keys: Set<string> };

/** The keys of the replaced instances that could overlap the window for an event `duration` long. */
function replacedKeys(overridden: Overridden, keepFrom: number, duration: number, budget: Budget): Set<string> {
  // The same bound as for EXDATE: an instance this far back ends before the window.
  while (overridden.placedFrom > 0) {
    const id = overridden.ids[overridden.placedFrom - 1] as OverrideId;
    if (id.wall + NEAR <= keepFrom - duration) break;
    overridden.placedFrom--;
    budget.work--;
    overridden.keys.add(key(resolveWall(id.wall, zoneFor(id.isDate, id.utc, id.tzid, budget), budget)));
  }
  return overridden.keys;
}

/** What `expand` adds to. `earlier` holds at most 2 x MAX_KEPT; `earlierCut` is true once some were let go. */
type Kept = { events: StoredEvent[]; earlier: StoredEvent[]; earlierCut: boolean };

/** Cuts `earlier` to the `limit` that end latest (nearest now), if it holds more. */
function cutEarlier(kept: Kept, limit: number): void {
  if (kept.earlier.length <= limit) return;
  kept.earlier.sort((a, b) => b.end - a.end);
  kept.earlier.length = limit;
  kept.earlierCut = true;
}

/**
 * Adds one VEVENT's occurrences near the window to `kept`.
 * `overridden` holds the instances of this event's series that other VEVENTs
 * replace. `single` is true for such a replacement: it never repeats.
 */
function expand(
  component: Component,
  overridden: Overridden | undefined,
  single: boolean,
  { keepFrom, keepUntil, countFrom }: Window,
  budget: Budget,
  kept: Kept,
): void {
  // Judged on the wall clock, before any time zone work: an event or a
  // series that starts after the window, and a single event that ended before it.
  const startValue = component.getFirstPropertyValue("dtstart");
  if (startValue instanceof ICAL.Time && wallSeconds(startValue) - NEAR >= keepUntil) return;
  const ruleProperties = single ? [] : component.getAllProperties(RULE);
  const listedProperties = single ? [] : component.getAllProperties("rdate");
  const recurring = ruleProperties.length > 0 || listedProperties.length > 0;
  if (!recurring && isLongOver(component, keepFrom)) return;

  const shape = shapeOf(component, recurring, budget);
  if (!shape) {
    budget.partial = true;
    return;
  }
  const { title, zone, duration, start } = shape;

  const emit = (occurrence: Resolved) => {
    if (occurrence.value >= keepUntil || occurrence.value + duration <= keepFrom) return;
    const event: StoredEvent = { kind: occurrence.kind, title, start: occurrence.value, end: occurrence.value + duration };
    if (event.end > countFrom) {
      kept.events.push(event);
    } else {
      kept.earlier.push(event);
      if (kept.earlier.length >= 2 * MAX_KEPT) cutEarlier(kept, MAX_KEPT);
    }
  };

  if (!recurring) {
    const only = resolveWall(shape.startWall, zone, budget);
    if (!(overridden && replacedKeys(overridden, keepFrom, duration, budget).has(key(only)))) emit(only);
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
    rules.every((rule) => rule.until && wallSeconds(rule.until) + duration + NEAR < keepFrom) &&
    // DTSTART is an occurrence even when UNTIL is earlier than it.
    shape.startWall + duration + NEAR < keepFrom
  ) {
    return;
  }

  const exclusionProperties = component.getAllProperties("exdate");
  // Counted without decoding: ical.js keeps every value it decodes.
  let listed = 0;
  for (const property of [...exclusionProperties, ...listedProperties]) listed += Math.max(0, property.jCal.length - 3);
  if (listed > MAX_LISTED_DATES) {
    budget.partial = true;
    return;
  }
  budget.work -= listed;
  // Decoded before anything is placed, so that a value ical.js cannot read
  // skips the whole event rather than part of it. (ical.js keeps these on the
  // event's wrapper, which is let go once the event is read.)
  for (const property of [...exclusionProperties, ...listedProperties]) property.getValues();

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
      else excluded.add(key(resolve(value, zoneOf(property, value, budget), budget)));
    }
  }

  const replaced = overridden && replacedKeys(overridden, keepFrom, duration, budget);
  const seen = new Set<string>();
  /** Adds an occurrence unless it was already added, is excluded, or is replaced by an override. */
  const offer = (occurrence: Resolved, wall: number) => {
    const id = key(occurrence);
    if (seen.has(id)) return;
    seen.add(id);
    if (excluded.has(id) || replaced?.has(id) || excludedDays.has(Math.floor(wall / DAY))) return;
    emit(occurrence);
  };

  // DTSTART is always an occurrence. It is placed only if it can be in the window.
  const startWall = shape.startWall;
  if (startWall + duration + NEAR > keepFrom) offer(resolveWall(startWall, zone, budget), startWall);

  for (const property of listedProperties) {
    for (const value of property.getValues()) {
      // An implausible year, or a date listed for a timed event, is not used;
      // nor would a period be, though none is handed to ical.js (`holdsPeriod`).
      if (!(value instanceof ICAL.Time) || !plausible(value)) continue;
      const wall = wallSeconds(value);
      if (wall + NEAR <= keepFrom - duration || wall - NEAR >= keepUntil) continue;
      const occurrence = resolve(value, zoneOf(property, value, budget), budget);
      if (occurrence.kind === shape.kind) offer(occurrence, wall);
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
      if (budget.work <= 0 || kept.events.length >= 4 * MAX_KEPT) {
        budget.partial = true;
        return false;
      }
      budget.work--;
      const wall = day * DAY + secondsIntoDay;
      const occurrence = resolveWall(wall, zone, budget);
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

/** The properties of a VEVENT this file reads, and the value types each may have. */
const EVENT_PROPERTIES: Readonly<Record<string, readonly string[]>> = {
  uid: ["text"],
  summary: ["text"],
  status: ["text"],
  dtstart: ["date-time", "date"],
  dtend: ["date-time", "date"],
  duration: ["duration"],
  "recurrence-id": ["date-time", "date"],
  exdate: ["date-time", "date"],
  rdate: ["date-time", "date"],
};

/** The properties of a VEVENT read once: ical.js is given the first of each, which is the one read. */
const EVENT_SINGLE = new Set(["UID", "SUMMARY", "STATUS", "DTSTART", "DTEND", "DURATION", "RECURRENCE-ID"]);
/** The properties of a STANDARD or DAYLIGHT block read once: `readZone` takes the last of each, so that is the one given. */
const BLOCK_SINGLE = new Set(["DTSTART", "TZOFFSETFROM", "TZOFFSETTO"]);
/** Every property name a reader here uses, wherever it stands. */
const READ_ANYWHERE = new Set([...EVENT_SINGLE, ...BLOCK_SINGLE, "EXDATE", "RDATE", "TZID", "RRULE", "EXRULE"]);

/**
 * A TZID or RANGE value in a form that ical.js reads exactly as it is
 * written here, so that where it ends, and so where the property's value
 * begins, is not in doubt: in quotes with no quote or backslash inside, or
 * bare with no quote, semicolon, colon or backslash. Outlook's quoted names
 * with colons in them, `"(UTC-06:00) Central Time (US & Canada)"`, pass.
 * - A quote: ical.js opens a quoted value only right after `=`, and a quote
 *   anywhere else in a value is an ordinary character to it.
 * - A backslash: ical.js unescapes a parameter as text and then looks for the
 *   property's value from the parameter's start plus its unescaped length, so
 *   each `\,` in the last parameter moves that search one character back,
 *   which can be onto a colon inside the quotes.
 * - A caret (RFC 6868) is allowed: ical.js decodes those and corrects the
 *   position for them.
 */
const HANDED_PARAMETER = /^(?:"[^"\\]*"|[^";:\\]*)$/;
/** Longest parameter handed on, its name and `=` included. */
const MAX_PARAMETER_LENGTH = 300;

type Scanned = {
  /** Where the value begins. */
  value: number;
  /**
   * The parameters handed to ical.js, rebuilt: the last TZID and RANGE when
   * they pass `HANDED_PARAMETER`, and the last VALUE that names a date or a
   * date-time, as `;TZID=…;RANGE=…;VALUE=…`. Nothing else of the original
   * parameters is passed on.
   */
  parameters: string;
  /** The line had a TZID that is not handed on, because of its form or length. */
  unreadTzid: boolean;
};

/**
 * Where a line's value begins, and the parameters to hand on with it. `at` is
 * the index of the `;` or `:` that ends the name. Returns null when the line
 * has no value. One pass, whatever the number of parameters, and nothing kept
 * per parameter.
 *
 * A parameter is its name, `=`, and a value of items split by commas, each in
 * quotes or bare (RFC 5545); a quote opens only at the start of an item, and
 * is an ordinary character anywhere else. A parameter without `=` is passed
 * over. ical.js reads the original line in its own way in places (a quote
 * after a comma, a parameter without `=`), but it never sees the original:
 * it is given the line rebuilt from the name, `parameters` and the value, in
 * which it cannot read the parameters as ending anywhere else.
 */
function scanParameters(line: string, at: number): Scanned | null {
  if (line[at] === ":") return { value: at + 1, parameters: "", unreadTzid: false };
  /** Where the last TZID and RANGE values start and end, and the last date-typed VALUE. */
  let tzidFrom = -1;
  let tzidTo = -1;
  let rangeFrom = -1;
  let rangeTo = -1;
  let valueType = "";
  const end = line.length;
  for (let from = at + 1; ; ) {
    let i = from;
    while (i < end && line[i] !== "=" && line[i] !== ";" && line[i] !== ":") i++;
    if (i >= end) return null;
    if (line[i] !== "=") {
      // A parameter without a value.
      if (line[i] === ":") return built(i + 1);
      from = i + 1;
      continue;
    }
    const nameEnd = i++;
    for (;;) {
      if (line[i] === '"') {
        const close = line.indexOf('"', i + 1);
        if (close < 0) return null;
        i = close + 1;
      }
      while (i < end && line[i] !== "," && line[i] !== ";" && line[i] !== ":") i++;
      if (line[i] !== ",") break;
      i++;
    }
    if (i >= end) return null;
    const nameLength = nameEnd - from;
    if (nameLength === 4 || nameLength === 5) {
      const name = line.slice(from, nameEnd).toUpperCase();
      if (name === "TZID") {
        tzidFrom = nameEnd + 1;
        tzidTo = i;
      } else if (name === "RANGE") {
        rangeFrom = nameEnd + 1;
        rangeTo = i;
      } else if (name === "VALUE" && i - nameEnd <= 12) {
        // VALUE is handed on only when it names a date or a date-time. Told
        // that a value is a rule or a period, ical.js decodes it while parsing
        // and rejects the whole file if it is malformed.
        const type = line.slice(nameEnd + 1, i).toUpperCase();
        if (/^(?:DATE|DATE-TIME|"DATE"|"DATE-TIME")$/.test(type)) valueType = type.replaceAll('"', "");
      }
    }
    if (line[i] === ":") return built(i + 1);
    from = i + 1;
  }

  function built(value: number): Scanned {
    let parameters = "";
    let unreadTzid = false;
    if (tzidFrom >= 0) {
      const text = line.slice(tzidFrom, tzidTo);
      if (text.length <= MAX_PARAMETER_LENGTH - 5 && HANDED_PARAMETER.test(text)) parameters += `;TZID=${text}`;
      else unreadTzid = true;
    }
    // Nothing reads RANGE (an override changes only its own instance), so one
    // that is not handed on is not reported.
    if (rangeFrom >= 0) {
      const text = line.slice(rangeFrom, rangeTo);
      if (text.length <= MAX_PARAMETER_LENGTH - 6 && HANDED_PARAMETER.test(text)) parameters += `;RANGE=${text}`;
    }
    if (valueType) parameters += `;VALUE=${valueType}`;
    return { value, parameters, unreadTzid };
  }
}

/**
 * How many values ical.js makes of a list such as EXDATE's: it splits at each
 * comma that does not come right after a backslash (`unescapedIndexOf`; so
 * `\,` does not split, and neither does `\\,`). Counted on the very text that
 * is handed on.
 */
function valueCount(value: string): number {
  let count = 1;
  for (let at = value.indexOf(","); at >= 0; at = value.indexOf(",", at + 1)) {
    if (at === 0 || value.charCodeAt(at - 1) !== 92) count++;
  }
  return count;
}

/**
 * Whether a line is an RDATE that ical.js would read as periods. Its
 * `detectType` for RDATE looks at the whole value, before it is split at
 * commas, and makes every value of the line a period when a "/" is anywhere
 * in it, whatever VALUE says. A period keeps every piece between slashes
 * (`period.fromICAL` splits at each "/" and keeps them all), so one value to
 * `valueCount` can be any number of pieces: 2 MB of slashes is a million. And
 * a value in the list without a "/" makes it throw, which refuses the whole
 * file. Periods are not used here, so such a line is not handed on at all, in
 * an event or in a zone's block, and sets `partial` (task 22). Tested on the
 * very value handed on, so a "/" in a TZID does not count.
 */
const holdsPeriod = (name: string, value: string) => name === "RDATE" && value.includes("/");

/** A line's property name as read here: upper case, trimmed, a group ("a.DTSTART") dropped. `at` is where the name ends. */
function propertyName(line: string, at: number): string {
  const name = line.slice(0, at).trim().toUpperCase();
  const dot = name.indexOf(".");
  return dot >= 0 && /^[A-Z0-9-]+$/.test(name.slice(0, dot)) ? name.slice(dot + 1) : name;
}

/** The line handed to ical.js for a property kept as it is: rebuilt from its name, the parameters handed on and its value. */
const rebuilt = (name: string, scanned: Scanned, value: string) => `${name}${scanned.parameters}:${value}`;

/**
 * What `readableLines` hands ical.js for a property line it keeps as it is
 * (the properties read once, EXDATE, RDATE, a zone's TZID), how many EXDATE
 * or RDATE values ical.js makes of that, and whether a TZID was left out;
 * also the name and value as read here. `text` is null, and `listed` 0, for
 * an RDATE holding a period, which is not handed on (`holdsPeriod`). Null for
 * a line that is not a property. For the tests.
 */
export function handedLine(line: string): { name: string; value: string; text: string | null; listed: number; unreadTzid: boolean } | null {
  const at = line.search(/[;:]/);
  const scanned = at < 0 ? null : scanParameters(line, at);
  if (!scanned) return null;
  const name = propertyName(line, at);
  const value = line.slice(scanned.value);
  if (holdsPeriod(name, value)) return { name, value, text: null, listed: 0, unreadTzid: scanned.unreadTzid };
  return { name, value, text: rebuilt(name, scanned, value), listed: valueCount(value), unreadTzid: scanned.unreadTzid };
}

/** A VEVENT or VTIMEZONE being read. Its lines are held until its END decides whether ical.js is given them. */
type Pending = {
  kind: "event" | "zone";
  lines: string[];
  /** Names of the properties read once that it has given already. */
  seen: Set<string>;
  rules: number;
  listed: number;
  observances: number;
  /** The STANDARD or DAYLIGHT block being read, in a zone: its name, its last DTSTART, TZOFFSETFROM and TZOFFSETTO, and its rules and dates. */
  block: { name: string; last: Map<string, string>; lines: string[] } | null;
  /** Over a limit: none of it is given to ical.js. */
  dropped: boolean;
};

const pending = (kind: Pending["kind"]): Pending => ({
  kind,
  lines: [kind === "event" ? "BEGIN:VEVENT" : "BEGIN:VTIMEZONE"],
  seen: new Set(),
  rules: 0,
  listed: 0,
  observances: 0,
  block: null,
  dropped: false,
});

/**
 * Reduces an unfolded file to what this reader uses, in one pass and before
 * ical.js sees any of it: the VCALENDARs, each VEVENT and VTIMEZONE directly
 * inside one with the properties `cleanEvent` and `readZone` read, and repeat
 * rules, renamed so that ical.js keeps their text as it is. Every line handed
 * on is rebuilt from its name, the parameters `scanParameters` vets (TZID,
 * RANGE, a date-typed VALUE) and its value, so that ical.js finds the value
 * where it is found here, and the listed dates are counted on that value as
 * ical.js splits it (`valueCount`). A TZID that is not handed on sets
 * `partial` in an event.
 *
 * What ical.js is given is bounded here, since it builds its whole tree at
 * once and memory cannot be charged to a budget as it goes:
 * - a file of more than MAX_EVENTS_PER_FILE events, or that would give ical.js
 *   more than MAX_LINES_PER_FILE lines or MAX_LISTED_PER_FILE listed dates,
 *   is refused (`CalendarTooLargeError`);
 * - an event with more than MAX_RULES_PER_EVENT rules or MAX_LISTED_DATES
 *   listed dates is left out, and sets `partial`;
 * - an RDATE line whose value holds a "/" (periods, to ical.js, of any number
 *   of pieces; `holdsPeriod`) is left out, in an event or a zone's block, and
 *   sets `partial`; the rest of the event or zone is read;
 * - a property read once is given once: the first in an event, the last in a
 *   zone's block, as they are read;
 * - nothing inside an event (alarms), inside an unknown component, or at the
 *   calendar's own level is given; it is only counted, to find where it ends.
 *   A VEVENT or VTIMEZONE in there is not read and sets `partial`;
 * - a VTIMEZONE that `readZone` would not use for its size (more than
 *   MAX_ZONE_OBSERVANCES blocks, MAX_ZONE_RULES rules or MAX_ZONE_DATES listed
 *   dates, or a rule under another name) is not given, nor are zones after
 *   MAX_ZONE_COMPONENTS;
 * - calendars after MAX_CALENDARS_PER_FILE are not read, and set `partial`.
 *
 * Components are matched as ical.js matches them: by count, END closing
 * whatever is open; one left open, or an END with nothing open, refuses the
 * file. Sets `partial` for a line that is not a property at all, or a line in
 * an event that looks like a rule under a name that is not one.
 *
 * The limits are for memory. The other reductions are for robustness and
 * speed, not safety (that is `cleanEvent` and `readZone`): ical.js rejects a
 * whole file for one value it cannot decode and takes seconds over a line
 * with 200,000 parameters, and the lines that could do either are not given
 * to it.
 */
function readableLines(unfolded: string, budget: Budget): string {
  const out: string[] = [];
  let given = 0;
  let events = 0;
  let listed = 0;
  let zones = 0;
  let calendars = 0;
  /** 0 outside any calendar, 1 in a VCALENDAR, 2 in a VEVENT or VTIMEZONE, 3 in a zone's block. */
  let depth = 0;
  /** How deep inside a component that is not read; 0 when not in one. */
  let skipping = 0;
  let item: Pending | null = null;

  const give = (lines: string[]) => {
    given += lines.length;
    if (given > MAX_LINES_PER_FILE) throw new CalendarTooLargeError("too many lines");
    for (const line of lines) out.push(line);
  };
  const drop = (pending: Pending) => {
    pending.dropped = true;
    pending.lines = [];
    pending.block = null;
  };

  // Lines end at CRLF, CR or LF. The text is walked, not split: a file of
  // short lines would otherwise be a list of hundreds of thousands of strings.
  const lineEnd = /\r\n?|\n/g;
  for (let from = 0; from < unfolded.length; ) {
    lineEnd.lastIndex = from;
    const found = lineEnd.exec(unfolded);
    const line = unfolded.slice(from, found ? found.index : unfolded.length);
    from = found ? found.index + found[0].length : unfolded.length;

    if (line.trim() === "") continue;
    const at = line.search(/[;:]/);
    const scanned = at < 0 ? null : scanParameters(line, at);
    if (!scanned) {
      budget.partial = true;
      continue;
    }
    const name = propertyName(line, at);
    const value = line.slice(scanned.value);

    if (name === "BEGIN") {
      // ical.js names a component by the value in lower case, untrimmed.
      const component = value.toLowerCase();
      const read = component === "vevent" || component === "vtimezone";
      if (skipping > 0) {
        skipping++;
        if (read) budget.partial = true;
      } else if (depth === 0) {
        if (component !== "vcalendar") throw new CalendarParseError("not a calendar");
        if (++calendars > MAX_CALENDARS_PER_FILE) {
          budget.partial = true;
          skipping = 1;
        } else {
          give(["BEGIN:VCALENDAR"]);
          depth = 1;
        }
      } else if (depth === 1 && component === "vevent") {
        if (++events > MAX_EVENTS_PER_FILE) throw new CalendarTooLargeError("too many events");
        item = pending("event");
        depth = 2;
      } else if (depth === 1 && component === "vtimezone" && zones < MAX_ZONE_COMPONENTS) {
        item = pending("zone");
        depth = 2;
      } else if (depth === 2 && item?.kind === "zone" && (component === "standard" || component === "daylight")) {
        if (!item.dropped && ++item.observances > MAX_ZONE_OBSERVANCES) drop(item);
        if (!item.dropped) item.block = { name: component.toUpperCase(), last: new Map(), lines: [] };
        depth = 3;
      } else {
        // An alarm, a to-do, anything unknown, a zone past the limit, or an
        // event or zone inside an event or a zone: counted, not read.
        skipping = 1;
        if (read && depth > 1) budget.partial = true;
      }
      continue;
    }

    if (name === "END") {
      if (skipping > 0) skipping--;
      else if (depth === 0) {
        // An END with nothing open: ical.js lets one at the end of a file pass.
      } else if (depth === 1) {
        give(["END:VCALENDAR"]);
        depth = 0;
      } else if (depth === 2) {
        const done = item as Pending;
        if (done.dropped) {
          if (done.kind === "event") budget.partial = true;
        } else {
          listed += done.listed;
          if (listed > MAX_LISTED_PER_FILE) throw new CalendarTooLargeError("too many listed dates");
          if (done.kind === "zone") zones++;
          done.lines.push(done.kind === "event" ? "END:VEVENT" : "END:VTIMEZONE");
          give(done.lines);
        }
        item = null;
        depth = 1;
      } else {
        const zone = item as Pending;
        if (zone.block) zone.lines.push(`BEGIN:${zone.block.name}`, ...zone.block.last.values(), ...zone.block.lines, `END:${zone.block.name}`);
        zone.block = null;
        depth = 2;
      }
      continue;
    }

    if (skipping > 0 || depth === 1) continue;
    const kept = () => rebuilt(name, scanned, value);
    /** In an event, a line handed on without the TZID it had may be read at the wrong time. (`readZone` reads no parameter but VALUE.) */
    const keptInEvent = () => {
      if (scanned.unreadTzid) budget.partial = true;
      return kept();
    };
    if (depth === 0) {
      // ical.js fails on a property outside any component.
      if (READ_ANYWHERE.has(name) || looksLikeRule(name.toLowerCase())) throw new CalendarParseError("not a calendar");
      continue;
    }
    const current = item as Pending;
    if (current.dropped) continue;

    if (current.kind === "event") {
      if (name === "RRULE" || name === "EXRULE") {
        if (++current.rules > MAX_RULES_PER_EVENT) drop(current);
        else current.lines.push(`X-SEASIGN-${name}:${value}`);
      } else if (holdsPeriod(name, value)) {
        // Not handed on, so not counted either.
        budget.partial = true;
      } else if (name === "EXDATE" || name === "RDATE") {
        current.listed += valueCount(value);
        if (current.listed > MAX_LISTED_DATES) drop(current);
        else current.lines.push(keptInEvent());
      } else if (EVENT_SINGLE.has(name)) {
        if (!current.seen.has(name)) {
          current.seen.add(name);
          current.lines.push(keptInEvent());
        }
      } else if (looksLikeRule(name.toLowerCase())) {
        // Something meant as a rule under a name no parser would take for one.
        budget.partial = true;
      }
    } else if (depth === 2) {
      // A zone reads only its first TZID at its own level.
      if (name === "TZID" && !current.seen.has(name)) {
        current.seen.add(name);
        current.lines.push(kept());
      }
    } else {
      const block = current.block as NonNullable<Pending["block"]>;
      if (BLOCK_SINGLE.has(name)) block.last.set(name, kept());
      else if (name === "RRULE") {
        if (++current.rules > MAX_ZONE_RULES) drop(current);
        else block.lines.push(`X-SEASIGN-RRULE:${value}`);
      } else if (holdsPeriod(name, value)) {
        // `readZone` would not use it, and it is neither handed on nor counted.
        budget.partial = true;
      } else if (name === "RDATE") {
        current.listed += valueCount(value);
        if (current.listed > MAX_ZONE_DATES) drop(current);
        else block.lines.push(kept());
      } else if (looksLikeRule(name.toLowerCase())) {
        // EXRULE, or a rule under another name: `readZone` would not use the zone.
        drop(current);
      }
    }
  }
  if (depth > 0 || skipping > 0) throw new CalendarParseError("not a calendar");
  return out.join("\n");
}

/**
 * Builds the VEVENT that ical.js is given: the listed properties, when they
 * have a listed value type, and the event's rules as plain text under names
 * ical.js has no meaning for. Everything else is left behind, alarms and any
 * other nested component included.
 *
 * This is what keeps a rule from reaching ical.js as a rule. It does not
 * matter how the line was written (case, folding, a group, parameters, a
 * `VALUE=RECUR` on another property): whatever ical.js made of it, only these
 * names with these types are copied, and none of the types is a rule.
 */
function cleanEvent(vevent: JCal, budget: Budget): JCal {
  const properties: JProperty[] = [];
  for (const property of vevent[1]) {
    const name = plainName(property);
    const types = Object.hasOwn(EVENT_PROPERTIES, name) ? EVENT_PROPERTIES[name] : undefined;
    if (types) {
      if (types.includes(property[2])) properties.push(property);
      // A property we read, in a form we do not: the event may be shown wrongly.
      else budget.partial = true;
    } else if (name === RULE || name === "rrule") {
      // An unreadable rule becomes an empty one, and the event is skipped for it.
      properties.push([RULE, {}, "unknown", ruleText(property) ?? ""]);
    } else if (name === EXCLUSION_RULE || name === "exrule") {
      properties.push([EXCLUSION_RULE, {}, "unknown", ""]);
    } else if (looksLikeRule(name)) {
      // Something meant as a rule under a name no parser would take for one.
      budget.partial = true;
    }
  }
  return ["vevent", properties, []];
}

/**
 * Parses the text of an .ics file and returns the occurrences near `now`:
 * those that end after `now - keepBefore` (seconds; one day unless given)
 * and start before `now + 8 days`. Those that end after `now - 1 day` are
 * kept and cut to MAX_KEPT exactly as when one day back was the whole window;
 * any from further back only fill the room left, the latest first (`partial`
 * when some do not fit), so a wider window never pushes out a later event.
 * Throws `CalendarParseError` when the text is not a calendar, and its
 * subclass `CalendarTooLargeError` when it is longer than MAX_CALENDAR_BYTES
 * characters or holds more than `readableLines` gives ical.js.
 *
 * Each of these leaves the calendar usable and sets `partial`:
 * - an event that cannot be read, or whose RRULE is malformed or is not a
 *   shape `readRule` supports, is skipped;
 * - an event listing more than 2,000 EXDATE and RDATE values, or with more
 *   than 8 repeat rules, is skipped;
 * - reading stops once the file has used its work budget (`MAX_WORK_PER_FILE`);
 * - at most 500 occurrences are kept;
 * - past 50 distinct TZIDs without a VTIMEZONE, times are read as floating;
 * - a VEVENT or VTIMEZONE inside another component is not read;
 * - calendars after the first 20 in one file are not read;
 * - a line that is not a property (no colon) is left out;
 * - an RDATE line holding a period ("/") is left out, its other values with
 *   it; an event that repeated only by such a line is read as a single event;
 * - a TZID parameter not handed to ical.js (it holds a quote or a backslash,
 *   or is over 300 characters) leaves that time floating.
 * A VTIMEZONE that `readZone` cannot use is ignored (and so are those past 50
 * in one file); times that name it fall back to the IANA zone of the same
 * name, or to floating. A file may hold several VCALENDARs.
 * `RANGE=THISANDFUTURE` on a RECURRENCE-ID is not applied: such an override
 * changes only its own instance.
 */
export function parseCalendar(text: string, now: Date, keepBefore: number = KEEP_BEFORE): ParsedCalendar {
  if (text.length > MAX_CALENDAR_BYTES) throw new CalendarTooLargeError("too large");
  // Folded lines are joined first, so that everything after this sees whole
  // lines. ical.js is given what `readableLines` makes of this text and has
  // no folds left to undo in a way of its own.
  const body = text
    .replace(/^\uFEFF/, "")
    .trimStart()
    .replace(/(?:\r\n|\r|\n)[ \t]/g, "");
  if (!/^BEGIN:VCALENDAR/i.test(body)) throw new CalendarParseError("not a calendar");

  const budget: Budget = { work: MAX_WORK_PER_FILE, partial: false, zones: new Map(), fileZones: new Map() };

  // Outside the `try`: a file over a limit is refused as too large.
  const readable = readableLines(body, budget);
  let calendars: JCal[];
  try {
    const result = ICAL.parse(readable) as JCal | JCal[];
    // A file holding several calendars comes back as a list.
    calendars = (Array.isArray(result[0]) ? result : [result]) as JCal[];
  } catch {
    // The parser's message can quote a line of the file; it is not passed on.
    throw new CalendarParseError("not a calendar");
  }
  const well = (component: unknown): component is JCal =>
    Array.isArray(component) && typeof component[0] === "string" && Array.isArray(component[1]) && Array.isArray(component[2]);
  if (calendars.length === 0 || !calendars.every((calendar) => well(calendar) && calendar[0] === "vcalendar")) {
    throw new CalendarParseError("not a calendar");
  }

  if (calendars.length > MAX_CALENDARS_PER_FILE) {
    calendars.length = MAX_CALENDARS_PER_FILE;
    budget.partial = true;
  }

  // One pass over the parsed data. Time zone definitions are read into our
  // own form; events are rebuilt from the properties we read. ical.js gets
  // the rebuilt events and nothing else. (`readableLines` gave it nothing
  // nested, so a calendar's children are its events and zones.)
  const eventData: JCal[] = [];
  for (const calendar of calendars) {
    for (const component of calendar[2]) {
      if (component[0] === "vevent") {
        eventData.push(cleanEvent(component, budget));
      } else if (component[0] === "vtimezone") {
        if (budget.fileZones.size >= MAX_ZONES_PER_FILE) continue;
        let read: ReturnType<typeof readZone> = null;
        try {
          read = readZone(component);
        } catch {
          read = null;
        }
        // The first definition of a name stands.
        if (read && !budget.fileZones.has(read.tzid)) budget.fileZones.set(read.tzid, read.zone);
      }
    }
  }
  calendars.length = 0;

  // Each event is wrapped in an ical.js component of its own when it is read,
  // with no parent, and the wrapper is let go afterwards: ical.js keeps every
  // property and value it decodes on the wrapper, which would otherwise hold
  // them all until the end. Without a parent there is also no calendar to
  // search for a VTIMEZONE: ical.js does that for every time with a TZID, and
  // with 30,000 events beside each other that search alone took 8 seconds.
  const wrap = (data: JCal) => new ICAL.Component(data);

  const nowSeconds = Math.floor(now.getTime() / 1000);
  const window: Window = {
    keepFrom: nowSeconds - keepBefore,
    keepUntil: nowSeconds + KEEP_AFTER,
    countFrom: nowSeconds - Math.min(keepBefore, KEEP_BEFORE),
  };

  // A repeating event and the VEVENTs that override single instances of it
  // share a UID; the overrides carry a RECURRENCE-ID.
  const masters: JCal[] = [];
  const overrides: JCal[] = [];
  const overridden = new Map<string, Overridden>();
  for (const data of eventData) {
    try {
      const vevent = wrap(data);
      const idProperty = vevent.getFirstProperty("recurrence-id");
      if (!idProperty) {
        masters.push(data);
        continue;
      }
      overrides.push(data);
      const uid = vevent.getFirstPropertyValue("uid");
      const id = idProperty.getFirstValue();
      if (typeof uid === "string" && id instanceof ICAL.Time) {
        // An instance that starts after the window never needs suppressing.
        // One that starts long before it may still be running, if the event
        // is long: that is decided in `expand`, which knows the length.
        const wall = wallSeconds(id);
        if (wall - NEAR >= window.keepUntil) continue;
        let entry = overridden.get(uid);
        if (!entry) overridden.set(uid, (entry = { ids: [], placedFrom: 0, keys: new Set() }));
        entry.ids.push({ wall, isDate: id.isDate, utc: id.zone === ICAL.Timezone.utcTimezone, tzid: idProperty.getParameter("tzid") });
      }
    } catch {
      budget.partial = true;
    }
  }
  for (const entry of overridden.values()) {
    entry.ids.sort((a, b) => a.wall - b.wall);
    entry.placedFrom = entry.ids.length;
  }

  const kept: Kept = { events: [], earlier: [], earlierCut: false };
  const { events, earlier } = kept;
  const each = (data: JCal, single: boolean) => {
    // Far more occurrences in the window than will be kept: stop reading.
    if (budget.work <= 0 || events.length >= 4 * MAX_KEPT) {
      budget.partial = true;
      return;
    }
    budget.work--;
    try {
      const component = wrap(data);
      if (isCancelled(component)) return;
      const uid = single ? undefined : component.getFirstPropertyValue("uid");
      // A cancelled override is still in `overridden`, so its instance is
      // removed, not handed back to the series.
      expand(component, typeof uid === "string" ? overridden.get(uid) : undefined, single, window, budget, kept);
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
  // Room left under the cap goes to the occurrences from before one day back
  // that end latest. They are only ever answered to a `day` request, so a
  // plain answer is what it was when they were not kept at all.
  if (earlier.length > 0) {
    cutEarlier(kept, MAX_KEPT - events.length);
    if (kept.earlierCut) budget.partial = true;
    // A stable sort: the others stay in the order they had.
    events.push(...earlier);
    events.sort((a, b) => a.start - b.start);
  }
  return { events, partial: budget.partial };
}

// ───────────────────────── answering a request ─────────────────────────

const instant = (epoch: number) => new Date(epoch * 1000).toISOString().replace(/\.\d{3}Z$/, "Z");

/**
 * One stored occurrence as it is answered, with floating and all-day times
 * placed in `timeZone` (which must pass `isTimeZone`). No window is applied:
 * `upcomingEvents` and `dayEvents` choose which to place; the create route
 * (routes/google-create.ts) places the one event Google echoes back.
 */
export function placeEvent(event: StoredEvent, timeZone: string): UpcomingEvent {
  const placed = event.kind !== "instant";
  const start = placed ? wallToEpoch(event.start, timeZone) : event.start;
  const end = placed ? wallToEpoch(event.end, timeZone) : event.end;
  return {
    title: event.title,
    start: instant(start),
    end: instant(end),
    allDay: event.kind === "allDay",
    ...(event.kind === "allDay" ? { date: instant(event.start).slice(0, 10) } : {}),
  };
}

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
    upcoming.push(placeEvent(event, timeZone));
  }
  return upcoming;
}

// ───────────────────────── one day ─────────────────────────

/** Days a `day` request may name: today in the request's zone and the six after it, the seven days `upcomingEvents` looks at. */
export const DAY_REQUEST_DAYS = UPCOMING_DAYS;

const DAY_TEXT = /^(\d{4})-(\d{2})-(\d{2})$/;

/** Wall-clock seconds of midnight at the start of a YYYY-MM-DD date, or null when it is not a real date. */
export function dayWall(text: string): number | null {
  const match = DAY_TEXT.exec(text);
  if (!match) return null;
  const [year, month, day] = [Number(match[1]), Number(match[2]), Number(match[3])];
  const ms = Date.UTC(year, month - 1, day);
  const back = new Date(ms);
  // 2026-02-30 is not a date.
  if (year < 1000 || back.getUTCFullYear() !== year || back.getUTCMonth() !== month - 1 || back.getUTCDate() !== day) return null;
  return ms / 1000;
}

/** True for text of the form YYYY-MM-DD that is a real date. For the request schemas. */
export const isDayText = (text: string) => dayWall(text) !== null;

/**
 * The wall-clock midnight (seconds) of `day` when it is today in `timeZone`
 * or one of the six days after, else null. `timeZone` must pass `isTimeZone`.
 */
export function dayInRange(day: string, now: Date, timeZone: string): number | null {
  const wall = dayWall(day);
  if (wall === null) return null;
  const nowSeconds = Math.floor(now.getTime() / 1000);
  const today = Math.floor((nowSeconds + offsetAt(nowSeconds, timeZone)) / DAY) * DAY;
  return wall >= today && wall < today + DAY_REQUEST_DAYS * DAY ? wall : null;
}

/**
 * The instants at which a day begins and ends in a zone: midnight to the next
 * midnight on its clocks, so 23 or 25 hours on a day the clocks change.
 */
export function dayBounds(wall: number, timeZone: string): { from: number; to: number } {
  // A date begins at its midnight or, where the clocks jump over midnight
  // (America/Santiago on 2026-09-06, America/Havana on 2026-03-08), at the
  // moment they jump, which is where `wallToEpoch` places a skipped time.
  return { from: wallToEpoch(wall, timeZone), to: wallToEpoch(wall + DAY, timeZone) };
}

/**
 * Whether a stored occurrence overlaps a day (`wall`, its midnight as
 * wall-clock seconds) in `timeZone`, which must pass `isTimeZone`. An
 * occurrence overlaps when it starts before the day ends and ends after it
 * begins, so one that ends at the day's first midnight belongs to the day
 * before; one without a length belongs to the day it starts on. Instants are
 * compared with `dayBounds`; floating and all-day times by their own wall
 * clock, so that each lands on the date it names even where the clocks skip
 * its hour.
 */
export function overlapsDay(wall: number, timeZone: string): (event: StoredEvent) => boolean {
  const { from, to } = dayBounds(wall, timeZone);
  return (event) => {
    const [dayFrom, dayTo] = event.kind === "instant" ? [from, to] : [wall, wall + DAY];
    if (event.start >= dayTo) return false;
    return event.end === event.start ? event.start >= dayFrom : event.end > dayFrom;
  };
}

/**
 * The stored occurrences that overlap one day in `timeZone` (which must pass
 * `isTimeZone`; `overlapsDay` says which), ended ones included, placed as
 * `upcomingEvents` places them. `wall` is the day's midnight as wall-clock
 * seconds (`dayWall`). Unsorted.
 */
export function dayEvents(stored: StoredEvent[], wall: number, timeZone: string): UpcomingEvent[] {
  const overlaps = overlapsDay(wall, timeZone);
  const found: UpcomingEvent[] = [];
  for (const event of stored) {
    if (overlaps(event)) found.push(placeEvent(event, timeZone));
  }
  return found;
}
