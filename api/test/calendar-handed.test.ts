// What ical.js is handed must be what the limits counted: the pre-parser and
// ical.js have to agree on where each handed line's parameters end and its
// value begins (task 18, round 2).
import ICAL from "ical.js";
import { afterEach, describe, expect, it, vi } from "vitest";
import { CalendarTooLargeError, MAX_LISTED_PER_FILE, handedLine, parseCalendar, upcomingEvents } from "../src/lib/calendar.ts";
import { checkFiles, checkLines } from "./calendar-fuzz.ts";

/** Monday 16 November 2026, 15:00 UTC. */
const NOW = new Date("2026-11-16T15:00:00Z");

const calendarOf = (...components: string[][]) =>
  ["BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//Test//Test//EN", ...components.flat(), "END:VCALENDAR"].join("\r\n");
let nextUid = 0;
const vevent = (...lines: string[]) => ["BEGIN:VEVENT", `UID:h${nextUid++}`, ...lines, "END:VEVENT"];
const series = (...lines: string[]) => vevent("SUMMARY:series", "DTSTART:20261116T090000Z", "RRULE:FREQ=DAILY;COUNT=3", ...lines);
const zone = (tzid: string, ...blockLines: string[]) => [
  "BEGIN:VTIMEZONE",
  `TZID:${tzid}`,
  "BEGIN:STANDARD",
  "DTSTART:19700101T000000",
  "TZOFFSETFROM:+0200",
  "TZOFFSETTO:+0200",
  ...blockLines,
  "END:STANDARD",
  "END:VTIMEZONE",
];

/**
 * The review's line: each `"` sits inside a value, where ical.js takes it for
 * an ordinary character, so its value begins at the first colon and holds
 * every comma. A count that took the quotes for quoted stretches saw 1 value.
 */
const hiddenByQuotes = (commas: number, end = "20200101T000000Z") =>
  `;TZID=a":${",".repeat(commas)}";TZID=b"${",".repeat(commas)}";TZID=c"${",".repeat(commas)}";TZID=d"${",".repeat(commas)}":${end}`;
/** Escapes in the last parameter: ical.js finds the value by the unescaped length, which `\,` shortens. */
const hiddenByEscapes = (escapes: number, commas: number) => `;TZID="${"\\,".repeat(escapes)}:${",".repeat(commas)}":20200101T000000Z`;

/** The EXDATE and RDATE values in what ICAL.parse returned, per event, per zone and in all. */
function listedHanded(result: unknown): { events: number[]; zones: number[]; total: number } {
  const count = (component: unknown[]) =>
    (component[1] as unknown[][]).reduce((sum, property) => sum + (property[0] === "exdate" || property[0] === "rdate" ? property.length - 3 : 0), 0);
  const events: number[] = [];
  const zones: number[] = [];
  const calendars = (Array.isArray((result as unknown[])[0]) ? result : [result]) as unknown[][];
  for (const calendar of calendars) {
    for (const component of calendar[2] as unknown[][]) {
      if (component[0] === "vevent") events.push(count(component));
      if (component[0] === "vtimezone") zones.push((component[2] as unknown[][]).reduce((sum: number, block) => sum + count(block), 0));
    }
  }
  return { events, zones, total: [...events, ...zones].reduce((a, b) => a + b, 0) };
}

/** Parses with ICAL.parse watched; returns the result and what ical.js made of what it was handed. */
function parseWatched(text: string) {
  const spy = vi.spyOn(ICAL, "parse");
  try {
    const parsed = parseCalendar(text, NOW);
    expect(spy).toHaveBeenCalledTimes(1);
    return { parsed, handed: listedHanded(spy.mock.results[0]?.value), input: spy.mock.calls[0]?.[0] as string };
  } finally {
    spy.mockRestore();
  }
}

afterEach(() => vi.restoreAllMocks());

describe("listed dates are counted on the value ical.js is handed", () => {
  it("counts the commas a quote inside a parameter used to hide, as ical.js does", () => {
    const line = `EXDATE${hiddenByQuotes(285)}`;
    const handed = handedLine(line);
    expect(handed?.listed).toBe(4 * 285 + 1);
    // ical.js on the handed line makes as many.
    const parsed = ICAL.parse(`BEGIN:VCALENDAR\nBEGIN:VEVENT\n${handed?.text}\nEND:VEVENT\nEND:VCALENDAR`) as unknown[];
    expect(listedHanded(parsed).total).toBe(4 * 285 + 1);
  });

  it("hands on an event of the review's lines only while it is within 2,000 values, and says so when it is not", () => {
    const one = parseWatched(calendarOf(series(`EXDATE${hiddenByQuotes(285)}`)));
    expect(one.handed.events).toEqual([1141]);
    // Its values are not dates, so the event is then skipped as unreadable.
    expect(one.parsed).toEqual({ events: [], partial: true });

    // Two such lines are 2,282 values: the event is left out before ical.js sees it.
    const two = parseWatched(calendarOf(series(`EXDATE${hiddenByQuotes(285)}`, `EXDATE${hiddenByQuotes(285)}`)));
    expect(two.handed.events).toEqual([]);
    expect(two.parsed).toEqual({ events: [], partial: true });
  });

  it("refuses a file whose events together list more than MAX_LISTED_PER_FILE this way", () => {
    // 1,141 values an event: 17 events are 19,397, 18 are 20,538.
    const file = (count: number) => calendarOf(...Array.from({ length: count }, () => series(`EXDATE${hiddenByQuotes(285)}`)));
    expect(17 * 1141).toBeLessThanOrEqual(MAX_LISTED_PER_FILE);

    const within = parseWatched(file(17));
    expect(within.handed.total).toBe(17 * 1141);
    expect(within.handed.events).toHaveLength(17);
    expect(() => parseCalendar(file(18), NOW)).toThrow(CalendarTooLargeError);
  });

  it("does not hand on a zone whose RDATE lines hide more than 400 values, and refuses a file of zones over the file's limit", () => {
    // 4 x 99 + 1 = 397 values on one line; with one more line of 4, 401.
    const at = (tzid: string) => vevent(`SUMMARY:${tzid}`, `DTSTART;TZID=${tzid}:20261117T090000`);
    const text = calendarOf(
      zone("Within", `RDATE${hiddenByQuotes(99, "19700101T000000")}`),
      zone("Over", `RDATE${hiddenByQuotes(99, "19700101T000000")}`, "RDATE:19710101T000000,19720101T000000,19730101T000000,19740101T000000"),
      at("Within"),
      at("Over"),
    );
    const watched = parseWatched(text);
    expect(watched.handed.zones).toEqual([397]);
    // The zone used puts 09:00 at 07:00 UTC; the one not handed on leaves the time floating, read here in UTC.
    expect(upcomingEvents(watched.parsed.events, NOW, "UTC").map((event) => `${event.title} ${event.start}`).sort()).toEqual([
      "Over 2026-11-17T09:00:00Z",
      "Within 2026-11-17T07:00:00Z",
    ]);

    // 50 zones of 397 are 19,850 values; 51 are 20,247.
    const zones = (count: number) => calendarOf(...Array.from({ length: count }, (_, i) => zone(`Z${i}`, `RDATE${hiddenByQuotes(99, "19700101T000000")}`)));
    expect(parseWatched(zones(50)).handed.total).toBe(50 * 397);
    expect(() => parseCalendar(zones(51), NOW)).toThrow(CalendarTooLargeError);
  });

  it("does not hand on a TZID with a backslash, so escapes cannot move where ical.js finds the value", () => {
    const line = `EXDATE${hiddenByEscapes(98, 96)}`;
    expect(handedLine(line)).toMatchObject({ text: "EXDATE:20200101T000000Z", listed: 1, unreadTzid: true });

    const watched = parseWatched(calendarOf(series(line)));
    expect(watched.handed.events).toEqual([1]);
    // The exclusion lost its zone: reported.
    expect(watched.parsed.partial).toBe(true);
  });

  it("counts an escaped comma as ical.js does: it does not split", () => {
    for (const value of ["a\\,b,c", "a\\\\,b", ",a", "a,", ""]) {
      const handed = handedLine(`EXDATE:${value}`);
      const parsed = ICAL.parse(`BEGIN:VCALENDAR\nBEGIN:VEVENT\n${handed?.text}\nEND:VEVENT\nEND:VCALENDAR`) as unknown[];
      expect(handed?.listed).toBe(listedHanded(parsed).total);
    }
    expect(handedLine("EXDATE:a\\,b,c")?.listed).toBe(2);
  });
});

describe("parameters are handed on only in a form ical.js reads as written", () => {
  it("reads Outlook's quoted zone names, colons and all", () => {
    const tzid = "(UTC-06:00) Central Time (US & Canada)";
    const text = calendarOf(
      ["BEGIN:VTIMEZONE", `TZID:${tzid}`, "BEGIN:STANDARD", "DTSTART:16010101T000000", "TZOFFSETFROM:-0600", "TZOFFSETTO:-0600", "END:STANDARD", "END:VTIMEZONE"],
      vevent("SUMMARY:x", `DTSTART;TZID="${tzid}":20261117T090000`, `EXDATE;TZID="${tzid}":20261118T090000`, "RRULE:FREQ=DAILY;COUNT=3"),
    );
    const parsed = parseCalendar(text, NOW);
    expect(parsed.partial).toBe(false);
    expect(upcomingEvents(parsed.events, NOW, "UTC").map((event) => event.start).sort()).toEqual(["2026-11-17T15:00:00Z", "2026-11-19T15:00:00Z"]);
  });

  it("leaves out a TZID it cannot hand on as written, reads the time as floating, and says so", () => {
    for (const tzid of ['Europe"Berlin', '"Europe\\,Berlin"', `"${"a".repeat(300)}"`]) {
      const parsed = parseCalendar(calendarOf(vevent("SUMMARY:x", `DTSTART;TZID=${tzid}:20261117T090000`)), NOW);
      expect(parsed.partial).toBe(true);
      expect(upcomingEvents(parsed.events, NOW, "America/Chicago").map((event) => event.start)).toEqual(["2026-11-17T15:00:00Z"]);
    }
  });

  it("does not report a TZID left out of a line that is not handed on", () => {
    const text = calendarOf(vevent("SUMMARY:x", "DTSTART:20261117T090000Z", 'ATTENDEE;TZID=a"b;CN="x\\,y":mailto:a@example.com'));
    expect(parseCalendar(text, NOW).partial).toBe(false);
  });

  it("takes the last TZID of a line, as ical.js would", () => {
    const text = calendarOf(vevent("SUMMARY:x", "DTSTART;TZID=America/New_York;TZID=Europe/Berlin:20261117T090000"));
    expect(upcomingEvents(parseCalendar(text, NOW).events, NOW, "UTC").map((event) => event.start)).toEqual(["2026-11-17T08:00:00Z"]);
  });

  it("hands on VALUE as DATE or DATE-TIME only, quoted or not, and refuses a quote left open", () => {
    expect(handedLine('DTSTART;VALUE="DATE":20261117')?.text).toBe("DTSTART;VALUE=DATE:20261117");
    expect(handedLine("DTSTART;value=date-time;TZID=Europe/Berlin:20261117T090000")?.text).toBe("DTSTART;TZID=Europe/Berlin;VALUE=DATE-TIME:20261117T090000");
    expect(handedLine("DTSTART;VALUE=PERIOD:20261117T090000Z/PT1H")?.text).toBe("DTSTART:20261117T090000Z/PT1H");
    // A quote that never closes: no value can be found, as for ical.js.
    expect(handedLine('DTSTART;VALUE="DATE:20261117')).toBeNull();
    const parsed = parseCalendar(calendarOf(vevent("SUMMARY:x", 'DTSTART;VALUE="DATE":20261117')), NOW);
    expect(parsed).toMatchObject({ partial: false, events: [{ kind: "allDay", title: "x" }] });
  });

  it("finds the value after a quoted parameter holding semicolons and colons, and after one with no `=`", () => {
    expect(handedLine('DTSTART;X-A="a;b:c";TZID=Europe/Berlin:20261117T090000')?.text).toBe("DTSTART;TZID=Europe/Berlin:20261117T090000");
    expect(handedLine('DTSTART;MEMBER="a:b","c;d";TZID=Europe/Berlin:20261117T090000')?.text).toBe("DTSTART;TZID=Europe/Berlin:20261117T090000");
    expect(handedLine("DTSTART;X;TZID=Europe/Berlin:20261117T090000")?.text).toBe("DTSTART;TZID=Europe/Berlin:20261117T090000");
  });
});

describe("random lines: what is counted is what ical.js makes of the handed line", () => {
  it("agrees on every one of 20,000 random lines", () => {
    const report = checkLines(18, 20_000);
    expect(report.checked).toBeGreaterThan(18_000);
    expect(report.listed).toBeGreaterThan(50_000);
    // Only RDATE periods ical.js cannot decode are refused.
    expect(report.refusedLines).toEqual([]);
    expect(report.kinds).toEqual({});
    expect(report.mismatches).toBe(0);
  });

  it("never hands ical.js more listed values than the limits allow, in 100 random files", () => {
    const report = checkFiles(19, 100);
    expect(report.files).toBe(100);
    expect(report.refused).toBe(0);
    expect(report.mostPerEvent).toBeLessThanOrEqual(2000);
    expect(report.mostPerZone).toBeLessThanOrEqual(400);
    expect(report.mostPerFile).toBeLessThanOrEqual(MAX_LISTED_PER_FILE);
    // The files did hand ical.js listed values.
    expect(report.mostPerFile).toBeGreaterThan(0);
  });
});
