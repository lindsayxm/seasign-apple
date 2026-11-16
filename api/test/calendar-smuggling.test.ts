// The parsing layer of the calendar reader, attacked.
//
// ical.js's recurrence iterator cannot be interrupted, and some rules make it
// run for a minute or more. The reader's answer is that nothing which repeats
// ever reaches ical.js: events are rebuilt from a short list of properties
// and time zones are read by our own code. These tests dress the same rules
// up in every way a file can (folds, case, groups, parameters, control
// characters, nesting, other properties' value types) and check three things:
// the parse returns at once, ical.js's iterator and zone code are never
// entered, and a rule that is merely written unusually still works.
import ICAL from "ical.js";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { CalendarParseError, parseCalendar, upcomingEvents } from "../src/lib/calendar.ts";
import google from "./fixtures/calendar/google.ics?raw";
import icloud from "./fixtures/calendar/icloud.ics?raw";
import outlook from "./fixtures/calendar/outlook.ics?raw";

const NOW = new Date("2026-11-16T15:00:00Z");

/** Rules that make ical.js's iterator spin from this DTSTART (45 seconds and more). */
const SPINNER_START = "20260210T100000";
const SPINNERS = [
  "FREQ=MONTHLY;INTERVAL=48;BYDAY=5MO",
  "FREQ=MONTHLY;INTERVAL=96;BYDAY=-5MO",
  "FREQ=DAILY;BYMONTH=2;BYMONTHDAY=30",
  "FREQ=DAILY;INTERVAL=7;BYDAY=TU",
  "FREQ=SECONDLY;BYMONTH=6",
];

const lines = (...parts: (string | string[])[]) => parts.flat().join("\r\n");

/** A calendar with one event; `ruleLines` go into the VEVENT as they are. */
const eventWith = (ruleLines: string[], start = `DTSTART:${SPINNER_START}Z`) =>
  lines("BEGIN:VCALENDAR", "VERSION:2.0", "BEGIN:VEVENT", "UID:e@example.com", "SUMMARY:x", start, ruleLines, "END:VEVENT", "END:VCALENDAR");

/** A calendar whose zone "Odd/Zone" is UTC+2 after its rule's change; `ruleLines` go into the STANDARD block. */
const zoneWith = (ruleLines: string[], zoneStart = "DTSTART:20260210T020000") =>
  lines(
    "BEGIN:VCALENDAR",
    "VERSION:2.0",
    "BEGIN:VTIMEZONE",
    "TZID:Odd/Zone",
    "BEGIN:STANDARD",
    zoneStart,
    "TZOFFSETFROM:+0100",
    "TZOFFSETTO:+0200",
    ruleLines,
    "END:STANDARD",
    "END:VTIMEZONE",
    "BEGIN:VEVENT",
    "UID:z@example.com",
    "SUMMARY:x",
    "DTSTART;TZID=Odd/Zone:20261117T090000",
    "END:VEVENT",
    "END:VCALENDAR",
  );

/** Every way to write the line `RRULE:<rule>` that some parser might still read as a rule. */
function dressings(rule: string, name = "RRULE"): [string, string[]][] {
  const half = Math.floor(name.length / 2);
  const cut = Math.floor(rule.length / 2);
  return [
    ["plain", [`${name}:${rule}`]],
    ["a fold before the colon", [`${name}\r\n :${rule}`]],
    ["a fold inside the name", [`${name.slice(0, half)}\r\n ${name.slice(half)}:${rule}`]],
    ["a fold after the first letter", [`${name[0]}\r\n ${name.slice(1)}:${rule}`]],
    ["a tab fold", [`${name.slice(0, half)}\r\n\t${name.slice(half)}:${rule}`]],
    ["an LF-only fold", [`${name.slice(0, half)}\n ${name.slice(half)}:${rule}`]],
    ["a CR-only fold", [`${name.slice(0, half)}\r ${name.slice(half)}:${rule}`]],
    ["two folds", [`${name[0]}\r\n ${name.slice(1, half)}\n\t${name.slice(half)}\r\n :${rule}`]],
    ["a fold inside the value", [`${name}:${rule.slice(0, cut)}\r\n ${rule.slice(cut)}`]],
    ["a fold after the colon", [`${name}:\r\n ${rule}`]],
    ["lower case", [`${name.toLowerCase()}:${rule}`]],
    ["mixed case", [`${name[0]}${name.slice(1, 3)}${name.slice(3).toLowerCase()}:${rule}`]],
    ["a lower-case value", [`${name}:${rule.toLowerCase()}`]],
    ["a group", [`a.${name}:${rule}`]],
    ["a group and lower case", [`G1-x.${name.toLowerCase()}:${rule}`]],
    ["a group and a fold", [`a.\r\n ${name}:${rule}`]],
    ["a parameter", [`${name};X-A=1:${rule}`]],
    ["a quoted parameter", [`${name};X-A="q;:,":${rule}`]],
    ["a parameter and a fold", [`${name}\r\n ;X-A=1\r\n :${rule}`]],
    ["a duplicate", [`${name}:${rule}`, `${name}:${rule}`]],
    ["a duplicate in another dress", [`${name}:${rule}`, `${name.toLowerCase()}\r\n ;X=1:${rule}`]],
  ];
}

/** Lines that are not a rule to any parser, though they carry one. */
function decoys(rule: string): [string, string[]][] {
  return [
    ["a NUL in the name", [`RRULE\u0000:${rule}`]],
    ["a control character in the name", [`RR\u0001ULE:${rule}`]],
    ["a space in the name", [`RR ULE:${rule}`]],
    ["a group that is not dropped", [`a.b.RRULE:${rule}`]],
    ["a rule as the value of an unknown property", [`X-RULE;VALUE=RECUR:${rule}`]],
    ["a rule as the value of EXDATE", [`EXDATE;VALUE=RECUR:${rule}`]],
    ["a rule as the value of RDATE", [`RDATE;VALUE=RECUR:${rule}`]],
    ["a rule as the value of DTEND", [`DTEND;VALUE=RECUR:${rule}`]],
    ["a rule as the value of SUMMARY", [`SUMMARY;VALUE=RECUR:${rule}`]],
    ["a rule as the value of DURATION", [`DURATION;VALUE=RECUR:${rule}`]],
    ["escaped semicolons", [`RRULE:${rule.replace(/;/g, "\\;")}`]],
    ["a quoted value", [`RRULE:"${rule}"`]],
  ];
}

/**
 * ical.js code that must never run: its recurrence iterator, its time zone
 * expansion, and the Time methods that ask a zone for an offset. (Creating a
 * Timezone object is not on the list: ical.js makes its own UTC one.)
 */
function forbidden() {
  const anyICAL = ICAL as unknown as Record<string, { prototype: Record<string, unknown> }>;
  const targets: [string, string][] = [
    ["Recur", "iterator"],
    ["RecurIterator", "next"],
    ["RecurIterator", "init"],
    ["RecurIterator", "fromData"],
    ["RecurExpansion", "next"],
    ["RecurExpansion", "fromData"],
    ["Timezone", "utcOffset"],
    ["Timezone", "_ensureCoverage"],
    ["Timezone", "_expandComponent"],
    ["Event", "iterator"],
    ["Event", "getOccurrenceDetails"],
    ["Time", "utcOffset"],
    ["Time", "toUnixTime"],
    ["Time", "convertToZone"],
    ["Time", "compare"],
  ];
  const spies = targets.map(([type, method]) => {
    expect(typeof anyICAL[type]?.prototype[method], `${type}.${method} exists`).toBe("function");
    // Throwing means a mistake shows up as a failure, not as a test run that never ends.
    return vi.spyOn(anyICAL[type]!.prototype as Record<string, () => unknown>, method).mockImplementation(() => {
      throw new Error(`ical.js ${type}.${method} was reached`);
    });
  });
  return () => targets.filter((_target, i) => (spies[i]?.mock.calls.length ?? 0) > 0).map(([type, method]) => `${type}.${method}`);
}

let reached: () => string[];

beforeEach(() => {
  reached = forbidden();
});

afterEach(() => {
  // Checked for every test in this file.
  expect(reached(), "calls into ical.js's iterator or zone code").toEqual([]);
  vi.restoreAllMocks();
});

const starts = (text: string, now = NOW) =>
  parseCalendar(text, now).events.map((event) => new Date(event.start * 1000).toISOString().slice(0, 16));

/** Parses, within a time that is nowhere near a spin. */
function quickly(text: string, now = NOW) {
  const started = performance.now();
  let result: ReturnType<typeof parseCalendar> | "not a calendar";
  try {
    result = parseCalendar(text, now);
  } catch (error) {
    if (!(error instanceof CalendarParseError)) throw error;
    result = "not a calendar";
  }
  expect(performance.now() - started).toBeLessThan(5000);
  return result;
}

describe("the provider fixtures", () => {
  it("are read without entering ical.js's iterator or zone code", () => {
    expect(parseCalendar(google, NOW).events.length).toBeGreaterThan(0);
    expect(parseCalendar(icloud, NOW).events.length).toBeGreaterThan(0);
    expect(parseCalendar(outlook, NOW).events.length).toBeGreaterThan(0);
  });
});

describe("a rule in a VEVENT, however it is written", () => {
  // Daily from 14 November, five times: the 15th to the 18th are in the window.
  const benign = "FREQ=DAILY;COUNT=5";
  const expected = ["2026-11-15T16:00", "2026-11-16T16:00", "2026-11-17T16:00", "2026-11-18T16:00"];

  it.each(dressings(benign))("is the same rule with %s", (_name, ruleLines) => {
    const parsed = parseCalendar(eventWith(ruleLines, "DTSTART:20261114T160000Z"), NOW);

    expect(parsed.events.map((event) => new Date(event.start * 1000).toISOString().slice(0, 16))).toEqual(expected);
    expect(parsed.partial).toBe(false);
  });

  it.each(SPINNERS.flatMap((rule) => dressings(rule).map(([name, ruleLines]) => [rule, name, ruleLines] as const)))(
    "%s with %s returns at once",
    (_rule, _name, ruleLines) => {
      for (const now of [NOW, new Date("2026-02-09T00:00:00Z"), new Date("2030-02-08T00:00:00Z")]) {
        expect(quickly(eventWith(ruleLines), now)).not.toBe("not a calendar");
      }
    },
  );

  it.each(dressings("FREQ=FOO;COUNT=abc"))("a malformed rule with %s skips the event, not the calendar", (_name, ruleLines) => {
    const text = eventWith(ruleLines, "DTSTART:20261117T100000Z").replace(
      "END:VCALENDAR",
      lines("BEGIN:VEVENT", "UID:good@example.com", "SUMMARY:good", "DTSTART:20261117T110000Z", "END:VEVENT", "END:VCALENDAR"),
    );

    const parsed = parseCalendar(text, NOW);

    expect(parsed.events.map((event) => event.title)).toEqual(["good"]);
    expect(parsed.partial).toBe(true);
  });

  it.each(dressings(benign, "EXRULE"))("EXRULE with %s skips the series", (_name, ruleLines) => {
    const parsed = parseCalendar(eventWith(["RRULE:FREQ=DAILY", ...ruleLines], "DTSTART:20261114T160000Z"), NOW);

    expect(parsed.events).toEqual([]);
    expect(parsed.partial).toBe(true);
  });

  it.each(SPINNERS.flatMap((rule) => decoys(rule).map(([name, ruleLines]) => [name, rule, ruleLines] as const)))(
    "%s is not a rule (%s)",
    (_name, _rule, ruleLines) => {
      const parsed = quickly(eventWith(ruleLines, "DTSTART:20261117T100000Z"));

      // Read as a single event, or the file is refused; never expanded, never slow.
      if (parsed !== "not a calendar") expect(parsed.events.length).toBeLessThanOrEqual(1);
    },
  );

  it.each([
    ["a NUL in the name", ["RRULE\u0000:FREQ=DAILY"]],
    ["a group that is not dropped", ["a.b.RRULE:FREQ=DAILY"]],
    ["a rule as the value of EXDATE", ["RRULE:FREQ=DAILY", "EXDATE;VALUE=RECUR:FREQ=DAILY"]],
    ["a rule as the value of DTEND", ["DTEND;VALUE=RECUR:FREQ=DAILY"]],
  ])("says the calendar is partial for %s", (_name, ruleLines) => {
    const parsed = quickly(eventWith(ruleLines, "DTSTART:20261117T100000Z"));

    if (parsed !== "not a calendar") expect(parsed.partial).toBe(true);
  });

  it("ignores component names' case", () => {
    const text = lines("begin:vcalendar", "begin:vevent", "uid:e", "dtstart:20261114T160000Z", `rrule:${benign.toLowerCase()}`, "end:vevent", "end:vcalendar");

    expect(starts(text)).toEqual(expected);
  });
});

describe("a rule in a VTIMEZONE, however it is written", () => {
  // The zone is UTC+1 until the first Sunday of November and UTC+2 after it:
  // 09:00 on the 17th is 07:00 UTC if the rule is read, 08:00 if only DTSTART
  // is, and 09:00 (floating) if the zone is not used at all.
  const yearly = "FREQ=YEARLY;BYMONTH=11;BYDAY=1SU";
  const zoneStart = "DTSTART:20101107T020000";

  it.each(dressings(yearly))("is the same rule with %s", (_name, ruleLines) => {
    const text = zoneWith(["BEGIN:DAYLIGHT", "DTSTART:20100314T020000", "TZOFFSETFROM:+0200", "TZOFFSETTO:+0100", "RRULE:FREQ=YEARLY;BYMONTH=3;BYDAY=2SU", "END:DAYLIGHT"], zoneStart)
      // The DAYLIGHT block belongs beside STANDARD, not inside it.
      .replace(/BEGIN:DAYLIGHT[\s\S]*END:DAYLIGHT\r\n/, "")
      .replace("END:STANDARD", lines(ruleLines, "END:STANDARD", "BEGIN:DAYLIGHT", "DTSTART:20100314T020000", "TZOFFSETFROM:+0200", "TZOFFSETTO:+0100", "RRULE:FREQ=YEARLY;BYMONTH=3;BYDAY=2SU", "END:DAYLIGHT"));

    expect(starts(text)).toEqual(["2026-11-17T07:00"]);
    // In July the March rule's UTC+1 is in force.
    const july = text.replace("20261117T090000", "20270715T090000");
    expect(starts(july, new Date("2027-07-12T00:00:00Z"))).toEqual(["2027-07-15T08:00"]);
  });

  it.each(SPINNERS.flatMap((rule) => dressings(rule).map(([name, ruleLines]) => [rule, name, ruleLines] as const)))(
    "%s with %s returns at once and the zone is not used",
    (_rule, _name, ruleLines) => {
      const parsed = quickly(zoneWith(ruleLines));

      expect(parsed).not.toBe("not a calendar");
      // Floating: 09:00 as written.
      if (parsed !== "not a calendar") expect(parsed.events.map((event) => [event.kind, event.start])).toEqual([["floating", Date.UTC(2026, 10, 17, 9) / 1000]]);
    },
  );

  it.each(SPINNERS.flatMap((rule) => decoys(rule).map(([name, ruleLines]) => [name, rule, ruleLines] as const)))(
    "%s is not a rule (%s)",
    (_name, _rule, ruleLines) => {
      quickly(zoneWith(ruleLines));
    },
  );

  it.each(dressings("FREQ=FOO"))("a malformed rule with %s drops the zone, not the calendar", (_name, ruleLines) => {
    expect(starts(zoneWith(ruleLines))).toEqual(["2026-11-17T09:00"]);
  });

  it("reads the zone when the rule is fine", () => {
    expect(starts(zoneWith([`RRULE:${yearly}`], zoneStart))).toEqual(["2026-11-17T07:00"]);
    expect(starts(zoneWith([], zoneStart))).toEqual(["2026-11-17T07:00"]);
  });
});

describe("nesting", () => {
  const spinner = `RRULE:${SPINNERS[0]}`;
  const inner = (name: string, ...content: string[]) => [`BEGIN:${name}`, ...content, `END:${name}`];
  const event = (...content: string[]) => inner("VEVENT", "UID:n@example.com", "SUMMARY:outer", "DTSTART:20261117T100000Z", ...content);
  const zone = (...content: string[]) =>
    inner("VTIMEZONE", "TZID:Odd/Zone", ...inner("STANDARD", "DTSTART:20260210T020000", "TZOFFSETFROM:+0100", "TZOFFSETTO:+0200", spinner), ...content);
  const calendar = (...content: string[][]) => lines("BEGIN:VCALENDAR", ...content, "END:VCALENDAR");

  it.each([
    ["an event inside an event", calendar(event(...inner("VEVENT", "UID:in", "DTSTART:20260210T100000Z", spinner)))],
    ["a zone inside an event", calendar(event(...zone()), inner("VEVENT", "UID:u", "DTSTART;TZID=Odd/Zone:20261117T090000"))],
    ["an event inside a zone", calendar(zone(...inner("VEVENT", "UID:in", "DTSTART;TZID=Odd/Zone:20260210T100000", spinner)))],
    ["an event inside an alarm", calendar(event(...inner("VALARM", "TRIGGER:-PT5M", ...inner("VEVENT", "UID:in", "DTSTART:20260210T100000Z", spinner))))],
    ["a zone inside a zone's block", calendar(inner("VTIMEZONE", "TZID:Odd/Zone", ...inner("STANDARD", "DTSTART:20260210T020000", "TZOFFSETFROM:+0100", "TZOFFSETTO:+0200", ...zone())), event())],
    ["an event inside an unknown component", calendar(inner("X-BOX", ...event(spinner)))],
    ["a rule in an alarm", calendar(event(...inner("VALARM", "TRIGGER:-PT5M", spinner, "DTSTART:20260210T100000Z")))],
    ["a rule on the calendar itself", calendar([spinner, "DTSTART:20260210T100000Z"], event())],
    ["a rule in a to-do", calendar(inner("VTODO", "UID:t", "DTSTART:20260210T100000Z", spinner), event())],
    ["a rule in a journal entry and free-busy", calendar(inner("VJOURNAL", "UID:j", "DTSTART:20260210T100000Z", spinner), inner("VFREEBUSY", "UID:f", "DTSTART:20260210T100000Z", spinner), event())],
    ["lower-case component names", calendar(inner("vevent", "UID:l", "DTSTART:20260210T100000Z", spinner))],
  ])("%s returns at once", (_name, text) => {
    for (const now of [NOW, new Date("2026-02-09T00:00:00Z")]) quickly(text, now);
  });

  it("does not read an event or a zone that is inside something else, and says so", () => {
    const text = calendar(event(...inner("VEVENT", "UID:in", "SUMMARY:inner", "DTSTART:20261117T110000Z")));

    const parsed = parseCalendar(text, NOW);

    expect(parsed.events.map((item) => item.title)).toEqual(["outer"]);
    expect(parsed.partial).toBe(true);
  });

  it("reads an event with an ordinary alarm in full", () => {
    const text = calendar(event(...inner("VALARM", "ACTION:DISPLAY", "TRIGGER:-PT5M", "DESCRIPTION:Reminder")));

    expect(parseCalendar(text, NOW)).toMatchObject({ partial: false, events: [{ title: "outer" }] });
  });
});

describe("random dressing", () => {
  it("of spinning rules, in events and in zones, always returns at once", () => {
    // A bounded run of the Node fuzz recorded in the task log: every rule is
    // written with random folds (of every kind, at any position in the name
    // and the value), random case, an optional group, optional parameters,
    // and sometimes twice.
    let seed = 5_2026;
    const random = () => ((seed = (seed * 1664525 + 1013904223) >>> 0) / 2 ** 32);
    const pick = <T,>(items: T[]) => items[Math.floor(random() * items.length)] as T;
    const folds = ["\r\n ", "\r\n\t", "\n ", "\n\t", "\r ", "\r\t"];
    const dress = (rule: string) => {
      let name = pick(["RRULE", "RRULE", "EXRULE"]);
      name = [...name].map((letter) => (random() < 0.3 ? letter.toLowerCase() : letter)).join("");
      let value = random() < 0.2 ? rule.toLowerCase() : rule;
      if (random() < 0.2) value = [...value].map((letter) => (random() < 0.5 ? letter.toLowerCase() : letter)).join("");
      let line = `${random() < 0.2 ? pick(["a.", "G-1.", "x.y."]) : ""}${name}${random() < 0.3 ? pick([";X=1", ';X="a:b;c"', ";VALUE=RECUR", ";TZID=Odd/Zone"]) : ""}:${value}`;
      for (let n = Math.floor(random() * 4); n > 0; n--) {
        const at = 1 + Math.floor(random() * (line.length - 1));
        line = line.slice(0, at) + pick(folds) + line.slice(at);
      }
      return line;
    };

    let slowest = 0;
    for (let n = 0; n < 600; n++) {
      const ruleLines = Array.from({ length: random() < 0.25 ? 2 : 1 }, () => dress(pick(SPINNERS)));
      const text = random() < 0.5 ? eventWith(ruleLines) : zoneWith(ruleLines);
      const now = pick([NOW, new Date("2026-02-09T00:00:00Z"), new Date("2030-02-08T00:00:00Z")]);

      const started = performance.now();
      try {
        const parsed = parseCalendar(text, now);
        upcomingEvents(parsed.events, now, "America/New_York");
      } catch (error) {
        if (!(error instanceof CalendarParseError)) throw error;
      }
      const took = performance.now() - started;
      slowest = Math.max(slowest, took);
      expect(took, JSON.stringify(ruleLines)).toBeLessThan(5000);
    }
    expect(slowest).toBeLessThan(5000);
  });
});
