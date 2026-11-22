// POST /v1/google/events with `day`, and accessRole on GET /v1/google/calendars
// (task 167). Google is mocked; nothing reaches the network.
import { exports } from "cloudflare:workers";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { calendarOf } from "../src/lib/google.ts";
import { startWorker } from "./start-worker.ts";

startWorker();

const TOKEN = "ya29.fake-google-token-for-tests-0000";
/** Thursday 19 November 2026, 22:30 in New York. */
const NOW = new Date("2026-11-20T03:30:00Z");
const NY = "America/New_York";

const INVALID_REQUEST = {
  error: "invalid_request",
  message: "Send an X-Google-Token header and, for events, a JSON body with 1 to 10 calendar ids and, optionally, an IANA time zone",
};

type Event = { calendar: number; title: string; start: string; end: string; allDay: boolean; date?: string };

function mockGoogle(reply: (url: URL) => Response) {
  const sent: URL[] = [];
  const spy = vi.spyOn(globalThis, "fetch").mockImplementation(async (input, init) => {
    const url = new URL(new Request(input, init).url);
    sent.push(url);
    return reply(url);
  });
  return { sent, spy };
}

const json = (body: unknown) => new Response(JSON.stringify(body), { headers: { "content-type": "application/json" } });

const postEvents = (body: unknown) =>
  exports.default.fetch("https://example.com/v1/google/events", {
    method: "POST",
    headers: { "content-type": "application/json", "x-google-token": TOKEN },
    body: JSON.stringify(body),
  });

const timed = (summary: string, start: string, end: string) => ({ status: "confirmed", summary, start: { dateTime: start }, end: { dateTime: end } });
const allDay = (summary: string, start: string, end: string) => ({ status: "confirmed", summary, start: { date: start }, end: { date: end } });

beforeEach(() => {
  vi.useFakeTimers({ toFake: ["Date"], now: NOW });
});

afterEach(() => {
  vi.useRealTimers();
  vi.restoreAllMocks();
});

/** What Google could send for Thursday in New York, a day of margin either side as an all-day event's own zone may need. */
const THURSDAY_ITEMS = [
  allDay("Wednesday", "2026-11-18", "2026-11-19"),
  timed("Ended at the first midnight", "2026-11-18T23:00:00-05:00", "2026-11-19T00:00:00-05:00"),
  allDay("Thursday", "2026-11-19", "2026-11-20"),
  timed("Breakfast", "2026-11-19T08:00:00-05:00", "2026-11-19T09:00:00-05:00"),
  { status: "cancelled", id: "x" },
  timed("Late call", "2026-11-19T23:00:00-05:00", "2026-11-20T00:00:00-05:00"),
  timed("Starts at the next midnight", "2026-11-20T00:00:00-05:00", "2026-11-20T01:00:00-05:00"),
];

describe("POST /v1/google/events with day", () => {
  it("asks Google for that day in the request's zone with a day of margin either side, and answers every event in it, ended ones included", async () => {
    const { sent } = mockGoogle(() => json({ items: THURSDAY_ITEMS }));

    const response = await postEvents({ calendars: ["primary"], timezone: NY, day: "2026-11-19" });

    expect(response.status).toBe(200);
    expect(response.headers.get("cache-control")).toBe("no-store");
    expect(await response.json()).toEqual({
      events: [
        { calendar: 0, title: "Thursday", start: "2026-11-19T05:00:00Z", end: "2026-11-20T05:00:00Z", allDay: true, date: "2026-11-19" },
        { calendar: 0, title: "Breakfast", start: "2026-11-19T13:00:00Z", end: "2026-11-19T14:00:00Z", allDay: false },
        { calendar: 0, title: "Late call", start: "2026-11-20T04:00:00Z", end: "2026-11-20T05:00:00Z", allDay: false },
      ],
      calendars: [{ index: 0, ok: true, partial: false }],
    });
    expect(sent).toHaveLength(1);
    // Thursday is 05:00 to 05:00 UTC; a day either side.
    expect(sent[0]!.searchParams.get("timeMin")).toBe("2026-11-18T05:00:00Z");
    expect(sent[0]!.searchParams.get("timeMax")).toBe("2026-11-21T05:00:00Z");
    // Everything else is asked as before.
    expect(sent[0]!.searchParams.get("singleEvents")).toBe("true");
    expect(sent[0]!.searchParams.get("orderBy")).toBe("startTime");
    expect(sent[0]!.searchParams.getAll("eventTypes")).toEqual(["default", "fromGmail"]);
    expect(sent[0]!.searchParams.get("fields")).toBe("items(status,summary,start,end,endTimeUnspecified),nextPageToken");
  });

  it("puts an event that ends at local midnight on the day before", async () => {
    mockGoogle(() => json({ items: THURSDAY_ITEMS }));
    const friday = await postEvents({ calendars: ["primary"], timezone: NY, day: "2026-11-20" });
    const titles = ((await friday.json()) as { events: Event[] }).events.map((event) => event.title);
    expect(titles).toEqual(["Starts at the next midnight"]);
  });

  it("asks for a later day of the week the same way", async () => {
    const { sent } = mockGoogle(() => json({ items: [] }));
    expect((await postEvents({ calendars: ["primary"], timezone: NY, day: "2026-11-25" })).status).toBe(200);
    expect(sent[0]!.searchParams.get("timeMin")).toBe("2026-11-24T05:00:00Z");
    expect(sent[0]!.searchParams.get("timeMax")).toBe("2026-11-27T05:00:00Z");
  });

  it("reads the day on a far zone's clock: Kiritimati (UTC+14) is already on Friday", async () => {
    const { sent } = mockGoogle(() => json({ items: [allDay("Friday", "2026-11-20", "2026-11-21"), allDay("Thursday", "2026-11-19", "2026-11-20")] }));

    const thursday = await postEvents({ calendars: ["primary"], timezone: "Pacific/Kiritimati", day: "2026-11-19" });
    expect(thursday.status).toBe(400);
    expect(sent).toHaveLength(0);

    const friday = await postEvents({ calendars: ["primary"], timezone: "Pacific/Kiritimati", day: "2026-11-20" });
    expect(friday.status).toBe(200);
    expect(((await friday.json()) as { events: Event[] }).events).toEqual([
      { calendar: 0, title: "Friday", start: "2026-11-19T10:00:00Z", end: "2026-11-20T10:00:00Z", allDay: true, date: "2026-11-20" },
    ]);
    expect(sent[0]!.searchParams.get("timeMin")).toBe("2026-11-18T10:00:00Z");
    expect(sent[0]!.searchParams.get("timeMax")).toBe("2026-11-21T10:00:00Z");
  });

  it("keeps the cap of 50", async () => {
    const items = Array.from({ length: 70 }, (_, i) => {
      const start = new Date(Date.UTC(2026, 10, 19, 10, i));
      return timed(`e${i}`, start.toISOString(), new Date(start.getTime() + 60_000).toISOString());
    });
    mockGoogle(() => json({ items }));
    const body = (await (await postEvents({ calendars: ["primary"], timezone: NY, day: "2026-11-19" })).json()) as { events: Event[] };
    expect(body.events).toHaveLength(50);
    expect(body.events[0]?.title).toBe("e0");
    expect(body.events[49]?.title).toBe("e49");
  });

  it.each([
    ["yesterday", "2026-11-18"],
    ["seven days on", "2026-11-26"],
    ["a date that does not exist", "2026-11-31"],
    ["a date without leading zeros", "2026-11-9"],
    ["a number", 20261119],
  ])("refuses %s with the fixed 400, before calling Google", async (_name, day) => {
    const { spy } = mockGoogle(() => json({ items: [] }));
    const response = await postEvents({ calendars: ["primary"], timezone: NY, day });
    expect(response.status).toBe(400);
    expect(response.headers.get("cache-control")).toBe("no-store");
    expect(await response.json()).toEqual(INVALID_REQUEST);
    expect(spy).not.toHaveBeenCalled();
  });

  describe("events Google leaves out of a midnight-to-midnight query", () => {
    type Item = { status: string; summary?: string; start?: { date?: string; dateTime?: string }; end?: { date?: string; dateTime?: string } };
    /**
     * Answers as Google does: an event is listed when it ends after timeMin
     * and starts before timeMax (an event without a length at timeMin is
     * not), with an all-day event's dates read as midnights in the
     * calendar's own zone, given here as its offset.
     */
    const googleLike = (items: Item[], calendarOffset: string) => (url: URL) => {
      const min = Date.parse(url.searchParams.get("timeMin")!);
      const max = Date.parse(url.searchParams.get("timeMax")!);
      const at = (time: { date?: string; dateTime?: string }) => Date.parse(time.dateTime ?? `${time.date}T00:00:00${calendarOffset}`);
      return json({ items: items.filter((item) => !item.start || !item.end || (at(item.end) > min && at(item.start) < max)) });
    };

    it("finds an event without a length at the day's first midnight", async () => {
      mockGoogle(googleLike([timed("Reminder at midnight", "2026-11-19T00:00:00-05:00", "2026-11-19T00:00:00-05:00"), timed("Breakfast", "2026-11-19T08:00:00-05:00", "2026-11-19T09:00:00-05:00")], "-05:00"));
      const body = (await (await postEvents({ calendars: ["primary"], timezone: NY, day: "2026-11-19" })).json()) as { events: Event[] };
      expect(body.events.map((event) => event.title)).toEqual(["Reminder at midnight", "Breakfast"]);
    });

    it("finds an all-day event of a calendar whose zone is a day away from the request's", async () => {
      // The calendar keeps Kiritimati time (UTC+14): to Google its Thursday is
      // 10:00 UTC Wednesday to 10:00 UTC Thursday. Thursday in UTC-12 begins at 12:00 UTC Thursday.
      mockGoogle(googleLike([allDay("Thursday", "2026-11-19", "2026-11-20"), allDay("Wednesday", "2026-11-18", "2026-11-19")], "+14:00"));
      const body = (await (await postEvents({ calendars: ["primary"], timezone: "Etc/GMT+12", day: "2026-11-19" })).json()) as { events: Event[] };
      expect(body.events).toEqual([
        { calendar: 0, title: "Thursday", start: "2026-11-19T12:00:00Z", end: "2026-11-20T12:00:00Z", allDay: true, date: "2026-11-19" },
      ]);
    });

    it("does not let the margin's events count against the cap of 500", async () => {
      // 600 events on Wednesday, listed first since Google sorts by start, then three on Thursday.
      const items = [
        ...Array.from({ length: 600 }, (_, i) => {
          const start = new Date(Date.UTC(2026, 10, 18, 12, 0, i * 10));
          return timed(`Wednesday ${i}`, start.toISOString(), new Date(start.getTime() + 60_000).toISOString());
        }),
        timed("Breakfast", "2026-11-19T08:00:00-05:00", "2026-11-19T09:00:00-05:00"),
        timed("Lunch", "2026-11-19T12:00:00-05:00", "2026-11-19T13:00:00-05:00"),
        timed("Dinner", "2026-11-19T19:00:00-05:00", "2026-11-19T20:00:00-05:00"),
      ];
      mockGoogle(googleLike(items, "-05:00"));
      const body = (await (await postEvents({ calendars: ["primary"], timezone: NY, day: "2026-11-19" })).json()) as {
        events: Event[];
        calendars: unknown[];
      };
      expect(body.events.map((event) => event.title)).toEqual(["Breakfast", "Lunch", "Dinner"]);
      expect(body.calendars).toEqual([{ index: 0, ok: true, partial: false }]);
    });

    it("answers the 25-hour day in New York, its repeated hour and its last hour included", async () => {
      // Thursday 29 October: Sunday 1 November is three days on.
      vi.setSystemTime(new Date("2026-10-29T12:00:00Z"));
      const { sent } = mockGoogle(
        googleLike(
          [
            timed("Ended at the first midnight", "2026-10-31T23:00:00-04:00", "2026-11-01T00:00:00-04:00"),
            allDay("Sunday", "2026-11-01", "2026-11-02"),
            timed("01:30 the first time", "2026-11-01T01:30:00-04:00", "2026-11-01T02:00:00-04:00"),
            timed("01:30 the second time", "2026-11-01T01:30:00-05:00", "2026-11-01T02:00:00-05:00"),
            timed("Last hour", "2026-11-01T23:30:00-05:00", "2026-11-02T00:00:00-05:00"),
            timed("Monday", "2026-11-02T00:00:00-05:00", "2026-11-02T01:00:00-05:00"),
          ],
          "-04:00",
        ),
      );

      const response = await postEvents({ calendars: ["primary"], timezone: NY, day: "2026-11-01" });

      expect(((await response.json()) as { events: Event[] }).events).toEqual([
        { calendar: 0, title: "Sunday", start: "2026-11-01T04:00:00Z", end: "2026-11-02T05:00:00Z", allDay: true, date: "2026-11-01" },
        { calendar: 0, title: "01:30 the first time", start: "2026-11-01T05:30:00Z", end: "2026-11-01T06:00:00Z", allDay: false },
        { calendar: 0, title: "01:30 the second time", start: "2026-11-01T06:30:00Z", end: "2026-11-01T07:00:00Z", allDay: false },
        { calendar: 0, title: "Last hour", start: "2026-11-02T04:30:00Z", end: "2026-11-02T05:00:00Z", allDay: false },
      ]);
      // Sunday is 04:00 UTC to 05:00 UTC the next day: 25 hours, and a day either side.
      expect(sent[0]!.searchParams.get("timeMin")).toBe("2026-10-31T04:00:00Z");
      expect(sent[0]!.searchParams.get("timeMax")).toBe("2026-11-03T05:00:00Z");
    });
  });

  it("asks Google for a day back to eight days on without day, as before", async () => {
    const { sent } = mockGoogle(() => json({ items: THURSDAY_ITEMS }));
    const response = await postEvents({ calendars: ["primary"], timezone: NY });
    expect(sent[0]!.searchParams.get("timeMin")).toBe("2026-11-19T03:30:00Z");
    expect(sent[0]!.searchParams.get("timeMax")).toBe("2026-11-28T03:30:00Z");
    // Only what has not ended.
    expect(((await response.json()) as { events: Event[] }).events.map((event) => event.title)).toEqual([
      "Thursday",
      "Late call",
      "Starts at the next midnight",
    ]);
  });
});

describe("accessRole on GET /v1/google/calendars", () => {
  it("passes on each of Google's roles and leaves out anything else", async () => {
    const { sent } = mockGoogle(() =>
      json({
        items: [
          { id: "user@example.com", summary: "Me", primary: true, accessRole: "owner" },
          { id: "shared@group.calendar.google.com", summary: "Shared", accessRole: "writer" },
          { id: "team@group.calendar.google.com", summary: "Team", accessRole: "writerWithoutPrivateAccess" },
          { id: "holidays@group.v.calendar.google.com", summary: "Holidays", accessRole: "reader" },
          { id: "boss@example.com", summary: "Boss", accessRole: "freeBusyReader" },
          { id: "odd@example.com", summary: "Odd", accessRole: "admin" },
          { id: "none@example.com", summary: "None" },
        ],
      }),
    );

    const response = await exports.default.fetch("https://example.com/v1/google/calendars", { headers: { "x-google-token": TOKEN } });

    expect(response.status).toBe(200);
    const { calendars } = (await response.json()) as { calendars: { id: string; accessRole?: string }[] };
    expect(calendars.map((calendar) => [calendar.id, calendar.accessRole])).toEqual([
      ["user@example.com", "owner"],
      ["shared@group.calendar.google.com", "writer"],
      ["team@group.calendar.google.com", "writerWithoutPrivateAccess"],
      ["holidays@group.v.calendar.google.com", "reader"],
      ["boss@example.com", "freeBusyReader"],
      ["odd@example.com", undefined],
      ["none@example.com", undefined],
    ]);
    expect(sent[0]!.searchParams.get("fields")).toBe(
      "items(id,summary,summaryOverride,primary,selected,backgroundColor,deleted,accessRole),nextPageToken",
    );
  });

  it("adds nothing else to a calendar", () => {
    expect(calendarOf({ id: "a@example.com", summary: "A", primary: true, selected: true, accessRole: "reader", kind: "calendar#calendarListEntry", timeZone: "Europe/Paris" })).toEqual({
      id: "a@example.com",
      name: "A",
      primary: true,
      selected: true,
      accessRole: "reader",
    });
  });
});
