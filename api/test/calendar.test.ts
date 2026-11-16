import { env, exports } from "cloudflare:workers";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { MAX_CALENDAR_BYTES, MAX_EVENTS_PER_FILE } from "../src/lib/calendar.ts";
import { calendarCacheKey } from "../src/routes/calendar.ts";
// Written by hand in the shape each provider exports; no real calendar was fetched.
import google from "./fixtures/calendar/google.ics?raw";
import icloud from "./fixtures/calendar/icloud.ics?raw";
import outlook from "./fixtures/calendar/outlook.ics?raw";

/** Monday 16 November 2026, 10:00 in New York. */
const NOW = new Date("2026-11-16T15:00:00Z");

// Made-up links in the shape of the real ones. Each holds a secret part.
const GOOGLE = "https://calendar.example.com/calendar/ical/someone%40example.com/private-9f8e7d6c5b4a3f2e/basic.ics";
const ICLOUD = "webcal://p42-caldav.example.net/published/2/MTIzNDU2Nzg5MDEyMzQ1Njc4OTAxMjM0NTY3ODkw";
const ICLOUD_HTTPS = ICLOUD.replace("webcal://", "https://");
const OUTLOOK = "https://outlook.example.org/owa/calendar/a1b2c3d4@example.org/e5f6a7b8c9d0/calendar.ics";
const BROKEN = "https://broken.example.com/feeds/tok-5550123/calendar.ics";

/** Pieces that must never show up in a log line, a KV key or value, or a response. */
const SECRETS = [
  "private-9f8e7d6c5b4a3f2e",
  "someone%40example.com",
  "someone@example.com",
  "calendar.example.com",
  "MTIzNDU2Nzg5MDEyMzQ1Njc4OTAxMjM0NTY3ODkw",
  "p42-caldav",
  "example.net",
  "outlook.example.org",
  "e5f6a7b8c9d0",
  "a1b2c3d4",
  "tok-5550123",
  "broken.example.com",
  "/published/",
  "basic.ics",
  "10.0.0.5",
];

type Reply = () => Response | Promise<Response>;

const ics = (text: string): Reply => () =>
  new Response(text, { headers: { "content-type": "text/calendar; charset=utf-8" } });

/** Replaces outbound fetch with a table of exact URLs. Any other request fails, so nothing reaches the network. */
function mockCalendars(replies: Record<string, Reply>) {
  return vi.spyOn(globalThis, "fetch").mockImplementation(async (input, init) => {
    const request = new Request(input, init);
    const reply = replies[request.url];
    if (!reply) throw new Error("Unexpected outbound request");
    return reply();
  });
}

const providers = {
  [GOOGLE]: ics(google),
  [ICLOUD_HTTPS]: ics(icloud),
  [OUTLOOK]: ics(outlook),
};

const post = (body: unknown) =>
  exports.default.fetch("https://example.com/v1/calendar/events", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: typeof body === "string" ? body : JSON.stringify(body),
  });

type Body = {
  events: { calendar: number; title: string; start: string; end: string; allDay: boolean; date?: string }[];
  calendars: { index: number; ok: boolean; partial: boolean; error?: string }[];
};

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
  // Only Date is faked: timers keep running, so the fetch deadline still works.
  vi.useFakeTimers({ toFake: ["Date"], now: NOW });
  await clearCache();
});

afterEach(() => {
  vi.useRealTimers();
  vi.restoreAllMocks();
});

describe("POST /v1/calendar/events", () => {
  it("merges three calendars, soonest first, and names each by its index", async () => {
    mockCalendars(providers);

    const body = await events({ links: [GOOGLE, ICLOUD, OUTLOOK], timezone: "America/New_York" });

    expect(body.calendars).toEqual([
      { index: 0, ok: true, partial: false },
      { index: 1, ok: true, partial: false },
      { index: 2, ok: true, partial: false },
    ]);
    expect(body.events).toEqual([
      { calendar: 0, title: "Road trip", start: "2026-11-14T05:00:00Z", end: "2026-11-18T05:00:00Z", allDay: true, date: "2026-11-14" },
      { calendar: 1, title: "Camping at the lake", start: "2026-11-15T23:00:00Z", end: "2026-11-17T17:00:00Z", allDay: false },
      { calendar: 1, title: "Morning run", start: "2026-11-17T12:30:00Z", end: "2026-11-17T13:00:00Z", allDay: false },
      { calendar: 2, title: "Budget review", start: "2026-11-17T15:00:00Z", end: "2026-11-17T16:00:00Z", allDay: false },
      { calendar: 0, title: "Dentist", start: "2026-11-17T19:00:00Z", end: "2026-11-17T20:00:00Z", allDay: false },
      { calendar: 1, title: "Call the landlord", start: "2026-11-18T00:00:00Z", end: "2026-11-18T00:00:00Z", allDay: false },
      { calendar: 0, title: "Mom's birthday", start: "2026-11-18T05:00:00Z", end: "2026-11-19T05:00:00Z", allDay: true, date: "2026-11-18" },
      { calendar: 1, title: "Morning run (late start)", start: "2026-11-19T13:30:00Z", end: "2026-11-19T14:00:00Z", allDay: false },
      // Floating: noon in the request's zone, New York.
      { calendar: 1, title: "Lunch with Ana", start: "2026-11-19T17:00:00Z", end: "2026-11-19T18:00:00Z", allDay: false },
      { calendar: 2, title: "Company holiday", start: "2026-11-20T05:00:00Z", end: "2026-11-21T05:00:00Z", allDay: true, date: "2026-11-20" },
      { calendar: 2, title: "Weekly staff meeting", start: "2026-11-20T14:00:00Z", end: "2026-11-20T15:00:00Z", allDay: false },
      { calendar: 0, title: "1:1 with Sam", start: "2026-11-20T16:00:00Z", end: "2026-11-20T16:30:00Z", allDay: false },
      { calendar: 2, title: "Payroll cutoff", start: "2026-11-20T17:00:00Z", end: "2026-11-20T17:30:00Z", allDay: false },
      { calendar: 1, title: "Book club", start: "2026-11-21T01:00:00Z", end: "2026-11-21T02:30:00Z", allDay: false },
      { calendar: 1, title: "Morning run", start: "2026-11-21T12:30:00Z", end: "2026-11-21T13:00:00Z", allDay: false },
      { calendar: 1, title: "Morning run", start: "2026-11-22T12:30:00Z", end: "2026-11-22T13:00:00Z", allDay: false },
      { calendar: 1, title: "Morning run", start: "2026-11-23T12:30:00Z", end: "2026-11-23T13:00:00Z", allDay: false },
      { calendar: 0, title: "Team sync", start: "2026-11-23T14:30:00Z", end: "2026-11-23T15:00:00Z", allDay: false },
    ]);
  });

  it("uses UTC for floating and all-day events when no time zone is sent", async () => {
    mockCalendars(providers);

    const body = await events({ links: [ICLOUD, OUTLOOK] });

    expect(body.events.find((event) => event.title === "Lunch with Ana")).toMatchObject({
      start: "2026-11-19T12:00:00Z",
      end: "2026-11-19T13:00:00Z",
    });
    expect(body.events.find((event) => event.title === "Company holiday")).toEqual({
      calendar: 1,
      title: "Company holiday",
      start: "2026-11-20T00:00:00Z",
      end: "2026-11-21T00:00:00Z",
      allDay: true,
      date: "2026-11-20",
    });
  });

  it("fetches a webcal link over https, as a plain GET that names no one", async () => {
    const spy = mockCalendars(providers);

    await events({ links: [ICLOUD] });

    expect(spy).toHaveBeenCalledTimes(1);
    const [input, init] = spy.mock.calls[0]!;
    expect(String(input)).toBe(ICLOUD_HTTPS);
    expect(init?.method).toBe("GET");
    expect(init?.redirect).toBe("manual");
    const headers = new Headers(init?.headers);
    expect(headers.get("user-agent")).toBe("SeasignBot/1.0");
    expect([...headers.keys()].sort()).toEqual(["accept", "user-agent"]);
  });

  it("follows a redirect to another public https address", async () => {
    mockCalendars({
      [GOOGLE]: () => new Response(null, { status: 302, headers: { location: "https://cdn.example.com/c/1.ics" } }),
      "https://cdn.example.com/c/1.ics": ics(google),
    });

    const body = await events({ links: [GOOGLE] });

    expect(body.calendars).toEqual([{ index: 0, ok: true, partial: false }]);
    expect(body.events.length).toBeGreaterThan(0);
  });

  it("caps the answer at 50 events", async () => {
    const lines = ["BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//Test//Test//EN"];
    for (let i = 0; i < 70; i++) {
      const minute = String(i % 60).padStart(2, "0");
      const hour = String(16 + Math.floor(i / 60)).padStart(2, "0");
      lines.push("BEGIN:VEVENT", `UID:many-${i}@example.com`, `SUMMARY:e${i}`, `DTSTART:20261116T${hour}${minute}00Z`, "END:VEVENT");
    }
    lines.push("END:VCALENDAR");
    mockCalendars({ [GOOGLE]: ics(lines.join("\r\n")) });

    const body = await events({ links: [GOOGLE] });

    expect(body.events).toHaveLength(50);
    expect(body.events[0]?.title).toBe("e0");
    expect(body.events[49]?.title).toBe("e49");
  });

  describe("one link failing", () => {
    const failures: [string, Reply, string][] = [
      ["answers 404", () => new Response("Not Found", { status: 404 }), "fetch_failed"],
      ["answers 500", () => new Response("oops", { status: 500 }), "fetch_failed"],
      ["is unreachable", () => Promise.reject(new TypeError("network down")), "fetch_failed"],
      ["returns a sign-in page", () => new Response("<!doctype html><html>Sign in</html>", { headers: { "content-type": "text/html" } }), "not_calendar"],
      ["returns a broken calendar", () => new Response("BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nSUMMARY:x"), "not_calendar"],
      ["returns more than 2 MB", () => new Response("BEGIN:VCALENDAR\r\n" + "X-PAD:".padEnd(1024, "x").concat("\r\n").repeat(MAX_CALENDAR_BYTES / 1024 + 1)), "too_large"],
      [
        "holds more events than a calendar is read with",
        () =>
          new Response(
            ["BEGIN:VCALENDAR", ...Array.from({ length: MAX_EVENTS_PER_FILE + 1 }, (_, i) => `BEGIN:VEVENT\r\nUID:${i}\r\nDTSTART:20261117T090000Z\r\nEND:VEVENT`), "END:VCALENDAR"].join("\r\n"),
          ),
        "too_large",
      ],
      ["redirects to a private address", () => new Response(null, { status: 302, headers: { location: "https://10.0.0.5/internal.ics" } }), "blocked_host"],
      ["redirects to plain http", () => new Response(null, { status: 301, headers: { location: "http://broken.example.com/c.ics" } }), "invalid_link"],
      ["redirects for ever", () => new Response(null, { status: 302, headers: { location: BROKEN } }), "fetch_failed"],
    ];

    it.each(failures)("does not fail the others when it %s", async (_name, reply, code) => {
      const spy = mockCalendars({ ...providers, [BROKEN]: reply });

      const body = await events({ links: [GOOGLE, BROKEN, OUTLOOK] });

      expect(body.calendars).toEqual([
        { index: 0, ok: true, partial: false },
        { index: 1, ok: false, partial: false, error: code },
        { index: 2, ok: true, partial: false },
      ]);
      expect(new Set(body.events.map((event) => event.calendar))).toEqual(new Set([0, 2]));
      expect(body.events).toHaveLength(9);

      // The failure is not cached: the next request asks that host again, and only that one.
      expect(await env.CACHE.get(await calendarCacheKey(BROKEN))).toBeNull();
      vi.restoreAllMocks();
      const retry = mockCalendars({ ...providers, [BROKEN]: ics(icloud) });
      const again = await events({ links: [GOOGLE, BROKEN, OUTLOOK] });
      expect(again.calendars[1]).toEqual({ index: 1, ok: true, partial: false });
      expect(retry.mock.calls.map(([input]) => String(input))).toEqual([BROKEN]);
      expect(spy).not.toBe(retry);
    });

    it("reports a host that never answers as timeout", async () => {
      // Timers are faked here too, so the 8 second deadline can be reached at once.
      vi.useFakeTimers({ toFake: ["Date", "setTimeout", "clearTimeout"], now: NOW });
      let aborted = false;
      vi.spyOn(globalThis, "fetch").mockImplementation(
        (_input, init) =>
          new Promise<Response>((_resolve, reject) => {
            init?.signal?.addEventListener("abort", () => {
              aborted = true;
              reject(new DOMException("aborted", "AbortError"));
            });
            queueMicrotask(() => vi.advanceTimersByTime(7999));
            queueMicrotask(() => expect(aborted).toBe(false));
            queueMicrotask(() => vi.advanceTimersByTime(1));
          }),
      );

      const body = await events({ links: [BROKEN] });

      expect(body).toEqual({ events: [], calendars: [{ index: 0, ok: false, partial: false, error: "timeout" }] });
      expect(aborted).toBe(true);
    });
  });

  describe("links that are refused without a request", () => {
    it.each([
      ["plain http", "http://calendar.example.com/private-9f8e7d6c5b4a3f2e/basic.ics", "invalid_link"],
      ["another scheme", "ftp://calendar.example.com/basic.ics", "invalid_link"],
      ["not a URL", "my calendar", "invalid_link"],
      ["an empty string", "", "invalid_link"],
      ["credentials in the URL", "https://someone:hunter2@calendar.example.com/basic.ics", "invalid_link"],
      ["another port", "https://calendar.example.com:8443/basic.ics", "invalid_link"],
      ["an absurdly long link", `https://calendar.example.com/${"a".repeat(3000)}`, "invalid_link"],
      ["a private IPv4 address", "https://192.168.1.10/calendar.ics", "blocked_host"],
      ["a private address behind webcal", "webcal://10.0.0.5/calendar.ics", "blocked_host"],
      ["loopback", "https://127.0.0.1/calendar.ics", "blocked_host"],
      ["loopback over IPv6", "https://[::1]/calendar.ics", "blocked_host"],
      ["link-local, where cloud metadata lives", "https://169.254.169.254/latest/meta-data/", "blocked_host"],
      ["a unique-local IPv6 address", "https://[fd00::1]/calendar.ics", "blocked_host"],
      ["IPv4 inside IPv6", "https://[::ffff:10.0.0.5]/calendar.ics", "blocked_host"],
      ["localhost", "https://localhost/calendar.ics", "blocked_host"],
      ["a .local name", "https://nas.local/calendar.ics", "blocked_host"],
      ["a .internal name", "https://calendar.corp.internal/calendar.ics", "blocked_host"],
    ])("%s", async (_name, link, code) => {
      const spy = mockCalendars(providers);

      const body = await events({ links: [link, OUTLOOK] });

      expect(body.calendars).toEqual([
        { index: 0, ok: false, partial: false, error: code },
        { index: 1, ok: true, partial: false },
      ]);
      expect(spy.mock.calls.map(([input]) => String(input))).toEqual([OUTLOOK]);
      const { keys } = await env.CACHE.list({ prefix: "cal:" });
      expect(keys).toHaveLength(1);
    });
  });

  describe("cache", () => {
    it("stores each calendar for 15 minutes under a hash of its link", async () => {
      mockCalendars(providers);
      await events({ links: [GOOGLE, ICLOUD] });

      const { keys } = await env.CACHE.list({ prefix: "cal:" });

      expect(keys.map((key) => key.name).sort()).toEqual(
        [await calendarCacheKey(GOOGLE), await calendarCacheKey(ICLOUD)].sort(),
      );
      for (const key of keys) {
        expect(key.name).toMatch(/^cal:v1:[0-9a-f]{64}$/);
        // KV reports the expiry in Unix seconds, by the real clock, not the faked Date.
        const expected = Math.floor(vi.getRealSystemTime() / 1000) + 15 * 60;
        expect(Math.abs((key.expiration ?? 0) - expected)).toBeLessThan(60);
      }
    });

    it("keys by SHA-256 of the checked link, the same for webcal and https", async () => {
      const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(ICLOUD_HTTPS));
      const hex = [...new Uint8Array(digest)].map((byte) => byte.toString(16).padStart(2, "0")).join("");

      expect(await calendarCacheKey(ICLOUD)).toBe(`cal:v1:${hex}`);
      expect(await calendarCacheKey(ICLOUD_HTTPS)).toBe(`cal:v1:${hex}`);
      expect(await calendarCacheKey(GOOGLE)).not.toBe(`cal:v1:${hex}`);
    });

    it("answers a second request without fetching", async () => {
      const spy = mockCalendars(providers);
      const first = await events({ links: [GOOGLE, ICLOUD, OUTLOOK], timezone: "America/New_York" });
      expect(spy).toHaveBeenCalledTimes(3);

      const second = await events({ links: [GOOGLE, ICLOUD_HTTPS, OUTLOOK], timezone: "America/New_York" });

      expect(spy).toHaveBeenCalledTimes(3);
      expect(second).toEqual(first);
    });

    it("answers from the cache for another time zone and a later moment", async () => {
      const spy = mockCalendars(providers);
      await events({ links: [ICLOUD], timezone: "America/New_York" });

      // Ten minutes on, asked from Chicago.
      vi.setSystemTime(new Date(NOW.getTime() + 10 * 60 * 1000));
      const body = await events({ links: [ICLOUD], timezone: "America/Chicago" });

      expect(spy).toHaveBeenCalledTimes(1);
      expect(body.events.find((event) => event.title === "Lunch with Ana")?.start).toBe("2026-11-19T18:00:00Z");
      // A full day later the cached copy would still answer correctly: the
      // run on the 17th has passed by then, the one on the 24th has come into view.
      vi.setSystemTime(new Date("2026-11-17T15:00:00Z"));
      const later = await events({ links: [ICLOUD], timezone: "America/Chicago" });
      expect(spy).toHaveBeenCalledTimes(1);
      const runs = later.events.filter((event) => event.title === "Morning run").map((event) => event.start);
      expect(runs).toEqual([
        "2026-11-21T12:30:00Z",
        "2026-11-22T12:30:00Z",
        "2026-11-23T12:30:00Z",
        "2026-11-24T12:30:00Z",
      ]);
    });

    it("fetches a link once when it is sent twice", async () => {
      const spy = mockCalendars(providers);

      const body = await events({ links: [OUTLOOK, OUTLOOK] });

      expect(spy).toHaveBeenCalledTimes(1);
      expect(body.calendars).toEqual([
        { index: 0, ok: true, partial: false },
        { index: 1, ok: true, partial: false },
      ]);
      expect(body.events).toHaveLength(8);
    });
  });

  it("fetches once when one calendar is sent as webcal and as https", async () => {
    const spy = mockCalendars(providers);

    const body = await events({ links: [ICLOUD, ICLOUD_HTTPS, `${ICLOUD_HTTPS}#today`, ` ${ICLOUD} `] });

    expect(spy).toHaveBeenCalledTimes(1);
    expect(body.calendars).toEqual([0, 1, 2, 3].map((index) => ({ index, ok: true, partial: false })));
    // Each index still gets the calendar's nine events.
    expect([0, 1, 2, 3].map((index) => body.events.filter((event) => event.calendar === index).length)).toEqual([9, 9, 9, 9]);
  });

  it("says when a calendar was only partly read", async () => {
    const withBadRule = [
      "BEGIN:VCALENDAR",
      "VERSION:2.0",
      "PRODID:-//Test//Test//EN",
      "BEGIN:VEVENT",
      "UID:bad@example.com",
      "SUMMARY:Bad rule",
      "DTSTART:20261117T090000Z",
      "RRULE:FREQ=FOO;COUNT=abc",
      "END:VEVENT",
      "BEGIN:VEVENT",
      "UID:hourly@example.com",
      "SUMMARY:Hourly",
      "DTSTART:20261117T090000Z",
      "RRULE:FREQ=HOURLY",
      "END:VEVENT",
      "BEGIN:VEVENT",
      "UID:good@example.com",
      "SUMMARY:Good",
      "DTSTART:20261117T100000Z",
      "END:VEVENT",
      "END:VCALENDAR",
    ].join("\r\n");
    const spy = mockCalendars({ ...providers, [BROKEN]: ics(withBadRule) });

    const first = await events({ links: [BROKEN, OUTLOOK] });

    expect(first.calendars).toEqual([
      { index: 0, ok: true, partial: true },
      { index: 1, ok: true, partial: false },
    ]);
    expect(first.events.filter((event) => event.calendar === 0).map((event) => event.title)).toEqual(["Good"]);

    // The flag comes back from the cache too.
    const second = await events({ links: [BROKEN, OUTLOOK] });
    expect(spy).toHaveBeenCalledTimes(2);
    expect(second).toEqual(first);
  });

  it("never puts a link in a log line, a KV key or value, or a response", async () => {
    const logged: string[] = [];
    for (const method of ["log", "info", "warn", "error", "debug", "trace"] as const) {
      vi.spyOn(console, method).mockImplementation((...args: unknown[]) => {
        logged.push(args.map((arg) => (arg instanceof Error ? `${arg.message} ${arg.stack}` : String(arg))).join(" "));
      });
    }
    const responses: string[] = [];
    const run = async (body: unknown) => {
      const response = await post(body);
      responses.push(await response.text());
      return response.status;
    };

    // Read, then answered from the cache, next to a host whose error text quotes the link.
    let outbound = mockCalendars({
      ...providers,
      [BROKEN]: () => Promise.reject(new TypeError(`fetch failed: ${BROKEN}`)),
    });
    expect(await run({ links: [GOOGLE, ICLOUD, OUTLOOK, BROKEN], timezone: "America/New_York" })).toBe(200);
    expect(await run({ links: [GOOGLE, ICLOUD, OUTLOOK, BROKEN] })).toBe(200);

    // Each kind of failure, with the link quoted back in the body or the redirect.
    outbound.mockRestore();
    await clearCache();
    outbound = mockCalendars({
      [GOOGLE]: () => new Response(`<html>${GOOGLE}</html>`),
      [ICLOUD_HTTPS]: () => new Response("gone", { status: 410 }),
      [OUTLOOK]: () =>
        new Response(null, { status: 302, headers: { location: "https://10.0.0.5/private-9f8e7d6c5b4a3f2e" } }),
      // Parses as a calendar with one unknown property and no events, so it is cached.
      [BROKEN]: () => new Response(`BEGIN:VCALENDAR\r\nX-SOURCE:${BROKEN}\r\nEND:VCALENDAR`),
    });
    expect(await run({ links: [GOOGLE, ICLOUD, OUTLOOK, BROKEN] })).toBe(200);

    // Refused before any request, and requests that are invalid as a whole.
    expect(
      await run({
        links: [
          "http://calendar.example.com/private-9f8e7d6c5b4a3f2e/basic.ics",
          "https://someone%40example.com:tok-5550123@calendar.example.com/basic.ics",
          "https://10.0.0.5/private-9f8e7d6c5b4a3f2e",
          "not a url private-9f8e7d6c5b4a3f2e",
        ],
      }),
    ).toBe(200);
    expect(await run({ links: Array(11).fill(GOOGLE) })).toBe(400);
    expect(await run({ links: [GOOGLE], timezone: "tok-5550123/Nowhere" })).toBe(400);
    expect(await run({ links: GOOGLE })).toBe(400);
    expect(await run(`{"links": ["${GOOGLE}"`)).toBe(400);

    // Read the good ones again so the cache holds real events to inspect.
    outbound.mockRestore();
    mockCalendars(providers);
    expect(await run({ links: [GOOGLE, ICLOUD, OUTLOOK] })).toBe(200);

    const stored: string[] = [];
    const { keys } = await env.CACHE.list();
    for (const { name } of keys) {
      if (name.startsWith("sky:")) continue;
      stored.push(name, (await env.CACHE.get(name)) ?? "");
    }

    // The checks below are not vacuous: four calendars are cached (keys and
    // values), the values hold events, failures were logged, events were returned.
    expect(stored).toHaveLength(8);
    expect(stored.join("\n")).toContain("Dentist");
    expect(logged).toContain("calendar: link 3 failed: fetch_failed");
    expect(logged).toContain("calendar: link 0 failed: not_calendar");
    expect(logged).toContain("calendar: link 2 failed: blocked_host");
    expect(responses.join("\n")).toContain("Dentist");

    for (const secret of SECRETS) {
      expect(logged.join("\n"), `logs hold ${secret}`).not.toContain(secret);
      expect(stored.join("\n"), `KV holds ${secret}`).not.toContain(secret);
      expect(responses.join("\n"), `a response holds ${secret}`).not.toContain(secret);
    }
  });

  describe("invalid requests", () => {
    it.each([
      ["no body", ""],
      ["malformed JSON", '{"links": ['],
      ["no links field", {}],
      ["an empty list", { links: [] }],
      ["eleven links", { links: Array(11).fill(OUTLOOK) }],
      ["links that are not strings", { links: [1, 2] }],
      ["links that is not a list", { links: OUTLOOK }],
      ["an unknown time zone", { links: [OUTLOOK], timezone: "Mars/Olympus_Mons" }],
      ["a Windows time zone name", { links: [OUTLOOK], timezone: "Eastern Standard Time" }],
      ["a time zone that is not a string", { links: [OUTLOOK], timezone: 5 }],
    ])("answers 400 to %s, with a fixed message and no outbound request", async (_name, body) => {
      const spy = mockCalendars(providers);

      const response = await post(body);

      expect(response.status).toBe(400);
      expect(await response.json()).toEqual({
        error: "invalid_request",
        message: "Send 1 to 10 calendar links and, optionally, an IANA time zone",
      });
      expect(spy).not.toHaveBeenCalled();
    });

    it.each([
      ["text/plain", "text/plain"],
      ["a form", "application/x-www-form-urlencoded"],
      ["no Content-Type", null],
      ["an empty Content-Type", ""],
      ["something that only looks like JSON", "application/jsonp"],
    ])("answers 400 to a JSON body sent as %s", async (_name, contentType) => {
      const spy = mockCalendars(providers);

      const response = await exports.default.fetch("https://example.com/v1/calendar/events", {
        method: "POST",
        headers: contentType === null ? {} : { "content-type": contentType },
        // A stream, so that no Content-Type is added on our behalf.
        body: new Blob([JSON.stringify({ links: [OUTLOOK] })]).stream(),
      });

      expect(response.status).toBe(400);
      expect(await response.json()).toEqual({
        error: "invalid_request",
        message: "Send 1 to 10 calendar links and, optionally, an IANA time zone",
      });
      expect(spy).not.toHaveBeenCalled();
    });

    it.each(["application/json", "application/json; charset=utf-8", "Application/JSON"])(
      "accepts Content-Type %s",
      async (contentType) => {
        mockCalendars(providers);

        const response = await exports.default.fetch("https://example.com/v1/calendar/events", {
          method: "POST",
          headers: { "content-type": contentType },
          body: JSON.stringify({ links: [OUTLOOK] }),
        });

        expect(response.status).toBe(200);
      },
    );

    it("accepts ten links", async () => {
      mockCalendars(providers);

      const body = await events({ links: Array(10).fill(OUTLOOK) });

      expect(body.calendars).toHaveLength(10);
      expect(body.calendars.every((calendar) => calendar.ok)).toBe(true);
    });
  });
});
