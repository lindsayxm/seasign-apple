// POST /v1/calendar/events with `day` (task 167): every event that overlaps one
// day in the request's time zone, ended ones included, answered from the same
// cached occurrences as a plain request.
import { env, exports } from "cloudflare:workers";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { dayBounds, dayEvents, dayInRange, dayWall, parseCalendar } from "../src/lib/calendar.ts";
import { calendarCacheKey } from "../src/routes/calendar.ts";
import { startWorker } from "./start-worker.ts";

startWorker();

const INVALID_REQUEST = {
  error: "invalid_request",
  message: "Send 1 to 10 calendar links and, optionally, an IANA time zone",
};

/** Monday 16 November 2026, 22:30 in New York: late in the day, so the morning is long over. */
const NOW = new Date("2026-11-17T03:30:00Z");
const NY = "America/New_York";
const LINK = "https://calendar.example.com/day/private-1234/basic.ics";
const OTHER = "https://calendar.example.com/day/private-5678/basic.ics";

type Event = { calendar: number; title: string; start: string; end: string; allDay: boolean; date?: string };
type Body = { events: Event[]; calendars: { index: number; ok: boolean; partial: boolean; error?: string }[] };

/** A calendar file of the given VEVENT bodies (each a list of lines without BEGIN/END). */
function calendar(events: string[][]): string {
  const lines = ["BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//Test//Test//EN"];
  events.forEach((event, i) => lines.push("BEGIN:VEVENT", `UID:day-${i}@example.com`, ...event, "END:VEVENT"));
  lines.push("END:VCALENDAR");
  return lines.join("\r\n");
}

function mockCalendars(replies: Record<string, string>) {
  return vi.spyOn(globalThis, "fetch").mockImplementation(async (input, init) => {
    const request = new Request(input, init);
    const text = replies[request.url];
    if (text === undefined) throw new Error("Unexpected outbound request");
    return new Response(text, { headers: { "content-type": "text/calendar; charset=utf-8" } });
  });
}

const post = (body: unknown) =>
  exports.default.fetch("https://example.com/v1/calendar/events", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(body),
  });

async function events(body: unknown): Promise<Body> {
  const response = await post(body);
  expect(response.status).toBe(200);
  return (await response.json()) as Body;
}

async function clearCache() {
  for (;;) {
    const { keys } = await env.CACHE.list({ prefix: "cal:" });
    if (keys.length === 0) return;
    for (const { name } of keys) await env.CACHE.delete(name);
  }
}

beforeEach(async () => {
  vi.useFakeTimers({ toFake: ["Date"], now: NOW });
  await clearCache();
});

afterEach(() => {
  vi.useRealTimers();
  vi.restoreAllMocks();
});

/** Monday 16 November in New York, around its two midnights. */
const MONDAY = calendar([
  ["SUMMARY:Ended at the first midnight", "DTSTART:20261116T040000Z", "DTEND:20261116T050000Z"],
  ["SUMMARY:Floating, just after midnight", "DTSTART:20261116T000000", "DTEND:20261116T003000"],
  ["SUMMARY:Breakfast", "DTSTART;TZID=America/New_York:20261116T080000", "DTEND;TZID=America/New_York:20261116T090000"],
  ["SUMMARY:Monday", "DTSTART;VALUE=DATE:20261116", "DTEND;VALUE=DATE:20261117"],
  ["SUMMARY:Weekend away", "DTSTART;VALUE=DATE:20261114", "DTEND;VALUE=DATE:20261117"],
  ["SUMMARY:Reminder at midnight", "DTSTART:20261116T050000Z"],
  ["SUMMARY:Until the last midnight", "DTSTART:20261117T040000Z", "DTEND:20261117T050000Z"],
  ["SUMMARY:Starts at the next midnight", "DTSTART:20261117T050000Z", "DTEND:20261117T060000Z"],
  ["SUMMARY:Tuesday", "DTSTART;VALUE=DATE:20261117", "DTEND;VALUE=DATE:20261118"],
  ["SUMMARY:Daily standup", "DTSTART:20261110T143000Z", "DTEND:20261110T144500Z", "RRULE:FREQ=DAILY"],
]);

describe("POST /v1/calendar/events with day", () => {
  it("answers every event of the day in the request's zone, ended ones included, soonest first", async () => {
    mockCalendars({ [LINK]: MONDAY });

    const body = await events({ links: [LINK], timezone: NY, day: "2026-11-16" });

    expect(body.calendars).toEqual([{ index: 0, ok: true, partial: false }]);
    expect(body.events).toEqual([
      { calendar: 0, title: "Weekend away", start: "2026-11-14T05:00:00Z", end: "2026-11-17T05:00:00Z", allDay: true, date: "2026-11-14" },
      { calendar: 0, title: "Monday", start: "2026-11-16T05:00:00Z", end: "2026-11-17T05:00:00Z", allDay: true, date: "2026-11-16" },
      // Floating: placed in New York. Ended about 22 hours ago. (Same start as the next: by title.)
      { calendar: 0, title: "Floating, just after midnight", start: "2026-11-16T05:00:00Z", end: "2026-11-16T05:30:00Z", allDay: false },
      // Without a length, at the day's first midnight: it belongs to this day.
      { calendar: 0, title: "Reminder at midnight", start: "2026-11-16T05:00:00Z", end: "2026-11-16T05:00:00Z", allDay: false },
      { calendar: 0, title: "Breakfast", start: "2026-11-16T13:00:00Z", end: "2026-11-16T14:00:00Z", allDay: false },
      { calendar: 0, title: "Daily standup", start: "2026-11-16T14:30:00Z", end: "2026-11-16T14:45:00Z", allDay: false },
      // Ends exactly at the day's last midnight: still this day.
      { calendar: 0, title: "Until the last midnight", start: "2026-11-17T04:00:00Z", end: "2026-11-17T05:00:00Z", allDay: false },
    ]);
  });

  it("puts an event that ends at local midnight on the day before, not the day after", async () => {
    mockCalendars({ [LINK]: MONDAY });

    const tuesday = await events({ links: [LINK], timezone: NY, day: "2026-11-17" });

    expect(tuesday.events.map((event) => event.title)).toEqual(["Tuesday", "Starts at the next midnight", "Daily standup"]);
  });

  it("still answers the upcoming events without day, from the same cached copy", async () => {
    const spy = mockCalendars({ [LINK]: MONDAY });

    const plain = await events({ links: [LINK], timezone: NY });
    const day = await events({ links: [LINK], timezone: NY, day: "2026-11-16" });
    const again = await events({ links: [LINK], timezone: NY });

    expect(spy).toHaveBeenCalledTimes(1);
    expect(again).toEqual(plain);
    // Nothing that has ended, whatever day it was on.
    expect(plain.events.map((event) => event.title).slice(0, 5)).toEqual([
      "Weekend away",
      "Monday",
      "Until the last midnight",
      "Tuesday",
      "Starts at the next midnight",
    ]);
    expect(day.events).toHaveLength(7);
    const { keys } = await env.CACHE.list({ prefix: "cal:" });
    expect(keys.map((key) => key.name)).toEqual([await calendarCacheKey(LINK)]);
  });

  it("answers a day request from an entry a plain request cached, and the other way round", async () => {
    const spy = mockCalendars({ [LINK]: MONDAY, [OTHER]: MONDAY });

    await events({ links: [LINK], timezone: NY });
    const fromPlain = await events({ links: [LINK], timezone: NY, day: "2026-11-16" });
    await events({ links: [OTHER], timezone: NY, day: "2026-11-16" });
    const fromDay = await events({ links: [OTHER], timezone: NY });

    expect(spy).toHaveBeenCalledTimes(2);
    expect(fromPlain.events).toHaveLength(7);
    expect(fromDay.events.map((event) => event.title)).not.toContain("Breakfast");
    const cached = await env.CACHE.get<{ version: number }>(await calendarCacheKey(OTHER), "json");
    expect(cached?.version).toBe(1);
  });

  it("reads the link again for fresh: true with day", async () => {
    const spy = mockCalendars({ [LINK]: MONDAY });
    await events({ links: [LINK], timezone: NY, day: "2026-11-16" });

    vi.restoreAllMocks();
    const added = MONDAY.replace(
      "END:VCALENDAR",
      "BEGIN:VEVENT\r\nUID:late@example.com\r\nSUMMARY:Added later\r\nDTSTART:20261116T200000Z\r\nDTEND:20261116T210000Z\r\nEND:VEVENT\r\nEND:VCALENDAR",
    );
    const again = mockCalendars({ [LINK]: added });
    const stale = await events({ links: [LINK], timezone: NY, day: "2026-11-16" });
    expect(again).not.toHaveBeenCalled();
    expect(stale.events.map((event) => event.title)).not.toContain("Added later");

    const fresh = await events({ links: [LINK], timezone: NY, day: "2026-11-16", fresh: true });
    expect(again).toHaveBeenCalledTimes(1);
    expect(fresh.events.map((event) => event.title)).toContain("Added later");
    expect(spy).toBeDefined();
  });

  it("answers a later day of the week, ended or not", async () => {
    mockCalendars({ [LINK]: MONDAY });
    const saturday = await events({ links: [LINK], timezone: NY, day: "2026-11-22" });
    expect(saturday.events).toEqual([
      { calendar: 0, title: "Daily standup", start: "2026-11-22T14:30:00Z", end: "2026-11-22T14:45:00Z", allDay: false },
    ]);
  });

  it("keeps the cap of 50, soonest first", async () => {
    const many = calendar(
      Array.from({ length: 70 }, (_, i) => [`SUMMARY:e${i}`, `DTSTART:20261116T${String(10 + Math.floor(i / 60)).padStart(2, "0")}${String(i % 60).padStart(2, "0")}00Z`]),
    );
    mockCalendars({ [LINK]: many });
    const body = await events({ links: [LINK], timezone: NY, day: "2026-11-16" });
    expect(body.events).toHaveLength(50);
    expect(body.events[0]?.title).toBe("e0");
    expect(body.events[49]?.title).toBe("e49");
  });

  describe("zones far from UTC", () => {
    it("reads today in the request's zone: in Kiritimati (UTC+14) it is already Tuesday", async () => {
      // 15:00 UTC on Monday is 05:00 on Tuesday in Kiritimati.
      vi.setSystemTime(new Date("2026-11-16T15:00:00Z"));
      const spy = mockCalendars({ [LINK]: MONDAY });

      const monday = await post({ links: [LINK], timezone: "Pacific/Kiritimati", day: "2026-11-16" });
      expect(monday.status).toBe(400);
      expect(await monday.json()).toEqual(INVALID_REQUEST);
      expect(spy).not.toHaveBeenCalled();

      const tuesday = await events({ links: [LINK], timezone: "Pacific/Kiritimati", day: "2026-11-17" });
      expect(tuesday.events.find((event) => event.title === "Tuesday")).toEqual({
        calendar: 0,
        title: "Tuesday",
        start: "2026-11-16T10:00:00Z",
        end: "2026-11-17T10:00:00Z",
        allDay: true,
        date: "2026-11-17",
      });
      // Instants are where they are: Monday 23:00 to midnight in New York is 18:00 to 19:00 on Tuesday there.
      expect(tuesday.events.map((event) => event.title)).toContain("Until the last midnight");
    });

    it("keeps an early floating event in UTC-12 when asked for late that evening", async () => {
      // 11:00 UTC on Tuesday is 23:00 on Monday in UTC-12; the floating event
      // at 00:00 that Monday ended 22.5 hours ago, 34.5 hours before by its wall clock.
      vi.setSystemTime(new Date("2026-11-17T11:00:00Z"));
      mockCalendars({ [LINK]: MONDAY });

      const body = await events({ links: [LINK], timezone: "Etc/GMT+12", day: "2026-11-16" });

      expect(body.events.find((event) => event.title === "Floating, just after midnight")).toEqual({
        calendar: 0,
        title: "Floating, just after midnight",
        start: "2026-11-16T12:00:00Z",
        end: "2026-11-16T12:30:00Z",
        allDay: false,
      });
      expect(body.events.find((event) => event.title === "Monday")).toMatchObject({ start: "2026-11-16T12:00:00Z", end: "2026-11-17T12:00:00Z" });
    });
  });

  describe("days that are refused with the fixed 400, before anything is read", () => {
    it.each([
      ["yesterday", "2026-11-15"],
      ["seven days on", "2026-11-23"],
      ["a year back", "2025-11-16"],
      ["a date that does not exist", "2026-02-30"],
      ["a date without leading zeros", "2026-11-1"],
      ["a date and time", "2026-11-16T00:00:00Z"],
      ["an empty string", ""],
      ["a number", 20261116],
    ])("%s", async (_name, day) => {
      const spy = mockCalendars({ [LINK]: MONDAY });
      const get = vi.spyOn(env.CACHE, "get");
      const response = await post({ links: [LINK], timezone: NY, day });
      expect(response.status).toBe(400);
      expect(await response.json()).toEqual(INVALID_REQUEST);
      expect(spy).not.toHaveBeenCalled();
      expect(get).not.toHaveBeenCalled();
    });

    it("accepts today and the six days after it", async () => {
      mockCalendars({ [LINK]: MONDAY });
      for (const day of ["2026-11-16", "2026-11-19", "2026-11-22"]) {
        expect((await post({ links: [LINK], timezone: NY, day })).status).toBe(200);
      }
    });

    it("reads the day in UTC when no time zone is sent", async () => {
      // 03:30 UTC on Tuesday: Monday is yesterday in UTC.
      mockCalendars({ [LINK]: MONDAY });
      expect((await post({ links: [LINK], day: "2026-11-16" })).status).toBe(400);
      const tuesday = await events({ links: [LINK], day: "2026-11-17" });
      expect(tuesday.events.find((event) => event.title === "Tuesday")).toMatchObject({ start: "2026-11-17T00:00:00Z", allDay: true });
    });
  });
});

describe("the day helpers", () => {
  it("dayWall reads real dates only", () => {
    expect(dayWall("2026-11-16")).toBe(Date.UTC(2026, 10, 16) / 1000);
    expect(dayWall("2028-02-29")).toBe(Date.UTC(2028, 1, 29) / 1000);
    expect(dayWall("2026-02-29")).toBeNull();
    expect(dayWall("2026-13-01")).toBeNull();
    expect(dayWall("0999-01-01")).toBeNull();
    expect(dayWall(" 2026-11-16")).toBeNull();
  });

  it("dayInRange counts days on the request zone's clock", () => {
    const now = new Date("2026-11-17T03:30:00Z");
    expect(dayInRange("2026-11-16", now, NY)).toBe(dayWall("2026-11-16"));
    expect(dayInRange("2026-11-22", now, NY)).toBe(dayWall("2026-11-22"));
    expect(dayInRange("2026-11-23", now, NY)).toBeNull();
    expect(dayInRange("2026-11-16", now, "UTC")).toBeNull();
    expect(dayInRange("2026-11-23", now, "UTC")).toBe(dayWall("2026-11-23"));
  });

  it("dayBounds follows the clock on the days it changes", () => {
    const fallBack = dayBounds(dayWall("2026-11-01")!, NY);
    expect(fallBack.to - fallBack.from).toBe(25 * 3600);
    const springForward = dayBounds(dayWall("2026-03-08")!, NY);
    expect(springForward.to - springForward.from).toBe(23 * 3600);
  });

  it("dayEvents places a floating event on the 25-hour day without losing its last hour", () => {
    const stored = parseCalendar(
      calendar([["SUMMARY:Late", "DTSTART:20261101T233000", "DTEND:20261101T235900"]]),
      new Date("2026-11-01T12:00:00Z"),
    ).events;
    expect(dayEvents(stored, dayWall("2026-11-01")!, NY)).toEqual([
      { title: "Late", start: "2026-11-02T04:30:00Z", end: "2026-11-02T04:59:00Z", allDay: false },
    ]);
  });
});
