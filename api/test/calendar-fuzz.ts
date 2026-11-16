// Random content lines for checking that `readableLines` and ical.js agree on
// where a line's parameters end and its value begins (task 18, round 2): the
// EXDATE and RDATE values counted on a line must be the values ical.js makes
// of the line it is handed, or the limits on listed dates do not hold. Values
// are counted by their pieces, since ical.js keeps every "/"-separated piece of
// a period; an RDATE holding "/" is never handed on (task 22).
// calendar-handed.test.ts runs a bounded number of these. A long run, from api/:
//   node --experimental-strip-types --no-warnings -e 'import("./test/calendar-fuzz.ts").then((m) => console.log(m.checkLines(1, 1_000_000), m.checkFiles(2, 2_000)))'
import ICAL from "ical.js";
import { CalendarParseError, handedLine, parseCalendar } from "../src/lib/calendar.ts";

/** The pieces ical.js made of a value: 1 for a date, every piece for a period, however many. */
export const pieces = (value: unknown): number => (Array.isArray(value) ? value.reduce((sum: number, piece) => sum + pieces(piece), 0) : 1);

/** A small seeded generator (mulberry32), so a failing case can be found again. */
export function mulberry32(seed: number): () => number {
  let state = seed >>> 0;
  return () => {
    state = (state + 0x6d2b79f5) >>> 0;
    let t = state;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

/** What parameters and values are made of: every character that ends or escapes something, and the words that matter. */
const PIECES = [
  '"', '"', ":", ":", ";", ";", ",", ",", "^", "\\", "=", "n", " ", "'", "a", "/", "/", "T", "0", "P",
  "^'", "^^", "^n", "\\,", "\\\\", "\\;", "\\:", '="', '",', '":', "TZID", "tzid", "RANGE", "VALUE", "DATE", "DATE-TIME", "PERIOD",
  "20200101T000000Z", "20200101", "Europe/Berlin", ",".repeat(40), "20200101T000000Z/PT1H", "/PT1H", "//", "/".repeat(40),
];
const PARAMETER_NAMES = ["TZID", "tzid", "Tzid", "RANGE", "VALUE", "X-A", "", "TZID ", "CN"];
const PROPERTY_NAMES = ["EXDATE", "RDATE", "exdate", "a.RDATE", "EXDATE ", "UID", "SUMMARY", "DTSTART", "TZID"];

export function randomLine(random: () => number): string {
  const pick = <T>(list: readonly T[]) => list[Math.floor(random() * list.length)] as T;
  const text = (most: number) => {
    let out = "";
    for (let n = Math.floor(random() * (most + 1)); n > 0; n--) out += pick(PIECES);
    return out;
  };
  let line = pick(PROPERTY_NAMES);
  for (let n = Math.floor(random() * 5); n > 0; n--) {
    const roll = random();
    // Mostly NAME=value; sometimes a quoted value with any inside, or no `=` at all.
    if (roll < 0.6) line += `;${pick(PARAMETER_NAMES)}=${text(6)}`;
    else if (roll < 0.85) line += `;${pick(PARAMETER_NAMES)}="${text(6)}"${random() < 0.3 ? text(2) : ""}`;
    else line += `;${text(4)}`;
  }
  return `${line}:${text(8)}`;
}

/** The one property ical.js reads from a line inside an event. */
function parsedProperty(line: string): unknown[] {
  const calendar = ICAL.parse(`BEGIN:VCALENDAR\nBEGIN:VEVENT\n${line}\nEND:VEVENT\nEND:VCALENDAR`) as unknown[];
  return ((calendar[2] as unknown[][])[0] as unknown[][])[1]?.[0] as unknown[];
}

const HANDED_HEAD = /^[A-Z-]+(?:;TZID=("[^"\\]*"|[^";:\\]*))?(?:;RANGE=("[^"\\]*"|[^";:\\]*))?(?:;VALUE=(?:DATE|DATE-TIME))?$/;

export type LineReport = {
  checked: number;
  /** Lines `handedLine` does not take for a property (no value); `readableLines` leaves them out. */
  notProperty: number;
  /** RDATE lines holding "/" (periods to ical.js), which are not handed on. */
  periodsLeftOut: number;
  /** Handed lines ical.js throws on; the file would then be refused whole. */
  refused: number;
  /** The first few of them, to see why. */
  refusedLines: string[];
  /** EXDATE and RDATE pieces ical.js made of the handed lines, all of them counted the same here. */
  listed: number;
  /** Lines on which ical.js and this file disagree, in all. */
  mismatches: number;
  /** How many of each kind of disagreement, with a few examples of each. */
  kinds: Record<string, { count: number; examples: { line: string; handed: string }[] }>;
};

/**
 * Hands `count` random lines on as `readableLines` would, parses each with
 * ical.js, and checks: ical.js does not throw on it; an EXDATE or RDATE gives
 * as many pieces as values counted here, and none is a period; ical.js reads the value exactly where it is read here (the property
 * parses as it does with the same value and no TZID or RANGE before it); and
 * the only parameters it sees are the ones handed on.
 */
export function checkLines(seed: number, count: number): LineReport {
  const random = mulberry32(seed);
  const report: LineReport = { checked: 0, notProperty: 0, periodsLeftOut: 0, refused: 0, refusedLines: [], listed: 0, mismatches: 0, kinds: {} };
  for (let i = 0; i < count; i++) {
    const line = randomLine(random);
    const handed = handedLine(line);
    if (!handed) {
      report.notProperty++;
      continue;
    }
    let failed = false;
    const fail = (why: string) => {
      if (!failed) report.mismatches++;
      failed = true;
      const kind = (report.kinds[why] ??= { count: 0, examples: [] });
      kind.count++;
      if (kind.examples.length < 3) kind.examples.push({ line, handed: handed.text ?? "(not handed on)" });
    };
    if (handed.text === null) {
      report.periodsLeftOut++;
      if (!(handed.name === "RDATE" && handed.value.includes("/"))) fail("left out a line that is not an RDATE period");
      if (handed.listed !== 0) fail("counted values on a line not handed on");
      continue;
    }
    const text = handed.text;
    report.checked++;
    let property: unknown[];
    try {
      property = parsedProperty(text);
    } catch {
      report.refused++;
      if (report.refusedLines.length < 5) report.refusedLines.push(text);
      continue;
    }
    if (handed.name === "EXDATE" || handed.name === "RDATE") {
      const theirs = pieces(property.slice(3));
      report.listed += theirs;
      if (theirs !== handed.listed) fail(theirs > handed.listed ? "ical.js made more values than counted" : "ical.js made fewer values than counted");
      if (property[2] === "period") fail("ical.js read a period");
    }
    // The same value with only the VALUE parameter (which sets the type) must parse the same.
    const valueType = /;VALUE=[A-Z-]+$/.exec(text.slice(0, text.length - handed.value.length - 1))?.[0] ?? "";
    let plain: unknown[] | null = null;
    try {
      plain = parsedProperty(`${handed.name}${valueType}:${handed.value}`);
    } catch {
      fail("ical.js read the handed line but not the same value without its TZID and RANGE");
    }
    if (plain && JSON.stringify(property.slice(2)) !== JSON.stringify(plain.slice(2))) fail("ical.js found a different value");
    const parameters = Object.keys(property[1] as object);
    if (parameters.some((name) => name !== "tzid" && name !== "range")) fail(`ical.js saw parameters ${parameters.join(",")}`);
    // What was handed on before the value: the name, then at most a TZID, a RANGE and a VALUE, in that order and form.
    const ours = HANDED_HEAD.exec(text.slice(0, text.length - handed.value.length - 1));
    if (!ours) fail("handed on parameters of another form");
    else {
      if (parameters.includes("tzid") !== (ours[1] !== undefined)) fail("TZID handed on and TZID read differ");
      if (parameters.includes("range") !== (ours[2] !== undefined)) fail("RANGE handed on and RANGE read differ");
      // A TZID with no quotes, carets or backslashes is read as it is written.
      if (ours[1] && !/["^\\]/.test(ours[1]) && (property[1] as Record<string, unknown>).tzid !== ours[1]) fail("ical.js read a different TZID");
    }
  }
  return report;
}

export type FileReport = {
  files: number;
  refusedTooLarge: number;
  refused: number;
  /** The most listed values ical.js was handed in one event, one zone and one file, counted by their pieces. */
  mostPerEvent: number;
  mostPerZone: number;
  mostPerFile: number;
  /** EXDATE and RDATE properties ical.js read as periods. */
  periods: number;
};

/**
 * Builds `count` calendars from random EXDATE and RDATE lines (three events
 * of `perEvent` lines, two zones of `perZone` RDATE lines; "/" included),
 * parses each with `parseCalendar`, and records the most listed values
 * ical.js was handed per event, zone and file, counted by their pieces, which
 * must stay within the limits, and how many it read as periods.
 */
export function checkFiles(seed: number, count: number, perEvent = 120, perZone = 40): FileReport {
  const random = mulberry32(seed);
  const report: FileReport = { files: 0, refusedTooLarge: 0, refused: 0, mostPerEvent: 0, mostPerZone: 0, mostPerFile: 0, periods: 0 };
  const listedLine = (name: string) => randomLine(random).replace(/^[^;:]*/, name);
  const parse = ICAL.parse;
  ICAL.parse = ((input: string) => {
    const result = parse(input) as unknown[];
    let file = 0;
    const listedIn = (component: unknown[]) => {
      let sum = 0;
      for (const property of component[1] as unknown[][]) {
        if (property[0] !== "exdate" && property[0] !== "rdate") continue;
        if (property[2] === "period") report.periods++;
        sum += pieces(property.slice(3));
      }
      return sum;
    };
    for (const calendar of (Array.isArray(result[0]) ? result : [result]) as unknown[][]) {
      for (const component of calendar[2] as unknown[][]) {
        if (component[0] === "vevent") {
          const here = listedIn(component);
          report.mostPerEvent = Math.max(report.mostPerEvent, here);
          file += here;
        } else if (component[0] === "vtimezone") {
          let here = 0;
          for (const block of component[2] as unknown[][]) here += listedIn(block);
          report.mostPerZone = Math.max(report.mostPerZone, here);
          file += here;
        }
      }
    }
    report.mostPerFile = Math.max(report.mostPerFile, file);
    return result;
  }) as typeof ICAL.parse;
  try {
    for (let i = 0; i < count; i++) {
      const lines = ["BEGIN:VCALENDAR", "VERSION:2.0"];
      for (let z = 0; z < 2; z++) {
        lines.push("BEGIN:VTIMEZONE", `TZID:Z${z}`, "BEGIN:STANDARD", "DTSTART:16010101T020000", "TZOFFSETFROM:+0200", "TZOFFSETTO:+0100");
        for (let n = 0; n < perZone; n++) lines.push(listedLine("RDATE"));
        lines.push("END:STANDARD", "END:VTIMEZONE");
      }
      for (let e = 0; e < 3; e++) {
        lines.push("BEGIN:VEVENT", `UID:e${e}`, "DTSTART:20261117T090000Z", "RRULE:FREQ=DAILY");
        for (let n = 0; n < perEvent; n++) lines.push(listedLine(random() < 0.5 ? "EXDATE" : "RDATE"));
        lines.push("END:VEVENT");
      }
      lines.push("END:VCALENDAR");
      report.files++;
      try {
        parseCalendar(lines.join("\r\n"), new Date("2026-11-16T15:00:00Z"));
      } catch (error) {
        if (!(error instanceof CalendarParseError)) throw error;
        if (error.constructor.name === "CalendarTooLargeError") report.refusedTooLarge++;
        else report.refused++;
      }
    }
  } finally {
    ICAL.parse = parse;
  }
  return report;
}
