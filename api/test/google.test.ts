import { env, exports } from "cloudflare:workers";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { app } from "../src/app.ts";
import { GOOGLE_MAX_BYTES, GOOGLE_TIMEOUT_MS, googleDeadline, isRateLimitBody, storedEventOf } from "../src/lib/google.ts";
import { RATE_LIMITED, RATE_LIMITS } from "../src/lib/rate-limit.ts";
import { MAX_TOKEN_LENGTH, MIN_TOKEN_LENGTH } from "../src/routes/google.ts";
import { startWorker } from "./start-worker.ts";

startWorker();

/** An obviously fake token. Every test checks it never comes back. */
const TOKEN = "ya29.fake-google-token-for-tests-0000";
const NOW = new Date("2026-11-19T15:00:00Z");
const ZONE = "America/New_York";
const GOOGLE = "https://www.googleapis.com";

const INVALID_REQUEST = {
  error: "invalid_request",
  message: "Send an X-Google-Token header and, for events, a JSON body with 1 to 10 calendar ids and, optionally, an IANA time zone",
};
const GOOGLE_AUTH = { error: "google_auth", message: "Google did not accept the access token; refresh it and try again" };
const GOOGLE_FORBIDDEN = { error: "google_forbidden", message: "Google refused access to the calendar list; connect Google Calendar again" };
const GOOGLE_UNAVAILABLE = { error: "google_unavailable", message: "Google Calendar could not be read; try again later" };

type Sent = { url: URL; authorization: string | null; redirect: RequestInit["redirect"]; method: string };
type Reply = (url: URL, signal: AbortSignal | undefined) => Response | Promise<Response>;

/** Outbound fetch: each request is recorded and answered by `reply`. */
function mockGoogle(reply: Reply) {
  const sent: Sent[] = [];
  const spy = vi.spyOn(globalThis, "fetch").mockImplementation(async (input, init) => {
    const request = new Request(input, init);
    const url = new URL(request.url);
    sent.push({ url, authorization: request.headers.get("authorization"), redirect: init?.redirect, method: request.method });
    return reply(url, init?.signal ?? undefined);
  });
  return { sent, spy };
}

const json = (body: unknown, status = 200, headers: Record<string, string> = {}) =>
  new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json", ...headers } });

/** Google's error body, with the token and an e-mail planted in its text, as a careless server might. */
const googleError = (code: number, reason: string, domain = "global") =>
  json({ error: { errors: [{ domain, reason, message: `Bad ${TOKEN} for user@example.com` }], code, message: `Token ${TOKEN} refused` } }, code);

const calendarIdOf = (url: URL) => {
  const match = /^\/calendar\/v3\/calendars\/([^/]+)\/events$/.exec(url.pathname);
  return match ? decodeURIComponent(match[1]!) : null;
};

function postEvents(body: unknown, headers: Record<string, string> = { "x-google-token": TOKEN }) {
  return exports.default.fetch(`${"https://example.com"}/v1/google/events`, {
    method: "POST",
    headers: { "content-type": "application/json", ...headers },
    body: typeof body === "string" ? body : JSON.stringify(body),
  });
}

function getCalendars(headers: Record<string, string> = { "x-google-token": TOKEN }) {
  return exports.default.fetch("https://example.com/v1/google/calendars", { headers });
}

/** Everything written to the console. */
function captureConsole() {
  const spies = (["log", "info", "warn", "error", "debug"] as const).map((method) => vi.spyOn(console, method).mockImplementation(() => {}));
  return {
    warn: spies[2]!,
    lines: () => spies.flatMap((spy) => spy.mock.calls.map((call) => call.map(String).join(" "))),
  };
}

const spyKv = () => (["get", "getWithMetadata", "put", "delete", "list"] as const).map((method) => vi.spyOn(env.CACHE, method));

/** The whole response as text, headers included, after checking it says not to cache. */
async function readAll(response: Response): Promise<string> {
  expect(response.headers.get("cache-control")).toBe("no-store");
  const headers = [...response.headers].map(([name, value]) => `${name}: ${value}`).join("\n");
  return `${headers}\n${await response.text()}`;
}

beforeEach(() => {
  vi.useFakeTimers({ toFake: ["Date"], now: NOW });
});

afterEach(() => {
  vi.useRealTimers();
  vi.restoreAllMocks();
  googleDeadline.ms = GOOGLE_TIMEOUT_MS;
});

// ───────────────────────── fixtures ─────────────────────────

const timed = (summary: string, start: string, end: string, extra: Record<string, unknown> = {}) => ({
  status: "confirmed",
  summary,
  start: { dateTime: start, timeZone: ZONE },
  end: { dateTime: end, timeZone: ZONE },
  ...extra,
});
const allDay = (summary: string, start: string, end: string) => ({ status: "confirmed", summary, start: { date: start }, end: { date: end } });

/** One page of a busy calendar: every kind of item the route has to handle. */
const PRIMARY_ITEMS = [
  timed("Ended this morning", "2026-11-19T08:00:00-05:00", "2026-11-19T09:00:00-05:00"),
  allDay("Today, all day", "2026-11-19", "2026-11-20"),
  timed("  Dentist\n  appointment ", "2026-11-19T12:00:00-05:00", "2026-11-19T13:00:00-05:00"),
  // A cancelled instance of a recurring event, as Google sends it: only these fields.
  { id: "abc_20261120T140000Z", status: "cancelled", recurringEventId: "abc", originalStartTime: { dateTime: "2026-11-20T09:00:00-05:00" } },
  timed("Standup", "2026-11-20T09:00:00-05:00", "2026-11-20T09:15:00-05:00", { recurringEventId: "std", id: "std_1" }),
  allDay("Trip", "2026-11-21", "2026-11-24"),
  timed("Standup", "2026-11-21T09:00:00-05:00", "2026-11-21T09:15:00-05:00", { recurringEventId: "std", id: "std_2" }),
  { status: "confirmed", summary: "Reminder", start: { dateTime: "2026-11-22T10:00:00Z" }, end: { dateTime: "2026-11-22T11:00:00Z" }, endTimeUnspecified: true },
  { status: "tentative", start: { dateTime: "2026-11-23T10:00:00Z" }, end: { dateTime: "2026-11-23T10:30:00Z" } },
  timed("Next week, too far", "2026-11-27T10:00:00Z", "2026-11-27T11:00:00Z"),
];

const EXPECTED_PRIMARY = [
  { calendar: 0, title: "Today, all day", start: "2026-11-19T05:00:00Z", end: "2026-11-20T05:00:00Z", allDay: true, date: "2026-11-19" },
  { calendar: 0, title: "Dentist appointment", start: "2026-11-19T17:00:00Z", end: "2026-11-19T18:00:00Z", allDay: false },
  { calendar: 0, title: "Standup", start: "2026-11-20T14:00:00Z", end: "2026-11-20T14:15:00Z", allDay: false },
  { calendar: 0, title: "Trip", start: "2026-11-21T05:00:00Z", end: "2026-11-24T05:00:00Z", allDay: true, date: "2026-11-21" },
  { calendar: 0, title: "Standup", start: "2026-11-21T14:00:00Z", end: "2026-11-21T14:15:00Z", allDay: false },
  { calendar: 0, title: "Reminder", start: "2026-11-22T10:00:00Z", end: "2026-11-22T10:00:00Z", allDay: false },
  { calendar: 0, title: "", start: "2026-11-23T10:00:00Z", end: "2026-11-23T10:30:00Z", allDay: false },
];

// ───────────────────────── validation ─────────────────────────

describe("validation", () => {
  const VALID = { calendars: ["primary"], timezone: ZONE };
  const cases: [string, unknown, Record<string, string>][] = [
    ["no X-Google-Token header", VALID, {}],
    ["an empty token", VALID, { "x-google-token": "" }],
    ["a token one character too short", VALID, { "x-google-token": "y".repeat(MIN_TOKEN_LENGTH - 1) }],
    ["a token one character too long", VALID, { "x-google-token": "y".repeat(MAX_TOKEN_LENGTH + 1) }],
    ["a token sent with Bearer in front", VALID, { "x-google-token": `Bearer ${TOKEN}` }],
    ["a token with a comma", VALID, { "x-google-token": `${TOKEN},x` }],
    ["no calendars", { timezone: ZONE }, { "x-google-token": TOKEN }],
    ["an empty list of calendars", { calendars: [] }, { "x-google-token": TOKEN }],
    ["11 calendars", { calendars: Array.from({ length: 11 }, (_, i) => `c${i}@group.calendar.google.com`) }, { "x-google-token": TOKEN }],
    ["an empty calendar id", { calendars: [""] }, { "x-google-token": TOKEN }],
    ["a calendar id with a space", { calendars: ["my calendar"] }, { "x-google-token": TOKEN }],
    ["a calendar id of 513 characters", { calendars: ["c".repeat(513)] }, { "x-google-token": TOKEN }],
    ["the calendar id .", { calendars: ["."] }, { "x-google-token": TOKEN }],
    ["the calendar id ..", { calendars: [".."] }, { "x-google-token": TOKEN }],
    ["a calendar id that is not a string", { calendars: [7] }, { "x-google-token": TOKEN }],
    ["an unknown time zone", { ...VALID, timezone: "Mars/Olympus_Mons" }, { "x-google-token": TOKEN }],
    ["JSON that does not parse", '{"calendars": ["primary"', { "x-google-token": TOKEN }],
    ["a JSON array", [VALID], { "x-google-token": TOKEN }],
  ];

  it.each(cases)("POST /v1/google/events refuses %s with the fixed 400, before any outbound request", async (_name, body, headers) => {
    const { spy } = mockGoogle(() => json({}));
    const response = await postEvents(body, headers);
    expect(response.status).toBe(400);
    const text = await readAll(response);
    expect(JSON.parse(text.slice(text.indexOf("\n{") + 1))).toEqual(INVALID_REQUEST);
    expect(text).not.toContain(TOKEN);
    expect(spy).not.toHaveBeenCalled();
  });

  it("POST /v1/google/events refuses a body not sent as application/json", async () => {
    const { spy } = mockGoogle(() => json({}));
    for (const type of ["text/plain", "application/x-www-form-urlencoded", ""]) {
      const response = await exports.default.fetch("https://example.com/v1/google/events", {
        method: "POST",
        headers: { "content-type": type, "x-google-token": TOKEN },
        body: JSON.stringify(VALID),
      });
      expect(response.status).toBe(400);
      expect(response.headers.get("cache-control")).toBe("no-store");
      expect(await response.json()).toEqual(INVALID_REQUEST);
    }
    expect(spy).not.toHaveBeenCalled();
  });

  it.each([
    ["no header", {}],
    ["a short token", { "x-google-token": "short" }],
    ["a token with a space", { "x-google-token": "ya29.has a-space-0000000" }],
  ])("GET /v1/google/calendars refuses %s with the fixed 400", async (_name, headers) => {
    const { spy } = mockGoogle(() => json({}));
    const response = await getCalendars(headers);
    expect(response.status).toBe(400);
    expect(response.headers.get("cache-control")).toBe("no-store");
    expect(await response.json()).toEqual(INVALID_REQUEST);
    expect(spy).not.toHaveBeenCalled();
  });

  it("accepts a token of every length and character the bounds allow", async () => {
    mockGoogle(() => json({ items: [] }));
    for (const token of ["y".repeat(MIN_TOKEN_LENGTH), "y".repeat(MAX_TOKEN_LENGTH), "ya29.a0-_~+/Zz9==", "1//0abc.def_GHI-jkl"]) {
      const response = await postEvents({ calendars: ["primary"] }, { "x-google-token": token.padEnd(MIN_TOKEN_LENGTH, "x") });
      expect(response.status).toBe(200);
    }
  });

  it("sends a body over 64 KB back with the body-limit 400, still marked no-store", async () => {
    const { spy } = mockGoogle(() => json({}));
    const response = await postEvents({ calendars: ["primary"], padding: "x".repeat(70_000) });
    expect(response.status).toBe(400);
    expect(response.headers.get("cache-control")).toBe("no-store");
    expect(spy).not.toHaveBeenCalled();
  });
});

// ───────────────────────── GET /v1/google/calendars ─────────────────────────

describe("GET /v1/google/calendars", () => {
  it("lists the user's calendars, the primary first, from every page", async () => {
    const { sent } = mockGoogle((url) => {
      if (url.searchParams.get("pageToken") === "page-2") {
        return json({ items: [{ id: "en.usa#holiday@group.v.calendar.google.com", summary: "Holidays in United States", backgroundColor: "#16A765", selected: true }] });
      }
      return json({
        items: [
          { id: "family@group.calendar.google.com", summary: "Family", summaryOverride: "  Home \n", backgroundColor: "#0088aa", selected: true },
          { id: "user@example.com", summary: "user@example.com", primary: true, backgroundColor: "#9fe1e7", selected: true },
          { id: "gone@group.calendar.google.com", summary: "Gone", deleted: true },
          { id: "odd@group.calendar.google.com", summary: "Odd colour", backgroundColor: "red" },
          { summary: "No id" },
        ],
        nextPageToken: "page-2",
      });
    });

    const response = await getCalendars();

    expect(response.status).toBe(200);
    expect(response.headers.get("cache-control")).toBe("no-store");
    expect(await response.json()).toEqual({
      calendars: [
        { id: "user@example.com", name: "user@example.com", primary: true, selected: true, color: "#9fe1e7" },
        { id: "family@group.calendar.google.com", name: "Home", primary: false, selected: true, color: "#0088aa" },
        { id: "odd@group.calendar.google.com", name: "Odd colour", primary: false, selected: false },
        { id: "en.usa#holiday@group.v.calendar.google.com", name: "Holidays in United States", primary: false, selected: true, color: "#16a765" },
      ],
    });
    expect(sent).toHaveLength(2);
    for (const request of sent) {
      expect(request.url.origin).toBe(GOOGLE);
      expect(request.url.pathname).toBe("/calendar/v3/users/me/calendarList");
      expect(request.url.searchParams.get("maxResults")).toBe("250");
      expect(request.url.searchParams.get("fields")).toBe("items(id,summary,summaryOverride,primary,selected,backgroundColor,deleted),nextPageToken");
      expect(request.authorization).toBe(`Bearer ${TOKEN}`);
      expect(request.redirect).toBe("manual");
      expect(request.method).toBe("GET");
    }
    expect(sent[0]!.url.searchParams.has("pageToken")).toBe(false);
    expect(sent[1]!.url.searchParams.get("pageToken")).toBe("page-2");
  });

  it("answers an empty list when Google leaves items out", async () => {
    mockGoogle(() => json({}));
    const response = await getCalendars();
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ calendars: [] });
  });

  it("stops after 4 pages", async () => {
    const { sent } = mockGoogle((url) => json({ items: [{ id: `c${url.searchParams.get("pageToken") ?? 0}`, summary: "C" }], nextPageToken: `${Number(url.searchParams.get("pageToken") ?? 0) + 1}` }));
    const response = await getCalendars();
    expect(response.status).toBe(200);
    expect(((await response.json()) as { calendars: unknown[] }).calendars).toHaveLength(4);
    expect(sent).toHaveLength(4);
  });

  const failures: [string, Reply, number, unknown, string][] = [
    ["401 (token expired)", () => googleError(401, "authError"), 401, GOOGLE_AUTH, "auth"],
    ["403 without the scope", () => googleError(403, "insufficientPermissions"), 403, GOOGLE_FORBIDDEN, "forbidden"],
    ["403 rate limit", () => googleError(403, "rateLimitExceeded", "usageLimits"), 502, GOOGLE_UNAVAILABLE, "rate_limited"],
    ["403 user rate limit", () => googleError(403, "userRateLimitExceeded", "usageLimits"), 502, GOOGLE_UNAVAILABLE, "rate_limited"],
    ["429", () => googleError(429, "rateLimitExceeded", "usageLimits"), 502, GOOGLE_UNAVAILABLE, "rate_limited"],
    ["500", () => googleError(500, "backendError"), 502, GOOGLE_UNAVAILABLE, "fetch_failed"],
    ["503 with a body that is not JSON", () => new Response("<html>down</html>", { status: 503 }), 502, GOOGLE_UNAVAILABLE, "fetch_failed"],
    ["a redirect", () => new Response(null, { status: 302, headers: { location: "https://evil.example.com/" } }), 502, GOOGLE_UNAVAILABLE, "fetch_failed"],
    ["a 200 that is not JSON", () => new Response("not json", { status: 200 }), 502, GOOGLE_UNAVAILABLE, "fetch_failed"],
    ["a 200 that is a JSON array", () => json([1, 2]), 502, GOOGLE_UNAVAILABLE, "fetch_failed"],
    ["items that are not a list", () => json({ items: "x" }), 502, GOOGLE_UNAVAILABLE, "fetch_failed"],
    ["the network failing", () => Promise.reject(new TypeError(`fetch failed for ${TOKEN}`)), 502, GOOGLE_UNAVAILABLE, "fetch_failed"],
  ];

  it.each(failures)("maps %s", async (_name, reply, status, body, code) => {
    const logs = captureConsole();
    const kv = spyKv();
    mockGoogle(reply);
    const response = await getCalendars();
    expect(response.status).toBe(status);
    const text = await readAll(response);
    expect(JSON.parse(text.slice(text.indexOf("\n{") + 1))).toEqual(body);
    expect(text).not.toContain(TOKEN);
    expect(text).not.toContain("user@example.com");
    expect(logs.lines()).toEqual([`google: calendar list failed: ${code}`]);
    for (const spy of kv) expect(spy).not.toHaveBeenCalled();
  });

  it("gives up after the deadline with 502", async () => {
    googleDeadline.ms = 50;
    captureConsole();
    mockGoogle(
      (_url, signal) =>
        new Promise((_resolve, reject) => signal?.addEventListener("abort", () => reject(new DOMException("aborted", "AbortError")))),
    );
    const response = await getCalendars();
    expect(response.status).toBe(502);
    expect(await response.json()).toEqual(GOOGLE_UNAVAILABLE);
  });
});

// ───────────────────────── POST /v1/google/events ─────────────────────────

describe("POST /v1/google/events", () => {
  it("answers timed, all-day, multi-day and recurring events in the shape of /v1/calendar/events", async () => {
    const { sent } = mockGoogle(() => json({ items: PRIMARY_ITEMS }));

    const response = await postEvents({ calendars: ["primary"], timezone: ZONE });

    expect(response.status).toBe(200);
    expect(response.headers.get("cache-control")).toBe("no-store");
    expect(await response.json()).toEqual({ events: EXPECTED_PRIMARY, calendars: [{ index: 0, ok: true, partial: false }] });

    expect(sent).toHaveLength(1);
    const [request] = sent;
    expect(request!.url.origin).toBe(GOOGLE);
    expect(request!.url.pathname).toBe("/calendar/v3/calendars/primary/events");
    expect(Object.fromEntries(request!.url.searchParams)).toEqual({
      singleEvents: "true",
      orderBy: "startTime",
      timeMin: "2026-11-18T15:00:00Z",
      timeMax: "2026-11-27T15:00:00Z",
      maxResults: "250",
      fields: "items(status,summary,start,end,endTimeUnspecified),nextPageToken",
    });
    expect(request!.authorization).toBe(`Bearer ${TOKEN}`);
    expect(request!.redirect).toBe("manual");
  });

  it("places all-day events in the request's time zone, UTC by default", async () => {
    mockGoogle(() => json({ items: [allDay("Holiday", "2026-11-20", "2026-11-21")] }));
    const utc = await postEvents({ calendars: ["primary"] });
    expect(((await utc.json()) as { events: unknown[] }).events).toEqual([
      { calendar: 0, title: "Holiday", start: "2026-11-20T00:00:00Z", end: "2026-11-21T00:00:00Z", allDay: true, date: "2026-11-20" },
    ]);
    const tokyo = await postEvents({ calendars: ["primary"], timezone: "Asia/Tokyo" });
    expect(((await tokyo.json()) as { events: unknown[] }).events).toEqual([
      { calendar: 0, title: "Holiday", start: "2026-11-19T15:00:00Z", end: "2026-11-20T15:00:00Z", allDay: true, date: "2026-11-20" },
    ]);
  });

  it("encodes calendar ids in the path, reads each id once, and numbers events by request position", async () => {
    const holiday = "en.usa#holiday@group.v.calendar.google.com";
    const { sent } = mockGoogle((url) => {
      const id = calendarIdOf(url);
      if (id === holiday) return json({ items: [allDay("Thanksgiving", "2026-11-26", "2026-11-27")] });
      if (id === "work@example.com") return json({ items: [timed("Review", "2026-11-19T11:00:00-05:00", "2026-11-19T12:00:00-05:00")] });
      return json({ items: [] });
    });

    const response = await postEvents({ calendars: ["work@example.com", holiday, "work@example.com"], timezone: ZONE });

    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({
      events: [
        { calendar: 0, title: "Review", start: "2026-11-19T16:00:00Z", end: "2026-11-19T17:00:00Z", allDay: false },
        { calendar: 2, title: "Review", start: "2026-11-19T16:00:00Z", end: "2026-11-19T17:00:00Z", allDay: false },
        { calendar: 1, title: "Thanksgiving", start: "2026-11-26T05:00:00Z", end: "2026-11-27T05:00:00Z", allDay: true, date: "2026-11-26" },
      ],
      calendars: [
        { index: 0, ok: true, partial: false },
        { index: 1, ok: true, partial: false },
        { index: 2, ok: true, partial: false },
      ],
    });
    expect(sent).toHaveLength(2);
    expect(sent.map((request) => request.url.pathname)).toEqual([
      "/calendar/v3/calendars/work%40example.com/events",
      "/calendar/v3/calendars/en.usa%23holiday%40group.v.calendar.google.com/events",
    ]);
  });

  it("follows nextPageToken and keeps every page's events", async () => {
    const { sent } = mockGoogle((url) => {
      const page = url.searchParams.get("pageToken");
      if (!page) return json({ items: [timed("First", "2026-11-19T16:00:00Z", "2026-11-19T17:00:00Z")], nextPageToken: "p2" });
      if (page === "p2") return json({ items: [timed("Second", "2026-11-20T16:00:00Z", "2026-11-20T17:00:00Z")], nextPageToken: "p3" });
      return json({ items: [timed("Third", "2026-11-21T16:00:00Z", "2026-11-21T17:00:00Z")] });
    });
    const response = await postEvents({ calendars: ["primary"] });
    const body = (await response.json()) as { events: { title: string }[]; calendars: unknown[] };
    expect(body.events.map((event) => event.title)).toEqual(["First", "Second", "Third"]);
    expect(body.calendars).toEqual([{ index: 0, ok: true, partial: false }]);
    expect(sent.map((request) => request.url.searchParams.get("pageToken"))).toEqual([null, "p2", "p3"]);
    // Every page asks the same question.
    for (const request of sent) expect(request.url.searchParams.get("timeMin")).toBe("2026-11-18T15:00:00Z");
  });

  it("stops after 4 pages and says the calendar is partial", async () => {
    let page = 0;
    const { sent } = mockGoogle(() => {
      page++;
      return json({ items: [timed(`Page ${page}`, `2026-11-2${page}T10:00:00Z`, `2026-11-2${page}T11:00:00Z`)], nextPageToken: `next-${page}` });
    });
    const response = await postEvents({ calendars: ["primary"] });
    const body = (await response.json()) as { events: unknown[]; calendars: unknown[] };
    expect(sent).toHaveLength(4);
    expect(body.events).toHaveLength(4);
    expect(body.calendars).toEqual([{ index: 0, ok: true, partial: true }]);
  });

  it("answers at most 50 events, soonest first, and drops cancelled ones without calling the calendar partial", async () => {
    const items = Array.from({ length: 80 }, (_, i) => {
      const start = new Date(NOW.getTime() + (80 - i) * 3600_000);
      const end = new Date(start.getTime() + 1800_000);
      return i % 10 === 0 ? { status: "cancelled", id: `x${i}` } : timed(`E${80 - i}`, start.toISOString(), end.toISOString());
    });
    mockGoogle(() => json({ items }));
    const response = await postEvents({ calendars: ["primary"] });
    const body = (await response.json()) as { events: { title: string; start: string }[]; calendars: unknown[] };
    expect(body.events).toHaveLength(50);
    expect(body.events.map((event) => event.start)).toEqual([...body.events.map((event) => event.start)].sort());
    expect(body.events[0]!.title).toBe("E1");
    expect(body.events.some((event) => event.title === "E80")).toBe(false);
    expect(body.calendars).toEqual([{ index: 0, ok: true, partial: false }]);
  });

  it("leaves out an event it cannot read and says the calendar is partial", async () => {
    mockGoogle(() =>
      json({
        items: [
          timed("Fine", "2026-11-19T16:00:00Z", "2026-11-19T17:00:00Z"),
          { status: "confirmed", summary: "No offset", start: { dateTime: "2026-11-19T16:00:00" }, end: { dateTime: "2026-11-19T17:00:00" } },
          { status: "confirmed", summary: "Not a date", start: { date: "2026-02-30" }, end: { date: "2026-03-01" } },
          { status: "confirmed", summary: "Ends first", start: { dateTime: "2026-11-19T18:00:00Z" }, end: { dateTime: "2026-11-19T17:00:00Z" } },
          "not an event",
        ],
      }),
    );
    const response = await postEvents({ calendars: ["primary"] });
    expect(await response.json()).toEqual({
      events: [{ calendar: 0, title: "Fine", start: "2026-11-19T16:00:00Z", end: "2026-11-19T17:00:00Z", allDay: false }],
      calendars: [{ index: 0, ok: true, partial: true }],
    });
  });

  it("reports each calendar's own failure and still answers the others", async () => {
    const logs = captureConsole();
    const kv = spyKv();
    const replies: Record<string, Reply> = {
      "forbidden@example.com": () => googleError(403, "forbidden"),
      "missing@example.com": () => googleError(404, "notFound"),
      "deleted@example.com": () => googleError(410, "deleted"),
      "throttled@example.com": () => googleError(403, "rateLimitExceeded", "usageLimits"),
      "busy@example.com": () => googleError(429, "rateLimitExceeded", "usageLimits"),
      "broken@example.com": () => googleError(500, "backendError"),
      "huge@example.com": () => new Response("x".repeat(GOOGLE_MAX_BYTES + 1), { status: 200 }),
      "redirect@example.com": () => new Response(null, { status: 307, headers: { location: "https://evil.example.com/" } }),
      "offline@example.com": () => Promise.reject(new TypeError("network down")),
    };
    mockGoogle((url) => (replies[calendarIdOf(url) ?? ""] ?? (() => json({ items: [timed("Fine", "2026-11-19T16:00:00Z", "2026-11-19T17:00:00Z")] })))(url, undefined));

    const ids = ["primary", ...Object.keys(replies)];
    const response = await postEvents({ calendars: ids });

    expect(response.status).toBe(200);
    const text = await readAll(response);
    expect(JSON.parse(text.slice(text.indexOf("\n{") + 1))).toEqual({
      events: [{ calendar: 0, title: "Fine", start: "2026-11-19T16:00:00Z", end: "2026-11-19T17:00:00Z", allDay: false }],
      calendars: [
        { index: 0, ok: true, partial: false },
        { index: 1, ok: false, partial: false, error: "forbidden" },
        { index: 2, ok: false, partial: false, error: "not_found" },
        { index: 3, ok: false, partial: false, error: "not_found" },
        { index: 4, ok: false, partial: false, error: "rate_limited" },
        { index: 5, ok: false, partial: false, error: "rate_limited" },
        { index: 6, ok: false, partial: false, error: "fetch_failed" },
        { index: 7, ok: false, partial: false, error: "too_large" },
        { index: 8, ok: false, partial: false, error: "fetch_failed" },
        { index: 9, ok: false, partial: false, error: "fetch_failed" },
      ],
    });
    expect(text).not.toContain(TOKEN);
    expect(logs.lines().sort()).toEqual(
      [
        "google: calendar 1 failed: forbidden",
        "google: calendar 2 failed: not_found",
        "google: calendar 3 failed: not_found",
        "google: calendar 4 failed: rate_limited",
        "google: calendar 5 failed: rate_limited",
        "google: calendar 6 failed: fetch_failed",
        "google: calendar 7 failed: too_large",
        "google: calendar 8 failed: fetch_failed",
        "google: calendar 9 failed: fetch_failed",
      ].sort(),
    );
    for (const spy of kv) expect(spy).not.toHaveBeenCalled();
  });

  it("answers 401 google_auth when Google refuses the token for any calendar", async () => {
    const logs = captureConsole();
    mockGoogle((url) => (calendarIdOf(url) === "primary" ? json({ items: [] }) : googleError(401, "authError")));
    const response = await postEvents({ calendars: ["primary", "work@example.com"] });
    expect(response.status).toBe(401);
    const text = await readAll(response);
    expect(JSON.parse(text.slice(text.indexOf("\n{") + 1))).toEqual(GOOGLE_AUTH);
    expect(text).not.toContain(TOKEN);
    expect(logs.lines()).toEqual(["google: calendar 1 failed: auth"]);
  });

  it("marks a calendar timeout when Google does not answer in time", async () => {
    googleDeadline.ms = 50;
    captureConsole();
    mockGoogle(
      (_url, signal) =>
        new Promise((_resolve, reject) => signal?.addEventListener("abort", () => reject(new DOMException("aborted", "AbortError")))),
    );
    const response = await postEvents({ calendars: ["primary"] });
    expect(await response.json()).toEqual({ events: [], calendars: [{ index: 0, ok: false, partial: false, error: "timeout" }] });
  });

  it("marks a calendar timeout when the body stalls after the headers", async () => {
    googleDeadline.ms = 50;
    captureConsole();
    mockGoogle(() => new Response(new ReadableStream({ start: (controller) => controller.enqueue(new TextEncoder().encode('{"items": [')) }), { status: 200 }));
    const response = await postEvents({ calendars: ["primary"] });
    expect(await response.json()).toEqual({ events: [], calendars: [{ index: 0, ok: false, partial: false, error: "timeout" }] });
  });
});

// ───────────────────────── the token ─────────────────────────

describe("the token", () => {
  it("appears in no log line, KV key or value, or response, whatever Google answers", async () => {
    const logs = captureConsole();
    const kv = spyKv();
    const outcomes: Reply[] = [
      () => json({ items: [timed("Dentist", "2026-11-19T16:00:00Z", "2026-11-19T17:00:00Z")] }, 200, { "x-echo": TOKEN }),
      () => googleError(401, "authError"),
      () => googleError(403, "insufficientPermissions"),
      () => googleError(403, "rateLimitExceeded", "usageLimits"),
      () => googleError(404, "notFound"),
      () => googleError(429, "rateLimitExceeded", "usageLimits"),
      () => googleError(500, "backendError"),
      () => Promise.reject(new TypeError(`connection to ${TOKEN} refused`)),
      () => new Response(`<html>${TOKEN}</html>`, { status: 200 }),
    ];
    const texts: string[] = [];
    for (const reply of outcomes) {
      const { spy } = mockGoogle(reply);
      texts.push(await readAll(await postEvents({ calendars: ["primary"] })));
      texts.push(await readAll(await getCalendars()));
      spy.mockRestore();
    }
    texts.push(await readAll(await postEvents({ calendars: [] })));

    expect(texts).toHaveLength(2 * outcomes.length + 1);
    expect(texts.some((text) => text.includes('"title":"Dentist"'))).toBe(true);
    for (const text of texts) expect(text).not.toContain(TOKEN);
    expect(logs.lines().join("\n")).not.toContain(TOKEN);
    expect(logs.lines().join("\n")).not.toContain("ya29");
    for (const spy of kv) expect(spy).not.toHaveBeenCalled();
    // Nothing is put in KV through any other path either.
    const { keys } = await env.CACHE.list();
    for (const { name } of keys) {
      expect(name).not.toContain(TOKEN);
      expect(await env.CACHE.get(name)).not.toContain(TOKEN);
    }
  });

  it("is sent only to www.googleapis.com, in the Authorization header", async () => {
    const { sent } = mockGoogle(() => json({ items: [] }));
    await postEvents({ calendars: ["primary", "a@example.com"] });
    await getCalendars();
    expect(sent.length).toBe(3);
    for (const request of sent) {
      expect(request.url.origin).toBe(GOOGLE);
      expect(request.url.href).not.toContain(TOKEN);
      expect(request.authorization).toBe(`Bearer ${TOKEN}`);
    }
  });
});

// ───────────────────────── rate limit ─────────────────────────

describe("rate limit", () => {
  it("refuses both Google routes past the limit, marked no-store, before any fetch", async () => {
    const { spy } = mockGoogle(() => json({ items: [] }));
    const refuse = { limit: async () => ({ success: false }) };
    const testEnv = { ...env, [RATE_LIMITS.google.binding]: refuse } as unknown as CloudflareBindings;
    const headers = { "cf-connecting-ip": "203.0.113.60", "x-google-token": TOKEN };
    const responses = [
      await app.fetch(new Request("https://example.com/v1/google/calendars", { headers }), testEnv),
      await app.fetch(
        new Request("https://example.com/v1/google/events", {
          method: "POST",
          headers: { ...headers, "content-type": "application/json" },
          body: JSON.stringify({ calendars: ["primary"] }),
        }),
        testEnv,
      ),
    ];
    for (const response of responses) {
      expect(response.status).toBe(429);
      expect(response.headers.get("retry-after")).toBe("60");
      expect(response.headers.get("cache-control")).toBe("no-store");
      expect(await response.json()).toEqual(RATE_LIMITED);
    }
    expect(spy).not.toHaveBeenCalled();
  });
});

// ───────────────────────── helpers ─────────────────────────

describe("storedEventOf", () => {
  it("reads an all-day event with no end as one day long", () => {
    expect(storedEventOf({ summary: "Day", start: { date: "2026-11-20" } })).toEqual({
      kind: "allDay",
      title: "Day",
      start: Date.UTC(2026, 10, 20) / 1000,
      end: Date.UTC(2026, 10, 21) / 1000,
    });
  });

  it("refuses an event that mixes a date and a time", () => {
    expect(storedEventOf({ start: { date: "2026-11-20" }, end: { dateTime: "2026-11-21T00:00:00Z" } })).toBeNull();
    expect(storedEventOf({ start: {}, end: {} })).toBeNull();
    expect(storedEventOf({ end: { date: "2026-11-21" } })).toBeNull();
  });

  it("reads a time with an offset and fractional seconds", () => {
    expect(storedEventOf({ start: { dateTime: "2026-11-20T09:00:00.500+01:00" }, end: { dateTime: "2026-11-20T10:00:00+01:00" } })).toEqual({
      kind: "instant",
      title: "",
      start: Date.UTC(2026, 10, 20, 8) / 1000,
      end: Date.UTC(2026, 10, 20, 9) / 1000,
    });
  });
});

describe("isRateLimitBody", () => {
  it("tells a rate limit from other refusals", () => {
    expect(isRateLimitBody({ error: { errors: [{ domain: "usageLimits", reason: "rateLimitExceeded" }] } })).toBe(true);
    expect(isRateLimitBody({ error: { errors: [{ domain: "global", reason: "quotaExceeded" }] } })).toBe(true);
    expect(isRateLimitBody({ error: { status: "RESOURCE_EXHAUSTED" } })).toBe(true);
    expect(isRateLimitBody({ error: { errors: [{ domain: "global", reason: "insufficientPermissions" }], status: "PERMISSION_DENIED" } })).toBe(false);
    expect(isRateLimitBody({ error: { errors: [{ domain: "calendar", reason: "forbiddenForNonOrganizer" }] } })).toBe(false);
    expect(isRateLimitBody(null)).toBe(false);
    expect(isRateLimitBody("x")).toBe(false);
  });
});
