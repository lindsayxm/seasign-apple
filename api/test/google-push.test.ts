import { applyD1Migrations } from "cloudflare:test";
import { env } from "cloudflare:workers";
import { drizzle } from "drizzle-orm/d1";
import { afterEach, beforeAll, beforeEach, describe, expect, it, vi } from "vitest";
import { app } from "../src/app.ts";
import { calendarChannels, type CalendarChannel } from "../src/db/schema.ts";
import { APNS_HOSTS, PROVIDER_TOKEN_TTL_MS, PUSH_PAYLOAD, apnsConfig, apnsDeadline, pemBytes, providerToken, resetApnsCache } from "../src/lib/apns.ts";
import { CHANNEL_TTL_SECONDS, resetNotifyLogs, sha256Hex } from "../src/routes/google-push.ts";
import { startWorker } from "./start-worker.ts";

startWorker();

// Google Calendar push channels and the APNs sender (task 156). Google and
// APNs are mocked: every outbound fetch goes to `reply`. The APNs key is a
// throwaway P-256 key made here, in memory.

/** An obviously fake Google access token. Every test checks it is never kept or shown. */
const TOKEN = "ya29.fake-google-token-for-push-tests-0000";
const NOW = new Date("2026-11-19T15:00:00Z");
const DAY_MS = 86400_000;
const WEBHOOK = "https://api.seasign.app/v1/google/notify";
const BUNDLE_ID = "technology.artisan.seasign";
const KEY_ID = "ABC123DEFG";
const TEAM_ID = "DEF123GHIJ";
const DEVICE_A = "00fc13adff785122b4ad28809a3420982341241421348097878e577c991de8f0";
const DEVICE_B = "1111111111111111111111111111111111111111111111111111111111111111";
const CALENDAR_EMAIL = "family1234@group.calendar.google.com";

const INVALID_REQUEST = {
  error: "invalid_request",
  message: "Send an X-Google-Token header and a JSON body with 1 to 10 calendar ids, the APNs device token in hex and the APNs environment",
};
const GOOGLE_AUTH = { error: "google_auth", message: "Google did not accept the access token; refresh it and try again" };
const PUSH_UNAVAILABLE = { error: "push_unavailable", message: "Calendar change notifications are not set up on this server" };

let pem = "";
let publicKey: CryptoKey;

const toBase64 = (bytes: ArrayBuffer) => btoa(String.fromCharCode(...new Uint8Array(bytes)));
const fromBase64url = (text: string) => Uint8Array.from(atob(text.replace(/-/g, "+").replace(/_/g, "/")), (char) => char.charCodeAt(0));

beforeAll(async () => {
  await applyD1Migrations(env.DB, env.TEST_MIGRATIONS);
  const pair = (await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"])) as CryptoKeyPair;
  publicKey = pair.publicKey;
  const der = toBase64((await crypto.subtle.exportKey("pkcs8", pair.privateKey)) as ArrayBuffer);
  pem = `-----BEGIN PRIVATE KEY-----\n${der.match(/.{1,64}/g)!.join("\n")}\n-----END PRIVATE KEY-----\n`;
});

const db = () => drizzle(env.DB);
const rows = () => db().select().from(calendarChannels).all();

/** The test environment: the real bindings, with or without the APNs secrets. */
function testEnv(extra: Record<string, unknown> = {}): CloudflareBindings {
  return { ...env, APNS_KEY: pem, APNS_KEY_ID: KEY_ID, APNS_TEAM_ID: TEAM_ID, ...extra } as unknown as CloudflareBindings;
}

// ───────────────────────── outbound mock ─────────────────────────

type Sent = { url: URL; method: string; headers: Headers; body: string; signal: AbortSignal };
type Reply = (sent: Sent) => Response | Promise<Response>;

const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } });

const calendarOfWatch = (url: URL) => {
  const match = /^\/calendar\/v3\/calendars\/([^/]+)\/events\/watch$/.exec(url.pathname);
  return match ? decodeURIComponent(match[1]!) : null;
};

/** Google's opaque resource id for a calendar; not derived visibly from the id, as Google's is not. */
const resourceIdOf = (calendar: string | null) => `rid${[...(calendar ?? "")].reduce((sum, char) => (sum * 31 + char.charCodeAt(0)) % 1_000_003, 7)}`;

/** Google's answer to events.watch, as the reference shows it: expiration is an int64 string of Unix ms. */
function watchAnswer(sent: Sent, expiration: unknown = String(NOW.getTime() + 7 * DAY_MS)) {
  const body = JSON.parse(sent.body) as { id: string; token: string };
  return json({
    kind: "api#channel",
    id: body.id,
    resourceId: resourceIdOf(calendarOfWatch(sent.url)),
    resourceUri: "https://www.googleapis.com/calendar/v3/calendars/x/events?alt=json",
    token: body.token,
    expiration,
  });
}

/** Google and APNs by default: every watch made, every stop accepted (204), every push accepted. */
const defaultReply: Reply = (sent) => {
  if (sent.url.origin === "https://www.googleapis.com") {
    if (calendarOfWatch(sent.url) !== null) return watchAnswer(sent);
    if (sent.url.pathname === "/calendar/v3/channels/stop") return new Response(null, { status: 204 });
  }
  if (sent.url.origin === APNS_HOSTS.sandbox || sent.url.origin === APNS_HOSTS.production) return new Response(null, { status: 200 });
  return new Response("unexpected", { status: 500 });
};

function mockFetch(reply: Reply = defaultReply) {
  const sent: Sent[] = [];
  const spy = vi.spyOn(globalThis, "fetch").mockImplementation(async (input, init) => {
    const request = new Request(input, init);
    const record = { url: new URL(request.url), method: request.method, headers: request.headers, body: await request.text(), signal: request.signal };
    sent.push(record);
    return reply(record);
  });
  return {
    sent,
    spy,
    watches: () => sent.filter((call) => calendarOfWatch(call.url) !== null),
    stops: () => sent.filter((call) => call.url.pathname === "/calendar/v3/channels/stop"),
    pushes: () => sent.filter((call) => call.url.pathname.startsWith("/3/device/")),
  };
}

// ───────────────────────── requests ─────────────────────────

function post(path: string, body: unknown, headers: Record<string, string> = { "x-google-token": TOKEN }, extraEnv: Record<string, unknown> = {}) {
  return app.fetch(
    new Request(`https://example.com${path}`, {
      method: "POST",
      headers: { "content-type": "application/json", ...headers },
      body: typeof body === "string" ? body : JSON.stringify(body),
    }),
    testEnv(extraEnv),
  );
}

const watch = (body: unknown, headers?: Record<string, string>, extraEnv?: Record<string, unknown>) => post("/v1/google/watch", body, headers, extraEnv);
const unwatch = (body: unknown, headers?: Record<string, string>) => post("/v1/google/unwatch", body, headers);

/** A call as Google makes it: headers only, no body. */
function googleCall(headers: Record<string, string>, extraEnv: Record<string, unknown> = {}) {
  return app.fetch(new Request(`https://example.com/v1/google/notify`, { method: "POST", headers }), testEnv(extraEnv));
}

/** A channel row with a known token, put straight into D1. */
async function seed(overrides: Partial<CalendarChannel> = {}, channelToken = "known-channel-token-0001") {
  const row: CalendarChannel = {
    id: crypto.randomUUID(),
    tokenHash: await sha256Hex(channelToken),
    resourceId: "res-seeded",
    deviceToken: DEVICE_A,
    environment: "sandbox",
    expiresAt: NOW.getTime() + 3 * DAY_MS,
    createdAt: NOW.getTime() - DAY_MS,
    ...overrides,
  };
  await db().insert(calendarChannels).values(row);
  return { row, channelToken };
}

const changeHeaders = (row: CalendarChannel, channelToken: string, state = "exists") => ({
  "x-goog-channel-id": row.id,
  "x-goog-channel-token": channelToken,
  "x-goog-resource-id": row.resourceId,
  "x-goog-resource-state": state,
  "x-goog-resource-uri": "https://www.googleapis.com/calendar/v3/calendars/x/events?alt=json",
  "x-goog-message-number": "2",
  "x-goog-channel-expiration": "Thu, 26 Nov 2026 15:00:00 GMT",
});

/** Everything written to the console. */
function captureConsole() {
  const spies = (["log", "info", "warn", "error", "debug"] as const).map((method) => vi.spyOn(console, method).mockImplementation(() => {}));
  return {
    error: spies[3]!,
    lines: () => spies.flatMap((spy) => spy.mock.calls.map((call) => call.map(String).join(" "))),
  };
}

/** The whole response as text, headers included. */
async function readAll(response: Response): Promise<string> {
  const headers = [...response.headers].map(([name, value]) => `${name}: ${value}`).join("\n");
  return `${headers}\n${await response.text()}`;
}

/** No secret, token or identifier in this text. */
function expectClean(text: string, extra: string[] = []) {
  const der = pem.split("\n").filter((line) => line && !line.startsWith("-----"));
  for (const secret of [TOKEN, ...der, ...extra]) expect(text).not.toContain(secret);
}

beforeEach(async () => {
  vi.useFakeTimers({ toFake: ["Date"], now: NOW });
  resetApnsCache();
  resetNotifyLogs();
  await db().delete(calendarChannels);
});

afterEach(() => {
  vi.useRealTimers();
  vi.restoreAllMocks();
});

// ───────────────────────── watch ─────────────────────────

describe("POST /v1/google/watch", () => {
  it("opens one channel per calendar at Google and keeps only the channel row", async () => {
    const google = mockFetch();
    const logs = captureConsole();
    const response = await watch({ calendars: ["primary", CALENDAR_EMAIL], deviceToken: DEVICE_A.toUpperCase(), environment: "sandbox" });
    expect(response.status).toBe(200);
    expect(response.headers.get("cache-control")).toBe("no-store");
    const body = await response.json();
    expect(body).toEqual({
      calendars: [
        { index: 0, ok: true },
        { index: 1, ok: true },
      ],
      expiresAt: "2026-11-26T15:00:00Z",
    });

    const watches = google.watches();
    expect(watches.map((call) => calendarOfWatch(call.url)).sort()).toEqual([CALENDAR_EMAIL, "primary"].sort());
    const tokens: string[] = [];
    for (const call of watches) {
      expect(call.method).toBe("POST");
      expect(call.url.origin).toBe("https://www.googleapis.com");
      expect(call.url.searchParams.getAll("eventTypes")).toEqual(["default", "fromGmail"]);
      expect(call.headers.get("authorization")).toBe(`Bearer ${TOKEN}`);
      expect(call.headers.get("content-type")).toBe("application/json");
      const sentBody = JSON.parse(call.body) as { id: string; type: string; address: string; token: string; params: { ttl: string } };
      expect(Object.keys(sentBody).sort()).toEqual(["address", "id", "params", "token", "type"]);
      expect(sentBody.type).toBe("web_hook");
      expect(sentBody.address).toBe(WEBHOOK);
      expect(sentBody.id).toMatch(/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/);
      expect(sentBody.token).toMatch(/^[A-Za-z0-9_-]{43}$/);
      expect(sentBody.params).toEqual({ ttl: String(CHANNEL_TTL_SECONDS) });
      tokens.push(sentBody.token);
    }
    expect(new Set(tokens).size).toBe(2);

    const stored = await rows();
    expect(stored).toHaveLength(2);
    for (const row of stored) {
      const call = watches.find((sent) => (JSON.parse(sent.body) as { id: string }).id === row.id)!;
      const sentBody = JSON.parse(call.body) as { token: string };
      expect(row).toEqual({
        id: row.id,
        tokenHash: await sha256Hex(sentBody.token),
        resourceId: resourceIdOf(calendarOfWatch(call.url)),
        deviceToken: DEVICE_A,
        environment: "sandbox",
        expiresAt: NOW.getTime() + 7 * DAY_MS,
        createdAt: NOW.getTime(),
      });
      // Not the channel token, the Google token or the calendar id.
      const text = JSON.stringify(row);
      expect(text).not.toContain(sentBody.token);
      expect(text).not.toContain("primary");
      expect(text).not.toContain(CALENDAR_EMAIL);
    }
    expectClean(JSON.stringify(stored));
    expectClean(JSON.stringify(body));
    expectClean(logs.lines().join("\n"), [DEVICE_A, ...tokens]);
    expect(google.stops()).toHaveLength(0);
  });

  it("replaces the device's earlier channels: new ones first, then the old ones stopped and forgotten", async () => {
    const old1 = await seed({ resourceId: "res-old-1" });
    const old2 = await seed({ resourceId: "res-old-2", environment: "production" });
    const other = await seed({ deviceToken: DEVICE_B, resourceId: "res-other" });
    const google = mockFetch();
    const response = await watch({ calendars: ["primary"], deviceToken: DEVICE_A, environment: "production" });
    expect(response.status).toBe(200);

    const stored = await rows();
    expect(stored.map((row) => row.id)).not.toContain(old1.row.id);
    expect(stored.map((row) => row.id)).not.toContain(old2.row.id);
    expect(stored.filter((row) => row.deviceToken === DEVICE_A)).toHaveLength(1);
    expect(stored.find((row) => row.deviceToken === DEVICE_A)!.environment).toBe("production");
    expect(stored.find((row) => row.id === other.row.id)).toEqual(other.row);

    const stops = google.stops().map((call) => ({ body: JSON.parse(call.body), authorization: call.headers.get("authorization"), method: call.method }));
    expect(stops).toHaveLength(2);
    expect(stops).toEqual(
      expect.arrayContaining([
        { body: { id: old1.row.id, resourceId: "res-old-1" }, authorization: `Bearer ${TOKEN}`, method: "POST" },
        { body: { id: old2.row.id, resourceId: "res-old-2" }, authorization: `Bearer ${TOKEN}`, method: "POST" },
      ]),
    );
    // The watch came before the stops.
    const firstStop = google.sent.findIndex((call) => call.url.pathname === "/calendar/v3/channels/stop");
    expect(google.sent.findIndex((call) => calendarOfWatch(call.url) !== null)).toBeLessThan(firstStop);
  });

  it("leaves exactly one of two overlapping watches for a device, and stops the other's channels at Google", async () => {
    const old = await seed({ resourceId: "res-old" });
    // Google answers neither watch until both have been sent, so the two
    // requests reach the database together.
    let release!: () => void;
    const bothSent = new Promise<void>((resolve) => (release = resolve));
    const google = mockFetch(async (sent) => {
      if (calendarOfWatch(sent.url) !== null) {
        if (google.watches().length === 3) release();
        await bothSent;
      }
      return defaultReply(sent);
    });
    const [first, second] = await Promise.all([
      watch({ calendars: ["primary", "work"], deviceToken: DEVICE_A, environment: "sandbox" }),
      watch({ calendars: [CALENDAR_EMAIL], deviceToken: DEVICE_A, environment: "sandbox" }),
    ]);
    expect(first.status).toBe(200);
    expect(second.status).toBe(200);

    const idsOf = (calendars: string[]) =>
      google
        .watches()
        .filter((call) => calendars.includes(calendarOfWatch(call.url)!))
        .map((call) => (JSON.parse(call.body) as { id: string }).id)
        .sort();
    const firstIds = idsOf(["primary", "work"]);
    const secondIds = idsOf([CALENDAR_EMAIL]);
    expect(firstIds).toHaveLength(2);
    expect(secondIds).toHaveLength(1);

    const stored = (await rows()).map((row) => row.id).sort();
    const winner = stored.length === 2 ? firstIds : secondIds;
    const loser = winner === firstIds ? secondIds : firstIds;
    expect(stored).toEqual(winner);
    // Every channel that lost its row, the old one and the other request's, is
    // stopped at Google exactly once; none that kept its row is.
    const stopped = google
      .stops()
      .map((call) => (JSON.parse(call.body) as { id: string }).id)
      .sort();
    expect(stopped).toEqual([old.row.id, ...loser].sort());
  });

  it("forgets the old channels even when Google will not stop them", async () => {
    const old = await seed();
    mockFetch((sent) => (sent.url.pathname === "/calendar/v3/channels/stop" ? json({ error: { code: 404, message: "Channel not found" } }, 404) : defaultReply(sent)));
    const response = await watch({ calendars: ["primary"], deviceToken: DEVICE_A, environment: "sandbox" });
    expect(response.status).toBe(200);
    expect((await rows()).map((row) => row.id)).not.toContain(old.row.id);
  });

  it("keeps the old channels when no new one could be made, and says why per calendar", async () => {
    const old = await seed();
    const google = mockFetch((sent) => {
      const calendar = calendarOfWatch(sent.url);
      if (calendar === "primary") return json({ error: { code: 404, message: "Not Found", errors: [{ reason: "notFound" }] } }, 404);
      if (calendar === "secret") return json({ error: { code: 403, errors: [{ domain: "calendar", reason: "forbiddenForNonOrganizer" }] } }, 403);
      if (calendar === "busy") return json({ error: { code: 403, errors: [{ domain: "usageLimits", reason: "rateLimitExceeded" }] } }, 403);
      if (calendar === "down") return new Response("oops", { status: 503 });
      return defaultReply(sent);
    });
    const response = await watch({ calendars: ["primary", "secret", "busy", "down"], deviceToken: DEVICE_A, environment: "sandbox" });
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({
      calendars: [
        { index: 0, ok: false, error: "not_found" },
        { index: 1, ok: false, error: "forbidden" },
        { index: 2, ok: false, error: "rate_limited" },
        { index: 3, ok: false, error: "fetch_failed" },
      ],
      expiresAt: null,
    });
    expect(await rows()).toEqual([old.row]);
    expect(google.stops()).toHaveLength(0);
  });

  it("reports a calendar it could not watch beside the ones it could", async () => {
    mockFetch((sent) => (calendarOfWatch(sent.url) === "gone" ? json({ error: { code: 404 } }, 404) : defaultReply(sent)));
    const response = await watch({ calendars: ["gone", "primary", "primary"], deviceToken: DEVICE_A, environment: "sandbox" });
    expect(await response.json()).toEqual({
      calendars: [
        { index: 0, ok: false, error: "not_found" },
        { index: 1, ok: true },
        { index: 2, ok: true },
      ],
      expiresAt: "2026-11-26T15:00:00Z",
    });
    // An id sent twice is watched once.
    expect(await rows()).toHaveLength(1);
  });

  it("answers the soonest expiry, and believes Google's only when it is ahead and within a month", async () => {
    const answers = [String(NOW.getTime() + 2 * DAY_MS), NOW.getTime() + 5 * DAY_MS, "not a number", String(NOW.getTime() - 1000), String(NOW.getTime() + 90 * DAY_MS)];
    let next = 0;
    mockFetch((sent) => (calendarOfWatch(sent.url) !== null ? watchAnswer(sent, answers[next++]) : defaultReply(sent)));
    const response = await watch({ calendars: ["a", "b", "c", "d", "e"], deviceToken: DEVICE_A, environment: "sandbox" });
    expect(((await response.json()) as { expiresAt: string }).expiresAt).toBe("2026-11-21T15:00:00Z");
    const expiries = (await rows()).map((row) => row.expiresAt).sort();
    expect(expiries).toEqual(
      [NOW.getTime() + 2 * DAY_MS, NOW.getTime() + 5 * DAY_MS, NOW.getTime() + 7 * DAY_MS, NOW.getTime() + 7 * DAY_MS, NOW.getTime() + 7 * DAY_MS].sort(),
    );
  });

  it("counts an answer without a resource id, or for another channel id, as a failure", async () => {
    let next = 0;
    mockFetch((sent) => {
      if (calendarOfWatch(sent.url) === null) return defaultReply(sent);
      next++;
      if (next === 1) return json({ kind: "api#channel", id: (JSON.parse(sent.body) as { id: string }).id });
      return json({ kind: "api#channel", id: crypto.randomUUID(), resourceId: "res-x" });
    });
    const response = await watch({ calendars: ["a", "b"], deviceToken: DEVICE_A, environment: "sandbox" });
    expect(((await response.json()) as { calendars: unknown }).calendars).toEqual([
      { index: 0, ok: false, error: "fetch_failed" },
      { index: 1, ok: false, error: "fetch_failed" },
    ]);
    expect(await rows()).toHaveLength(0);
  });

  it("answers 401 when Google refuses the token, stops what it made and changes nothing", async () => {
    const old = await seed();
    const google = mockFetch((sent) =>
      calendarOfWatch(sent.url) === "primary"
        ? json({ error: { code: 401, message: `Invalid ${TOKEN}`, errors: [{ reason: "authError", location: "Authorization" }] } }, 401)
        : defaultReply(sent),
    );
    const response = await watch({ calendars: ["primary", "work"], deviceToken: DEVICE_A, environment: "sandbox" });
    expect(response.status).toBe(401);
    const text = await readAll(response);
    expect(JSON.parse(text.slice(text.indexOf("\n{") + 1))).toEqual(GOOGLE_AUTH);
    expectClean(text);
    expect(await rows()).toEqual([old.row]);
    // The channel made on "work" was stopped; the old one was not touched.
    const stops = google.stops().map((call) => JSON.parse(call.body) as { resourceId: string });
    expect(stops).toEqual([expect.objectContaining({ resourceId: resourceIdOf("work") })]);
  });

  it("tells a refused webhook address apart from a refused token", async () => {
    mockFetch((sent) =>
      calendarOfWatch(sent.url) !== null
        ? json({ error: { code: 401, message: "Unauthorized WebHook callback channel", errors: [{ domain: "global", reason: "push.webhookUrlUnauthorized" }] } }, 401)
        : defaultReply(sent),
    );
    const response = await watch({ calendars: ["primary"], deviceToken: DEVICE_A, environment: "sandbox" });
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ calendars: [{ index: 0, ok: false, error: "webhook_refused" }], expiresAt: null });
  });

  it("answers 503 without asking Google when no https webhook address is configured", async () => {
    const google = mockFetch();
    const logs = captureConsole();
    for (const value of [undefined, "", "http://api.seasign.app/v1/google/notify", "not a url"]) {
      const response = await watch({ calendars: ["primary"], deviceToken: DEVICE_A, environment: "sandbox" }, undefined, { GOOGLE_WEBHOOK_URL: value });
      expect(response.status).toBe(503);
      expect(await response.json()).toEqual(PUSH_UNAVAILABLE);
    }
    expect(google.sent).toHaveLength(0);
    expect(logs.error).toHaveBeenCalledWith("google-watch: GOOGLE_WEBHOOK_URL is missing or not https");
  });

  it("answers 500 and stops the new channels when the database fails", async () => {
    const google = mockFetch();
    const logs = captureConsole();
    const failing = { prepare: () => ({ bind: () => { throw new Error("D1 down"); }, all: () => { throw new Error("D1 down"); }, run: () => { throw new Error("D1 down"); }, raw: () => { throw new Error("D1 down"); } }), batch: () => { throw new Error("D1 down"); } };
    const response = await watch({ calendars: ["primary"], deviceToken: DEVICE_A, environment: "sandbox" }, undefined, { DB: failing });
    expect(response.status).toBe(500);
    expect(await response.json()).toEqual({ error: "internal_error", message: "Something went wrong" });
    expect(google.stops()).toHaveLength(1);
    expect(logs.lines()).toEqual(["google-watch: database failed"]);
  });

  it("removes rows past their expiry while it is there", async () => {
    const stale = await seed({ deviceToken: DEVICE_B, expiresAt: NOW.getTime() - 1 });
    const fresh = await seed({ deviceToken: DEVICE_B, expiresAt: NOW.getTime() + DAY_MS });
    mockFetch();
    await watch({ calendars: ["primary"], deviceToken: DEVICE_A, environment: "sandbox" });
    const ids = (await rows()).map((row) => row.id);
    expect(ids).not.toContain(stale.row.id);
    expect(ids).toContain(fresh.row.id);
  });

  describe("refuses with the fixed 400, before any fetch", () => {
    const VALID = { calendars: ["primary"], deviceToken: DEVICE_A, environment: "sandbox" };
    const cases: [string, unknown, Record<string, string>][] = [
      ["no X-Google-Token header", VALID, {}],
      ["a token with Bearer in front", VALID, { "x-google-token": `Bearer ${TOKEN}` }],
      ["no calendars", { ...VALID, calendars: [] }, { "x-google-token": TOKEN }],
      ["11 calendars", { ...VALID, calendars: Array.from({ length: 11 }, (_, i) => `c${i}`) }, { "x-google-token": TOKEN }],
      ["a calendar id with a space", { ...VALID, calendars: ["a b"] }, { "x-google-token": TOKEN }],
      ["the calendar id ..", { ...VALID, calendars: [".."] }, { "x-google-token": TOKEN }],
      ["no device token", { calendars: ["primary"], environment: "sandbox" }, { "x-google-token": TOKEN }],
      ["a device token that is not hex", { ...VALID, deviceToken: "z".repeat(64) }, { "x-google-token": TOKEN }],
      ["a device token of odd length", { ...VALID, deviceToken: `${DEVICE_A}0` }, { "x-google-token": TOKEN }],
      ["a device token too short", { ...VALID, deviceToken: "ab".repeat(15) }, { "x-google-token": TOKEN }],
      ["a device token too long", { ...VALID, deviceToken: "ab".repeat(201) }, { "x-google-token": TOKEN }],
      ["a device token with a path in it", { ...VALID, deviceToken: `${DEVICE_A}/../x` }, { "x-google-token": TOKEN }],
      ["no environment", { calendars: ["primary"], deviceToken: DEVICE_A }, { "x-google-token": TOKEN }],
      ["an unknown environment", { ...VALID, environment: "development" }, { "x-google-token": TOKEN }],
      ["a body that is not JSON", "{nope", { "x-google-token": TOKEN }],
    ];
    it.each(cases)("%s", async (_name, body, headers) => {
      const google = mockFetch();
      const response = await watch(body, headers);
      expect(response.status).toBe(400);
      const text = await readAll(response);
      expect(text).toContain("cache-control: no-store");
      expect(JSON.parse(text.slice(text.indexOf("\n{") + 1))).toEqual(INVALID_REQUEST);
      expectClean(text);
      expect(google.sent).toHaveLength(0);
    });

    it("a body not sent as application/json", async () => {
      const google = mockFetch();
      const response = await app.fetch(
        new Request("https://example.com/v1/google/watch", { method: "POST", headers: { "x-google-token": TOKEN, "content-type": "text/plain" }, body: JSON.stringify(VALID) }),
        testEnv(),
      );
      expect(response.status).toBe(400);
      expect(await response.json()).toEqual(INVALID_REQUEST);
      expect(google.sent).toHaveLength(0);
    });
  });
});

// ───────────────────────── unwatch ─────────────────────────

describe("POST /v1/google/unwatch", () => {
  it("stops and forgets every channel of the device, and only that device", async () => {
    const a1 = await seed({ resourceId: "res-a1" });
    const a2 = await seed({ resourceId: "res-a2" });
    const b = await seed({ deviceToken: DEVICE_B });
    const google = mockFetch();
    const logs = captureConsole();
    const response = await unwatch({ deviceToken: DEVICE_A.toUpperCase() });
    expect(response.status).toBe(200);
    expect(response.headers.get("cache-control")).toBe("no-store");
    expect(await response.json()).toEqual({ removed: 2 });
    expect(await rows()).toEqual([b.row]);
    expect(google.stops().map((call) => JSON.parse(call.body))).toEqual(
      expect.arrayContaining([
        { id: a1.row.id, resourceId: "res-a1" },
        { id: a2.row.id, resourceId: "res-a2" },
      ]),
    );
    expect(google.stops().every((call) => call.headers.get("authorization") === `Bearer ${TOKEN}`)).toBe(true);
    expect(logs.lines()).toEqual([]);
  });

  it("forgets the channels even when Google refuses to stop them", async () => {
    await seed();
    mockFetch((sent) => (sent.url.pathname === "/calendar/v3/channels/stop" ? json({ error: { code: 401 } }, 401) : defaultReply(sent)));
    const response = await unwatch({ deviceToken: DEVICE_A });
    expect(await response.json()).toEqual({ removed: 1 });
    expect(await rows()).toEqual([]);
  });

  it("answers removed 0 for a device with no channels, without asking Google", async () => {
    const google = mockFetch();
    const response = await unwatch({ deviceToken: DEVICE_A });
    expect(await response.json()).toEqual({ removed: 0 });
    expect(google.sent).toHaveLength(0);
  });

  it("refuses a bad device token or a missing token header with the fixed 400", async () => {
    const google = mockFetch();
    for (const [body, headers] of [
      [{ deviceToken: "xyz" }, { "x-google-token": TOKEN }],
      [{}, { "x-google-token": TOKEN }],
      [{ deviceToken: DEVICE_A }, {}],
    ] as const) {
      const response = await unwatch(body, headers);
      expect(response.status).toBe(400);
      expect(await response.json()).toEqual(INVALID_REQUEST);
    }
    expect(google.sent).toHaveLength(0);
  });
});

// ───────────────────────── notify ─────────────────────────

describe("POST /v1/google/notify (Google's call)", () => {
  /** The bare 200 every handled call gets: no body, nothing that tells one case from another. */
  async function expectBare(response: Response) {
    expect(response.status).toBe(200);
    expect(await response.text()).toBe("");
    const headers = [...response.headers.keys()].sort();
    expect(headers.filter((name) => name !== "cache-control" && name !== "content-type")).toEqual([]);
  }

  it("sends one background push to the channel's device", async () => {
    const { row, channelToken } = await seed();
    const outbound = mockFetch();
    const logs = captureConsole();
    await expectBare(await googleCall(changeHeaders(row, channelToken)));

    expect(outbound.sent).toHaveLength(1);
    const [push] = outbound.pushes();
    expect(push!.url.toString()).toBe(`https://api.sandbox.push.apple.com/3/device/${DEVICE_A}`);
    expect(push!.method).toBe("POST");
    expect(push!.headers.get("apns-topic")).toBe(BUNDLE_ID);
    expect(push!.headers.get("apns-push-type")).toBe("background");
    expect(push!.headers.get("apns-priority")).toBe("5");
    expect(push!.headers.get("apns-expiration")).toBe(String(NOW.getTime() / 1000 + 3600));
    expect(push!.headers.get("authorization")).toMatch(/^bearer [A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$/);
    expect(JSON.parse(push!.body)).toEqual({ aps: { "content-available": 1 }, type: "calendar-changed" });
    expect(push!.body).toBe(PUSH_PAYLOAD);
    // Never Google.
    expect(outbound.sent.some((call) => call.url.hostname.endsWith("googleapis.com"))).toBe(false);
    expect(await rows()).toEqual([row]);
    expect(logs.lines()).toEqual([]);
  });

  it("uses the production host for a production device, and pushes for not_exists too", async () => {
    const { row, channelToken } = await seed({ environment: "production" });
    const outbound = mockFetch();
    await expectBare(await googleCall(changeHeaders(row, channelToken, "not_exists")));
    expect(outbound.pushes().map((call) => call.url.origin)).toEqual(["https://api.push.apple.com"]);
  });

  it("signs an ES256 provider token that the key's public half verifies, and reuses it for 40 minutes", async () => {
    const { row, channelToken } = await seed();
    const outbound = mockFetch();
    await googleCall(changeHeaders(row, channelToken));
    const jwt = outbound.pushes()[0]!.headers.get("authorization")!.slice("bearer ".length);
    const [header, claims, signature] = jwt.split(".");
    expect(JSON.parse(new TextDecoder().decode(fromBase64url(header!)))).toEqual({ alg: "ES256", kid: KEY_ID });
    expect(JSON.parse(new TextDecoder().decode(fromBase64url(claims!)))).toEqual({ iss: TEAM_ID, iat: NOW.getTime() / 1000 });
    const raw = fromBase64url(signature!);
    expect(raw.byteLength).toBe(64);
    const valid = await crypto.subtle.verify({ name: "ECDSA", hash: "SHA-256" }, publicKey, raw, new TextEncoder().encode(`${header}.${claims}`));
    expect(valid).toBe(true);
    expect(jwt).not.toMatch(/=/);

    // The same token within the window.
    vi.setSystemTime(NOW.getTime() + PROVIDER_TOKEN_TTL_MS - 1000);
    await googleCall(changeHeaders(row, channelToken));
    expect(outbound.pushes()[1]!.headers.get("authorization")).toBe(`bearer ${jwt}`);

    // A fresh one after it, still inside Apple's 20 to 60 minutes.
    expect(PROVIDER_TOKEN_TTL_MS).toBeGreaterThanOrEqual(20 * 60 * 1000);
    expect(PROVIDER_TOKEN_TTL_MS).toBeLessThan(60 * 60 * 1000);
    vi.setSystemTime(NOW.getTime() + PROVIDER_TOKEN_TTL_MS);
    await googleCall(changeHeaders(row, channelToken));
    const fresh = outbound.pushes()[2]!.headers.get("authorization")!.slice("bearer ".length);
    expect(fresh).not.toBe(jwt);
    expect(JSON.parse(new TextDecoder().decode(fromBase64url(fresh.split(".")[1]!))).iat).toBe((NOW.getTime() + PROVIDER_TOKEN_TTL_MS) / 1000);
  });

  /** A provider token made at `iat`, cached as the one in use, as an isolate that has run for a while has. */
  async function cacheTokenFrom(iat: number) {
    return providerToken({ key: pem, keyId: KEY_ID, teamId: TEAM_ID, topic: BUNDLE_ID }, iat);
  }
  const iatOf = (call: Sent) => JSON.parse(new TextDecoder().decode(fromBase64url(call.headers.get("authorization")!.split(".")[1]!))).iat as number;

  it("resends the push once with a fresh provider token after APNs calls the old one expired", async () => {
    const { row, channelToken } = await seed();
    const stale = await cacheTokenFrom(NOW.getTime() - 10 * 60_000);
    const outbound = mockFetch((sent) => {
      if (sent.url.pathname.startsWith("/3/device/") && sent.headers.get("authorization") === `bearer ${stale}`) return json({ reason: "ExpiredProviderToken" }, 403);
      return defaultReply(sent);
    });
    const logs = captureConsole();
    await expectBare(await googleCall(changeHeaders(row, channelToken)));
    const pushes = outbound.pushes();
    expect(pushes).toHaveLength(2);
    expect(pushes[0]!.headers.get("authorization")).toBe(`bearer ${stale}`);
    expect(pushes[1]!.headers.get("authorization")).not.toBe(`bearer ${stale}`);
    expect(iatOf(pushes[1]!)).toBe(NOW.getTime() / 1000);
    expect(pushes[1]!.url.toString()).toBe(pushes[0]!.url.toString());
    expect(pushes[1]!.body).toBe(PUSH_PAYLOAD);
    // The resend went through: nothing to report.
    expect(logs.lines()).toEqual([]);

    // The fresh token is the one kept for the next push.
    await googleCall(changeHeaders(row, channelToken));
    expect(outbound.pushes()[2]!.headers.get("authorization")).toBe(pushes[1]!.headers.get("authorization"));
  });

  it("resends only once when the fresh provider token is called expired too", async () => {
    const { row, channelToken } = await seed();
    const outbound = mockFetch((sent) => (sent.url.pathname.startsWith("/3/device/") ? json({ reason: "ExpiredProviderToken" }, 403) : defaultReply(sent)));
    const logs = captureConsole();
    await expectBare(await googleCall(changeHeaders(row, channelToken)));
    expect(outbound.pushes()).toHaveLength(2);
    expect(logs.lines()).toEqual(["google-notify: push auth_failed"]);
    expect(await rows()).toEqual([row]);
  });

  it("does not resend after any other 403", async () => {
    const { row, channelToken } = await seed();
    const outbound = mockFetch((sent) => (sent.url.pathname.startsWith("/3/device/") ? json({ reason: "InvalidProviderToken" }, 403) : defaultReply(sent)));
    captureConsole();
    await googleCall(changeHeaders(row, channelToken));
    await googleCall(changeHeaders(row, channelToken));
    const pushes = outbound.pushes();
    expect(pushes).toHaveLength(2);
    // One push per call, and the token kept.
    expect(pushes[1]!.headers.get("authorization")).toBe(pushes[0]!.headers.get("authorization"));
  });

  it("gives the push and its resend one deadline between them", async () => {
    const { row, channelToken } = await seed();
    await cacheTokenFrom(NOW.getTime() - 10 * 60_000);
    let calls = 0;
    let resendStartedAborted: boolean | null = null;
    const outbound = mockFetch(async (sent) => {
      if (!sent.url.pathname.startsWith("/3/device/")) return defaultReply(sent);
      calls += 1;
      if (calls === 1) {
        // The first answer comes after the whole deadline has passed.
        await new Promise((resolve) => setTimeout(resolve, 150));
        return json({ reason: "ExpiredProviderToken" }, 403);
      }
      resendStartedAborted = sent.signal.aborted;
      if (sent.signal.aborted) throw sent.signal.reason;
      // Otherwise it hangs until the deadline cuts it off, as fetch does.
      return new Promise<Response>((_, reject) => sent.signal.addEventListener("abort", () => reject(sent.signal.reason)));
    });
    const logs = captureConsole();
    const deadline = apnsDeadline.ms;
    apnsDeadline.ms = 30;
    try {
      await expectBare(await googleCall(changeHeaders(row, channelToken)));
    } finally {
      apnsDeadline.ms = deadline;
    }
    expect(outbound.pushes()).toHaveLength(2);
    // The resend had no time of its own left: the deadline had already passed.
    expect(resendStartedAborted).toBe(true);
    expect(logs.lines()).toEqual(["google-notify: push failed"]);
  });

  it("ignores the sync message that opens a channel", async () => {
    const { row, channelToken } = await seed();
    const outbound = mockFetch();
    await expectBare(await googleCall({ ...changeHeaders(row, channelToken, "sync"), "x-goog-message-number": "1" }));
    expect(outbound.sent).toHaveLength(0);
    expect(await rows()).toEqual([row]);
  });

  it("does nothing for a wrong, missing or oversized channel token, and keeps the row", async () => {
    const { row, channelToken } = await seed();
    const outbound = mockFetch();
    const wrong = [`${channelToken}x`, channelToken.slice(0, -1), "", "x".repeat(300), channelToken.toUpperCase()];
    for (const token of wrong) {
      const headers: Record<string, string> = changeHeaders(row, token);
      if (token === "") delete headers["x-goog-channel-token"];
      await expectBare(await googleCall(headers));
    }
    expect(outbound.sent).toHaveLength(0);
    expect(await rows()).toEqual([row]);
  });

  it("does nothing for an unknown channel or one that is not of our shape", async () => {
    const { row, channelToken } = await seed();
    const outbound = mockFetch();
    const prepare = vi.spyOn(env.DB, "prepare");
    await expectBare(await googleCall({ ...changeHeaders(row, channelToken), "x-goog-channel-id": crypto.randomUUID() }));
    const reads = prepare.mock.calls.length;
    expect(reads).toBeGreaterThan(0);
    for (const id of ["", "not-a-uuid", row.id.toUpperCase(), `${row.id}0`, "' OR 1=1 --"]) {
      await expectBare(await googleCall({ ...changeHeaders(row, channelToken), "x-goog-channel-id": id }));
    }
    // A channel id that is not a lowercase UUID costs no database read.
    expect(prepare.mock.calls.length).toBe(reads);
    expect(outbound.sent).toHaveLength(0);
  });

  it("does nothing when the resource id is not the channel's", async () => {
    const { row, channelToken } = await seed();
    const outbound = mockFetch();
    await expectBare(await googleCall({ ...changeHeaders(row, channelToken), "x-goog-resource-id": "res-someone-else" }));
    expect(outbound.sent).toHaveLength(0);
  });

  it("answers an unknown channel and a wrong token exactly as it answers a push", async () => {
    const { row, channelToken } = await seed();
    mockFetch();
    const answers = [
      await googleCall(changeHeaders(row, channelToken)),
      await googleCall(changeHeaders(row, "wrong-token")),
      await googleCall({ ...changeHeaders(row, channelToken), "x-goog-channel-id": crypto.randomUUID() }),
    ];
    const texts = await Promise.all(answers.map(readAll));
    expect(new Set(answers.map((answer) => answer.status))).toEqual(new Set([200]));
    expect(new Set(texts).size).toBe(1);
  });

  it("deletes an expired channel's row and sends nothing", async () => {
    const { row, channelToken } = await seed({ expiresAt: NOW.getTime() - 1 });
    const other = await seed({ resourceId: "res-other" });
    const outbound = mockFetch();
    await expectBare(await googleCall(changeHeaders(row, channelToken)));
    expect(outbound.sent).toHaveLength(0);
    expect(await rows()).toEqual([other.row]);
  });

  it.each([
    ["410 Unregistered", 410, { reason: "Unregistered", timestamp: NOW.getTime() }],
    ["410 ExpiredToken", 410, { reason: "ExpiredToken" }],
    ["400 BadDeviceToken", 400, { reason: "BadDeviceToken" }],
    ["400 DeviceTokenNotForTopic", 400, { reason: "DeviceTokenNotForTopic" }],
  ])("forgets every channel of the device after APNs answers %s", async (_name, status, body) => {
    const { row, channelToken } = await seed();
    await seed({ resourceId: "res-second" });
    const other = await seed({ deviceToken: DEVICE_B });
    mockFetch((sent) => (sent.url.pathname.startsWith("/3/device/") ? json(body, status) : defaultReply(sent)));
    const logs = captureConsole();
    await expectBare(await googleCall(changeHeaders(row, channelToken)));
    expect(await rows()).toEqual([other.row]);
    expect(logs.lines()).toEqual(["google-notify: push unregistered"]);
  });

  it.each([
    ["400 BadTopic", 400, { reason: "BadTopic" }, "failed"],
    ["403 InvalidProviderToken", 403, { reason: "InvalidProviderToken" }, "auth_failed"],
    ["429 TooManyRequests", 429, { reason: "TooManyRequests" }, "throttled"],
    ["500", 500, { reason: "InternalServerError" }, "failed"],
    ["503 with no body", 503, null, "failed"],
  ])("keeps the rows after APNs answers %s", async (_name, status, body, outcome) => {
    const { row, channelToken } = await seed();
    mockFetch((sent) => (sent.url.pathname.startsWith("/3/device/") ? (body === null ? new Response(null, { status }) : json(body, status)) : defaultReply(sent)));
    const logs = captureConsole();
    await expectBare(await googleCall(changeHeaders(row, channelToken)));
    expect(await rows()).toEqual([row]);
    expect(logs.lines()).toEqual([`google-notify: push ${outcome}`]);
  });

  it("still answers 200 when APNs cannot be reached", async () => {
    const { row, channelToken } = await seed();
    mockFetch((sent) => {
      if (sent.url.pathname.startsWith("/3/device/")) throw new TypeError("network down");
      return defaultReply(sent);
    });
    const logs = captureConsole();
    await expectBare(await googleCall(changeHeaders(row, channelToken)));
    expect(logs.lines()).toEqual(["google-notify: push failed"]);
    expect(await rows()).toEqual([row]);
  });

  it("reports 'not configured' once and still answers 200 when the APNs secrets are absent", async () => {
    const { row, channelToken } = await seed();
    const outbound = mockFetch();
    const logs = captureConsole();
    const missing = [{ APNS_KEY: undefined }, { APNS_KEY_ID: undefined }, { APNS_TEAM_ID: "  " }, { APNS_KEY: undefined, APNS_KEY_ID: undefined, APNS_TEAM_ID: undefined }];
    for (const extra of missing) await expectBare(await googleCall(changeHeaders(row, channelToken), extra));
    expect(outbound.sent).toHaveLength(0);
    expect(logs.lines()).toEqual(["google-notify: APNs is not configured; no push sent"]);
    expect(await rows()).toEqual([row]);
  });

  it("reports a key that is not a P-256 PKCS#8 key without throwing or showing it", async () => {
    const { row, channelToken } = await seed();
    const outbound = mockFetch();
    const logs = captureConsole();
    const notKeys = ["-----BEGIN PRIVATE KEY-----\nbm90IGEga2V5\n-----END PRIVATE KEY-----", "%%% not base64 %%%"];
    for (const key of notKeys) await expectBare(await googleCall(changeHeaders(row, channelToken), { APNS_KEY: key }));
    expect(outbound.sent).toHaveLength(0);
    expect(logs.lines()).toEqual(["google-notify: APNS_KEY is not a P-256 PKCS#8 key; no push sent"]);
    expectClean(logs.lines().join("\n"), ["bm90IGEga2V5"]);
  });

  it("answers 503 (which Google may retry) when the database fails, and logs a fixed line", async () => {
    const { row, channelToken } = await seed();
    const outbound = mockFetch();
    const logs = captureConsole();
    const failing = { prepare: () => { throw new Error(`D1 down ${channelToken}`); } };
    const response = await googleCall(changeHeaders(row, channelToken), { DB: failing });
    expect(response.status).toBe(503);
    expect(await response.text()).toBe("");
    expect(outbound.sent).toHaveLength(0);
    expect(logs.lines()).toEqual(["google-notify: database failed"]);
  });

  it("is reached without an X-Google-Token and is not in the google rate-limit group", async () => {
    const { row, channelToken } = await seed();
    const limiter = { limit: vi.fn(async () => ({ success: false })) };
    const notifyLimiter = { limit: vi.fn(async () => ({ success: true })) };
    const outbound = mockFetch();
    const response = await app.fetch(
      new Request("https://example.com/v1/google/notify", { method: "POST", headers: { ...changeHeaders(row, channelToken), "cf-connecting-ip": "66.249.84.1" } }),
      testEnv({ RATE_LIMIT_GOOGLE: limiter, RATE_LIMIT_NOTIFY: notifyLimiter }),
    );
    expect(response.status).toBe(200);
    expect(limiter.limit).not.toHaveBeenCalled();
    expect(notifyLimiter.limit).toHaveBeenCalledOnce();
    expect(outbound.pushes()).toHaveLength(1);
  });

  it("never logs a token, a device token, a channel id or the key across a busy run", async () => {
    const { row, channelToken } = await seed();
    const logs = captureConsole();
    let status = 200;
    mockFetch((sent) => (sent.url.pathname.startsWith("/3/device/") ? json({ reason: `Bad ${DEVICE_A}` }, status) : defaultReply(sent)));
    for (const next of [200, 500, 403, 429]) {
      status = next;
      await googleCall(changeHeaders(row, channelToken));
    }
    await googleCall(changeHeaders(row, "wrong"));
    await watch({ calendars: ["primary"], deviceToken: DEVICE_B, environment: "sandbox" });
    await unwatch({ deviceToken: DEVICE_B });
    const text = logs.lines().join("\n");
    expectClean(text, [DEVICE_A, DEVICE_B, channelToken, row.id, KEY_ID, TEAM_ID, "primary"]);
  });
});

// ───────────────────────── the sender's parts ─────────────────────────

describe("APNs sender parts", () => {
  it("reads the configuration only when every value is present", () => {
    expect(apnsConfig({ APNS_KEY: pem, APNS_KEY_ID: KEY_ID, APNS_TEAM_ID: TEAM_ID, APPLE_APP_BUNDLE_ID: BUNDLE_ID } as Partial<CloudflareBindings>)).toEqual({
      key: pem,
      keyId: KEY_ID,
      teamId: TEAM_ID,
      topic: BUNDLE_ID,
    });
    expect(apnsConfig({ APNS_KEY: pem, APNS_KEY_ID: KEY_ID, APNS_TEAM_ID: TEAM_ID } as Partial<CloudflareBindings>)).toBeNull();
    expect(apnsConfig(undefined)).toBeNull();
  });

  it("reads a PEM with Windows line ends, literal \\n sequences, or no armour", () => {
    const bytes = pemBytes(pem)!;
    expect(bytes.byteLength).toBeGreaterThan(100);
    expect(pemBytes(pem.replace(/\n/g, "\r\n"))).toEqual(bytes);
    expect(pemBytes(pem.replace(/\n/g, "\\n"))).toEqual(bytes);
    expect(pemBytes(pem.split("\n").filter((line) => !line.startsWith("-----")).join(""))).toEqual(bytes);
    expect(pemBytes("")).toBeNull();
    expect(pemBytes("-----BEGIN PRIVATE KEY-----\n-----END PRIVATE KEY-----")).toBeNull();
  });

  it("signs with a key pasted on one line with literal \\n sequences", async () => {
    const token = await providerToken({ key: pem.replace(/\n/g, "\\n"), keyId: KEY_ID, teamId: TEAM_ID, topic: BUNDLE_ID });
    const [header, claims, signature] = token.split(".");
    expect(await crypto.subtle.verify({ name: "ECDSA", hash: "SHA-256" }, publicKey, fromBase64url(signature!), new TextEncoder().encode(`${header}.${claims}`))).toBe(true);
  });
});
