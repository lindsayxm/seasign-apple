// Reading an iCalendar (.ics) file for /v1/calendar/events.
//
// `parseCalendar` turns the text of a calendar into a compact list of the
// occurrences that fall near "now": repeating events expanded, EXDATEs and
// RECURRENCE-ID overrides applied, cancelled events dropped. That list is what
// gets cached. `upcomingEvents` then answers one request from it: it places
// floating and all-day times in the caller's time zone and keeps the next
// seven days.
//
// The file comes from an arbitrary URL, so everything here is bounded: rules
// that can make ical.js spin are refused before they are iterated, and the
// number of recurrence steps per event and per file is capped.
//
// Nothing here imports `cloudflare:*`, so the spec writer can load it in Node.
import ICAL from "ical.js";

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
 * Recurrence work allowed for one file, in units of roughly 10 µs of CPU (one
 * step of a plain daily rule). `stepCost` prices the slower rules, so a
 * hostile file costs about a second at worst.
 */
const MAX_WORK_PER_FILE = 100_000;
/** Occurrences kept per calendar; a nine-day window with more than this is not a personal calendar. */
const MAX_KEPT = 500;
const MAX_TITLE_LENGTH = 200;
/** EXDATE and RDATE values one event may list. ical.js sorts them by insertion, which is quadratic. */
const MAX_LISTED_DATES = 2000;
/** Limits on one VTIMEZONE, and on the repeating observances of all of a file's zones together. */
const MAX_ZONE_OBSERVANCES = 60;
const MAX_ZONE_RULES = 12;
const MAX_ZONE_DATES = 400;
const MAX_ZONE_RULES_PER_FILE = 40;
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
  /** True when a cap was reached or an event was skipped as unsafe or unreadable. */
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
  /** No VTIMEZONE, but the TZID is an IANA name the runtime knows. */
  | { type: "iana"; timeZone: string }
  /** No zone at all, or a TZID nobody can interpret: the request's time zone decides. */
  | { type: "floating" };

function zoneOf(property: Property, time: Time): Zone {
  if (time.isDate) return { type: "date" };
  const zone = time.zone;
  if (zone === ICAL.Timezone.utcTimezone) return { type: "utc" };
  if (zone && zone !== ICAL.Timezone.localTimezone && zone.component) return { type: "file", zone };
  const tzid = property.getParameter("tzid");
  if (typeof tzid === "string" && isTimeZone(tzid)) return { type: "iana", timeZone: tzid };
  return { type: "floating" };
}

type Resolved = { kind: StoredEvent["kind"]; value: number };

function resolve(time: Time, zone: Zone): Resolved {
  const wall = wallSeconds(time);
  switch (zone.type) {
    case "date":
      return { kind: "allDay", value: wall };
    case "utc":
      return { kind: "instant", value: wall };
    case "file":
      return { kind: "instant", value: wall - zone.zone.utcOffset(time) };
    case "iana":
      return { kind: "instant", value: wallToEpoch(wall, zone.timeZone) };
    case "floating":
      return { kind: "floating", value: wall };
  }
}

const key = (resolved: Resolved) => `${resolved.kind}:${resolved.value}`;

// ───────────────────────── rule safety ─────────────────────────

const DAYS_IN_MONTH = [31, 29, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31];

function numbers(value: unknown): number[] | null {
  if (value === undefined) return [];
  if (!Array.isArray(value) || value.length > 62) return null;
  return value.every((n) => typeof n === "number" && Number.isInteger(n)) ? (value as number[]) : null;
}

/** True when some listed month has some listed day of the month. */
function monthDayExists(months: number[], monthDays: number[]): boolean {
  if (monthDays.length === 0) return true;
  const candidates = months.length > 0 ? months : [1];
  return candidates.some((month) => {
    const length = DAYS_IN_MONTH[month - 1];
    return length !== undefined && monthDays.some((day) => day !== 0 && Math.abs(day) <= length);
  });
}

/**
 * Whether ical.js can iterate this RRULE in bounded time.
 *
 * One call to the iterator's `next()` cannot be interrupted, and some rules
 * make it search for a date that never comes (`FREQ=DAILY;BYMONTH=2;
 * BYMONTHDAY=30` ran for a minute) or step through enormous spans
 * (`FREQ=SECONDLY;BYMONTH=6`). So only the shapes calendar apps actually
 * write are accepted: daily, weekly, monthly or yearly, filtered by weekday,
 * day of the month, month, and set position. Anything else is skipped.
 */
export function isSafeRule(rule: Recur): boolean {
  const freq = rule.freq;
  if (freq !== "DAILY" && freq !== "WEEKLY" && freq !== "MONTHLY" && freq !== "YEARLY") return false;
  if (!Number.isInteger(rule.interval) || rule.interval < 1 || rule.interval > 100) return false;

  const parts = rule.parts as Record<string, unknown>;
  for (const name of Object.keys(parts)) {
    if (name !== "BYDAY" && name !== "BYMONTHDAY" && name !== "BYMONTH" && name !== "BYSETPOS") return false;
  }
  const byDay = parts.BYDAY ?? [];
  if (!Array.isArray(byDay) || byDay.length > 14 || !byDay.every((day) => typeof day === "string")) return false;
  const weekdays = (byDay as string[]).map((day) => /^([+-]?\d{1,2})?(SU|MO|TU|WE|TH|FR|SA)$/.exec(day));
  if (weekdays.some((match) => match === null)) return false;
  /** The numbers in front of weekdays: 2 in "2MO", the second Monday. */
  const ordinals = weekdays.flatMap((match) => (match?.[1] ? [Number(match[1])] : []));
  const monthDays = numbers(parts.BYMONTHDAY);
  const months = numbers(parts.BYMONTH);
  const setPositions = numbers(parts.BYSETPOS);
  if (!monthDays || !months || !setPositions) return false;

  if (months.some((month) => month < 1 || month > 12)) return false;
  if (!monthDayExists(months, monthDays)) return false;
  if (byDay.length > 0 && monthDays.length > 0) return false;

  if (freq === "DAILY" || freq === "WEEKLY") {
    // "2MO" only means something within a month or a year.
    if (monthDays.length > 0 || setPositions.length > 0 || ordinals.length > 0) return false;
    // With a month filter every period outside those months is stepped over
    // one by one. And "every 7 days, on Tuesdays" from a Monday never comes.
    if (months.length > 0 && rule.interval !== 1) return false;
    if (freq === "DAILY" && byDay.length > 0 && rule.interval !== 1) return false;
    return true;
  }

  // The fifth Monday of a month exists; the sixth does not. Counting through
  // a whole year ("the 20th Monday") is not supported: ical.js gets it wrong.
  if (ordinals.some((ordinal) => ordinal === 0 || Math.abs(ordinal) > 5)) return false;
  if (freq === "YEARLY" && ordinals.length > 0 && months.length === 0) return false;
  // "The fifth Friday of February" comes once in decades, and ical.js walks
  // every month in between (about 2 ms a step).
  const fifthInAMonth = (n: number) => Math.abs(n) === 5 && months.length > 0;
  if (ordinals.some(fifthInAMonth) || setPositions.some(fifthInAMonth)) return false;

  if (setPositions.length > 0) {
    // "The last weekday of the month" (BYDAY=MO,TU,WE,TH,FR;BYSETPOS=-1) and
    // "the second Tuesday" (BYDAY=TU;BYSETPOS=2), as Apple and Outlook write them.
    if (setPositions.length !== 1 || byDay.length === 0 || ordinals.length > 0) return false;
    const position = setPositions[0] as number;
    if (position === 0 || Math.abs(position) > 5) return false;
    // In a yearly rule the set is the whole year unless one month is named.
    if (freq === "YEARLY" && months.length !== 1) return false;
  }
  return true;
}

/** What one iterator step of this rule costs, in units of about 10 µs (measured). */
function stepCost(rule: Recur): number {
  const parts = rule.parts as Record<string, unknown>;
  if ("BYSETPOS" in parts) return 70;
  const monthly = rule.freq === "MONTHLY" || rule.freq === "YEARLY";
  if (monthly && ("BYDAY" in parts || "BYMONTHDAY" in parts)) return 25;
  if (rule.freq === "WEEKLY" || "BYMONTH" in parts) return 4;
  return monthly ? 2 : 1;
}

/**
 * What a VTIMEZONE costs to expand, as its number of repeating observances,
 * or -1 when it cannot be expanded in bounded time.
 *
 * ical.js expands every observance's rule from its DTSTART (1601 in Outlook's
 * files) to five years past the latest date it is asked about, the first time
 * the zone is used: about 2.5 ms per repeating observance. Real zones change
 * clocks twice a year (`FREQ=YEARLY;BYMONTH=3;BYDAY=2SU`), sometimes with a
 * few earlier rules and a list of historical dates.
 */
function timezoneCost(vtimezone: Component): number {
  const tzid = vtimezone.getFirstPropertyValue("tzid");
  if (typeof tzid !== "string" || tzid === "") return -1;
  const observances = [...vtimezone.getAllSubcomponents("standard"), ...vtimezone.getAllSubcomponents("daylight")];
  if (observances.length === 0 || observances.length > MAX_ZONE_OBSERVANCES) return -1;

  let repeating = 0;
  let listedDates = 0;
  for (const observance of observances) {
    const start = observance.getFirstPropertyValue("dtstart");
    if (!(start instanceof ICAL.Time) || start.year < 1600 || start.year > 2100) return -1;
    for (const property of observance.getAllProperties("rrule")) {
      const rule = property.getFirstValue();
      if (!(rule instanceof ICAL.Recur)) return -1;
      if (rule.freq !== "YEARLY" || rule.interval !== 1 || !isSafeRule(rule)) return -1;
      if ("BYSETPOS" in rule.parts) return -1;
      repeating++;
    }
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

/**
 * A later starting point for the iterator that yields exactly the same
 * occurrences from the window on, or null when the rule gives no such
 * shortcut. Without it a standing meeting or a birthday costs a step for
 * every occurrence since the day it began.
 *
 * Starting the iterator anywhere else than DTSTART re-anchors the rule, which
 * changes what COUNT and INTERVAL mean, and DTSTART also supplies whatever the
 * rule leaves out (the weekday, the day of the month, the month). So the
 * start is moved only when there is no COUNT, and only by a whole number of
 * the rule's own periods, keeping those fields:
 * - daily and weekly: by days, a multiple of 7 when weekdays are involved;
 * - monthly: by months, when the day exists in every month;
 * - yearly: by years, unless it is 29 February.
 * The moved start is itself returned as an occurrence, as DTSTART always is,
 * so it is placed well before the window, where it is dropped.
 */
function seekStart(component: Component, shape: Shape, rules: Recur[], keepFrom: number): Time | null {
  if (rules.length !== 1 || component.hasProperty("rdate")) return null;
  const rule = rules[0] as Recur;
  if (rule.count != null) return null;
  const start = shape.start;
  const target = keepFrom - shape.duration - 40 * DAY;
  const startWall = wallSeconds(start);
  if (target <= startWall) return null;
  const moved = start.clone();

  switch (rule.freq) {
    case "DAILY":
    case "WEEKLY": {
      // A multiple of 7 keeps the weekday. A plain daily rule needs none.
      const plainDaily = rule.freq === "DAILY" && Object.keys(rule.parts).length === 0;
      const periodDays = plainDaily ? rule.interval : rule.interval * 7;
      const periods = Math.floor((target - startWall) / (periodDays * DAY));
      if (periods < 1) return null;
      moved.adjust(periods * periodDays, 0, 0, 0);
      return moved;
    }
    case "MONTHLY": {
      if (start.day > 28) return null;
      const targetDate = new Date(target * 1000);
      const months = (targetDate.getUTCFullYear() - start.year) * 12 + (targetDate.getUTCMonth() + 1 - start.month) - 1;
      const periods = Math.floor(months / rule.interval);
      if (periods < 1) return null;
      const index = start.year * 12 + (start.month - 1) + periods * rule.interval;
      moved.year = Math.floor(index / 12);
      moved.month = (index % 12) + 1;
      return moved;
    }
    case "YEARLY": {
      if (start.month === 2 && start.day === 29) return null;
      const years = new Date(target * 1000).getUTCFullYear() - start.year - 1;
      const periods = Math.floor(years / rule.interval);
      if (periods < 1) return null;
      moved.year = start.year + periods * rule.interval;
      return moved;
    }
    default:
      return null;
  }
}

function expand(
  component: Component,
  suppressed: Set<string>,
  keepFrom: number,
  keepUntil: number,
  budget: Budget,
  seek: boolean,
  out: StoredEvent[],
): void {
  // Judged on the wall clock, before any time zone work: an event or a
  // series that starts after the window, and a single event that ended before it.
  const startValue = component.getFirstPropertyValue("dtstart");
  if (startValue instanceof ICAL.Time && wallSeconds(startValue) - NEAR >= keepUntil) return;
  const recurring = component.hasProperty("rrule") || component.hasProperty("rdate");
  if (!recurring && isLongOver(component, keepFrom)) return;

  const shape = shapeOf(component);
  if (!shape) return;
  const { title, zone, duration } = shape;

  const emit = (start: Resolved) => {
    if (start.value >= keepUntil || start.value + duration <= keepFrom) return;
    out.push({ kind: start.kind, title, start: start.value, end: start.value + duration });
  };

  if (!recurring) {
    if (!suppressed.has(key(shape.first))) emit(shape.first);
    return;
  }

  const rules: Recur[] = [];
  for (const property of component.getAllProperties("rrule")) {
    const rule = property.getFirstValue();
    if (!(rule instanceof ICAL.Recur) || !isSafeRule(rule)) {
      budget.partial = true;
      return;
    }
    rules.push(rule);
  }
  // A series that ended long ago needs no steps at all.
  if (
    rules.length > 0 &&
    !component.hasProperty("rdate") &&
    rules.every((rule) => rule.until && wallSeconds(rule.until) + duration + 3 * DAY < keepFrom)
  ) {
    return;
  }

  let listed = 0;
  let plausibleDates = true;
  for (const property of [...component.getAllProperties("exdate"), ...component.getAllProperties("rdate")]) {
    const values = property.getValues();
    listed += values.length;
    if (property.name === "rdate" && !values.every((value) => value instanceof ICAL.Time && plausible(value))) {
      // A period, or a date in the year 9999: ical.js would take the time zone there.
      plausibleDates = false;
    }
  }
  if (listed > MAX_LISTED_DATES || !plausibleDates) {
    budget.partial = true;
    return;
  }
  budget.work -= listed;

  for (const property of component.getAllProperties("exdate")) {
    for (const value of property.getValues()) {
      if (!(value instanceof ICAL.Time)) continue;
      // Only an exclusion near the window can matter.
      const wall = wallSeconds(value);
      if (wall + NEAR <= keepFrom || wall - NEAR >= keepUntil) continue;
      suppressed.add(key(resolve(value, zoneOf(property, value))));
    }
  }
  // The exclusions are applied here, by instant. Left in place, ical.js would
  // apply them too, comparing each in its time zone however far off it is.
  component.removeAllProperties("exdate");

  const event = new ICAL.Event(component);
  const from = seek ? seekStart(component, shape, rules, keepFrom) : null;
  const iterator = event.iterator(from ?? undefined);
  const cost = rules.reduce((sum, rule) => sum + stepCost(rule), 0) || 1;
  for (;;) {
    if (budget.work <= 0) {
      budget.partial = true;
      return;
    }
    budget.work -= cost;
    const occurrence = iterator.next();
    if (!occurrence) return;
    // Cheap comparison on the wall clock first; zone maths only near the window.
    const wall = wallSeconds(occurrence);
    if (wall - 2 * DAY >= keepUntil) return;
    if (wall + duration + 2 * DAY <= keepFrom) continue;
    const start = resolve(occurrence, zone);
    if (!suppressed.has(key(start))) emit(start);
  }
}

/**
 * Parses the text of an .ics file and returns the occurrences near `now`.
 * Throws `CalendarParseError` when the text is not a calendar.
 *
 * Limits, each of which leaves the calendar usable and sets `partial`:
 * - an event whose RRULE is not a shape `isSafeRule` accepts is skipped;
 * - expansion stops once the file has used its work budget (`MAX_WORK_PER_FILE`);
 * - at most 500 occurrences are kept.
 * - an event listing more than 2,000 EXDATE and RDATE values is skipped.
 * A VTIMEZONE that is not a few plain yearly rules is ignored (and so are
 * those past 40 repeating observances in one file), and times that name it
 * fall back to the IANA zone of the same name, or to floating.
 * `RANGE=THISANDFUTURE` on a RECURRENCE-ID is not applied: such an override
 * changes only its own instance.
 */
export function parseCalendar(text: string, now: Date, options: { seek?: boolean } = {}): ParsedCalendar {
  const body = text.replace(/^﻿/, "").trimStart();
  if (!/^BEGIN:VCALENDAR/i.test(body)) throw new CalendarParseError("not a calendar");

  let calendar: Component;
  try {
    calendar = new ICAL.Component(ICAL.parse(body));
  } catch {
    // The parser's message can quote a line of the file; it is not passed on.
    throw new CalendarParseError("not a calendar");
  }
  if (calendar.name !== "vcalendar") throw new CalendarParseError("not a calendar");

  const budget: Budget = { work: MAX_WORK_PER_FILE, partial: false };

  // Must happen before any time value is read: ical.js looks a TZID up in the
  // file's VTIMEZONEs the first time a value is decoded.
  let zoneRules = 0;
  for (const vtimezone of calendar.getAllSubcomponents("vtimezone")) {
    let cost = -1;
    try {
      cost = timezoneCost(vtimezone);
    } catch {
      cost = -1;
    }
    if (cost < 0 || zoneRules + cost > MAX_ZONE_RULES_PER_FILE) calendar.removeSubcomponent(vtimezone);
    else zoneRules += cost;
  }

  const nowSeconds = Math.floor(now.getTime() / 1000);
  const keepFrom = nowSeconds - KEEP_BEFORE;
  const keepUntil = nowSeconds + KEEP_AFTER;

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
        if (wall + NEAR <= keepFrom || wall - NEAR >= keepUntil) continue;
        let keys = overridden.get(uid);
        if (!keys) overridden.set(uid, (keys = new Set()));
        keys.add(key(resolve(id, zoneOf(idProperty, id))));
      }
    } catch {
      budget.partial = true;
    }
  }

  const events: StoredEvent[] = [];
  const seek = options.seek ?? true;
  const each = (component: Component, suppressed: Set<string>) => {
    // Far more occurrences in nine days than will be kept: stop reading.
    if (budget.work <= 0 || events.length >= 4 * MAX_KEPT) {
      budget.partial = true;
      return;
    }
    budget.work--;
    try {
      if (isCancelled(component)) return;
      expand(component, suppressed, keepFrom, keepUntil, budget, seek, events);
    } catch {
      // One unreadable event does not spoil the calendar.
      budget.partial = true;
    }
  };

  for (const master of masters) {
    const uid = master.getFirstPropertyValue("uid");
    // A cancelled override is still in `overridden`, so its instance is
    // removed, not handed back to the series.
    each(master, new Set(typeof uid === "string" ? overridden.get(uid) : undefined));
  }
  for (const override of overrides) {
    // An override stands as an event of its own at its own time. It never
    // repeats, whatever properties it carries.
    for (const name of ["rrule", "rdate", "exdate"]) override.removeAllProperties(name);
    each(override, new Set());
  }

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
