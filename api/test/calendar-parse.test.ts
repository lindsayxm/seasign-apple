import ICAL from "ical.js";
import { describe, expect, it } from "vitest";
import {
  CalendarParseError,
  isSafeRule,
  isTimeZone,
  parseCalendar,
  upcomingEvents,
  type UpcomingEvent,
} from "../src/lib/calendar.ts";
// Written by hand in the shape each provider exports; no real calendar was fetched.
import google from "./fixtures/calendar/google.ics?raw";
import icloud from "./fixtures/calendar/icloud.ics?raw";
import outlook from "./fixtures/calendar/outlook.ics?raw";

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
    // A Windows zone name with no VTIMEZONE to define it.
    const text = calendarOf(vevent("SUMMARY:x", "DTSTART;TZID=Eastern Standard Time:20261117T090000"));

    expect(brief(upcoming(text, NOW, "UTC"))).toEqual(["x @ 2026-11-17T09:00:00Z"]);
    expect(brief(upcoming(text, NOW, "America/Chicago"))).toEqual(["x @ 2026-11-17T15:00:00Z"]);
  });

  it("knows IANA names and nothing else", () => {
    expect(isTimeZone("America/New_York")).toBe(true);
    expect(isTimeZone("UTC")).toBe(true);
    expect(isTimeZone("Eastern Standard Time")).toBe(false);
    expect(isTimeZone("Mars/Olympus_Mons")).toBe(false);
    expect(isTimeZone("")).toBe(false);
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
      vevent("SUMMARY:count", "DTSTART:20261114T100000Z", "RRULE:FREQ=DAILY;COUNT=4"),
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

  describe("starting the iterator late gives the same answer as starting at DTSTART", () => {
    const rules: [string, string][] = [
      ["19990104T090000Z", "FREQ=DAILY"],
      ["20100104T090000Z", "FREQ=DAILY;INTERVAL=3"],
      ["20100104T090000Z", "FREQ=DAILY;BYDAY=MO,TU,WE,TH,FR"],
      ["20100103T090000Z", "FREQ=DAILY;BYDAY=TU,TH"],
      ["20100104T090000Z", "FREQ=DAILY;BYMONTH=11,12"],
      ["20100104T090000Z", "FREQ=DAILY;UNTIL=20261120T090000Z"],
      ["20100104T090000Z", "FREQ=WEEKLY"],
      ["20100104T090000Z", "FREQ=WEEKLY;BYDAY=MO,WE,FR"],
      ["20100105T090000Z", "FREQ=WEEKLY;BYDAY=MO,WE,FR"],
      ["20100104T090000Z", "FREQ=WEEKLY;INTERVAL=2;BYDAY=TU,SU;WKST=SU"],
      ["20100104T090000Z", "FREQ=WEEKLY;INTERVAL=2;BYDAY=TU,SU;WKST=MO"],
      ["20100106T090000Z", "FREQ=WEEKLY;INTERVAL=3"],
      ["20100117T090000Z", "FREQ=MONTHLY"],
      ["20100127T090000Z", "FREQ=MONTHLY;INTERVAL=5"],
      ["20100104T090000Z", "FREQ=MONTHLY;BYMONTHDAY=18"],
      ["20100104T090000Z", "FREQ=MONTHLY;BYMONTHDAY=-10"],
      ["20100104T090000Z", "FREQ=MONTHLY;BYDAY=3TU"],
      ["20100104T090000Z", "FREQ=MONTHLY;BYDAY=-2FR"],
      ["20100104T090000Z", "FREQ=MONTHLY;BYDAY=MO,TU,WE,TH,FR;BYSETPOS=-1"],
      ["20100104T090000Z", "FREQ=MONTHLY;BYDAY=TH;BYSETPOS=3"],
      ["20100104T090000Z", "FREQ=MONTHLY;INTERVAL=2;BYDAY=3WE"],
      ["19701118T090000Z", "FREQ=YEARLY"],
      ["19701119T090000Z", "FREQ=YEARLY;INTERVAL=2"],
      ["19700105T090000Z", "FREQ=YEARLY;BYMONTH=11;BYDAY=4TH"],
      ["19700105T090000Z", "FREQ=YEARLY;BYMONTH=11;BYMONTHDAY=20"],
      ["19700105T090000Z", "FREQ=YEARLY;BYMONTH=11;BYDAY=TH;BYSETPOS=3"],
      ["19701118", "FREQ=YEARLY"],
      ["20100104", "FREQ=WEEKLY;BYDAY=MO,SA"],
    ];

    const nows = [
      NOW,
      new Date("2026-11-20T08:00:00Z"),
      new Date("2027-02-25T00:00:00Z"),
      new Date("2028-12-27T23:00:00Z"),
    ];

    it.each(rules)("DTSTART %s, %s", (start, rule) => {
      const dtstart = start.length === 8 ? `DTSTART;VALUE=DATE:${start}` : `DTSTART:${start}`;
      const text = calendarOf(
        vevent("SUMMARY:x", dtstart, `RRULE:${rule}`, "EXDATE:20150105T090000Z,20261118T090000Z"),
      );
      for (const now of nows) {
        const direct = parseCalendar(text, now, { seek: false });
        const sought = parseCalendar(text, now);
        expect(direct.partial).toBe(false);
        expect(sought).toEqual(direct);
      }
    });

    it("finds occurrences for every one of them at some date, so the comparison is not empty", () => {
      const empty = rules.filter(([start, rule]) => {
        const dtstart = start.length === 8 ? `DTSTART;VALUE=DATE:${start}` : `DTSTART:${start}`;
        const text = calendarOf(vevent("SUMMARY:x", dtstart, `RRULE:${rule}`));
        return nows.every((now) => parseCalendar(text, now).events.length === 0);
      });
      expect(empty).toEqual([]);
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
    ["a calendar with a broken line", "BEGIN:VCALENDAR\r\nthis line has no colon\r\nEND:VCALENDAR"],
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

  it("accepts a byte-order mark and leading blank lines", () => {
    const text = "﻿\r\n" + calendarOf(vevent("SUMMARY:x", "DTSTART:20261117T100000Z"));
    expect(brief(upcoming(text))).toEqual(["x @ 2026-11-17T10:00:00Z"]);
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

  // Each of these made ical.js search for a date that never comes, or step
  // through an enormous span, inside one uninterruptible call.
  const unsafe = [
    "FREQ=DAILY;BYMONTH=2;BYMONTHDAY=30",
    "FREQ=DAILY;BYMONTHDAY=-31;BYMONTH=2",
    "FREQ=DAILY;INTERVAL=7;BYDAY=TU",
    "FREQ=SECONDLY;BYMONTH=6",
    "FREQ=SECONDLY",
    "FREQ=MINUTELY",
    "FREQ=HOURLY",
    "FREQ=DAILY;INTERVAL=1000000",
    "FREQ=MONTHLY;BYMONTH=2;BYMONTHDAY=30",
    "FREQ=MONTHLY;BYMONTH=4,6;BYMONTHDAY=31",
    "FREQ=YEARLY;BYDAY=MO;BYMONTHDAY=30;BYMONTH=2",
    "FREQ=YEARLY;BYDAY=FR;BYMONTH=6,1;BYSETPOS=-20",
    "FREQ=MONTHLY;BYDAY=2TU,-5SA;BYSETPOS=-2",
    "FREQ=MONTHLY;BYDAY=5MO;BYMONTH=2",
    "FREQ=YEARLY;BYDAY=20MO",
    "FREQ=YEARLY;BYWEEKNO=20;BYDAY=MO",
    "FREQ=YEARLY;BYYEARDAY=100",
    "FREQ=DAILY;BYHOUR=9,10;BYMINUTE=0,30",
    "FREQ=WEEKLY;INTERVAL=100;BYMONTH=12,4",
    "FREQ=MONTHLY;BYSETPOS=1",
  ];

  it.each(unsafe)("refuses to iterate %s", (rule) => {
    expect(isSafeRule(ICAL.Recur.fromString(rule))).toBe(false);
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
  ])("iterates %s, as calendar apps write it", (rule) => {
    expect(isSafeRule(ICAL.Recur.fromString(rule))).toBe(true);
  });

  it("skips events with unsafe rules, quickly, and keeps the rest", () => {
    const text = calendarOf(
      ...unsafe.map((rule) => vevent("SUMMARY:trap", "DTSTART:20261102T090000Z", `RRULE:${rule}`)),
      vevent("SUMMARY:good", "DTSTART:20261117T100000Z"),
    );

    const started = performance.now();
    const parsed = parseCalendar(text, NOW);

    expect(performance.now() - started).toBeLessThan(2000);
    expect(parsed.partial).toBe(true);
    expect(parsed.events.map((event) => event.title)).toEqual(["good"]);
  });

  it("ignores a VTIMEZONE that would be expensive to expand", () => {
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

    for (const rule of ["FREQ=SECONDLY", "FREQ=DAILY", "FREQ=YEARLY;BYMONTH=2;BYMONTHDAY=30", "FREQ=YEARLY;INTERVAL=2;BYMONTH=3;BYDAY=2SU"]) {
      const started = performance.now();
      // The file's definition says UTC+2; it is dropped, so the IANA zone answers.
      expect(brief(upcoming(calendarOf(trap(rule), event)))).toEqual(["x @ 2026-11-17T14:00:00Z"]);
      expect(performance.now() - started).toBeLessThan(2000);
    }
  });

  describe("time zones that are expensive in bulk", () => {
    // ical.js expands every observance from its DTSTART the first time a zone
    // is used. Before these limits, 20 zones of 300 observances took 22 seconds.
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

    it("drops the zones past 40 repeating observances in one file", () => {
      const names = ["A", "B", "C", "D", "E"];
      const text = calendarOf(...names.map((name) => zone(name, 10)), ...names.map(at));

      expect(brief(upcoming(text))).toEqual([kept("A"), kept("B"), kept("C"), kept("D"), dropped("E")]);
    });

    it("reads a file of 20 zones with 300 observances each quickly", () => {
      const names = Array.from({ length: 20 }, (_, i) => `Zone${i}`);
      const text = calendarOf(...names.map((name) => zone(name, 300)), ...names.map(at));

      const started = performance.now();
      const found = upcoming(text);

      expect(performance.now() - started).toBeLessThan(2000);
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

      expect(performance.now() - started).toBeLessThan(1000);
      expect(brief(found)).toEqual([kept("Slow"), "series @ 2026-11-22T07:00:00Z"]);
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

    expect(performance.now() - started).toBeLessThan(2000);
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
    // COUNT rules cannot be started late, so each costs a step per day since 1990.
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
    // 13,468 days from 1990 to now: seven series fit in 100,000 steps.
    const titles = new Set(parsed.events.map((event) => event.title));
    expect(titles.has("long 0")).toBe(true);
    expect(titles.has("long 6")).toBe(true);
    expect(titles.has("long 8")).toBe(false);
    expect(titles.has("after the budget ran out")).toBe(false);
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
