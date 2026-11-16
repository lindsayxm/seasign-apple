import ICAL from "ical.js";
import { describe, expect, it } from "vitest";
import {
  CalendarParseError,
  isTimeZone,
  parseCalendar,
  readRule,
  upcomingEvents,
  type UpcomingEvent,
} from "../src/lib/calendar.ts";
// Written by hand in the shape each provider exports; no real calendar was fetched.
import google from "./fixtures/calendar/google.ics?raw";
import icloud from "./fixtures/calendar/icloud.ics?raw";
import outlook from "./fixtures/calendar/outlook.ics?raw";
import { WINDOWS_ZONES } from "../src/lib/windows-zones.ts";

/** Monday 16 November 2026, 10:00 in New York, 09:00 in Chicago. */
const NOW = new Date("2026-11-16T15:00:00Z");

const calendarOf = (...components: string[][]) =>
  ["BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//Test//Test//EN", ...components.flat(), "END:VCALENDAR"].join("\r\n");

let nextUid = 0;
/** A VEVENT. A UID is added unless one is given. */
const vevent = (...lines: string[]) => [
  "BEGIN:VEVENT",
  ...(lines.some((line) => line.startsWith("UID:")) ? [] : [`UID:test-${nextUid++}@example.com`]),
  "DTSTAMP:20261101T000000Z",
  ...lines,
  "END:VEVENT",
];

const NEW_YORK = [
  "BEGIN:VTIMEZONE",
  "TZID:America/New_York",
  "BEGIN:DAYLIGHT",
  "TZOFFSETFROM:-0500",
  "TZOFFSETTO:-0400",
  "DTSTART:19700308T020000",
  "RRULE:FREQ=YEARLY;BYMONTH=3;BYDAY=2SU",
  "END:DAYLIGHT",
  "BEGIN:STANDARD",
  "TZOFFSETFROM:-0400",
  "TZOFFSETTO:-0500",
  "DTSTART:19701101T020000",
  "RRULE:FREQ=YEARLY;BYMONTH=11;BYDAY=1SU",
  "END:STANDARD",
  "END:VTIMEZONE",
];

/** Parses and answers in one go, sorted by start then title. */
function upcoming(text: string, now = NOW, timeZone = "UTC"): UpcomingEvent[] {
  return upcomingEvents(parseCalendar(text, now).events, now, timeZone).sort(
    (a, b) => a.start.localeCompare(b.start) || a.title.localeCompare(b.title),
  );
}

const brief = (events: UpcomingEvent[]) => events.map((event) => `${event.title} @ ${event.start}`);

describe("provider fixtures", () => {
  it("reads a Google Calendar export", () => {
    expect(upcoming(google, NOW, "America/New_York")).toEqual([
      // All-day, four days, begun on Saturday and still running.
      {
        title: "Road trip",
        start: "2026-11-14T05:00:00Z",
        end: "2026-11-18T05:00:00Z",
        allDay: true,
        date: "2026-11-14",
      },
      { title: "Dentist", start: "2026-11-17T19:00:00Z", end: "2026-11-17T20:00:00Z", allDay: false },
      // Yearly since 1990.
      {
        title: "Mom's birthday",
        start: "2026-11-18T05:00:00Z",
        end: "2026-11-19T05:00:00Z",
        allDay: true,
        date: "2026-11-18",
      },
      // Thursday's instance was moved to Friday by a RECURRENCE-ID override.
      { title: "1:1 with Sam", start: "2026-11-20T16:00:00Z", end: "2026-11-20T16:30:00Z", allDay: false },
      // Weekly on Monday and Wednesday at 09:30 New York time. The series
      // began in summer time (13:30Z); this instance is in winter time. Today's
      // has just ended and Wednesday's is an EXDATE.
      { title: "Team sync", start: "2026-11-23T14:30:00Z", end: "2026-11-23T15:00:00Z", allDay: false },
    ]);
  });

  it("reads an iCloud published calendar", () => {
    expect(upcoming(icloud, NOW, "America/Chicago")).toEqual([
      // Timed, spanning three days, begun yesterday.
      { title: "Camping at the lake", start: "2026-11-15T23:00:00Z", end: "2026-11-17T17:00:00Z", allDay: false },
      { title: "Morning run", start: "2026-11-17T12:30:00Z", end: "2026-11-17T13:00:00Z", allDay: false },
      // No DTEND: it ends when it starts.
      { title: "Call the landlord", start: "2026-11-18T00:00:00Z", end: "2026-11-18T00:00:00Z", allDay: false },
      // The 18th is an EXDATE. The 19th is overridden: an hour later, new title.
      { title: "Morning run (late start)", start: "2026-11-19T13:30:00Z", end: "2026-11-19T14:00:00Z", allDay: false },
      // Floating: noon wherever the user is, here Chicago.
      { title: "Lunch with Ana", start: "2026-11-19T18:00:00Z", end: "2026-11-19T19:00:00Z", allDay: false },
      // An override whose series is not in the file (an invitation to one instance).
      { title: "Book club", start: "2026-11-21T01:00:00Z", end: "2026-11-21T02:30:00Z", allDay: false },
      // The 20th is a cancelled override: gone, not restored from the series.
      { title: "Morning run", start: "2026-11-21T12:30:00Z", end: "2026-11-21T13:00:00Z", allDay: false },
      { title: "Morning run", start: "2026-11-22T12:30:00Z", end: "2026-11-22T13:00:00Z", allDay: false },
      { title: "Morning run", start: "2026-11-23T12:30:00Z", end: "2026-11-23T13:00:00Z", allDay: false },
    ]);
  });

  it("reads an Outlook published calendar, whose time zone has a Windows name", () => {
    expect(upcoming(outlook)).toEqual([
      { title: "Budget review", start: "2026-11-17T15:00:00Z", end: "2026-11-17T16:00:00Z", allDay: false },
      {
        title: "Company holiday",
        start: "2026-11-20T00:00:00Z",
        end: "2026-11-21T00:00:00Z",
        allDay: true,
        date: "2026-11-20",
      },
      // Weekly on Friday since September (summer time), until 18 December.
      { title: "Weekly staff meeting", start: "2026-11-20T14:00:00Z", end: "2026-11-20T15:00:00Z", allDay: false },
      // Monthly on the 20th since January.
      { title: "Payroll cutoff", start: "2026-11-20T17:00:00Z", end: "2026-11-20T17:30:00Z", allDay: false },
    ]);
  });

  it.each([
    ["google", google],
    ["icloud", icloud],
    ["outlook", outlook],
  ])("reads %s completely, and the same with CRLF line endings", (_name, text) => {
    expect(parseCalendar(text, NOW).partial).toBe(false);
    expect(upcoming(text.replace(/\r?\n/g, "\r\n"))).toEqual(upcoming(text));
  });
});

describe("times", () => {
  it("keeps what has not ended and starts within seven days", () => {
    const text = calendarOf(
      vevent("SUMMARY:ended a minute ago", "DTSTART:20261116T140000Z", "DTEND:20261116T145900Z"),
      vevent("SUMMARY:ends this very second", "DTSTART:20261116T140000Z", "DTEND:20261116T150000Z"),
      vevent("SUMMARY:in progress", "DTSTART:20261116T140000Z", "DTEND:20261116T150100Z"),
      vevent("SUMMARY:starts now", "DTSTART:20261116T150000Z", "DTEND:20261116T160000Z"),
      vevent("SUMMARY:last second of the week", "DTSTART:20261123T145959Z", "DTEND:20261123T160000Z"),
      vevent("SUMMARY:exactly seven days out", "DTSTART:20261123T150000Z", "DTEND:20261123T160000Z"),
      vevent("SUMMARY:two-week trip begun ten days ago", "DTSTART:20261106T120000Z", "DTEND:20261120T120000Z"),
    );

    expect(brief(upcoming(text))).toEqual([
      "two-week trip begun ten days ago @ 2026-11-06T12:00:00Z",
      "in progress @ 2026-11-16T14:00:00Z",
      "starts now @ 2026-11-16T15:00:00Z",
      "last second of the week @ 2026-11-23T14:59:59Z",
    ]);
  });

  it("gives an event without DTEND no length, or DURATION's length", () => {
    const text = calendarOf(
      vevent("SUMMARY:reminder passed", "DTSTART:20261116T145959Z"),
      vevent("SUMMARY:reminder now", "DTSTART:20261116T150000Z"),
      vevent("SUMMARY:reminder later", "DTSTART:20261117T090000Z"),
      vevent("SUMMARY:with duration", "DTSTART:20261117T100000Z", "DURATION:PT1H30M"),
      vevent("SUMMARY:all day by default", "DTSTART;VALUE=DATE:20261118"),
      vevent("SUMMARY:all day same end", "DTSTART;VALUE=DATE:20261119", "DTEND;VALUE=DATE:20261119"),
      vevent("SUMMARY:all day three days", "DTSTART;VALUE=DATE:20261120", "DURATION:P3D"),
    );

    expect(upcoming(text).map((event) => [event.title, event.start, event.end])).toEqual([
      ["reminder now", "2026-11-16T15:00:00Z", "2026-11-16T15:00:00Z"],
      ["reminder later", "2026-11-17T09:00:00Z", "2026-11-17T09:00:00Z"],
      ["with duration", "2026-11-17T10:00:00Z", "2026-11-17T11:30:00Z"],
      ["all day by default", "2026-11-18T00:00:00Z", "2026-11-19T00:00:00Z"],
      ["all day same end", "2026-11-19T00:00:00Z", "2026-11-20T00:00:00Z"],
      ["all day three days", "2026-11-20T00:00:00Z", "2026-11-23T00:00:00Z"],
    ]);
  });

  it("places floating and all-day events in the request's time zone", () => {
    const text = calendarOf(
      vevent("SUMMARY:all day", "DTSTART;VALUE=DATE:20261118", "DTEND;VALUE=DATE:20261119"),
      vevent("SUMMARY:floating", "DTSTART:20261118T090000", "DTEND:20261118T100000"),
    );
    const stored = parseCalendar(text, NOW).events;
    const at = (timeZone: string) =>
      upcomingEvents(stored, NOW, timeZone).map((event) => [event.title, event.start, event.end, event.date]);

    expect(at("UTC")).toEqual([
      ["all day", "2026-11-18T00:00:00Z", "2026-11-19T00:00:00Z", "2026-11-18"],
      ["floating", "2026-11-18T09:00:00Z", "2026-11-18T10:00:00Z", undefined],
    ]);
    expect(at("America/Los_Angeles")).toEqual([
      ["all day", "2026-11-18T08:00:00Z", "2026-11-19T08:00:00Z", "2026-11-18"],
      ["floating", "2026-11-18T17:00:00Z", "2026-11-18T18:00:00Z", undefined],
    ]);
    // UTC+13 in November: the 18th begins while it is still the 17th in UTC.
    expect(at("Pacific/Auckland")).toEqual([
      ["all day", "2026-11-17T11:00:00Z", "2026-11-18T11:00:00Z", "2026-11-18"],
      ["floating", "2026-11-17T20:00:00Z", "2026-11-17T21:00:00Z", undefined],
    ]);
    expect(at("Asia/Kolkata")[0]).toEqual(["all day", "2026-11-17T18:30:00Z", "2026-11-18T18:30:00Z", "2026-11-18"]);
  });

  it("decides whether an all-day event is over by the request's time zone", () => {
    // Sunday the 15th, all day. An hour after midnight UTC on Monday it is
    // over in UTC and still Sunday afternoon in Los Angeles.
    const text = calendarOf(vevent("SUMMARY:Sunday", "DTSTART;VALUE=DATE:20261115", "DTEND;VALUE=DATE:20261116"));
    const justAfterMidnight = new Date("2026-11-16T01:00:00Z");
    const stored = parseCalendar(text, justAfterMidnight).events;

    expect(upcomingEvents(stored, justAfterMidnight, "UTC")).toEqual([]);
    expect(brief(upcomingEvents(stored, justAfterMidnight, "America/Los_Angeles"))).toEqual([
      "Sunday @ 2026-11-15T08:00:00Z",
    ]);
  });

  describe("across a daylight-saving change", () => {
    // Weekly at 09:00 New York time. Clocks go back on Sunday 1 November 2026.
    const weekly = vevent(
      "SUMMARY:Weekly",
      "DTSTART;TZID=America/New_York:20261005T090000",
      "DTEND;TZID=America/New_York:20261005T100000",
      "RRULE:FREQ=WEEKLY",
    );
    const beforeTheChange = new Date("2026-10-25T00:00:00Z");
    const expected = ["Weekly @ 2026-10-26T13:00:00Z"];
    const afterTheChange = new Date("2026-11-01T12:00:00Z");
    const expectedAfter = ["Weekly @ 2026-11-02T14:00:00Z"];

    it("follows the file's VTIMEZONE", () => {
      const text = calendarOf(NEW_YORK, weekly);
      expect(brief(upcoming(text, beforeTheChange))).toEqual(expected);
      expect(brief(upcoming(text, afterTheChange))).toEqual(expectedAfter);
    });

    it("follows the IANA zone when the file has no VTIMEZONE", () => {
      const text = calendarOf(weekly);
      expect(brief(upcoming(text, beforeTheChange))).toEqual(expected);
      expect(brief(upcoming(text, afterTheChange))).toEqual(expectedAfter);
    });

    it("follows it in spring too", () => {
      // Clocks go forward on Sunday 14 March 2027.
      const text = calendarOf(weekly);
      expect(brief(upcoming(text, new Date("2027-03-07T12:00:00Z")))).toEqual(["Weekly @ 2027-03-08T14:00:00Z"]);
      expect(brief(upcoming(text, new Date("2027-03-14T12:00:00Z")))).toEqual(["Weekly @ 2027-03-15T13:00:00Z"]);
      expect(brief(upcoming(calendarOf(NEW_YORK, weekly), new Date("2027-03-14T12:00:00Z")))).toEqual([
        "Weekly @ 2027-03-15T13:00:00Z",
      ]);
    });
  });

  it("prefers the file's VTIMEZONE over the IANA zone of the same name", () => {
    // A made-up definition: "America/New_York" at UTC+2 all year.
    const odd = [
      "BEGIN:VTIMEZONE",
      "TZID:America/New_York",
      "BEGIN:STANDARD",
      "TZOFFSETFROM:+0200",
      "TZOFFSETTO:+0200",
      "DTSTART:19700101T000000",
      "END:STANDARD",
      "END:VTIMEZONE",
    ];
    const event = vevent("SUMMARY:x", "DTSTART;TZID=America/New_York:20261117T090000");

    expect(brief(upcoming(calendarOf(odd, event)))).toEqual(["x @ 2026-11-17T07:00:00Z"]);
    expect(brief(upcoming(calendarOf(event)))).toEqual(["x @ 2026-11-17T14:00:00Z"]);
  });

  it("treats a TZID nobody can interpret as floating", () => {
    const text = calendarOf(vevent("SUMMARY:x", "DTSTART;TZID=Customized Time Zone 7:20261117T090000"));

    expect(brief(upcoming(text, NOW, "UTC"))).toEqual(["x @ 2026-11-17T09:00:00Z"]);
    expect(brief(upcoming(text, NOW, "America/Chicago"))).toEqual(["x @ 2026-11-17T15:00:00Z"]);
  });

  describe("Windows time zone names without a VTIMEZONE", () => {
    // 09:00 on 17 November 2026 and on 15 July 2027, wherever the zone is.
    it.each([
      ["Eastern Standard Time", "2026-11-17T14:00:00Z", "2027-07-15T13:00:00Z"],
      ["Central Standard Time", "2026-11-17T15:00:00Z", "2027-07-15T14:00:00Z"],
      ["Mountain Standard Time", "2026-11-17T16:00:00Z", "2027-07-15T15:00:00Z"],
      ["US Mountain Standard Time", "2026-11-17T16:00:00Z", "2027-07-15T16:00:00Z"],
      ["Pacific Standard Time", "2026-11-17T17:00:00Z", "2027-07-15T16:00:00Z"],
      ["Alaskan Standard Time", "2026-11-17T18:00:00Z", "2027-07-15T17:00:00Z"],
      ["Hawaiian Standard Time", "2026-11-17T19:00:00Z", "2027-07-15T19:00:00Z"],
      ["GMT Standard Time", "2026-11-17T09:00:00Z", "2027-07-15T08:00:00Z"],
      ["W. Europe Standard Time", "2026-11-17T08:00:00Z", "2027-07-15T07:00:00Z"],
      ["Romance Standard Time", "2026-11-17T08:00:00Z", "2027-07-15T07:00:00Z"],
      ["India Standard Time", "2026-11-17T03:30:00Z", "2027-07-15T03:30:00Z"],
      ["China Standard Time", "2026-11-17T01:00:00Z", "2027-07-15T01:00:00Z"],
      ["Tokyo Standard Time", "2026-11-17T00:00:00Z", "2027-07-15T00:00:00Z"],
      ["AUS Eastern Standard Time", "2026-11-16T22:00:00Z", "2027-07-14T23:00:00Z"],
      ["UTC", "2026-11-17T09:00:00Z", "2027-07-15T09:00:00Z"],
    ])("reads %s as its IANA zone, summer and winter", (tzid, winter, summer) => {
      const event = (date: string) => calendarOf(vevent("SUMMARY:x", `DTSTART;TZID=${tzid}:${date}T090000`));

      // Asked from Auckland, so a floating time would come out quite different.
      expect(brief(upcoming(event("20261117"), NOW, "Pacific/Auckland"))).toEqual([`x @ ${winter}`]);
      expect(brief(upcoming(event("20270715"), new Date("2027-07-12T00:00:00Z"), "Pacific/Auckland"))).toEqual([
        `x @ ${summer}`,
      ]);
    });

    it("maps every name to a zone the runtime knows", () => {
      const unknown = Object.entries(WINDOWS_ZONES).filter(([, iana]) => !isTimeZone(iana));

      expect(unknown).toEqual([]);
      expect(Object.keys(WINDOWS_ZONES).length).toBeGreaterThan(130);
    });

    it("still prefers the file's own definition of that name", () => {
      // The Outlook fixture defines "Eastern Standard Time" itself; here it is redefined as UTC+2.
      const odd = [
        "BEGIN:VTIMEZONE",
        "TZID:Eastern Standard Time",
        "BEGIN:STANDARD",
        "TZOFFSETFROM:+0200",
        "TZOFFSETTO:+0200",
        "DTSTART:19700101T000000",
        "END:STANDARD",
        "END:VTIMEZONE",
      ];
      const text = calendarOf(odd, vevent("SUMMARY:x", "DTSTART;TZID=Eastern Standard Time:20261117T090000"));

      expect(brief(upcoming(text))).toEqual(["x @ 2026-11-17T07:00:00Z"]);
    });

    it("does not take a property name on Object for a zone", () => {
      const text = calendarOf(vevent("SUMMARY:x", "DTSTART;TZID=constructor:20261117T090000"));

      expect(brief(upcoming(text))).toEqual(["x @ 2026-11-17T09:00:00Z"]);
    });
  });

  it("knows IANA names and nothing else", () => {
    expect(isTimeZone("America/New_York")).toBe(true);
    expect(isTimeZone("UTC")).toBe(true);
    expect(isTimeZone("Eastern Standard Time")).toBe(false);
    expect(isTimeZone("Mars/Olympus_Mons")).toBe(false);
    expect(isTimeZone("")).toBe(false);
  });
});

describe("time zone definitions in the file, read by our own code", () => {
  const block = (kind: string, start: string, from: string, to: string, ...more: string[]) => [
    `BEGIN:${kind}`,
    `DTSTART:${start}`,
    `TZOFFSETFROM:${from}`,
    `TZOFFSETTO:${to}`,
    ...more,
    `END:${kind}`,
  ];
  const zone = (...blocks: string[][]) => ["BEGIN:VTIMEZONE", "TZID:File/Zone", ...blocks.flat(), "END:VTIMEZONE"];

  // Each definition says what an IANA zone says, for the years given. A daily
  // event is read once through the file's definition and once through the
  // IANA zone (no VTIMEZONE), a window at a time across those years, and the
  // two must agree on every instant. The times of day stay clear of the hour
  // a clock change skips or repeats.
  const definitions: [string, string, number, number, string[]][] = [
    [
      "New York as Google writes it",
      "America/New_York",
      2008,
      2031,
      zone(
        block("DAYLIGHT", "20070311T020000", "-0500", "-0400", "RRULE:FREQ=YEARLY;BYMONTH=3;BYDAY=2SU"),
        block("STANDARD", "20071104T020000", "-0400", "-0500", "RRULE:FREQ=YEARLY;BYMONTH=11;BYDAY=1SU"),
      ),
    ],
    [
      "New York as Outlook writes it, from 1601",
      "America/New_York",
      2008,
      2031,
      zone(
        block("STANDARD", "16010101T020000", "-0400", "-0500", "RRULE:FREQ=YEARLY;INTERVAL=1;BYDAY=1SU;BYMONTH=11"),
        block("DAYLIGHT", "16010101T020000", "-0500", "-0400", "RRULE:FREQ=YEARLY;INTERVAL=1;BYDAY=2SU;BYMONTH=3"),
      ),
    ],
    [
      "New York with days of the month and a weekday",
      "America/New_York",
      2008,
      2031,
      zone(
        block("DAYLIGHT", "20070311T020000", "-0500", "-0400", "RRULE:FREQ=YEARLY;BYMONTH=3;BYMONTHDAY=8,9,10,11,12,13,14;BYDAY=SU"),
        block("STANDARD", "20071104T020000", "-0400", "-0500", "RRULE:FREQ=YEARLY;BYMONTH=11;BYMONTHDAY=1,2,3,4,5,6,7;BYDAY=SU"),
      ),
    ],
    [
      "New York with its earlier rules, ended by UNTIL",
      "America/New_York",
      1988,
      2031,
      zone(
        block("DAYLIGHT", "19870405T020000", "-0500", "-0400", "RRULE:FREQ=YEARLY;BYMONTH=4;BYDAY=1SU;UNTIL=20060402T070000Z"),
        block("STANDARD", "19671029T020000", "-0400", "-0500", "RRULE:FREQ=YEARLY;BYMONTH=10;BYDAY=-1SU;UNTIL=20061029T060000Z"),
        block("DAYLIGHT", "20070311T020000", "-0500", "-0400", "RRULE:FREQ=YEARLY;BYMONTH=3;BYDAY=2SU"),
        block("STANDARD", "20071104T020000", "-0400", "-0500", "RRULE:FREQ=YEARLY;BYMONTH=11;BYDAY=1SU"),
      ),
    ],
    [
      "Berlin, changing on last Sundays",
      "Europe/Berlin",
      1997,
      2031,
      zone(
        block("DAYLIGHT", "19960331T020000", "+0100", "+0200", "RRULE:FREQ=YEARLY;BYMONTH=3;BYDAY=-1SU"),
        block("STANDARD", "19961027T030000", "+0200", "+0100", "RRULE:FREQ=YEARLY;BYMONTH=10;BYDAY=-1SU"),
      ),
    ],
    [
      "Sydney, where summer spans the new year",
      "Australia/Sydney",
      2009,
      2031,
      zone(
        block("DAYLIGHT", "20081005T020000", "+1000", "+1100", "RRULE:FREQ=YEARLY;BYMONTH=10;BYDAY=1SU"),
        block("STANDARD", "20080406T030000", "+1100", "+1000", "RRULE:FREQ=YEARLY;BYMONTH=4;BYDAY=1SU"),
      ),
    ],
    ["Kolkata, which never changes", "Asia/Kolkata", 1990, 2031, zone(block("STANDARD", "19700101T000000", "+0530", "+0530"))],
    [
      "Phoenix, with changes listed as dates long ago",
      "America/Phoenix",
      1990,
      2031,
      zone(
        block("STANDARD", "19671029T020000", "-0600", "-0700", "RDATE:19671029T020000"),
        block("DAYLIGHT", "19670430T020000", "-0700", "-0600", "RDATE:19670430T020000"),
      ),
    ],
  ];

  it.each(definitions)("%s agrees with %s", (_name, iana, fromYear, toYear, definition) => {
    const series = (tzid: string) =>
      ["0030", "0330", "1200", "2330"].map((time) =>
        vevent(`SUMMARY:${time}`, `DTSTART;TZID=${tzid}:${fromYear - 1}0101T${time}00`, "RRULE:FREQ=DAILY"),
      );
    const fromFile = calendarOf(definition, ...series("File/Zone"));
    const fromIana = calendarOf(...series(iana));

    let compared = 0;
    for (let at = Date.UTC(fromYear, 0, 3); at < Date.UTC(toYear, 0, 1); at += 9 * 86_400_000) {
      const now = new Date(at);
      const ours = parseCalendar(fromFile, now);
      expect(ours, now.toISOString()).toEqual(parseCalendar(fromIana, now));
      compared += ours.events.length;
    }
    // Four events a day, nine days in ten kept.
    expect(compared).toBeGreaterThan((toYear - fromYear) * 365 * 3);
  });

  it("uses the offset before the first change for earlier times", () => {
    const definition = zone(block("STANDARD", "20300101T000000", "+0300", "+0500"));
    const text = calendarOf(definition, vevent("SUMMARY:x", "DTSTART;TZID=File/Zone:20261117T090000"));

    expect(brief(upcoming(text))).toEqual(["x @ 2026-11-17T06:00:00Z"]);
  });

  it("reads offsets with seconds and the first definition of a name", () => {
    const text = calendarOf(
      zone(block("STANDARD", "19000101T000000", "+002000", "+001932")),
      zone(block("STANDARD", "19000101T000000", "+0900", "+0900")),
      vevent("SUMMARY:x", "DTSTART;TZID=File/Zone:20261117T090000"),
    );

    expect(brief(upcoming(text))).toEqual(["x @ 2026-11-17T08:40:28Z"]);
  });

  it.each([
    ["no DTSTART", ["BEGIN:STANDARD", "TZOFFSETFROM:+0200", "TZOFFSETTO:+0200", "END:STANDARD"]],
    ["a date for DTSTART", ["BEGIN:STANDARD", "DTSTART;VALUE=DATE:19700101", "TZOFFSETFROM:+0200", "TZOFFSETTO:+0200", "END:STANDARD"]],
    ["no TZOFFSETTO", ["BEGIN:STANDARD", "DTSTART:19700101T000000", "TZOFFSETFROM:+0200", "END:STANDARD"]],
    ["an offset that is not one", ["BEGIN:STANDARD", "DTSTART:19700101T000000", "TZOFFSETFROM:+0200", "TZOFFSETTO:+9900", "END:STANDARD"]],
    ["no blocks", []],
  ])("does not use a definition with %s", (_name, blocks) => {
    const text = calendarOf(
      ["BEGIN:VTIMEZONE", "TZID:File/Zone", ...blocks, "END:VTIMEZONE"],
      vevent("SUMMARY:x", "DTSTART;TZID=File/Zone:20261117T090000"),
    );

    // Floating: 09:00 as written.
    expect(brief(upcoming(text))).toEqual(["x @ 2026-11-17T09:00:00Z"]);
  });
});

describe("repeating events", () => {
  it("applies an EXDATE written in UTC to a series in a named zone", () => {
    const text = calendarOf(
      vevent(
        "SUMMARY:Daily",
        "DTSTART;TZID=America/New_York:20261110T090000",
        "RRULE:FREQ=DAILY",
        "EXDATE:20261117T140000Z",
        "EXDATE;TZID=America/New_York:20261119T090000,20261120T090000",
      ),
    );

    expect(brief(upcoming(text))).toEqual([
      "Daily @ 2026-11-18T14:00:00Z",
      "Daily @ 2026-11-21T14:00:00Z",
      "Daily @ 2026-11-22T14:00:00Z",
      "Daily @ 2026-11-23T14:00:00Z",
    ]);
  });

  it("applies an EXDATE to an all-day series", () => {
    const text = calendarOf(
      vevent("SUMMARY:Daily", "DTSTART;VALUE=DATE:20261101", "RRULE:FREQ=DAILY;COUNT=20", "EXDATE;VALUE=DATE:20261118"),
    );

    expect(upcoming(text).map((event) => event.date)).toEqual([
      "2026-11-16",
      "2026-11-17",
      "2026-11-19",
      "2026-11-20",
    ]);
  });

  it("applies EXDATE;VALUE=DATE to a timed series as that local day", () => {
    const text = calendarOf(
      // 21:00 in New York is 02:00 UTC the next day: the local day is what counts.
      vevent(
        "SUMMARY:Evening",
        "DTSTART;TZID=America/New_York:20261110T210000",
        "RRULE:FREQ=DAILY",
        "EXDATE;VALUE=DATE:20261117,20261119",
      ),
      vevent("SUMMARY:Utc", "DTSTART:20261110T030000Z", "RRULE:FREQ=DAILY;COUNT=10", "EXDATE;VALUE=DATE:20261118"),
    );

    const found = brief(upcoming(text));

    expect(found.filter((line) => line.startsWith("Evening"))).toEqual([
      "Evening @ 2026-11-17T02:00:00Z", // Monday the 16th, local
      "Evening @ 2026-11-19T02:00:00Z", // Wednesday the 18th
      "Evening @ 2026-11-21T02:00:00Z", // Friday the 20th
      "Evening @ 2026-11-22T02:00:00Z",
      "Evening @ 2026-11-23T02:00:00Z",
    ]);
    expect(found.filter((line) => line.startsWith("Utc"))).toEqual([
      "Utc @ 2026-11-17T03:00:00Z",
      "Utc @ 2026-11-19T03:00:00Z",
    ]);
  });

  it("moves an overridden instance into the window from outside it, and out of it", () => {
    const uid = "UID:moved@example.com";
    const text = calendarOf(
      vevent(uid, "SUMMARY:Monthly", "DTSTART:20260105T100000Z", "DTEND:20260105T110000Z", "RRULE:FREQ=MONTHLY"),
      // December's instance is brought forward to this week.
      vevent(uid, "SUMMARY:Monthly (early)", "RECURRENCE-ID:20261205T100000Z", "DTSTART:20261118T100000Z", "DTEND:20261118T110000Z"),
      vevent("UID:weekly@example.com", "SUMMARY:Weekly", "DTSTART:20261103T100000Z", "RRULE:FREQ=WEEKLY"),
      // This week's instance is pushed out to January.
      vevent("UID:weekly@example.com", "SUMMARY:Weekly", "RECURRENCE-ID:20261117T100000Z", "DTSTART:20270112T100000Z"),
    );

    expect(brief(upcoming(text))).toEqual(["Monthly (early) @ 2026-11-18T10:00:00Z"]);
  });

  it("matches an override to its instance when one is in UTC and the other in a zone", () => {
    const uid = "UID:mixed@example.com";
    const text = calendarOf(
      vevent(uid, "SUMMARY:Daily", "DTSTART;TZID=America/New_York:20261110T090000", "RRULE:FREQ=DAILY;UNTIL=20261119T140000Z"),
      vevent(uid, "SUMMARY:Daily (moved)", "RECURRENCE-ID:20261118T140000Z", "DTSTART:20261118T180000Z"),
    );

    expect(brief(upcoming(text))).toEqual([
      "Daily @ 2026-11-17T14:00:00Z",
      "Daily (moved) @ 2026-11-18T18:00:00Z",
      "Daily @ 2026-11-19T14:00:00Z",
    ]);
  });

  it("removes a cancelled instance and a cancelled series", () => {
    const uid = "UID:cancelled@example.com";
    const text = calendarOf(
      vevent(uid, "SUMMARY:Daily", "DTSTART:20261116T200000Z", "RRULE:FREQ=DAILY;COUNT=3"),
      vevent(uid, "SUMMARY:Daily", "RECURRENCE-ID:20261117T200000Z", "DTSTART:20261117T200000Z", "STATUS:CANCELLED"),
      vevent("SUMMARY:Whole series", "DTSTART:20261116T210000Z", "RRULE:FREQ=DAILY;COUNT=3", "STATUS:CANCELLED"),
      vevent("SUMMARY:lower case", "DTSTART:20261116T220000Z", "STATUS:cancelled"),
    );

    expect(brief(upcoming(text))).toEqual(["Daily @ 2026-11-16T20:00:00Z", "Daily @ 2026-11-18T20:00:00Z"]);
  });

  it("honours COUNT, UNTIL and INTERVAL", () => {
    const text = calendarOf(
      vevent("SUMMARY:count", "DTSTART:20261114T100000Z", "RRULE:freq=daily;count=4"),
      vevent("SUMMARY:until", "DTSTART:20261114T110000Z", "RRULE:FREQ=DAILY;UNTIL=20261118T110000Z"),
      vevent("SUMMARY:every third day", "DTSTART:20261101T120000Z", "RRULE:FREQ=DAILY;INTERVAL=3"),
      vevent("SUMMARY:every other week", "DTSTART:20260105T130000Z", "RRULE:FREQ=WEEKLY;INTERVAL=2;BYDAY=MO,FR"),
    );

    expect(brief(upcoming(text))).toEqual([
      "count @ 2026-11-17T10:00:00Z",
      "until @ 2026-11-17T11:00:00Z",
      "until @ 2026-11-18T11:00:00Z",
      "every third day @ 2026-11-19T12:00:00Z",
      "every third day @ 2026-11-22T12:00:00Z",
      // 5 January 2026 is a Monday; 16 November is 45 weeks on, an odd week.
      // Even weeks are the 9th and the 23rd.
      "every other week @ 2026-11-23T13:00:00Z",
    ]);
  });

  it("includes RDATE instances", () => {
    const text = calendarOf(
      vevent("SUMMARY:listed", "DTSTART:20261101T100000Z", "RDATE:20261117T100000Z,20261119T100000Z,20270101T100000Z"),
    );

    expect(brief(upcoming(text))).toEqual(["listed @ 2026-11-17T10:00:00Z", "listed @ 2026-11-19T10:00:00Z"]);
  });

  it("ignores RANGE=THISANDFUTURE and repeat rules on an override", () => {
    const uid = "UID:range@example.com";
    const text = calendarOf(
      vevent(uid, "SUMMARY:Daily", "DTSTART:20261116T200000Z", "RRULE:FREQ=DAILY;COUNT=3"),
      vevent(
        uid,
        "SUMMARY:Daily (later)",
        "RECURRENCE-ID;RANGE=THISANDFUTURE:20261117T200000Z",
        "DTSTART:20261117T210000Z",
        "RRULE:FREQ=DAILY",
      ),
    );

    expect(brief(upcoming(text))).toEqual([
      "Daily @ 2026-11-16T20:00:00Z",
      "Daily (later) @ 2026-11-17T21:00:00Z",
      "Daily @ 2026-11-18T20:00:00Z",
    ]);
  });

  describe("our own expansion agrees with ical.js's iterator on the rules apps write", () => {
    // ical.js is safe to iterate on these shapes. (It is not used to expand
    // events in the Worker: see `expandRule`.)
    const rules: [string, string][] = [
      ["19990104T090000Z", "FREQ=DAILY"],
      ["20100104T090000Z", "FREQ=DAILY;INTERVAL=3"],
      ["20100104T090000Z", "FREQ=DAILY;BYDAY=MO,TU,WE,TH,FR"],
      ["20100103T090000Z", "FREQ=DAILY;BYDAY=TU,TH"],
      ["20100104T090000Z", "FREQ=DAILY;BYMONTH=11,12"],
      ["20100104T090000Z", "FREQ=DAILY;UNTIL=20261120T090000Z"],
      ["20260104T090000Z", "FREQ=DAILY;COUNT=320"],
      ["20100104T090000Z", "FREQ=WEEKLY"],
      ["20100104T090000Z", "FREQ=WEEKLY;BYDAY=MO,WE,FR"],
      ["20100105T090000Z", "FREQ=WEEKLY;BYDAY=MO,WE,FR"],
      ["20100104T090000Z", "FREQ=WEEKLY;INTERVAL=2;BYDAY=TU,SU;WKST=SU"],
      ["20100104T090000Z", "FREQ=WEEKLY;INTERVAL=2;BYDAY=TU,SU;WKST=MO"],
      ["20100106T090000Z", "FREQ=WEEKLY;INTERVAL=3"],
      ["20260105T090000Z", "FREQ=WEEKLY;BYDAY=MO,TH;COUNT=92"],
      ["20100127T090000Z", "FREQ=MONTHLY"],
      ["20100127T090000Z", "FREQ=MONTHLY;INTERVAL=5"],
      ["20100104T090000Z", "FREQ=MONTHLY;BYMONTHDAY=18"],
      ["20100104T090000Z", "FREQ=MONTHLY;BYMONTHDAY=-10"],
      ["20100104T090000Z", "FREQ=MONTHLY;BYMONTHDAY=-1"],
      ["20100104T090000Z", "FREQ=MONTHLY;BYDAY=3TU"],
      ["20100104T090000Z", "FREQ=MONTHLY;BYDAY=-2FR"],
      ["20100104T090000Z", "FREQ=MONTHLY;BYDAY=MO,TU,WE,TH,FR;BYSETPOS=-1"],
      ["20100104T090000Z", "FREQ=MONTHLY;BYDAY=TH;BYSETPOS=3"],
      ["20100104T090000Z", "FREQ=MONTHLY;INTERVAL=2;BYDAY=3WE"],
      ["20250120T090000Z", "FREQ=MONTHLY;BYDAY=3TU;COUNT=24"],
      ["19701118T090000Z", "FREQ=YEARLY"],
      ["19701119T090000Z", "FREQ=YEARLY;INTERVAL=2"],
      ["19701126T090000Z", "FREQ=YEARLY;BYMONTH=11;BYDAY=4TH"],
      ["19701120T090000Z", "FREQ=YEARLY;BYMONTH=11;BYMONTHDAY=20"],
      ["19701119T090000Z", "FREQ=YEARLY;BYMONTH=11;BYDAY=TH;BYSETPOS=3"],
      ["19701118", "FREQ=YEARLY"],
      ["20100104", "FREQ=WEEKLY;BYDAY=MO,SA"],
    ];
    const nows = [
      NOW,
      new Date("2026-11-20T08:00:00Z"),
      new Date("2027-02-25T00:00:00Z"),
      new Date("2028-12-27T23:00:00Z"),
    ];
    const eventOf = (start: string, rule: string) =>
      calendarOf(vevent("SUMMARY:x", start.length === 8 ? `DTSTART;VALUE=DATE:${start}` : `DTSTART:${start}`, `RRULE:${rule}`));

    /** What ical.js's iterator gives for the kept window, the way `parseCalendar` reports it. */
    function reference(start: string, rule: string, now: Date) {
      const allDay = start.length === 8;
      const length = allDay ? 86400 : 0;
      const keepFrom = now.getTime() / 1000 - 86400;
      const keepUntil = now.getTime() / 1000 + 8 * 86400;
      const vcalendar = new ICAL.Component(ICAL.parse(eventOf(start, rule)));
      const iterator = new ICAL.Event(vcalendar.getFirstSubcomponent("vevent")!).iterator();
      const events = [];
      for (let steps = 0; steps < 30_000; steps++) {
        const next = iterator.next();
        if (!next) break;
        const at = Date.UTC(next.year, next.month - 1, next.day, next.hour, next.minute, next.second) / 1000;
        if (at >= keepUntil) break;
        if (at + length > keepFrom) events.push({ kind: allDay ? "allDay" : "instant", title: "x", start: at, end: at + length });
      }
      return events;
    }

    it.each(rules)("DTSTART %s, %s", (start, rule) => {
      for (const now of nows) {
        expect(parseCalendar(eventOf(start, rule), now)).toEqual({ events: reference(start, rule, now), partial: false });
      }
    });

    it("finds occurrences for every one of them at some date, so the comparison is not empty", () => {
      const empty = rules.filter(([start, rule]) =>
        nows.every((now) => parseCalendar(eventOf(start, rule), now).events.length === 0),
      );
      expect(empty).toEqual([]);
    });
  });

  describe("rules worked out by hand", () => {
    const starts = (start: string, rule: string, now: Date) =>
      parseCalendar(calendarOf(vevent("SUMMARY:x", `DTSTART:${start}`, `RRULE:${rule}`)), now).events.map((event) =>
        new Date(event.start * 1000).toISOString().slice(0, 16),
      );

    it("skips months that lack the day, and years without 29 February", () => {
      // The 31st, monthly: no February, April, June.
      expect(starts("20260131T100000Z", "FREQ=MONTHLY", new Date("2026-02-25T00:00:00Z"))).toEqual([]);
      expect(starts("20260131T100000Z", "FREQ=MONTHLY", new Date("2026-03-25T00:00:00Z"))).toEqual(["2026-03-31T10:00"]);
      expect(starts("20240229T100000Z", "FREQ=YEARLY", new Date("2027-02-25T00:00:00Z"))).toEqual([]);
      expect(starts("20240229T100000Z", "FREQ=YEARLY", new Date("2028-02-25T00:00:00Z"))).toEqual(["2028-02-29T10:00"]);
      expect(starts("20200131T100000Z", "FREQ=YEARLY;BYMONTH=2;BYMONTHDAY=-1", new Date("2027-02-25T00:00:00Z"))).toEqual([
        "2027-02-28T10:00",
      ]);
    });

    it("keeps to the interval's months when months are also listed", () => {
      // Every fourth month from February: February, June, October. Of the
      // listed January and June, only June ever comes up.
      const rule = "FREQ=MONTHLY;INTERVAL=4;BYDAY=SA;BYMONTH=1,6";
      expect(starts("20260210T100000Z", rule, new Date("2026-12-28T05:00:00Z"))).toEqual([]);
      expect(starts("20260210T100000Z", rule, new Date("2027-05-29T00:00:00Z"))).toEqual(["2027-06-05T10:00"]);
    });

    it("narrows days of the month by weekday", () => {
      // Friday the 13th: November 2026 has one, December does not.
      const rule = "FREQ=MONTHLY;BYDAY=FR;BYMONTHDAY=13";
      expect(starts("20260213T100000Z", rule, new Date("2026-11-10T00:00:00Z"))).toEqual(["2026-11-13T10:00"]);
      expect(starts("20260213T100000Z", rule, new Date("2026-12-10T00:00:00Z"))).toEqual([]);
    });

    it("counts DTSTART as the first of COUNT even when the rule does not match it", () => {
      // Tuesday 10 November, then Mondays: the 16th and the 23rd make three.
      expect(starts("20261110T100000Z", "FREQ=WEEKLY;BYDAY=MO;COUNT=3", new Date("2026-11-22T00:00:00Z"))).toEqual([
        "2026-11-23T10:00",
      ]);
      expect(starts("20261110T100000Z", "FREQ=WEEKLY;BYDAY=MO;COUNT=3", new Date("2026-11-29T00:00:00Z"))).toEqual([]);
    });

    it("gives DTSTART alone when UNTIL is earlier than it", () => {
      for (const until of ["20261101T000000Z", "20200101T000000Z", "20261116", "19990101"]) {
        for (const rule of [`FREQ=DAILY;UNTIL=${until}`, `FREQ=WEEKLY;BYDAY=MO,TU,WE;UNTIL=${until}`, `FREQ=MONTHLY;UNTIL=${until}`]) {
          expect(starts("20261117T100000Z", rule, NOW), rule).toEqual(["2026-11-17T10:00"]);
        }
      }
      // And nothing once DTSTART itself has passed.
      expect(starts("20261117T100000Z", "FREQ=DAILY;UNTIL=20200101T000000Z", new Date("2026-11-25T00:00:00Z"))).toEqual([]);
    });

    it("reads UNTIL as a UTC instant, a local time or a date", () => {
      const daily = (until: string, tzid = "") =>
        parseCalendar(
          calendarOf(vevent("SUMMARY:x", `DTSTART${tzid}:20261110T200000`, `RRULE:FREQ=DAILY;UNTIL=${until}`)),
          NOW,
        ).events.map((event) => new Date(event.start * 1000).toISOString().slice(0, 16));
      const newYork = ";TZID=America/New_York";

      // 20:00 in New York is 01:00 UTC the next day.
      expect(daily("20261119T010000Z", newYork)).toEqual(["2026-11-16T01:00", "2026-11-17T01:00", "2026-11-18T01:00", "2026-11-19T01:00"]);
      expect(daily("20261119T005959Z", newYork)).toEqual(["2026-11-16T01:00", "2026-11-17T01:00", "2026-11-18T01:00"]);
      expect(daily("20261117", newYork)).toEqual(["2026-11-16T01:00", "2026-11-17T01:00", "2026-11-18T01:00"]);
      expect(daily("20261117T200000")).toEqual(["2026-11-15T20:00", "2026-11-16T20:00", "2026-11-17T20:00"]);
    });
  });
});

describe("hostile and broken files", () => {
  it.each([
    ["an empty body", ""],
    ["a web page", "<!doctype html><html><body>Sign in to continue</body></html>"],
    ["JSON", '{"error":"not found"}'],
    ["a vCard", "BEGIN:VCARD\r\nVERSION:4.0\r\nFN:Someone\r\nEND:VCARD"],
    ["a calendar cut off mid-way", "BEGIN:VCALENDAR\r\nVERSION:2.0\r\nBEGIN:VEVENT\r\nSUMMARY:x"],
    ["a calendar whose components do not close", "BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nEND:VCALENDAR"],
  ])("refuses %s", (_name, text) => {
    expect(() => parseCalendar(text, NOW)).toThrow(CalendarParseError);
  });

  it("does not quote the file in its error", () => {
    try {
      parseCalendar("BEGIN:VCALENDAR\r\nsecret-line-content\r\nEND:VCALENDAR", NOW);
      expect.unreachable();
    } catch (error) {
      expect(String((error as Error).message)).not.toContain("secret-line-content");
    }
  });

  it("leaves out a line that is not a property, and says so", () => {
    const text = calendarOf(vevent("SUMMARY:x", "this line has no colon", "DTSTART:20261117T100000Z"));

    const parsed = parseCalendar(text, NOW);

    expect(parsed.events.map((event) => event.title)).toEqual(["x"]);
    expect(parsed.partial).toBe(true);
  });

  it("is not put off by values it does not read, however malformed", () => {
    const text = calendarOf(
      vevent(
        "SUMMARY:x",
        "DTSTART:20261117T100000Z",
        "X-ANY;VALUE=RECUR:FREQ=FOO",
        "X-P;VALUE=PERIOD:garbage",
        "FREEBUSY:garbage",
        "REQUEST-STATUS:zz",
        "ATTACH;VALUE=BINARY:@@@",
        "GEO:nowhere",
        "TRIGGER;VALUE=RECUR:FREQ=FOO",
        "SEQUENCE:abc",
        "SUMMARY-ISH;VALUE=RECUR:freq=secondly",
      ),
    );

    expect(parseCalendar(text, NOW)).toMatchObject({ partial: false, events: [{ title: "x" }] });
  });

  it("reads a line with 200,000 parameters, or 2 MB long, at once", () => {
    // ical.js takes two to three seconds over the first of these.
    const event = (line: string) => calendarOf(vevent("SUMMARY:x", "DTSTART:20261117T100000Z", line));
    const texts = [
      event(`X-P${";A=1".repeat(200_000)}:v`),
      event(`DTEND${';A="b;:"'.repeat(150_000)};TZID=America/New_York:20261117T060000`),
      event(`DESCRIPTION:${"x".repeat(2_000_000)}`),
      event(`CATEGORIES:${"a,".repeat(500_000)}`),
    ];

    for (const text of texts) {
      const started = performance.now();
      const parsed = parseCalendar(text, NOW);
      expect(performance.now() - started).toBeLessThan(5000);
      expect(parsed.events.map((item) => item.title)).toEqual(["x"]);
    }
    // The TZID after 150,000 other parameters is still read: 06:00 in New York.
    expect(parseCalendar(texts[1] as string, NOW).events[0]).toMatchObject({ start: 1794909600, end: 1794913200 });
  });

  it("accepts a byte-order mark and leading blank lines", () => {
    const text = "﻿\r\n" + calendarOf(vevent("SUMMARY:x", "DTSTART:20261117T100000Z"));
    expect(brief(upcoming(text))).toEqual(["x @ 2026-11-17T10:00:00Z"]);
  });

  it("reads every calendar of a file that holds several", () => {
    const text = [
      calendarOf(vevent("SUMMARY:first", "DTSTART:20261117T100000Z")),
      calendarOf(NEW_YORK, vevent("SUMMARY:second", "DTSTART;TZID=America/New_York:20261117T070000")),
      calendarOf(vevent("SUMMARY:third", "DTSTART:20261117T140000Z")),
    ].join("\r\n");

    expect(parseCalendar(text, NOW).partial).toBe(false);
    expect(brief(upcoming(text))).toEqual([
      "first @ 2026-11-17T10:00:00Z",
      "second @ 2026-11-17T12:00:00Z",
      "third @ 2026-11-17T14:00:00Z",
    ]);
  });

  it("reads the first 20 calendars of a file and says the rest was left out", () => {
    const text = Array.from({ length: 25 }, (_, i) =>
      calendarOf(vevent(`SUMMARY:c${i}`, `DTSTART:20261117T10${String(i).padStart(2, "0")}00Z`)),
    ).join("\r\n");

    const parsed = parseCalendar(text, NOW);

    expect(parsed.partial).toBe(true);
    expect(parsed.events.map((event) => event.title)).toEqual(Array.from({ length: 20 }, (_, i) => `c${i}`));
  });

  it("reads an empty calendar as no events", () => {
    expect(parseCalendar(calendarOf(), NOW)).toEqual({ events: [], partial: false });
  });

  it("skips an event it cannot read and keeps the rest", () => {
    const text = calendarOf(
      vevent("SUMMARY:no start"),
      vevent("SUMMARY:year 0900", "DTSTART:09001117T100000Z"),
      vevent("SUMMARY:good", "DTSTART:20261117T100000Z"),
      vevent("DTSTART:20261117T110000Z"),
    );

    expect(brief(upcoming(text))).toEqual(["good @ 2026-11-17T10:00:00Z", " @ 2026-11-17T11:00:00Z"]);
  });

  it("tidies the title", () => {
    const text = calendarOf(
      vevent("SUMMARY:  Line one\\nline two\\,  with   spaces ", "DTSTART:20261117T100000Z"),
      vevent(`SUMMARY:${"x".repeat(60)}`, " " + "y".repeat(400), "DTSTART:20261117T110000Z"),
    );

    const [first, second] = upcoming(text);
    expect(first?.title).toBe("Line one line two, with spaces");
    expect(second?.title).toHaveLength(200);
  });

  // Each of these makes ical.js's iterator search for a date that never
  // comes, or step through an enormous span, inside one call that cannot be
  // interrupted (45 seconds and more). The last four got past an earlier
  // whitelist: an interval that is a multiple of 12 pins the month, and
  // February of a year that is never a leap year has no fifth Monday.
  const spinners: [string, string][] = [
    ["20261102T090000Z", "FREQ=DAILY;BYMONTH=2;BYMONTHDAY=30"],
    ["20261102T090000Z", "FREQ=DAILY;BYMONTHDAY=-31;BYMONTH=2"],
    ["20261102T090000Z", "FREQ=DAILY;INTERVAL=7;BYDAY=TU"],
    ["20261102T090000Z", "FREQ=MONTHLY;BYMONTH=2;BYMONTHDAY=30"],
    ["20261102T090000Z", "FREQ=MONTHLY;BYMONTH=4,6;BYMONTHDAY=31"],
    ["20261102T090000Z", "FREQ=YEARLY;BYDAY=MO;BYMONTHDAY=30;BYMONTH=2"],
    ["20261102T090000Z", "FREQ=MONTHLY;BYDAY=2TU,-5SA;BYSETPOS=-2"],
    ["20261102T090000Z", "FREQ=MONTHLY;BYDAY=5MO;BYMONTH=2"],
    ["20261102T090000Z", "FREQ=WEEKLY;INTERVAL=100;BYMONTH=12,4"],
    ["20261102T090000Z", "FREQ=DAILY;INTERVAL=1000;BYMONTH=2;BYMONTHDAY=30"],
    ["20260210T100000Z", "FREQ=MONTHLY;INTERVAL=48;BYDAY=5MO"],
    ["20260210T100000Z", "FREQ=MONTHLY;INTERVAL=96;BYDAY=5MO"],
    ["20260210T100000Z", "FREQ=MONTHLY;INTERVAL=48;BYDAY=-5MO"],
    ["19010228T000000Z", "FREQ=MONTHLY;INTERVAL=48;BYDAY=5MO,5TU"],
  ];

  it.each(spinners)("expands DTSTART %s, %s itself, at once", (start, rule) => {
    const text = calendarOf(
      vevent("SUMMARY:trap", `DTSTART:${start}`, `RRULE:${rule}`),
      vevent("SUMMARY:trap with count", `DTSTART:${start}`, `RRULE:${rule};COUNT=1000000`),
      vevent("SUMMARY:good", "DTSTART:20261117T100000Z"),
    );

    for (const now of [NOW, new Date("2030-02-20T00:00:00Z"), new Date("2126-02-20T00:00:00Z")]) {
      const started = performance.now();
      const parsed = parseCalendar(text, now);
      expect(performance.now() - started).toBeLessThan(5000);
      expect(parsed.partial).toBe(false);
    }
  });

  it("finds the rare dates those rules do have, and none where there are none", () => {
    const starts = (start: string, rule: string, now: string) =>
      parseCalendar(calendarOf(vevent("SUMMARY:x", `DTSTART:${start}`, `RRULE:${rule}`)), new Date(now)).events.map(
        (event) => new Date(event.start * 1000).toISOString().slice(0, 10),
      );

    // February 2030, 2034 … are never leap years: no fifth Monday, ever.
    expect(starts("20260210T100000Z", "FREQ=MONTHLY;INTERVAL=48;BYDAY=5MO", "2030-02-20T00:00:00Z")).toEqual([]);
    // DTSTART itself is always an occurrence.
    expect(starts("20260210T100000Z", "FREQ=MONTHLY;INTERVAL=48;BYDAY=5MO", "2026-02-08T00:00:00Z")).toEqual(["2026-02-10"]);
    // 29 February 2044 is a Monday, the fifth of that month.
    expect(starts("20261102T090000Z", "FREQ=MONTHLY;BYDAY=5MO;BYMONTH=2", "2044-02-25T00:00:00Z")).toEqual(["2044-02-29"]);
    expect(starts("20261102T090000Z", "FREQ=MONTHLY;BYDAY=5MO;BYMONTH=2", "2045-02-25T00:00:00Z")).toEqual([]);
    // Every seventh day from Monday 2 November is a Monday, never a Tuesday.
    expect(starts("20261102T090000Z", "FREQ=DAILY;INTERVAL=7;BYDAY=TU", "2026-11-16T15:00:00Z")).toEqual([]);
    expect(starts("20261102T090000Z", "FREQ=DAILY;BYMONTH=2;BYMONTHDAY=30", "2027-02-25T00:00:00Z")).toEqual([]);
  });

  it("expands thousands of generated rules, each well within a time budget", () => {
    // The same generator as the Node fuzz run recorded in the task log, at a
    // smaller size: large intervals, fifth weekdays, days that few months
    // have, dates from 1900 to 2100. Nothing here can hang, because no rule
    // is handed to ical.js; this checks that nothing is slow either.
    let seed = 20261116;
    const random = () => ((seed = (seed * 1664525 + 1013904223) >>> 0) / 2 ** 32);
    const pick = <T,>(items: T[]) => items[Math.floor(random() * items.length)] as T;
    const some = <T,>(items: T[], max: number) =>
      [...new Set(Array.from({ length: 1 + Math.floor(random() * max) }, () => pick(items)))];
    const weekdays = ["SU", "MO", "TU", "WE", "TH", "FR", "SA"];
    const startDates = ["20260210T100000Z", "19010228T000000Z", "19000101T000000Z", "20240229T090000Z", "20230131T233000Z", "20221231", "21000228T100000Z"];
    const nows = [NOW, new Date("2028-02-27T12:00:00Z"), new Date("2100-03-01T00:00:00Z")];

    let slowest = 0;
    let expanded = 0;
    for (let n = 0; n < 1500; n++) {
      const parts = [`FREQ=${pick(["MONTHLY", "MONTHLY", "YEARLY", "YEARLY", "WEEKLY", "DAILY"])}`];
      if (random() < 0.7) parts.push(`INTERVAL=${pick([12, 24, 36, 48, 96, 120, 400, 1000, 7, 5, 13])}`);
      if (random() < 0.7) parts.push(`BYDAY=${some(weekdays, 4).map((day) => pick(["", "1", "4", "5", "-1", "-5"]) + day).join(",")}`);
      if (random() < 0.4) parts.push(`BYMONTHDAY=${some([1, 29, 30, 31, -1, -30, -31, 13], 3).join(",")}`);
      if (random() < 0.5) parts.push(`BYMONTH=${some([1, 2, 4, 6, 9, 11, 12], 3).join(",")}`);
      if (random() < 0.3) parts.push(`BYSETPOS=${some([1, 5, -1, -5, 20, -366], 2).join(",")}`);
      if (random() < 0.3) parts.push(`COUNT=${pick([1, 2, 1000, 99999999])}`);
      const start = pick(startDates);
      const dtstart = start.length === 8 ? `DTSTART;VALUE=DATE:${start}` : `DTSTART:${start}`;
      const text = calendarOf(vevent("SUMMARY:x", dtstart, `RRULE:${parts.join(";")}`));
      const now = pick(nows);

      const started = performance.now();
      const parsed = parseCalendar(text, now);
      const took = performance.now() - started;

      slowest = Math.max(slowest, took);
      if (!parsed.partial) expanded++;
      expect(took, `${start} ${parts.join(";")}`).toBeLessThan(5000);
    }
    // Most of them are shapes we expand, not shapes we skip.
    expect(expanded).toBeGreaterThan(700);
    expect(slowest).toBeLessThan(5000);
  });

  it.each([
    "FREQ=SECONDLY",
    "FREQ=MINUTELY",
    "FREQ=HOURLY",
    "FREQ=SECONDLY;BYMONTH=6",
    "FREQ=DAILY;INTERVAL=1000000",
    "FREQ=DAILY;BYHOUR=9,10;BYMINUTE=0,30",
    "FREQ=YEARLY;BYWEEKNO=20;BYDAY=MO",
    "FREQ=YEARLY;BYYEARDAY=100",
    "FREQ=YEARLY;BYDAY=20MO",
    "FREQ=YEARLY;BYDAY=MO",
    "FREQ=YEARLY;BYMONTHDAY=15",
    "FREQ=MONTHLY;BYSETPOS=1",
    "FREQ=WEEKLY;BYDAY=2MO",
    "FREQ=MONTHLY;BYDAY=6MO",
    // Malformed.
    "FREQ=FOO",
    "FREQ=DAILY;COUNT=abc",
    "FREQ=WEEKLY;BYDAY=XX",
    "FREQ=YEARLY;BYMONTH=13",
    "FREQ=MONTHLY;BYDAY=MO;BYSETPOS=400",
    "FREQ=DAILY;UNTIL=whenever",
    "BYDAY=MO",
    "",
    "garbage",
  ])("does not support %s", (rule) => {
    expect(readRule(rule)).toBeNull();
  });

  it.each([
    "FREQ=DAILY",
    "FREQ=DAILY;INTERVAL=2;COUNT=10",
    "FREQ=DAILY;BYDAY=MO,TU,WE,TH,FR",
    "FREQ=WEEKLY;WKST=SU;BYDAY=MO,WE",
    "FREQ=WEEKLY;UNTIL=20261218T140000Z;INTERVAL=1;BYDAY=FR;WKST=SU",
    "FREQ=MONTHLY;BYMONTHDAY=15",
    "FREQ=MONTHLY;BYMONTHDAY=-1",
    "FREQ=MONTHLY;INTERVAL=1;BYDAY=2TU",
    "FREQ=MONTHLY;BYDAY=-1FR",
    "FREQ=MONTHLY;BYDAY=MO,TU,WE,TH,FR;BYSETPOS=-1",
    "FREQ=MONTHLY;BYDAY=TU;BYSETPOS=2",
    "FREQ=YEARLY",
    "FREQ=YEARLY;BYMONTH=2;BYMONTHDAY=29",
    "FREQ=YEARLY;INTERVAL=1;BYMONTHDAY=15;BYMONTH=11",
    "FREQ=YEARLY;BYMONTH=11;BYDAY=4TH",
    "FREQ=YEARLY;BYMONTH=11;BYDAY=TH;BYSETPOS=4",
    "FREQ=YEARLY;BYMONTH=3;BYDAY=2SU",
  ])("supports %s, as calendar apps write it", (rule) => {
    expect(readRule(rule)).not.toBeNull();
  });

  it("skips an event whose rule is malformed or unsupported, and keeps the rest of the calendar", () => {
    const bad = ["FREQ=FOO", "FREQ=DAILY;COUNT=abc", "FREQ=WEEKLY;BYDAY=XX", "FREQ=YEARLY;BYMONTH=13", "FREQ=MONTHLY;BYDAY=MO;BYSETPOS=400", "FREQ=SECONDLY", ""];
    const text = calendarOf(
      ...bad.map((rule, i) => vevent(`SUMMARY:bad ${i}`, "DTSTART:20261117T090000Z", `RRULE:${rule}`)),
      vevent("SUMMARY:withdrawn exclusion rule", "DTSTART:20261117T090000Z", "RRULE:FREQ=DAILY", "EXRULE:FREQ=FOO"),
      vevent("SUMMARY:good", "DTSTART:20261117T100000Z"),
      vevent("SUMMARY:good series", "DTSTART:20261117T110000Z", "rrule:FREQ=DAILY;COUNT=2"),
    );

    const parsed = parseCalendar(text, NOW);

    expect(parsed.partial).toBe(true);
    expect(parsed.events.map((event) => event.title)).toEqual(["good", "good series", "good series"]);
    // The same file with only the good events is complete.
    const clean = calendarOf(vevent("SUMMARY:good", "DTSTART:20261117T100000Z"));
    expect(parseCalendar(clean, NOW).partial).toBe(false);
  });

  it("drops a time zone whose rule is malformed and keeps the calendar", () => {
    const zone = [
      "BEGIN:VTIMEZONE",
      "TZID:America/New_York",
      "BEGIN:STANDARD",
      "TZOFFSETFROM:+0200",
      "TZOFFSETTO:+0200",
      "DTSTART:19700101T000000",
      "RRULE:FREQ=FOO;BYMONTH=13",
      "END:STANDARD",
      "END:VTIMEZONE",
    ];
    const text = calendarOf(zone, vevent("SUMMARY:x", "DTSTART;TZID=America/New_York:20261117T090000"));

    // The file's UTC+2 definition is unusable, so the IANA zone answers.
    expect(brief(upcoming(text))).toEqual(["x @ 2026-11-17T14:00:00Z"]);
  });

  it("ignores a VTIMEZONE whose rule is not a yearly one", () => {
    const trap = (rule: string) => [
      "BEGIN:VTIMEZONE",
      "TZID:America/New_York",
      "BEGIN:STANDARD",
      "TZOFFSETFROM:+0200",
      "TZOFFSETTO:+0200",
      "DTSTART:16010101T000000",
      `RRULE:${rule}`,
      "END:STANDARD",
      "END:VTIMEZONE",
    ];
    const event = vevent("SUMMARY:x", "DTSTART;TZID=America/New_York:20261117T090000");

    for (const rule of ["FREQ=SECONDLY", "FREQ=DAILY", "FREQ=MONTHLY;INTERVAL=48;BYDAY=5MO", "FREQ=YEARLY;INTERVAL=2;BYMONTH=3;BYDAY=2SU", "FREQ=YEARLY;COUNT=3", "FREQ=FOO"]) {
      const started = performance.now();
      // The file's definition says UTC+2; it is dropped, so the IANA zone answers.
      expect(brief(upcoming(calendarOf(trap(rule), event)))).toEqual(["x @ 2026-11-17T14:00:00Z"]);
      expect(performance.now() - started).toBeLessThan(5000);
    }
  });

  describe("time zones that are expensive in bulk", () => {
    // When ical.js expanded zones, 20 zones of 300 observances took 22 seconds.
    // Zones are now read by our own code, and still limited in size.
    const zone = (tzid: string, observances: number) => [
      "BEGIN:VTIMEZONE",
      `TZID:${tzid}`,
      ...Array.from({ length: observances }, (_, i) => [
        "BEGIN:STANDARD",
        "DTSTART:16010101T020000",
        "TZOFFSETFROM:+0200",
        "TZOFFSETTO:+0200",
        `RRULE:FREQ=YEARLY;BYMONTH=${1 + (i % 12)};BYDAY=1SU`,
        "END:STANDARD",
      ]).flat(),
      "END:VTIMEZONE",
    ];
    const at = (tzid: string) => vevent(`SUMMARY:${tzid}`, `DTSTART;TZID=${tzid}:20261117T090000`);
    // The zones say UTC+2. An event whose zone was dropped is floating: 09:00Z here.
    const kept = (title: string) => `${title} @ 2026-11-17T07:00:00Z`;
    const dropped = (title: string) => `${title} @ 2026-11-17T09:00:00Z`;

    it("drops a zone with more than 12 repeating observances", () => {
      const text = calendarOf(zone("Twelve", 12), zone("Thirteen", 13), at("Twelve"), at("Thirteen"));

      expect(brief(upcoming(text))).toEqual([kept("Twelve"), dropped("Thirteen")]);
    });

    it("uses the first 50 zones of a file", () => {
      const names = Array.from({ length: 52 }, (_, i) => `Z${i}`);
      const text = calendarOf(...names.map((name) => zone(name, 1)), ...names.map(at));

      const found = brief(upcoming(text));

      expect(found.filter((line) => line.endsWith("07:00:00Z"))).toHaveLength(50);
      expect(found).toContain(dropped("Z50"));
      expect(found).toContain(dropped("Z51"));
    });

    it("reads a file of 20 zones with 300 observances each quickly", () => {
      const names = Array.from({ length: 20 }, (_, i) => `Zone${i}`);
      const text = calendarOf(...names.map((name) => zone(name, 300)), ...names.map(at));

      const started = performance.now();
      const found = upcoming(text);

      expect(performance.now() - started).toBeLessThan(5000);
      expect(found).toHaveLength(20);
      expect(found.every((event) => event.start === "2026-11-17T09:00:00Z")).toBe(true);
    });

    it("does not expand a zone for dates far from now", () => {
      // Each of these would otherwise make the zone expand to the year it names.
      const text = calendarOf(
        zone("Slow", 12),
        vevent("SUMMARY:far future", "DTSTART;TZID=Slow:21991117T090000"),
        vevent("SUMMARY:not yet begun", "DTSTART;TZID=Slow:21990101T090000", "RRULE:FREQ=DAILY"),
        vevent("UID:o@example.com", "SUMMARY:series", "DTSTART;TZID=Slow:20261101T090000", "RRULE:FREQ=WEEKLY", "EXDATE;TZID=Slow:99990101T090000"),
        vevent("SUMMARY:listed far off", "DTSTART;TZID=Slow:20261101T090000", "RDATE;TZID=Slow:20261118T090000,99990101T090000"),
        vevent("UID:o@example.com", "SUMMARY:far override", "RECURRENCE-ID;TZID=Slow:99981101T090000", "DTSTART;TZID=Slow:99981101T100000"),
        vevent("SUMMARY:long ago", "DTSTART;TZID=Slow:19050101T090000", "DTEND;TZID=Slow:19050101T100000"),
        at("Slow"),
      );

      const started = performance.now();
      const found = upcoming(text);

      expect(performance.now() - started).toBeLessThan(5000);
      // The listed date in the year 9999 is ignored; the one this week is kept.
      expect(brief(found)).toEqual([kept("Slow"), "listed far off @ 2026-11-18T07:00:00Z", "series @ 2026-11-22T07:00:00Z"]);
    });
  });

  it("skips an event that lists more than 2,000 EXDATE and RDATE values", () => {
    const hours = (count: number) =>
      Array.from({ length: count }, (_, i) =>
        new Date(Date.UTC(2020, 0, 1) + i * 3600e3).toISOString().replace(/[-:]/g, "").slice(0, 15) + "Z",
      ).join(",");
    const series = (title: string, listed: string) =>
      vevent(`SUMMARY:${title}`, "DTSTART:20261101T090000Z", "RRULE:FREQ=DAILY;COUNT=20", listed);
    const text = calendarOf(
      series("at the limit", `EXDATE:20261118T090000Z,${hours(1999)}`),
      series("over the limit", `EXDATE:${hours(2001)}`),
      series("over with both", `EXDATE:${hours(1500)}\r\nRDATE:${hours(501)}`),
      series("huge", `EXDATE:${hours(60000)}`),
    );

    const started = performance.now();
    const parsed = parseCalendar(text, NOW);

    expect(performance.now() - started).toBeLessThan(5000);
    expect(parsed.partial).toBe(true);
    expect(parsed.events.map((event) => `${event.title} ${new Date(event.start * 1000).toISOString().slice(0, 10)}`)).toEqual([
      "at the limit 2026-11-16",
      "at the limit 2026-11-17",
      "at the limit 2026-11-19",
      "at the limit 2026-11-20",
    ]);
  });

  it("stops reading once nine days hold 2,000 occurrences", () => {
    const text = calendarOf(
      ...Array.from({ length: 2500 }, (_, i) => vevent(`SUMMARY:e${i}`, "DTSTART;TZID=America/New_York:20261117T090000")),
    );

    const parsed = parseCalendar(text, NOW);

    expect(parsed.partial).toBe(true);
    expect(parsed.events).toHaveLength(500);
  });

  it("survives a VTIMEZONE without a TZID or without rules", () => {
    const text = calendarOf(
      ["BEGIN:VTIMEZONE", "BEGIN:STANDARD", "TZOFFSETFROM:+0200", "TZOFFSETTO:+0200", "DTSTART:19700101T000000", "END:STANDARD", "END:VTIMEZONE"],
      ["BEGIN:VTIMEZONE", "TZID:Empty/Zone", "END:VTIMEZONE"],
      vevent("SUMMARY:x", "DTSTART;TZID=Empty/Zone:20261117T090000"),
      vevent("SUMMARY:y", "DTSTART;TZID=America/New_York:20261117T090000"),
    );

    expect(brief(upcoming(text))).toEqual(["x @ 2026-11-17T09:00:00Z", "y @ 2026-11-17T14:00:00Z"]);
  });

  it("reaches today in a daily series that began in 2005, in few steps", () => {
    const text = calendarOf(
      ...Array.from({ length: 40 }, (_, i) =>
        vevent(`SUMMARY:standing ${i}`, "DTSTART:20050103T160000Z", "DTEND:20050103T163000Z", "RRULE:FREQ=DAILY"),
      ),
    );

    const parsed = parseCalendar(text, NOW);

    // Without the late start this would be 40 x 7,988 steps, far over the
    // budget. Nine days are kept of each series: one back, eight ahead.
    expect(parsed.partial).toBe(false);
    expect(parsed.events).toHaveLength(40 * 9);
  });

  it("stops expanding when a file uses up its work budget, and says so", () => {
    // A COUNT has to be counted from DTSTART: a period per day since 1990,
    // 13,468 of them. The budget of 200,000 covers fourteen such series.
    const text = calendarOf(
      ...Array.from({ length: 40 }, (_, i) =>
        vevent(`SUMMARY:long ${i}`, "DTSTART:19900101T160000Z", "RRULE:FREQ=DAILY;COUNT=100000"),
      ),
      vevent("SUMMARY:after the budget ran out", "DTSTART:20261117T100000Z"),
    );

    const started = performance.now();
    const parsed = parseCalendar(text, NOW);

    expect(performance.now() - started).toBeLessThan(5000);
    expect(parsed.partial).toBe(true);
    const titles = new Set(parsed.events.map((event) => event.title));
    expect(titles.has("long 0")).toBe(true);
    expect(titles.has("long 13")).toBe(true);
    expect(titles.has("long 15")).toBe(false);
    expect(titles.has("after the budget ran out")).toBe(false);
  });

  describe("work that grows faster than the file", () => {
    it("reads thousands of events and overrides that share one UID in linear time", () => {
      // Each event used to copy the UID's whole set of overridden instances.
      const uid = "UID:shared@example.com";
      const minutes = (i: number) => `202611${String(17 + (i % 6)).padStart(2, "0")}T${String(Math.floor(i / 60) % 24).padStart(2, "0")}${String(i % 60).padStart(2, "0")}00Z`;
      const text = calendarOf(
        ...Array.from({ length: 12_000 }, (_, i) => vevent(uid, `SUMMARY:m${i}`, "DTSTART:20200101T000000Z")),
        ...Array.from({ length: 8_000 }, (_, i) => vevent(uid, `SUMMARY:o${i}`, `RECURRENCE-ID:${minutes(i)}`, "DTSTART:20200101T000000Z")),
        vevent(uid, "SUMMARY:series", "DTSTART:20261101T000000Z", "RRULE:FREQ=DAILY"),
      );

      const started = performance.now();
      const parsed = parseCalendar(text, NOW);

      expect(performance.now() - started).toBeLessThan(5000);
      // The override at 00:00 on the 17th removed that instance of the series.
      const days = parsed.events.filter((event) => event.title === "series").map((event) => new Date(event.start * 1000).toISOString().slice(0, 10));
      expect(days).toContain("2026-11-16");
      expect(days).not.toContain("2026-11-17");
    });

    it("reads 30,000 events whose time zone the file does not define in linear time", () => {
      // For each such time ical.js searched every child of the calendar for a
      // VTIMEZONE: 8 seconds here, before the events were moved one level down.
      const text = calendarOf(
        ...Array.from({ length: 30_000 }, (_, i) => vevent(`SUMMARY:e${i}`, "DTSTART;TZID=America/New_York:20100114T090000")),
        vevent("SUMMARY:now", "DTSTART;TZID=America/New_York:20261117T090000"),
      );

      const started = performance.now();
      const parsed = parseCalendar(text, NOW);

      expect(performance.now() - started).toBeLessThan(5000);
      expect(parsed).toEqual({ events: [{ kind: "instant", title: "now", start: 1794924000, end: 1794924000 }], partial: false });
    });

    it("gives a file 50 time zone names and reads the rest as floating", () => {
      // Intl takes a zone name in any mix of capitals and builds a formatter
      // for each spelling.
      const spelling = (i: number) =>
        [..."america/new_york"].map((letter, at) => ((i >> at % 14) & 1 ? letter.toUpperCase() : letter)).join("");
      const text = calendarOf(
        ...Array.from({ length: 300 }, (_, i) => vevent(`SUMMARY:e${i}`, `DTSTART;TZID=${spelling(i + 1)}:20261117T090000`)),
      );

      const started = performance.now();
      const parsed = parseCalendar(text, NOW);

      expect(performance.now() - started).toBeLessThan(5000);
      expect(parsed.partial).toBe(true);
      // 09:00 in New York is 14:00 UTC; read as floating it stays 09:00.
      // Events that reuse one of the first 50 spellings are still placed.
      const placed = parsed.events.filter((event) => event.kind === "instant").length;
      const floating = parsed.events.filter((event) => event.kind === "floating").length;
      expect(placed).toBeGreaterThanOrEqual(50);
      expect(floating).toBeGreaterThan(100);
      expect(placed + floating).toBe(300);
    });

    it("charges time zone lookups for long lists of exclusions inside the window", () => {
      const exclusions = Array.from({ length: 1990 }, (_, i) =>
        new Date(Date.UTC(2026, 10, 15, 16) + i * 300_000).toISOString().replace(/[-:]/g, "").slice(0, 15),
      ).join(",");
      const text = calendarOf(
        ...Array.from({ length: 60 }, (_, i) =>
          vevent(`SUMMARY:s${i}`, "DTSTART;TZID=America/New_York:20261101T090000", "RRULE:FREQ=DAILY", `EXDATE;TZID=America/New_York:${exclusions}`),
        ),
      );

      const started = performance.now();
      const parsed = parseCalendar(text, NOW);

      expect(performance.now() - started).toBeLessThan(5000);
      // 60 x 1,990 lookups is more than the budget allows. The first series is
      // read in full: the exclusions, every five minutes for a week, take out
      // the 16th to the 22nd, which leaves the 23rd and the 24th.
      expect(parsed.partial).toBe(true);
      expect(parsed.events.filter((event) => event.title === "s0").map((event) => new Date(event.start * 1000).toISOString())).toEqual([
        "2026-11-23T14:00:00.000Z",
        "2026-11-24T14:00:00.000Z",
      ]);
      expect(parsed.events.some((event) => event.title === "s59")).toBe(false);
    });

    it("reads a file of 60,000 empty time zone definitions in linear time", () => {
      // They used to be removed from the calendar one at a time.
      const junk = Array.from({ length: 60_000 }, (_, i) => ["BEGIN:VTIMEZONE", `TZID:Z${i}`, "END:VTIMEZONE"]);
      const text = calendarOf(...junk, NEW_YORK, vevent("SUMMARY:x", "DTSTART;TZID=America/New_York:20261117T090000"));

      const started = performance.now();
      const found = upcoming(text);

      expect(performance.now() - started).toBeLessThan(5000);
      expect(brief(found)).toEqual(["x @ 2026-11-17T14:00:00Z"]);
    });
  });

  it("keeps at most 500 occurrences, the soonest", () => {
    const text = calendarOf(
      ...Array.from({ length: 600 }, (_, i) => {
        const minute = String(i % 60).padStart(2, "0");
        const hour = String(10 + Math.floor(i / 60)).padStart(2, "0");
        return vevent(`SUMMARY:e${i}`, `DTSTART:20261117T${hour}${minute}00Z`);
      }),
    );

    const parsed = parseCalendar(text, NOW);

    expect(parsed.partial).toBe(true);
    expect(parsed.events).toHaveLength(500);
    expect(parsed.events[0]?.title).toBe("e0");
    expect(parsed.events[499]?.title).toBe("e499");
  });

  it("stores nothing but titles and times", () => {
    const parsed = parseCalendar(google, NOW);

    for (const event of parsed.events) {
      expect(Object.keys(event).sort()).toEqual(["end", "kind", "start", "title"]);
    }
    expect(JSON.stringify(parsed)).not.toContain("Example Ave");
    expect(JSON.stringify(parsed)).not.toContain("insurance");
  });
});
