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
  it("asks Google for that day, midnight to midnight in the request's zone, and answers every event in it, ended ones included", async () => {
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
    expect(sent[0]!.searchParams.get("timeMin")).toBe("2026-11-19T05:00:00Z");
    expect(sent[0]!.searchParams.get("timeMax")).toBe("2026-11-20T05:00:00Z");
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
    expect(sent[0]!.searchParams.get("timeMin")).toBe("2026-11-25T05:00:00Z");
    expect(sent[0]!.searchParams.get("timeMax")).toBe("2026-11-26T05:00:00Z");
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
    expect(sent[0]!.searchParams.get("timeMin")).toBe("2026-11-19T10:00:00Z");
    expect(sent[0]!.searchParams.get("timeMax")).toBe("2026-11-20T10:00:00Z");
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
