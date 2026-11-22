import { exports } from "cloudflare:workers";
import { afterEach, describe, expect, it, vi } from "vitest";
import { GOOGLE_MAX_BYTES, GOOGLE_TIMEOUT_MS, googleDeadline } from "../src/lib/google.ts";
import { startWorker } from "./start-worker.ts";

startWorker();

// POST /v1/google/events/create (task 168). Google is mocked: every outbound
// fetch is recorded, body included, and answered by `reply`. The 403 bodies
// below follow community reports and Google's ErrorReason list, not Google's
// Calendar documentation (which does not show them): these tests check the
// mapping table in src/lib/google.ts, not that Google really sends these.

/** An obviously fake token. Every test checks it never comes back or reaches a log. */
const TOKEN = "ya29.fake-google-token-for-create-tests-0000";
const ZONE = "America/New_York";
const CALENDAR = "family1234@group.calendar.google.com";
const EVENT_ID = "3f2b8c9d4e5f40718293a4b5c6d7e8f9";
const TITLE = "Meeting with Rahaf";
const INSERT_FIELDS = "status,summary,start,end,endTimeUnspecified";

const INVALID_REQUEST = {
  error: "invalid_request",
  message:
    "Send an X-Google-Token header and a JSON body with a calendar id, an event id of 32 lowercase hex digits, a title of 1 to 200 characters, an IANA time zone, and either a start and end up to 24 hours apart or an all-day date",
};
const GOOGLE_AUTH = { error: "google_auth", message: "Google did not accept the access token; refresh it and try again" };
const INSUFFICIENT_SCOPE = { error: "insufficient_scope", message: "Google Calendar was connected without permission to add events; connect it again" };
const FORBIDDEN = { error: "forbidden", message: "Google did not allow adding events to this calendar" };
const NOT_FOUND = { error: "not_found", message: "Google has no such calendar for this account" };
const RATE_LIMITED = { error: "rate_limited", message: "Google is limiting requests; try again later" };
const FETCH_FAILED = { error: "fetch_failed", message: "Google Calendar could not be reached; try again with the same event id" };
const TIMEOUT = { error: "timeout", message: "Google Calendar did not answer in time; the event may have been added. Try again with the same event id" };

type Sent = { url: URL; method: string; headers: Headers; body: string; redirect: RequestInit["redirect"] };
type Reply = (sent: Sent, signal: AbortSignal | undefined) => Response | Promise<Response>;

const json = (body: unknown, status = 200, headers: Record<string, string> = {}) =>
  new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json", ...headers } });

/** Google's answer to events.insert: the event as sent, in the event's own zone, limited to the fields asked for. */
const echo: Reply = (sent) => {
  const body = JSON.parse(sent.body) as { summary: string; start: Record<string, string>; end: Record<string, string> };
  const local = (side: Record<string, string>) =>
    side.dateTime
      ? { dateTime: new Date(Date.parse(side.dateTime) - 5 * 3600_000).toISOString().replace(/\.\d{3}Z$/, "-05:00"), timeZone: side.timeZone }
      : { date: side.date };
  return json({ status: "confirmed", summary: body.summary, start: local(body.start), end: local(body.end) });
};

function mockGoogle(reply: Reply = echo) {
  const sent: Sent[] = [];
  const spy = vi.spyOn(globalThis, "fetch").mockImplementation(async (input, init) => {
    const request = new Request(input, init);
    const record = { url: new URL(request.url), method: request.method, headers: request.headers, body: await request.text(), redirect: init?.redirect };
    sent.push(record);
    return reply(record, init?.signal ?? undefined);
  });
  return { sent, spy };
}

/** Google's error body with the token, the title and a time planted in its text, as a careless server might. */
const googleError = (code: number, reasons: string[], extra: Record<string, unknown> = {}, headers: Record<string, string> = {}) =>
  json(
    {
      error: {
        code,
        message: `Token ${TOKEN} refused for ${TITLE} at 2026-11-22T15:00:00-05:00 on ${CALENDAR}`,
        errors: reasons.map((reason) => ({ domain: "global", reason, message: `Bad ${TOKEN} ${TITLE}` })),
        ...extra,
      },
    },
    code,
    headers,
  );

const timedRequest = (extra: Record<string, unknown> = {}) => ({
  calendar: CALENDAR,
  id: EVENT_ID,
  title: TITLE,
  timezone: ZONE,
  start: "2026-11-22T15:00:00-05:00",
  end: "2026-11-22T16:00:00-05:00",
  ...extra,
});
const allDayRequest = (extra: Record<string, unknown> = {}) => ({ calendar: CALENDAR, id: EVENT_ID, title: TITLE, timezone: ZONE, date: "2026-11-22", ...extra });

function create(body: unknown, headers: Record<string, string> = { "x-google-token": TOKEN, "content-type": "application/json" }) {
  return exports.default.fetch("https://example.com/v1/google/events/create", {
    method: "POST",
    headers,
    body: typeof body === "string" ? body : JSON.stringify(body),
  });
}

/** Everything written to the console. */
function captureConsole() {
  const spies = (["log", "info", "warn", "error", "debug"] as const).map((method) => vi.spyOn(console, method).mockImplementation(() => {}));
  return { lines: () => spies.flatMap((spy) => spy.mock.calls.map((call) => call.map(String).join(" "))) };
}

/** The whole response as text, headers included, after checking it says not to cache. */
async function readAll(response: Response): Promise<string> {
  expect(response.headers.get("cache-control")).toBe("no-store");
  const headers = [...response.headers].map(([name, value]) => `${name}: ${value}`).join("\n");
  return `${headers}\n${await response.text()}`;
}

/** Nothing the user sent, other than the event id, in this text. */
function expectPrivate(text: string) {
  for (const secret of [TOKEN, TITLE, "Rahaf", CALENDAR, "family1234", "2026-11-22", "15:00", "20:00:00"]) expect(text).not.toContain(secret);
}

afterEach(() => {
  vi.restoreAllMocks();
  googleDeadline.ms = GOOGLE_TIMEOUT_MS;
});

describe("POST /v1/google/events/create", () => {
  it("adds a timed event with the title and times only, and answers it in the events shape", async () => {
    const google = mockGoogle();
    const logs = captureConsole();
    const response = await create(timedRequest({ title: `  ${TITLE}  ` }));
    expect(response.status).toBe(200);
    expect(response.headers.get("cache-control")).toBe("no-store");
    expect(await response.json()).toEqual({
      id: EVENT_ID,
      created: true,
      event: { calendar: 0, title: TITLE, start: "2026-11-22T20:00:00Z", end: "2026-11-22T21:00:00Z", allDay: false },
    });

    expect(google.sent).toHaveLength(1);
    const [call] = google.sent;
    expect(call!.method).toBe("POST");
    expect(call!.url.origin).toBe("https://www.googleapis.com");
    expect(call!.url.pathname).toBe(`/calendar/v3/calendars/${encodeURIComponent(CALENDAR)}/events`);
    // Only `fields`: no sendUpdates (there are no guests to notify), no conferenceDataVersion.
    expect([...call!.url.searchParams]).toEqual([["fields", INSERT_FIELDS]]);
    expect(call!.headers.get("authorization")).toBe(`Bearer ${TOKEN}`);
    expect(call!.headers.get("content-type")).toBe("application/json");
    expect(call!.redirect).toBe("manual");
    const sent = JSON.parse(call!.body) as Record<string, unknown>;
    expect(Object.keys(sent).sort()).toEqual(["end", "id", "start", "summary"]);
    expect(sent).toEqual({
      id: EVENT_ID,
      summary: TITLE,
      start: { dateTime: "2026-11-22T20:00:00Z", timeZone: ZONE },
      end: { dateTime: "2026-11-22T21:00:00Z", timeZone: ZONE },
    });
    expect(logs.lines()).toEqual([]);
  });

  it("reads a start and end given in UTC the same way", async () => {
    const google = mockGoogle();
    const response = await create(timedRequest({ start: "2026-11-22T20:00:00Z", end: "2026-11-23T20:00:00Z" }));
    expect(response.status).toBe(200);
    const sent = JSON.parse(google.sent[0]!.body) as { start: unknown; end: unknown };
    expect(sent.start).toEqual({ dateTime: "2026-11-22T20:00:00Z", timeZone: ZONE });
    expect(sent.end).toEqual({ dateTime: "2026-11-23T20:00:00Z", timeZone: ZONE });
  });

  it("adds an all-day event with an exclusive end date and places it in the time zone", async () => {
    const google = mockGoogle();
    const response = await create(allDayRequest());
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({
      id: EVENT_ID,
      created: true,
      event: { calendar: 0, title: TITLE, start: "2026-11-22T05:00:00Z", end: "2026-11-23T05:00:00Z", allDay: true, date: "2026-11-22" },
    });
    const sent = JSON.parse(google.sent[0]!.body) as Record<string, unknown>;
    expect(Object.keys(sent).sort()).toEqual(["end", "id", "start", "summary"]);
    expect(sent).toEqual({ id: EVENT_ID, summary: TITLE, start: { date: "2026-11-22" }, end: { date: "2026-11-23" } });
  });

  it("ends an all-day event on the last day of the year in the next year", async () => {
    const google = mockGoogle();
    expect((await create(allDayRequest({ date: "2026-12-31" }))).status).toBe(200);
    expect(JSON.parse(google.sent[0]!.body)).toMatchObject({ start: { date: "2026-12-31" }, end: { date: "2027-01-01" } });
  });

  it("answers a duplicate id as success without reading the event back", async () => {
    const google = mockGoogle(() => googleError(409, ["duplicate"]));
    const logs = captureConsole();
    const response = await create(timedRequest());
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ id: EVENT_ID, created: false });
    expect(google.sent).toHaveLength(1);
    expect(logs.lines()).toEqual(["google-create: event id already exists; answered as added"]);
  });

  it("sends the same id again on a retry, so the retry finds the first event", async () => {
    let calls = 0;
    const google = mockGoogle((sent, signal) => (++calls === 1 ? Promise.reject(new TypeError("connection reset")) : googleError(409, ["duplicate"])));
    captureConsole();
    const first = await create(timedRequest());
    expect(first.status).toBe(502);
    expect(await first.json()).toEqual(FETCH_FAILED);
    const second = await create(timedRequest());
    expect(await second.json()).toEqual({ id: EVENT_ID, created: false });
    expect(google.sent.map((call) => (JSON.parse(call.body) as { id: string }).id)).toEqual([EVENT_ID, EVENT_ID]);
  });

  it("answers success without the event when Google's 2xx has nothing to read", async () => {
    mockGoogle(() => new Response(null, { status: 200 }));
    const logs = captureConsole();
    const response = await create(timedRequest());
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ id: EVENT_ID, created: true });
    expect(logs.lines()).toEqual(["google-create: added, but the answer could not be read"]);
  });

  describe("Google's failures, each a fixed body", () => {
    const cases: [string, Reply, number, unknown][] = [
      ["401", () => googleError(401, ["authError"]), 401, GOOGLE_AUTH],
      [
        "403 insufficientPermissions with ACCESS_TOKEN_SCOPE_INSUFFICIENT",
        () =>
          googleError(403, ["insufficientPermissions"], {
            status: "PERMISSION_DENIED",
            details: [{ "@type": "type.googleapis.com/google.rpc.ErrorInfo", reason: "ACCESS_TOKEN_SCOPE_INSUFFICIENT", domain: "googleapis.com" }],
          }),
        403,
        INSUFFICIENT_SCOPE,
      ],
      ["403 insufficientPermissions alone", () => googleError(403, ["insufficientPermissions"]), 403, INSUFFICIENT_SCOPE],
      [
        "403 ACCESS_TOKEN_SCOPE_INSUFFICIENT in details alone",
        () => googleError(403, [], { status: "PERMISSION_DENIED", details: [{ reason: "ACCESS_TOKEN_SCOPE_INSUFFICIENT", domain: "googleapis.com" }] }),
        403,
        INSUFFICIENT_SCOPE,
      ],
      [
        "403 with WWW-Authenticate insufficient_scope and no readable body",
        () =>
          new Response("not json", {
            status: 403,
            headers: { "www-authenticate": 'Bearer realm="https://accounts.google.com/", error="insufficient_scope", scope="https://www.googleapis.com/auth/calendar.events.owned"' },
          }),
        403,
        INSUFFICIENT_SCOPE,
      ],
      ["403 requiredAccessLevel (calendar not writable)", () => googleError(403, ["requiredAccessLevel"]), 403, FORBIDDEN],
      ["403 forbiddenForNonOrganizer", () => googleError(403, ["forbiddenForNonOrganizer"]), 403, FORBIDDEN],
      ["403 with an unknown reason", () => googleError(403, ["somethingNew"]), 403, FORBIDDEN],
      ["403 with no body", () => new Response(null, { status: 403 }), 403, FORBIDDEN],
      ["403 rateLimitExceeded", () => googleError(403, ["rateLimitExceeded"]), 429, RATE_LIMITED],
      ["403 userRateLimitExceeded", () => googleError(403, ["userRateLimitExceeded"]), 429, RATE_LIMITED],
      ["429", () => googleError(429, ["rateLimitExceeded"]), 429, RATE_LIMITED],
      ["404", () => googleError(404, ["notFound"]), 404, NOT_FOUND],
      ["410", () => googleError(410, ["deleted"]), 404, NOT_FOUND],
      ["409 conflict (not a duplicate)", () => googleError(409, ["conflict"]), 502, FETCH_FAILED],
      ["409 with no body", () => new Response(null, { status: 409 }), 502, FETCH_FAILED],
      ["400 from Google", () => googleError(400, ["invalid"]), 502, FETCH_FAILED],
      ["500", () => googleError(500, ["backendError"]), 502, FETCH_FAILED],
      ["a push.* reason", () => googleError(400, ["push.webhookUrlUnauthorized"]), 502, FETCH_FAILED],
      ["a redirect", () => new Response(null, { status: 307, headers: { location: "https://evil.example.com/" } }), 502, FETCH_FAILED],
      ["a network failure", () => Promise.reject(new TypeError("network down")), 502, FETCH_FAILED],
      ["a 2xx that is not JSON", () => new Response("<html>", { status: 200 }), 502, FETCH_FAILED],
      ["a 2xx over the cap", () => new Response("x".repeat(GOOGLE_MAX_BYTES + 1), { status: 200 }), 502, FETCH_FAILED],
    ];

    it.each(cases)("%s", async (_name, reply, status, body) => {
      const google = mockGoogle(reply);
      const logs = captureConsole();
      const response = await create(timedRequest());
      expect(response.status).toBe(status);
      // Google's limit is not ours: no Retry-After is made up for it.
      expect(response.headers.get("retry-after")).toBeNull();
      const text = await readAll(response);
      expect(JSON.parse(text.slice(text.indexOf("\n{") + 1))).toEqual(body);
      expect(google.sent).toHaveLength(1);
      expectPrivate(text);
      const lines = logs.lines();
      expect(lines).toHaveLength(1);
      expect(lines[0]).toMatch(/^google-create: failed: [a-z_]+( \([a-z_]+\))?$/);
      expectPrivate(lines.join("\n"));
    });

    it("gives up after the deadline with timeout", async () => {
      googleDeadline.ms = 50;
      const logs = captureConsole();
      mockGoogle(
        (_sent, signal) => new Promise((_resolve, reject) => signal?.addEventListener("abort", () => reject(new DOMException("aborted", "AbortError")))),
      );
      const response = await create(timedRequest());
      expect(response.status).toBe(502);
      expect(await response.json()).toEqual(TIMEOUT);
      expect(logs.lines()).toEqual(["google-create: failed: timeout"]);
    });

    it("gives up on a body that stalls after the headers with timeout", async () => {
      googleDeadline.ms = 50;
      captureConsole();
      mockGoogle(() => new Response(new ReadableStream({ start: (controller) => controller.enqueue(new TextEncoder().encode('{"status": ')) }), { status: 200 }));
      const response = await create(timedRequest());
      expect(response.status).toBe(502);
      expect(await response.json()).toEqual(TIMEOUT);
    });
  });

  describe("validation: a fixed 400 and no call to Google", () => {
    const tooLongTitle = "x".repeat(201);
    const bodies: [string, unknown][] = [
      ["no body fields", {}],
      ["a calendar that is empty", timedRequest({ calendar: "" })],
      ["a calendar of ..", timedRequest({ calendar: ".." })],
      ["a calendar with a space", timedRequest({ calendar: "my calendar" })],
      ["a calendar over 512 characters", timedRequest({ calendar: "a".repeat(513) })],
      ["no event id", timedRequest({ id: undefined })],
      ["an event id in upper case", timedRequest({ id: EVENT_ID.toUpperCase() })],
      ["an event id with dashes", timedRequest({ id: "3f2b8c9d-4e5f-4071-8293-a4b5c6d7e8f9" })],
      ["an event id of 31 digits", timedRequest({ id: EVENT_ID.slice(1) })],
      ["an event id outside hex", timedRequest({ id: "z".repeat(32) })],
      ["no title", timedRequest({ title: undefined })],
      ["an empty title", timedRequest({ title: "" })],
      ["a title of spaces", timedRequest({ title: "    " })],
      ["a title over 200 characters", timedRequest({ title: tooLongTitle })],
      ["a title with a line break", timedRequest({ title: "Meeting\nwith Rahaf" })],
      ["a title with a C1 control", timedRequest({ title: "Meeting\u0085with Rahaf" })],
      ["a title that is not text", timedRequest({ title: 42 })],
      ["no time zone", timedRequest({ timezone: undefined })],
      ["an unknown time zone", timedRequest({ timezone: "Mars/Olympus_Mons" })],
      ["an offset for a time zone", timedRequest({ timezone: "+05:00" })],
      ["an abbreviation for a time zone", timedRequest({ timezone: "EST" })],
      ["a time zone in lower case", timedRequest({ timezone: "america/new_york" })],
      ["a US/ alias for a time zone", timedRequest({ timezone: "US/Eastern" })],
      ["a start without an end", timedRequest({ end: undefined })],
      ["an end without a start", timedRequest({ start: undefined })],
      ["neither times nor a date", timedRequest({ start: undefined, end: undefined })],
      ["times and a date", timedRequest({ date: "2026-11-22" })],
      ["a date and a start", allDayRequest({ start: "2026-11-22T15:00:00-05:00" })],
      ["an end equal to the start", timedRequest({ end: "2026-11-22T15:00:00-05:00" })],
      ["an end before the start", timedRequest({ end: "2026-11-22T14:00:00-05:00" })],
      ["more than 24 hours", timedRequest({ end: "2026-11-23T15:00:01-05:00" })],
      ["a time without an offset", timedRequest({ start: "2026-11-22T15:00:00" })],
      ["a time without seconds", timedRequest({ start: "2026-11-22T15:00-05:00" })],
      ["a time with fractions", timedRequest({ start: "2026-11-22T15:00:00.000Z" })],
      ["hour 24", timedRequest({ start: "2026-11-22T24:00:00Z" })],
      ["30 February", timedRequest({ start: "2026-02-30T15:00:00Z" })],
      ["an all-day date that does not exist", allDayRequest({ date: "2026-02-30" })],
      ["an all-day date with a time", allDayRequest({ date: "2026-11-22T00:00:00Z" })],
      ["attendees", timedRequest({ attendees: [{ email: "rahaf@example.com" }] })],
      ["a location", timedRequest({ location: "Cafe" })],
      ["a description", timedRequest({ description: "Notes" })],
      ["a repeat rule", timedRequest({ recurrence: ["RRULE:FREQ=WEEKLY"] })],
      ["reminders", timedRequest({ reminders: { useDefault: false } })],
      ["conferencing", timedRequest({ conferenceData: { createRequest: { requestId: "x" } } })],
      ["sendUpdates", timedRequest({ sendUpdates: "all" })],
      ["an array", [timedRequest()]],
      ["JSON that does not parse", '{"calendar": "primary",'],
    ];

    it.each(bodies)("%s", async (_name, body) => {
      const google = mockGoogle();
      const logs = captureConsole();
      const response = await create(body);
      expect(response.status).toBe(400);
      const text = await readAll(response);
      expect(JSON.parse(text.slice(text.indexOf("\n{") + 1))).toEqual(INVALID_REQUEST);
      expectPrivate(text);
      expect(google.spy).not.toHaveBeenCalled();
      expectPrivate(logs.lines().join("\n"));
    });

    it("refuses a body not sent as JSON", async () => {
      const google = mockGoogle();
      const response = await create(timedRequest(), { "x-google-token": TOKEN, "content-type": "text/plain" });
      expect(response.status).toBe(400);
      expect(await response.json()).toEqual(INVALID_REQUEST);
      expect(google.spy).not.toHaveBeenCalled();
    });

    it.each([
      ["no token", { "content-type": "application/json" }],
      ["a short token", { "content-type": "application/json", "x-google-token": "short" }],
      ["a token with a space", { "content-type": "application/json", "x-google-token": "ya29.has a space-0000000" }],
    ])("refuses %s", async (_name, headers) => {
      const google = mockGoogle();
      const response = await create(timedRequest(), headers);
      expect(response.status).toBe(400);
      expect(await response.json()).toEqual(INVALID_REQUEST);
      expect(google.spy).not.toHaveBeenCalled();
    });

    it("accepts a title of exactly 200 characters after trimming, and an event of exactly 24 hours", async () => {
      const google = mockGoogle();
      const title = "y".repeat(200);
      const response = await create(timedRequest({ title: ` ${title} `, end: "2026-11-23T15:00:00-05:00" }));
      expect(response.status).toBe(200);
      expect(JSON.parse(google.sent[0]!.body)).toMatchObject({ summary: title });
    });
  });
});

// The finer reasons are read only by the create route: the read routes answer
// a scope 403 and a 409 exactly as before.
describe("the read routes are unchanged by the finer reasons", () => {
  const scope403 = () =>
    googleError(403, ["insufficientPermissions"], { status: "PERMISSION_DENIED", details: [{ reason: "ACCESS_TOKEN_SCOPE_INSUFFICIENT" }] });

  it("calendar list: a scope 403 is still google_forbidden", async () => {
    mockGoogle(scope403);
    captureConsole();
    const response = await exports.default.fetch("https://example.com/v1/google/calendars", { headers: { "x-google-token": TOKEN } });
    expect(response.status).toBe(403);
    expect(await response.json()).toEqual({ error: "google_forbidden", message: "Google refused access to the calendar list; connect Google Calendar again" });
  });

  it("events: a scope 403 is still forbidden and a 409 still fetch_failed", async () => {
    mockGoogle((sent) => (sent.url.pathname.includes("primary") ? scope403() : googleError(409, ["duplicate"])));
    captureConsole();
    const response = await exports.default.fetch("https://example.com/v1/google/events", {
      method: "POST",
      headers: { "x-google-token": TOKEN, "content-type": "application/json" },
      body: JSON.stringify({ calendars: ["primary", "other@example.com"] }),
    });
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({
      events: [],
      calendars: [
        { index: 0, ok: false, partial: false, error: "forbidden" },
        { index: 1, ok: false, partial: false, error: "fetch_failed" },
      ],
    });
  });
});
