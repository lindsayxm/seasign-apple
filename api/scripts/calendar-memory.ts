// Measures how much V8 old space `parseCalendar` needs for a calendar file of
// a given shape: the file is built in the process, decoded the way the route
// decodes a fetched body, and parsed under `--max-old-space-size`. The local
// test runtime does not enforce a Worker's 128 MB, so this is how the calendar
// limits were chosen (figures in memory/architecture.md).
//
//   node --experimental-strip-types scripts/calendar-memory.ts                  list the shapes
//   node --experimental-strip-types scripts/calendar-memory.ts <shape>...       smallest passing cap for each
//   node --experimental-strip-types scripts/calendar-memory.ts --one <shape>    parse once in this process
//
// Options: --bytes N (file size, default the route's cap); --links N (parse N
// copies one after another with all N bodies held, as one request of N links
// does); --two-byte (add one byte that is not UTF-8, so the text decodes to
// two bytes a character); --caps 96,64,... (caps tried, largest first); --runs N (runs per cap;
// a cap passes when every run does); --count (with --one: also print how many
// lines ical.js was handed and how many EXDATE and RDATE values it made of
// them, counting every piece of a period). Old space does not include the bodies themselves (Buffers live
// outside the V8 heap).
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import ICAL from "ical.js";
import {
  CalendarParseError,
  MAX_CALENDAR_BYTES,
  MAX_EVENTS_PER_FILE,
  MAX_LINES_PER_FILE,
  MAX_LISTED_PER_FILE,
  parseCalendar,
} from "../src/lib/calendar.ts";

const NOW = new Date("2026-11-16T15:00:00Z");
const CRLF = "\r\n";

/**
 * Repeats `unit(i)` between `head` and `tail` until the whole is about `bytes`
 * long, or until a unit does not fit (a unit longer than `bytes` ends it).
 * Joined in chunks, so that building a file of tiny lines does not itself
 * need more memory than parsing it.
 */
function fill(bytes: number, head: string, unit: (i: number) => string, tail: string): string {
  const chunks = [head];
  let parts: string[] = [];
  let length = head.length + tail.length;
  for (let i = 0; ; i++) {
    const piece = unit(i);
    if (length + piece.length > bytes) break;
    parts.push(piece);
    length += piece.length;
    if (parts.length === 4096) {
      chunks.push(parts.join(""));
      parts = [];
    }
  }
  chunks.push(parts.join(""), tail);
  return chunks.join("");
}

const CAL = `BEGIN:VCALENDAR${CRLF}VERSION:2.0${CRLF}PRODID:-//Test//Test//EN${CRLF}`;
const END = `END:VCALENDAR${CRLF}`;
const lines = (...parts: string[]) => parts.map((part) => part + CRLF).join("");
const stamp = (seconds: number) => new Date(seconds * 1000).toISOString().replace(/[-:]/g, "").slice(0, 15) + "Z";
const day = (n: number) => stamp(Date.UTC(2026, 10, 16) / 1000 + n * 86400);
/** An event whose master is a daily series running through the window. */
const SERIES = lines("BEGIN:VEVENT", "UID:s@example.com", "SUMMARY:series", "DTSTART:20261101T090000Z", "RRULE:FREQ=DAILY");
const SERIES_HEAD = CAL + SERIES;
const NEW_YORK = lines(
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
);

/**
 * A realistic busy calendar: one VTIMEZONE, `count` events over five years
 * written the way Google writes them, one in twelve a weekly series with an
 * exclusion and an override.
 */
export function ordinaryCalendar(count: number): string {
  const out = [CAL, "X-WR-CALNAME:Work", CRLF, "X-WR-TIMEZONE:America/New_York", CRLF, NEW_YORK];
  const first = Date.UTC(2022, 0, 3, 14) / 1000;
  for (let i = 0; i < count; i++) {
    const start = first + Math.floor((i * 5 * 365 * 86400) / count);
    const local = stamp(start - 5 * 3600).slice(0, 15);
    const end = stamp(start - 5 * 3600 + 3600).slice(0, 15);
    const series = i % 12 === 0;
    out.push(
      lines(
        "BEGIN:VEVENT",
        `DTSTART;TZID=America/New_York:${local}`,
        `DTEND;TZID=America/New_York:${end}`,
        ...(series ? [`RRULE:FREQ=WEEKLY;BYDAY=MO,WE;UNTIL=${stamp(start + 180 * 86400)}`, `EXDATE;TZID=America/New_York:${stamp(start - 5 * 3600 + 14 * 86400).slice(0, 15)}`] : []),
        "DTSTAMP:20261101T120000Z",
        `UID:${i.toString(16).padStart(8, "0")}a1b2c3d4e5f6@google.com`,
        "CREATED:20211201T120000Z",
        `DESCRIPTION:Agenda for meeting ${i}: review the open items\\, decide next steps\\nJoin: https://meet.example.com/abc-defg-hij`,
        "LAST-MODIFIED:20261101T120000Z",
        `LOCATION:Room ${i % 40}\\, Building 2`,
        "SEQUENCE:0",
        "STATUS:CONFIRMED",
        `SUMMARY:Meeting ${i} with the planning group`,
        "TRANSP:OPAQUE",
        "BEGIN:VALARM",
        "ACTION:DISPLAY",
        "DESCRIPTION:This is an event reminder",
        "TRIGGER:-P0DT0H10M0S",
        "END:VALARM",
        "END:VEVENT",
      ),
    );
    if (series) {
      out.push(
        lines(
          "BEGIN:VEVENT",
          `DTSTART;TZID=America/New_York:${stamp(start - 5 * 3600 + 7 * 86400 + 3600).slice(0, 15)}`,
          `DTEND;TZID=America/New_York:${stamp(start - 5 * 3600 + 7 * 86400 + 7200).slice(0, 15)}`,
          `UID:${i.toString(16).padStart(8, "0")}a1b2c3d4e5f6@google.com`,
          `RECURRENCE-ID;TZID=America/New_York:${stamp(start - 5 * 3600 + 7 * 86400).slice(0, 15)}`,
          `SUMMARY:Meeting ${i} (moved)`,
          "END:VEVENT",
        ),
      );
    }
  }
  out.push(END);
  return out.join("");
}

/**
 * Every limit at once: 3,500 events of 17 lines handed on, eight of them
 * rules, the first ten listing 2,000 EXDATE values (`all-limits`), long past
 * or (`inWindow`) in this week. With `period`, the tenth lists 1,999 and one
 * more event has an RDATE period of as many pieces as fit in what is left of
 * `bytes` (less a few bytes, so that --two-byte does not cut the end off).
 */
function allLimits(bytes: number, inWindow: boolean, period: boolean): string {
  const count = 3500;
  const listers = MAX_LISTED_PER_FILE / 2000;
  const listing = (n: number) =>
    Array.from({ length: n }, (_, k) => (inWindow ? stamp(Date.UTC(2026, 10, 10) / 1000 + k * 600) : stamp(Date.UTC(2020, 0, 1) / 1000 + k * 3600))).join(",");
  const full = listing(2000);
  const short = period ? listing(1999) : full;
  const tail = period ? lines("BEGIN:VEVENT", "UID:p", "DTSTART:20261117T090000Z", "RDATE:20261118T090000Z/PT1H@", "END:VEVENT") + END : END;
  const text = fill(
    bytes,
    CAL,
    (i) =>
      i >= count
        ? "\0".repeat(bytes)
        : lines(
            "BEGIN:VEVENT",
            `UID:${i}`,
            inWindow ? `SUMMARY:e${i}` : "SUMMARY:s",
            "STATUS:x",
            inWindow ? "DTSTART:20261117T090000Z" : "DTSTART:20100114T090000Z",
            inWindow ? "DTEND:20261117T100000Z" : "DTEND:20100114T100000Z",
            "DURATION:PT1H",
            inWindow ? `RECURRENCE-ID:${day(i % 7)}` : "RECURRENCE-ID:20100114T090000Z",
            ..."12345678".split("").map((n) => `RRULE:FREQ=DAILY;INTERVAL=${n}`),
            ...(i < listers ? [`EXDATE:${i === listers - 1 ? short : full}`] : []),
            "END:VEVENT",
          ),
    tail,
  );
  return period ? text.replace("@", "/".repeat(Math.max(0, bytes - 16 - text.length + 1))) : text;
}

/** The pieces ical.js made of a value: 1 for a date, every piece for a period. */
const pieces = (value: unknown): number => (Array.isArray(value) ? value.reduce((sum: number, piece) => sum + pieces(piece), 0) : 1);

/**
 * The shapes. Each builds about `bytes` of text. A character `\xff` stands for
 * a byte that is not UTF-8, which decoding turns into U+FFFD, one UTF-16 unit
 * per byte (the most string a byte can make).
 */
const SHAPES: Record<string, (bytes: number) => string> = {
  tiny: () => CAL + lines("BEGIN:VEVENT", "UID:x", "SUMMARY:x", "DTSTART:20261117T100000Z", "END:VEVENT") + END,
  ordinary: (bytes) => {
    // As many ordinary events as fit.
    let count = Math.floor(bytes / 700);
    let text = ordinaryCalendar(count);
    while (text.length > bytes) text = ordinaryCalendar((count = Math.floor(count * 0.97)));
    return text;
  },
  "exdate-lines": (bytes) => fill(bytes, SERIES_HEAD, () => `EXDATE:20200101T000000Z${CRLF}`, `END:VEVENT${CRLF}${END}`),
  "exdate-values": (bytes) => fill(bytes, SERIES_HEAD + "EXDATE:20200101T000000Z", () => ",20200101T000000Z", `${CRLF}END:VEVENT${CRLF}${END}`),
  "rdate-lines": (bytes) => fill(bytes, SERIES_HEAD, (i) => `RDATE:${day(i % 7)}${CRLF}`, `END:VEVENT${CRLF}${END}`),
  "exdate-lines-tzid": (bytes) =>
    fill(bytes, CAL + NEW_YORK + SERIES, (i) => `EXDATE;TZID=America/New_York:${day(i % 7).slice(0, 15)}${CRLF}`, `END:VEVENT${CRLF}${END}`),
  "nested-open": (bytes) => fill(bytes, CAL, () => `BEGIN:X${CRLF}`, ""),
  "nested-closed": (bytes) => {
    const depth = Math.floor((bytes - CAL.length - END.length) / 16);
    return CAL + `BEGIN:X${CRLF}`.repeat(depth) + `END:X${CRLF}`.repeat(depth) + END;
  },
  "nested-in-event": (bytes) => {
    const depth = Math.floor((bytes - CAL.length - END.length - 80) / 16);
    return CAL + lines("BEGIN:VEVENT", "UID:x", "DTSTART:20261117T100000Z") + `BEGIN:X${CRLF}`.repeat(depth) + `END:X${CRLF}`.repeat(depth) + lines("END:VEVENT") + END;
  },
  "sibling-components": (bytes) => fill(bytes, CAL, () => `BEGIN:X${CRLF}END:X${CRLF}`, END),
  "small-events": (bytes) => fill(bytes, CAL, (i) => lines("BEGIN:VEVENT", `UID:${i}`, "DTSTART:20100114T090000Z", "END:VEVENT"), END),
  "smallest-events": (bytes) => fill(bytes, CAL, () => lines("BEGIN:VEVENT", "END:VEVENT"), END),
  "small-events-tzid": (bytes) =>
    fill(bytes, CAL, (i) => lines("BEGIN:VEVENT", `UID:${i}`, "DTSTART;TZID=America/New_York:20100114T090000", "END:VEVENT"), END),
  "events-in-window": (bytes) =>
    fill(bytes, CAL, (i) => lines("BEGIN:VEVENT", `UID:${i}`, `SUMMARY:e${i}`, "DTSTART:20261117T090000Z", "END:VEVENT"), END),
  "events-with-alarms": (bytes) =>
    fill(bytes, CAL, (i) => lines("BEGIN:VEVENT", `UID:${i}`, "DTSTART:20100114T090000Z", "BEGIN:VALARM", "ACTION:DISPLAY", "TRIGGER:-PT10M", "END:VALARM", "END:VEVENT"), END),
  "alarms-in-one-event": (bytes) =>
    fill(bytes, CAL + lines("BEGIN:VEVENT", "UID:x", "DTSTART:20261117T100000Z"), () => lines("BEGIN:VALARM", "END:VALARM"), lines("END:VEVENT") + END),
  "summary-lines": (bytes) =>
    fill(bytes, CAL + lines("BEGIN:VEVENT", "UID:x", "DTSTART:20261117T100000Z"), () => `SUMMARY:x${CRLF}`, lines("END:VEVENT") + END),
  "dtstart-lines": (bytes) =>
    fill(bytes, CAL + lines("BEGIN:VEVENT", "UID:x"), () => `DTSTART:20261117T100000Z${CRLF}`, lines("END:VEVENT") + END),
  "tzid-dtstart-lines": (bytes) =>
    fill(bytes, CAL + NEW_YORK + lines("BEGIN:VEVENT", "UID:x"), () => `DTSTART;TZID=America/New_York:20261117T100000${CRLF}`, lines("END:VEVENT") + END),
  "huge-summary": (bytes) => CAL + lines("BEGIN:VEVENT", "UID:x", "DTSTART:20261117T100000Z") + "SUMMARY:" + "x".repeat(bytes - 200) + CRLF + lines("END:VEVENT") + END,
  "huge-summary-escaped": (bytes) =>
    CAL + lines("BEGIN:VEVENT", "UID:x", "DTSTART:20261117T100000Z") + "SUMMARY:" + "\\n".repeat((bytes - 200) / 2) + CRLF + lines("END:VEVENT") + END,
  "huge-summary-bad-bytes": (bytes) =>
    CAL + lines("BEGIN:VEVENT", "UID:x", "DTSTART:20261117T100000Z") + "SUMMARY:" + "\xff".repeat(bytes - 200) + CRLF + lines("END:VEVENT") + END,
  "huge-uid": (bytes) => CAL + lines("BEGIN:VEVENT", "DTSTART:20261117T100000Z") + "UID:" + "x".repeat(bytes - 200) + CRLF + lines("END:VEVENT") + END,
  "folded-summary": (bytes) =>
    CAL + lines("BEGIN:VEVENT", "UID:x", "DTSTART:20261117T100000Z") + "SUMMARY:" + `x${CRLF} `.repeat((bytes - 200) / 4) + CRLF + lines("END:VEVENT") + END,
  "long-summaries": (bytes) =>
    fill(bytes, CAL, (i) => lines("BEGIN:VEVENT", `UID:${i}`, "DTSTART:20100114T090000Z", "SUMMARY:" + "\xff".repeat(4000), "END:VEVENT"), END),
  "long-summaries-in-window": (bytes) =>
    fill(bytes, CAL, (i) => lines("BEGIN:VEVENT", `UID:${i}`, `DTSTART:${day(i % 7)}`, "SUMMARY:" + "\xff".repeat(4000), "END:VEVENT"), END),
  "huge-description": (bytes) =>
    CAL + lines("BEGIN:VEVENT", "UID:x", "DTSTART:20261117T100000Z") + "DESCRIPTION:" + "\xff".repeat(bytes - 200) + CRLF + lines("END:VEVENT") + END,
  "ignored-lines": (bytes) => fill(bytes, CAL, () => `X:${CRLF}`, END),
  "no-colon-lines": (bytes) => fill(bytes, CAL, () => `X${CRLF}`, END),
  "blank-lines": (bytes) => fill(bytes, CAL, () => "\n", END),
  "lf-folds": (bytes) => fill(bytes, CAL + "X-A:", () => "\n ", CRLF + END),
  params: (bytes) =>
    CAL + lines("BEGIN:VEVENT", "UID:x") + "DTSTART" + ";TZID=a".repeat((bytes - 200) / 7) + ":20261117T100000Z" + CRLF + lines("END:VEVENT") + END,
  "tzid-long": (bytes) =>
    CAL + lines("BEGIN:VEVENT", "UID:x") + "DTSTART;TZID=" + "a".repeat(bytes - 200) + ":20261117T100000" + CRLF + lines("END:VEVENT") + END,
  "vtimezones-empty": (bytes) => fill(bytes, CAL, (i) => lines("BEGIN:VTIMEZONE", `TZID:Z${i}`, "END:VTIMEZONE"), END),
  "vtimezones-full": (bytes) =>
    fill(
      bytes,
      CAL,
      (i) =>
        lines(
          "BEGIN:VTIMEZONE",
          `TZID:Z${i}`,
          "BEGIN:STANDARD",
          "DTSTART:16010101T020000",
          "TZOFFSETFROM:+0200",
          "TZOFFSETTO:+0100",
          "RRULE:FREQ=YEARLY;BYMONTH=10;BYDAY=-1SU",
          "END:STANDARD",
          "END:VTIMEZONE",
        ),
      END,
    ),
  "zone-observances": (bytes) =>
    fill(
      bytes,
      CAL + lines("BEGIN:VTIMEZONE", "TZID:Z"),
      () => lines("BEGIN:STANDARD", "DTSTART:16010101T020000", "TZOFFSETFROM:+0200", "TZOFFSETTO:+0100", "END:STANDARD"),
      lines("END:VTIMEZONE") + END,
    ),
  "zone-rdates": (bytes) =>
    fill(
      bytes,
      CAL + lines("BEGIN:VTIMEZONE", "TZID:Z", "BEGIN:STANDARD", "DTSTART:16010101T020000", "TZOFFSETFROM:+0200", "TZOFFSETTO:+0100"),
      () => `RDATE:20200101T020000${CRLF}`,
      lines("END:STANDARD", "END:VTIMEZONE") + END,
    ),
  "overrides-shared-uid": (bytes) =>
    fill(
      bytes,
      SERIES_HEAD + lines("END:VEVENT"),
      (i) => lines("BEGIN:VEVENT", "UID:s@example.com", `RECURRENCE-ID:${stamp(Date.UTC(2026, 10, 16) / 1000 + (i % 20000) * 30)}`, "DTSTART:20261117T100000Z", "END:VEVENT"),
      END,
    ),
  "many-calendars": (bytes) => fill(bytes, "", () => `BEGIN:VCALENDAR${CRLF}END:VCALENDAR${CRLF}`, ""),
  // Shapes that sit just inside the limits: the most a file can give ical.js.
  "full-events": (bytes) => {
    const count = Math.min(MAX_EVENTS_PER_FILE, Math.floor((MAX_LINES_PER_FILE - 2) / 9));
    return fill(
      bytes,
      CAL,
      (i) =>
        i >= count
          ? "\0".repeat(bytes)
          : lines("BEGIN:VEVENT", `UID:${i}`, "SUMMARY:s", "STATUS:x", "DTSTART:20100114T090000Z", "DTEND:20100114T100000Z", "DURATION:PT1H", "RECURRENCE-ID:20100114T090000Z", "END:VEVENT"),
      END,
    );
  },
  "full-events-in-window": (bytes) => {
    const count = Math.min(MAX_EVENTS_PER_FILE, Math.floor((MAX_LINES_PER_FILE - 2) / 9));
    return fill(
      bytes,
      CAL,
      (i) =>
        i >= count
          ? "\0".repeat(bytes)
          : lines("BEGIN:VEVENT", `UID:${i}`, `SUMMARY:e${i}`, "STATUS:x", "DTSTART:20261117T090000Z", "DTEND:20261117T100000Z", "DURATION:PT1H", `RECURRENCE-ID:${day(i % 7)}`, "END:VEVENT"),
      END,
    );
  },
  "max-events": (bytes) =>
    fill(bytes, CAL, (i) => (i >= MAX_EVENTS_PER_FILE ? "\0".repeat(bytes) : lines("BEGIN:VEVENT", `UID:${i}`, "DTSTART:20100114T090000Z", "END:VEVENT")), END),
  "max-rules": (bytes) => {
    const count = Math.floor((MAX_LINES_PER_FILE - 2) / 12);
    return fill(
      bytes,
      CAL,
      (i) => (i >= count ? "\0".repeat(bytes) : lines("BEGIN:VEVENT", `UID:${i}`, "DTSTART:20261101T090000Z", ..."12345678".split("").map((n) => `RRULE:FREQ=DAILY;INTERVAL=${n}`), "END:VEVENT")),
      END,
    );
  },
  "max-listed-lines": (bytes) => {
    const events = Math.floor(MAX_LISTED_PER_FILE / 2000);
    return fill(
      bytes,
      CAL,
      (i) => (i >= events ? "\0".repeat(bytes) : SERIES.replace("UID:s", `UID:s${i}`) + Array.from({ length: 2000 }, (_, n) => `EXDATE:${stamp(Date.UTC(2020, 0, 1) / 1000 + n * 3600)}${CRLF}`).join("") + lines("END:VEVENT")),
      END,
    );
  },
  "max-listed-values": (bytes) => {
    const events = Math.floor(MAX_LISTED_PER_FILE / 2000);
    return fill(
      bytes,
      CAL,
      (i) => (i >= events ? "\0".repeat(bytes) : SERIES.replace("UID:s", `UID:s${i}`) + "EXDATE:" + Array.from({ length: 2000 }, (_, n) => stamp(Date.UTC(2026, 10, 10) / 1000 + n * 600)).join(",") + CRLF + lines("END:VEVENT")),
      END,
    );
  },
  "max-zones": (bytes) =>
    fill(
      bytes,
      CAL,
      (i) =>
        i >= 100
          ? "\0".repeat(bytes)
          : lines("BEGIN:VTIMEZONE", `TZID:Z${i}`) +
            Array.from({ length: 60 }, (_, n) =>
              lines(
                "BEGIN:STANDARD",
                "DTSTART:16010101T020000",
                "TZOFFSETFROM:+0200",
                "TZOFFSETTO:+0100",
                ...(n < 12 ? ["RRULE:FREQ=YEARLY;BYMONTH=10;BYDAY=-1SU"] : []),
                ...(n < 20 ? Array.from({ length: 10 }, (_, k) => `RDATE:${1900 + n * 10 + k}0101T020000`) : []),
                "END:STANDARD",
              ),
            ).join("") +
            lines("END:VTIMEZONE"),
      END,
    ),
  "rrule-lines": (bytes) =>
    fill(bytes, CAL + lines("BEGIN:VEVENT", "UID:x", "DTSTART:20261117T100000Z"), () => `RRULE:FREQ=DAILY${CRLF}`, lines("END:VEVENT") + END),
  // Every limit at once, without any trick: 3,500 events of 17 lines handed on
  // (BEGIN, the seven properties read once, eight rules, END), the first ten
  // with one EXDATE line of 2,000 values each (MAX_LISTED_PER_FILE).
  "all-limits": (bytes) => allLimits(bytes, false, false),
  // The same in the window: every event starts now, overrides an instance this
  // week, and the listed dates are around now.
  "all-limits-in-window": (bytes) => allLimits(bytes, true, false),
  // Each of those plus one event whose RDATE is a period of as many pieces as
  // the rest of the 2 MB holds (about 300,000): one value to a count of commas,
  // every piece to ical.js (task 22). The last EXDATE line is one value short,
  // so the file is at MAX_LISTED_PER_FILE as counted before task 22.
  "all-limits-period": (bytes) => allLimits(bytes, false, true),
  "all-limits-in-window-period": (bytes) => allLimits(bytes, true, true),
  // One RDATE line of a period with about 2 million pieces, in an event and in a zone's block.
  "rdate-period-pieces": (bytes) =>
    CAL + lines("BEGIN:VEVENT", "UID:x", "DTSTART:20261117T090000Z") + "RDATE:20261118T090000Z/PT1H" + "/".repeat(bytes - 200) + CRLF + lines("END:VEVENT") + END,
  "zone-rdate-period-pieces": (bytes) =>
    CAL +
    lines("BEGIN:VTIMEZONE", "TZID:Z", "BEGIN:STANDARD", "DTSTART:16010101T020000", "TZOFFSETFROM:+0200", "TZOFFSETTO:+0100") +
    "RDATE:19800101T000000/PT1H" +
    "/".repeat(bytes - 400) +
    CRLF +
    lines("END:STANDARD", "END:VTIMEZONE", "BEGIN:VEVENT", "UID:x", "DTSTART;TZID=Z:20261117T090000", "END:VEVENT") +
    END,
  // Commas hidden from a count that takes a quote anywhere in a parameter to
  // open a quoted stretch. ical.js honours a quote only right after `=`, so its
  // value starts at the first colon and holds every comma (task 18, review 1).
  // 1,900 such lines an event, under the 2,000 an event may list.
  "hidden-exdate-quoted": (bytes) => {
    const hidden = Array.from({ length: 4 }, (_, k) => `;TZID=${"abcd"[k]}"${k === 0 ? ":" : ""}${",".repeat(285)}"`).join("");
    return fill(
      bytes,
      SERIES_HEAD,
      (i) => (i > 0 && i % 1900 === 0 ? lines("END:VEVENT", "BEGIN:VEVENT", `UID:s${i}`, "DTSTART:20261101T090000Z", "RRULE:FREQ=DAILY") : "") + `EXDATE${hidden}:20200101T000000Z${CRLF}`,
      `END:VEVENT${CRLF}${END}`,
    );
  },
  // The same in a zone's RDATE lines: 390 a zone, under the 400 a zone may list.
  "hidden-zone-rdate-quoted": (bytes) => {
    const hidden = Array.from({ length: 4 }, (_, k) => `;TZID=${"abcd"[k]}"${k === 0 ? ":" : ""}${",".repeat(285)}"`).join("");
    const zone = (i: number) => lines("BEGIN:VTIMEZONE", `TZID:Z${i}`, "BEGIN:STANDARD", "DTSTART:16010101T020000", "TZOFFSETFROM:+0200", "TZOFFSETTO:+0100");
    return fill(
      bytes,
      CAL + zone(0),
      (i) => (i > 0 && i % 390 === 0 ? lines("END:STANDARD", "END:VTIMEZONE") + zone(i) : "") + `RDATE${hidden}:20200101T020000${CRLF}`,
      lines("END:STANDARD", "END:VTIMEZONE") + END,
    );
  },
  // Commas hidden by escapes in the last parameter: ical.js finds the value by
  // the length of the parameter once unescaped, which `\,` shortens, so it
  // starts reading at a colon inside the quotes. The parameter is 300
  // characters, the most the pre-parser handed on.
  "hidden-exdate-escaped": (bytes) => {
    const hidden = `;TZID="${"\\,".repeat(98)}:${",".repeat(96)}"`;
    return fill(
      bytes,
      SERIES_HEAD,
      (i) => (i > 0 && i % 1900 === 0 ? lines("END:VEVENT", "BEGIN:VEVENT", `UID:s${i}`, "DTSTART:20261101T090000Z", "RRULE:FREQ=DAILY") : "") + `EXDATE${hidden}:20200101T000000Z${CRLF}`,
      `END:VEVENT${CRLF}${END}`,
    );
  },
};

/**
 * Parses one shape `links` times in this process, as one request with that
 * many links does: every body is held (as the route holds the fetched bodies
 * while it parses them one after another) and every result is kept. Prints a
 * line and exits 0, or dies of memory.
 */
function one(shape: string, bytes: number, links: number, twoByte: boolean): void {
  const make = SHAPES[shape];
  if (!make) throw new Error(`unknown shape ${shape}`);
  let handed = "";
  if (countListed) {
    // Counts the EXDATE and RDATE values ical.js made of what it was handed.
    const parse = ICAL.parse;
    ICAL.parse = ((input: string) => {
      const result = parse(input);
      let lines = 0;
      let values = 0;
      const walk = (component: unknown) => {
        if (!Array.isArray(component) || !Array.isArray(component[1])) return;
        for (const property of component[1] as unknown[][]) {
          if (property[0] === "exdate" || property[0] === "rdate") values += pieces(property.slice(3));
        }
        for (const child of (component[2] as unknown[]) ?? []) walk(child);
      };
      for (let at = input.indexOf("\n"); at >= 0; at = input.indexOf("\n", at + 1)) lines++;
      for (const calendar of Array.isArray(result[0]) ? result : [result]) walk(calendar);
      handed = `, handed ${lines + 1} lines and ${values} listed values (pieces)`;
      return result;
    }) as typeof ICAL.parse;
  }
  // Built as bytes and decoded as the route decodes a fetched body.
  // With --two-byte, one byte that is not UTF-8 on the calendar's own level
  // makes the decoded text, and every string cut from it, two bytes a character.
  const text = (twoByte ? (body: string) => body.replace("\r\n", "\r\nX-B:\xff\r\n").slice(0, bytes) : (body: string) => body)(make(bytes));
  const bodies = Array.from({ length: links }, () => Buffer.from(text, "latin1"));
  const size = bodies[0]?.byteLength ?? 0;
  const results: unknown[] = [];
  const started = performance.now();
  let outcome = "";
  for (const body of bodies) {
    try {
      const parsed = parseCalendar(new TextDecoder().decode(body), NOW);
      results.push(parsed);
      outcome = `events=${parsed.events.length} partial=${parsed.partial}`;
    } catch (error) {
      if (!(error instanceof CalendarParseError)) throw error;
      outcome = `refused (${error.message})`;
    }
  }
  const ms = Math.round((performance.now() - started) / links);
  const times = links > 1 ? ` x${links}` : "";
  console.log(`${shape}${times} ${size} bytes: ${outcome}${handed}, ${ms} ms, rss ${Math.round(process.memoryUsage().rss / 2 ** 20)} MB`);
}

function smallestCap(shape: string, bytes: number, links: number, twoByte: boolean, caps: number[], runs: number): void {
  const script = fileURLToPath(import.meta.url);
  let smallest: number | null = null;
  let last = "";
  for (const cap of caps) {
    let passed = true;
    for (let run = 0; run < runs && passed; run++) {
      const child = spawnSync(
        process.execPath,
        [`--max-old-space-size=${cap}`, "--experimental-strip-types", "--no-warnings", script, "--one", shape, "--bytes", String(bytes), "--links", String(links), ...(twoByte ? ["--two-byte"] : [])],
        { encoding: "utf8" },
      );
      passed = child.status === 0;
      if (passed) last = child.stdout.trim();
    }
    if (!passed) break;
    smallest = cap;
  }
  const failedAt = smallest === null ? caps[0] : caps[caps.indexOf(smallest) + 1];
  console.log(`${shape.padEnd(24)} ${smallest === null ? `fails at ${caps[0]}` : `passes at ${smallest} MB`}${failedAt && smallest !== null ? ` (fails at ${failedAt})` : ""}  ${last}`);
}

const args = process.argv.slice(2);
const option = (name: string) => {
  const at = args.indexOf(name);
  if (at < 0) return undefined;
  const [value] = args.splice(at, 2).slice(1);
  return value;
};
const bytes = Number(option("--bytes") ?? MAX_CALENDAR_BYTES);
const links = Number(option("--links") ?? 1);
const caps = (option("--caps") ?? "128,112,96,80,64,56,48,40,32,28,24,20,16,12,8").split(",").map(Number);
const runs = Number(option("--runs") ?? 2);
const twoByte = args.includes("--two-byte");
if (twoByte) args.splice(args.indexOf("--two-byte"), 1);
const countListed = args.includes("--count");
if (countListed) args.splice(args.indexOf("--count"), 1);
const single = option("--one");
if (single) one(single, bytes, links, twoByte);
else if (args.length === 0) console.log(Object.keys(SHAPES).join("\n"));
else for (const shape of args[0] === "all" ? Object.keys(SHAPES) : args) smallestCap(shape, bytes, links, twoByte, caps, runs);
