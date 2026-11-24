// Calendar time follow-ups (task 174): wall-clock times in an hour the clocks
// skip, and a series instance replaced by an override far back.
import { describe, expect, it } from "vitest";
import { CACHED_KEEP_BEFORE, dayEvents, dayWall, parseCalendar, placeEvent, upcomingEvents, type StoredEvent } from "../src/lib/calendar.ts";
import { offsetChanges, wallIn } from "./zone-changes.ts";

const calendarOf = (...events: string[][]) =>
  [
    "BEGIN:VCALENDAR",
    "VERSION:2.0",
    "PRODID:-//Test//Test//EN",
    ...events.flatMap((lines, i) => ["BEGIN:VEVENT", ...(lines.some((line) => line.startsWith("UID:")) ? [] : [`UID:time-${i}@example.com`]), ...lines, "END:VEVENT"]),
    "END:VCALENDAR",
  ].join("\r\n");

const wallOf = (text: string) => Date.UTC(+text.slice(0, 4), +text.slice(5, 7) - 1, +text.slice(8, 10), +text.slice(11, 13), +text.slice(14, 16)) / 1000;
const floating = (start: string, end: string): StoredEvent => ({ kind: "floating", title: "x", start: wallOf(start), end: wallOf(end) });
const placed = (event: StoredEvent, timeZone: string) => {
  const { start, end } = placeEvent(event, timeZone);
  return [start, end];
};

describe("a wall-clock time in an hour the clocks skip", () => {
  // Worked by hand from each zone's rules:
  // Beirut, Sunday 29 March 2026: at 00:00 (UTC+2) the clocks go to 01:00 (UTC+3), at 2026-03-28T22:00Z.
  // Berlin, Sunday 29 March 2026: at 02:00 (UTC+1) the clocks go to 03:00 (UTC+2), at 2026-03-29T01:00Z.
  // New York, Sunday 8 March 2026: at 02:00 (UTC-5) the clocks go to 03:00 (UTC-4), at 2026-03-08T07:00Z.

  it("is the instant of the jump, so a floating event never ends before it starts", () => {
    // The review's cases: these came back as 22:45Z to 22:00Z, 01:45Z to 01:15Z and 06:45Z to 06:30Z.
    expect(placed(floating("2026-03-29 00:45", "2026-03-29 01:00"), "Asia/Beirut")).toEqual(["2026-03-28T22:00:00Z", "2026-03-28T22:00:00Z"]);
    expect(placed(floating("2026-03-29 02:45", "2026-03-29 03:15"), "Europe/Berlin")).toEqual(["2026-03-29T01:00:00Z", "2026-03-29T01:15:00Z"]);
    expect(placed(floating("2026-03-08 01:45", "2026-03-08 02:30"), "America/New_York")).toEqual(["2026-03-08T06:45:00Z", "2026-03-08T07:00:00Z"]);
    // Either side of the jump, times are where they always were.
    expect(placed(floating("2026-03-28 23:59", "2026-03-29 01:01"), "Asia/Beirut")).toEqual(["2026-03-28T21:59:00Z", "2026-03-28T22:01:00Z"]);
    expect(placed(floating("2026-03-29 01:59", "2026-03-29 03:00"), "Europe/Berlin")).toEqual(["2026-03-29T00:59:00Z", "2026-03-29T01:00:00Z"]);
    expect(placed(floating("2026-03-08 01:59", "2026-03-08 03:00"), "America/New_York")).toEqual(["2026-03-08T06:59:00Z", "2026-03-08T07:00:00Z"]);
  });

  it("starts an event with a TZID in the skipped hour at the jump, keeping the length it has on the clock that does exist", () => {
    const text = calendarOf(
      ["SUMMARY:Berlin", "DTSTART;TZID=Europe/Berlin:20260329T023000", "DTEND;TZID=Europe/Berlin:20260329T033000"],
      ["SUMMARY:New York", "DTSTART;TZID=America/New_York:20260308T023000", "DTEND;TZID=America/New_York:20260308T033000"],
      ["SUMMARY:Beirut", "DTSTART;TZID=Asia/Beirut:20260329T003000", "DURATION:PT1H"],
    );
    // Each read the day before its change.
    const stored = [
      ...parseCalendar(text, new Date("2026-03-07T12:00:00Z")).events,
      ...parseCalendar(text, new Date("2026-03-28T12:00:00Z")).events,
    ];
    const answer = (title: string) => {
      const found = stored.filter((each) => each.title === title);
      expect(found).toHaveLength(1);
      return placed(found[0]!, "UTC");
    };
    // 03:30 CEST is 01:30Z; 03:30 EDT is 07:30Z.
    expect(answer("Berlin")).toEqual(["2026-03-29T01:00:00Z", "2026-03-29T01:30:00Z"]);
    expect(answer("New York")).toEqual(["2026-03-08T07:00:00Z", "2026-03-08T07:30:00Z"]);
    expect(answer("Beirut")).toEqual(["2026-03-28T22:00:00Z", "2026-03-28T23:00:00Z"]);
  });

  it("puts an all-day event on a skipped midnight at the moment its date begins", () => {
    const sunday: StoredEvent = { kind: "allDay", title: "Sunday", start: wallOf("2026-09-06 00:00"), end: wallOf("2026-09-07 00:00") };
    // Santiago, 6 September 2026: at midnight (UTC-4) the clocks go to 01:00 (UTC-3).
    expect(placeEvent(sunday, "America/Santiago")).toMatchObject({ start: "2026-09-06T04:00:00Z", end: "2026-09-07T03:00:00Z", date: "2026-09-06" });
  });

  it("answers the Beirut day with the skipped-hour event at the jump", () => {
    const stored = parseCalendar(
      calendarOf(["SUMMARY:Floating in the skipped hour", "DTSTART:20260329T004500", "DTEND:20260329T010000"]),
      new Date("2026-03-28T12:00:00Z"),
    ).events;
    expect(dayEvents(stored, dayWall("2026-03-29")!, "Asia/Beirut")).toEqual([
      { title: "Floating in the skipped hour", start: "2026-03-28T22:00:00Z", end: "2026-03-28T22:00:00Z", allDay: false },
    ]);
  });

  it("never places a later wall-clock time before an earlier one, and gives each time its own instant or the jump, around every change of 2026 in every zone", () => {
    const failures: string[] = [];
    let changes = 0;
    const STEP = 15 * 60;
    for (const zone of Intl.supportedValuesOf("timeZone")) {
      for (const change of offsetChanges(zone, 2026)) {
        changes++;
        // Every quarter of an hour on the wall clock from three hours before the change to three after.
        const low = Math.floor((change.at + Math.min(change.before, change.after) - 3 * 3600) / STEP) * STEP;
        const high = change.at + Math.max(change.before, change.after) + 3 * 3600;
        let previous = -Infinity;
        for (let wall = low; wall <= high; wall += STEP) {
          const event: StoredEvent = { kind: "floating", title: "x", start: wall, end: wall + STEP };
          const { start, end } = placeEvent(event, zone);
          const [from, to] = [Date.parse(start) / 1000, Date.parse(end) / 1000];
          // The time itself, or, where the clocks never show it, the first instant they show a later one.
          const own = wallIn(from, zone) === wall || (wallIn(from, zone) > wall && wallIn(from - 1, zone) < wall);
          if (to < from || from < previous || !own) {
            failures.push(`${zone} ${new Date(wall * 1000).toISOString()}: ${start} to ${end}`);
          }
          previous = from;
        }
      }
    }
    expect(changes).toBeGreaterThan(100);
    expect(failures.slice(0, 20)).toEqual([]);
  }, 30_000);
});

describe("a series instance replaced by an override far back", () => {
  // A weekly on-call rota, each turn seven days long. This week's turn (from
  // Monday 16 November) was swapped; on Saturday the 21st its RECURRENCE-ID
  // is five days back, and the turn it replaces is still running.
  const ON_CALL = calendarOf(
    [
      "UID:on-call@example.com",
      "SUMMARY:On call",
      "DTSTART;TZID=America/New_York:20261102T090000",
      "DTEND;TZID=America/New_York:20261109T090000",
      "RRULE:FREQ=WEEKLY",
    ],
    [
      "UID:on-call@example.com",
      "SUMMARY:On call (swapped with Sam)",
      "RECURRENCE-ID;TZID=America/New_York:20261116T090000",
      "DTSTART;TZID=America/New_York:20261116T090000",
      "DTEND;TZID=America/New_York:20261123T090000",
    ],
  );
  const SATURDAY = new Date("2026-11-21T18:00:00Z");
  const titles = (events: { title: string }[]) => events.map((event) => event.title);

  it("is not shown beside its override, one day back or two", () => {
    for (const keepBefore of [undefined, CACHED_KEEP_BEFORE]) {
      const parsed = parseCalendar(ON_CALL, SATURDAY, keepBefore);
      expect(parsed.partial).toBe(false);
      expect(titles(parsed.events)).toEqual(["On call (swapped with Sam)", "On call"]);
      expect(upcomingEvents(parsed.events, SATURDAY, "America/New_York")).toEqual([
        { title: "On call (swapped with Sam)", start: "2026-11-16T14:00:00Z", end: "2026-11-23T14:00:00Z", allDay: false },
        { title: "On call", start: "2026-11-23T14:00:00Z", end: "2026-11-30T14:00:00Z", allDay: false },
      ]);
      expect(titles(dayEvents(parsed.events, dayWall("2026-11-21")!, "America/New_York"))).toEqual(["On call (swapped with Sam)"]);
    }
  });

  it("is not shown beside its override whatever its length, up to a year", () => {
    for (const days of [1, 4, 7, 30, 365]) {
      const now = new Date(Date.UTC(2026, 10, 16, 14) * 1 + (days - 0.5) * 86400_000);
      const stamp = (ms: number) => new Date(ms).toISOString().replace(/[-:]/g, "").slice(0, 15) + "Z";
      const text = calendarOf(
        ["UID:long@example.com", "SUMMARY:Turn", "DTSTART:20261116T140000Z", `DURATION:P${days}D`, `RRULE:FREQ=DAILY;INTERVAL=${days}`],
        ["UID:long@example.com", "SUMMARY:Turn (swapped)", "RECURRENCE-ID:20261116T140000Z", "DTSTART:20261116T140000Z", `DTEND:${stamp(Date.UTC(2026, 10, 16, 14) + days * 86400_000)}`],
      );
      for (const keepBefore of [undefined, CACHED_KEEP_BEFORE]) {
        const { events } = parseCalendar(text, now, keepBefore);
        // Only the override starts where the replaced turn did; the next turn is there too.
        expect([days, titles(events.filter((event) => event.start === Date.UTC(2026, 10, 16, 14) / 1000))]).toEqual([days, ["Turn (swapped)"]]);
        expect(events.some((event) => event.title === "Turn")).toBe(true);
      }
    }
  });

  it("is not shown beside its override when the event does not repeat", () => {
    const text = calendarOf(
      ["UID:once@example.com", "SUMMARY:Week away", "DTSTART:20261116T140000Z", "DTEND:20261123T140000Z"],
      ["UID:once@example.com", "SUMMARY:Week away (moved)", "RECURRENCE-ID:20261116T140000Z", "DTSTART:20261116T150000Z", "DTEND:20261123T150000Z"],
    );
    expect(titles(parseCalendar(text, SATURDAY).events)).toEqual(["Week away (moved)"]);
  });

  it("looks up nothing for an override far from every instance it could replace", () => {
    // Its TZID is unknown: looked up, it would leave the calendar partly read.
    const text = calendarOf(
      ["UID:daily@example.com", "SUMMARY:Daily", "DTSTART:20261101T140000Z", "DTEND:20261101T150000Z", "RRULE:FREQ=DAILY"],
      ["UID:daily@example.com", "SUMMARY:Daily (moved)", "RECURRENCE-ID;TZID=Nowhere/Made Up:20100105T090000", "DTSTART:20100105T100000Z"],
    );
    const parsed = parseCalendar(text, SATURDAY);
    expect(parsed.partial).toBe(false);
    expect(new Set(titles(parsed.events))).toEqual(new Set(["Daily"]));
  });
});
