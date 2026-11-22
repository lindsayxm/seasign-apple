import { env, exports } from "cloudflare:workers";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { app } from "../src/app.ts";
import { RATE_LIMITED, RATE_LIMITS, clientKey, resetRateLimitLogs, type RateLimitGroup } from "../src/lib/rate-limit.ts";
import wranglerConfig from "../wrangler.jsonc?raw";
import { startWorker } from "./start-worker.ts";

startWorker();

/** An obviously fake LLM key, for the route that needs one. */
const FAKE_KEY = "fake-llm-key-for-tests-0000";
/** An obviously fake Google access token, for the Google routes. */
const FAKE_GOOGLE_TOKEN = "ya29.fake-google-token-for-tests";

/**
 * One request per limited route that would be served normally: valid, with
 * every outbound fetch failing (see `failFetch`), so it reaches the route,
 * tries the network, and answers without a 429.
 */
const ROUTES: Record<RateLimitGroup, { path: string; init: () => RequestInit; offline?: true }> = {
  sky: { path: "/v1/sky?zip=10001", init: () => ({}) },
  calendar: { path: "/v1/calendar/events", init: () => json({ links: ["https://calendar.example.com/a.ics"] }) },
  resolve: { path: "/v1/sites/resolve", init: () => json({ url: "https://news.example.com/" }) },
  feed: { path: "/v1/feed", init: () => json({ sites: [{ url: "https://news.example.com/", mode: "links" }] }) },
  discover: {
    path: "/v1/discover",
    init: () => json({ provider: "openai", interests: ["tide pools"] }, { "x-llm-key": FAKE_KEY }),
  },
  google: { path: "/v1/google/events", init: () => json({ calendars: ["primary"] }, { "x-google-token": FAKE_GOOGLE_TOKEN }) },
  // Google's webhook: a sync message is answered 200 at once, with no fetch and no database read.
  notify: { path: "/v1/google/notify", init: () => googleCall(), offline: true },
};

/** The same routes with a request each one refuses with a 400 before any fetch: cheap to send in bulk. */
const INVALID: Record<RateLimitGroup, { path: string; init: () => RequestInit; status?: number }> = {
  sky: { path: "/v1/sky?zip=nope", init: () => ({}) },
  calendar: { path: "/v1/calendar/events", init: () => json({ links: [] }) },
  resolve: { path: "/v1/sites/resolve", init: () => json({}) },
  feed: { path: "/v1/feed", init: () => json({ sites: [] }) },
  discover: { path: "/v1/discover", init: () => json({ provider: "openai", interests: [] }, { "x-llm-key": FAKE_KEY }) },
  google: { path: "/v1/google/events", init: () => json({ calendars: [] }, { "x-google-token": FAKE_GOOGLE_TOKEN }) },
  // The webhook refuses nothing: whatever arrives is answered 200.
  notify: { path: "/v1/google/notify", init: () => googleCall(), status: 200 },
};

/** A call as Google makes it to the webhook: the first message on a channel. */
function googleCall(): RequestInit {
  return {
    method: "POST",
    headers: {
      "x-goog-channel-id": "6f1c2a3b-4d5e-4f60-8a7b-9c0d1e2f3a4b",
      "x-goog-channel-token": "fake-channel-token",
      "x-goog-resource-state": "sync",
      "x-goog-resource-id": "fake-resource",
      "x-goog-message-number": "1",
    },
  };
}

const GROUPS = Object.keys(RATE_LIMITS) as RateLimitGroup[];

function json(body: unknown, headers: Record<string, string> = {}): RequestInit {
  return { method: "POST", headers: { "content-type": "application/json", ...headers }, body: JSON.stringify(body) };
}

function request(route: { path: string; init: () => RequestInit }, headers: Record<string, string> = {}): Request {
  const init = route.init();
  return new Request(`https://example.com${route.path}`, { ...init, headers: { ...(init.headers as Record<string, string>), ...headers } });
}

/** A stand-in for the binding: records each key, and refuses, throws, or counts as told. */
class FakeLimiter {
  keys: string[] = [];
  mode: "allow" | "refuse" | "throw" = "allow";
  /** When set, each key may pass this many times. */
  max: number | undefined;
  private counts = new Map<string, number>();

  async limit({ key }: { key: string }): Promise<{ success: boolean }> {
    this.keys.push(key);
    if (this.mode === "throw") throw new Error("limiter exploded");
    if (this.mode === "refuse") return { success: false };
    if (this.max === undefined) return { success: true };
    const count = (this.counts.get(key) ?? 0) + 1;
    this.counts.set(key, count);
    return { success: count <= this.max };
  }
}

/** A fake for every group, and the test environment with them in place of the real bindings. */
function fakes() {
  const limiters = Object.fromEntries(GROUPS.map((group) => [group, new FakeLimiter()])) as Record<RateLimitGroup, FakeLimiter>;
  const bindings = Object.fromEntries(GROUPS.map((group) => [RATE_LIMITS[group].binding, limiters[group]]));
  return { limiters, env: { ...env, ...bindings } as unknown as CloudflareBindings };
}

/** Every outbound fetch fails, and is recorded. */
const failFetch = () => vi.spyOn(globalThis, "fetch").mockRejectedValue(new Error("no network in tests"));

/** Spies on every KV method the routes use. */
const spyKv = () => (["get", "getWithMetadata", "put", "delete", "list"] as const).map((method) => vi.spyOn(env.CACHE, method));

/** Everything written to the console, joined, to check that no address is ever logged. */
function captureConsole() {
  const spies = (["log", "info", "warn", "error", "debug"] as const).map((method) => vi.spyOn(console, method).mockImplementation(() => {}));
  return {
    error: spies[3]!,
    text: () => spies.flatMap((spy) => spy.mock.calls.flat()).map(String).join("\n"),
  };
}

beforeEach(() => resetRateLimitLogs());
afterEach(() => vi.restoreAllMocks());

describe("clientKey", () => {
  it("keys IPv4 by the whole address", () => {
    expect(clientKey("203.0.113.7")).toBe("4:203.0.113.7");
    expect(clientKey(" 203.0.113.7 ")).toBe("4:203.0.113.7");
    expect(clientKey("203.0.113.8")).not.toBe(clientKey("203.0.113.7"));
  });

  it("keys IPv6 by its /64, however it is written", () => {
    const a = clientKey("2001:db8:85a3:1234:aaaa:bbbb:cccc:dddd");
    expect(a).toBe("6:2001:db8:85a3:1234::/64");
    expect(clientKey("2001:0DB8:85A3:1234::1")).toBe(a);
    expect(clientKey("2001:db8:85a3:1234:0:0:0:ffff")).toBe(a);
    expect(clientKey("2001:db8:85a3:1234::ffff:192.0.2.1")).toBe(a);
    expect(clientKey("2001:db8:85a3:1234::1%en0")).toBe(a);
    expect(clientKey("2001:db8:85a3:1235::1")).not.toBe(a);
    expect(clientKey("2001:db8::1")).toBe("6:2001:db8:0:0::/64");
    expect(clientKey("::1")).toBe("6:0:0:0:0::/64");
  });

  it("keys an IPv4-mapped IPv6 address as the IPv4 address", () => {
    expect(clientKey("::ffff:203.0.113.7")).toBe("4:203.0.113.7");
    expect(clientKey("::FFFF:cb00:7107")).toBe("4:203.0.113.7");
  });

  it("uses anything else as it came, shortened, and never throws", () => {
    expect(clientKey("not an address")).toBe("x:not an address");
    expect(clientKey("x".repeat(500))).toBe(`x:${"x".repeat(64)}`);
    for (const odd of ["", ":", ":::", "1::2::3", "1:2:3:4:5:6:7:8:9", "12345::", "::ffff:999.0.0.1", "256.1.1.1", "1.2.3", "01.2.3.4.5", "[::1]"]) {
      expect(() => clientKey(odd)).not.toThrow();
    }
    expect(clientKey("256.1.1.1")).toBe("x:256.1.1.1");
    expect(clientKey("1:2:3:4:5:6:7:8:9")).toBe("x:1:2:3:4:5:6:7:8:9");
  });
});

describe("the limits", () => {
  it("are the ones wrangler.jsonc gives the bindings", () => {
    // wrangler.jsonc allows comments; it has no trailing commas.
    const config = JSON.parse(wranglerConfig.replace(/\/\*[\s\S]*?\*\//g, "").replace(/^\s*\/\/.*$/gm, "")) as {
      ratelimits: { name: string; namespace_id: string; simple: { limit: number; period: number } }[];
    };
    const declared = Object.fromEntries(config.ratelimits.map((entry) => [entry.name, entry]));
    expect(config.ratelimits).toHaveLength(GROUPS.length);
    for (const group of GROUPS) {
      const { binding, namespaceId, limit, period } = RATE_LIMITS[group];
      expect(declared[binding]).toEqual({ name: binding, namespace_id: namespaceId, simple: { limit, period } });
    }
    expect(new Set(config.ratelimits.map((entry) => entry.namespace_id)).size).toBe(GROUPS.length);
  });

  it("are ordered by cost: sky highest, discover lowest", () => {
    const { sky, calendar, feed, resolve, discover } = RATE_LIMITS;
    expect(sky.limit).toBeGreaterThan(calendar.limit);
    expect(calendar.limit).toBeGreaterThanOrEqual(feed.limit);
    expect(feed.limit).toBeGreaterThan(resolve.limit);
    expect(resolve.limit).toBeGreaterThan(discover.limit);
  });

  it("let Google's webhook take far more than any one client route", () => {
    const { notify, google } = RATE_LIMITS;
    expect(notify.period).toBe(60);
    expect(notify.limit).toBeGreaterThan(google.limit);
  });

  it("let the Google routes be polled every 5 seconds with room for a shared address", () => {
    const { google } = RATE_LIMITS;
    expect(google.period).toBe(60);
    // 12 a minute is one phone polling every 5 seconds.
    expect(google.limit).toBeGreaterThanOrEqual(5 * 12);
  });
});

describe.each(GROUPS)("%s, with a fake limiter", (group) => {
  const route = ROUTES[group];
  const { period } = RATE_LIMITS[group];

  it("serves a request under the limit, keyed by CF-Connecting-IP", async () => {
    const fetchSpy = failFetch();
    const { limiters, env: testEnv } = fakes();
    const response = await app.fetch(request(route, { "cf-connecting-ip": "203.0.113.10" }), testEnv);
    expect(response.status).not.toBe(429);
    expect(limiters[group].keys).toEqual(["4:203.0.113.10"]);
    // It reached the route, which went to the network (the webhook answers without it).
    if (route.offline) expect(response.status).toBe(200);
    else expect(fetchSpy).toHaveBeenCalled();
    // No other group's limiter was asked.
    for (const other of GROUPS.filter((name) => name !== group)) expect(limiters[other].keys).toEqual([]);
  });

  it("answers the fixed 429 over the limit, before the body is read, any fetch, or any KV use", async () => {
    const fetchSpy = failFetch();
    const kv = spyKv();
    const logs = captureConsole();
    const { limiters, env: testEnv } = fakes();
    limiters[group].mode = "refuse";
    const sent = request(route, { "cf-connecting-ip": "203.0.113.11" });
    const response = await app.fetch(sent, testEnv);
    expect(response.status).toBe(429);
    expect(response.headers.get("retry-after")).toBe(String(period));
    expect(response.headers.get("content-type")).toMatch(/^application\/json/);
    const text = await response.text();
    expect(JSON.parse(text)).toEqual(RATE_LIMITED);
    expect(text).not.toContain("203.0.113.11");
    expect(sent.bodyUsed).toBe(false);
    expect(fetchSpy).not.toHaveBeenCalled();
    for (const spy of kv) expect(spy).not.toHaveBeenCalled();
    expect(logs.text()).not.toContain("203.0.113.11");
  });

  it("counts different addresses separately", async () => {
    failFetch();
    const { limiters, env: testEnv } = fakes();
    limiters[group].max = 1;
    const send = (ip: string) => app.fetch(request(route, { "cf-connecting-ip": ip }), testEnv);
    expect((await send("203.0.113.20")).status).not.toBe(429);
    expect((await send("203.0.113.20")).status).toBe(429);
    expect((await send("203.0.113.21")).status).not.toBe(429);
    expect((await send("2001:db8:1:2::1")).status).not.toBe(429);
    // The same /64 is the same client.
    expect((await send("2001:db8:1:2:ffff::9")).status).toBe(429);
    expect((await send("2001:db8:1:3::1")).status).not.toBe(429);
  });

  it("serves the request when the limiter throws, and logs a fixed line without the address", async () => {
    const fetchSpy = failFetch();
    const logs = captureConsole();
    const { limiters, env: testEnv } = fakes();
    limiters[group].mode = "throw";
    const response = await app.fetch(request(route, { "cf-connecting-ip": "203.0.113.30" }), testEnv);
    expect(response.status).not.toBe(429);
    if (!route.offline) expect(fetchSpy).toHaveBeenCalled();
    expect(logs.error).toHaveBeenCalledWith(`rate-limit: ${group} limiter failed; request served`);
    expect(logs.text()).not.toContain("203.0.113.30");
  });

  it("serves the request when the binding is missing, and logs that once", async () => {
    const fetchSpy = failFetch();
    const logs = captureConsole();
    const { env: testEnv } = fakes();
    const binding = RATE_LIMITS[group].binding;
    const withoutBinding = { ...testEnv, [binding]: undefined } as unknown as CloudflareBindings;
    for (let i = 0; i < 3; i++) {
      const response = await app.fetch(request(route, { "cf-connecting-ip": "203.0.113.31" }), withoutBinding);
      expect(response.status).not.toBe(429);
    }
    if (!route.offline) expect(fetchSpy).toHaveBeenCalled();
    const line = `rate-limit: binding ${binding} is missing; ${group} is not limited`;
    expect(logs.error.mock.calls.filter(([text]) => text === line)).toHaveLength(1);
    expect(logs.text()).not.toContain("203.0.113.31");
  });

  it("keys by CF-Connecting-IP and ignores X-Forwarded-For", async () => {
    failFetch();
    const { limiters, env: testEnv } = fakes();
    await app.fetch(request(route, { "cf-connecting-ip": "203.0.113.40", "x-forwarded-for": "198.51.100.9, 198.51.100.10" }), testEnv);
    expect(limiters[group].keys).toEqual(["4:203.0.113.40"]);
    // X-Forwarded-For alone is not an address to count by.
    limiters[group].mode = "refuse";
    const response = await app.fetch(request(route, { "x-forwarded-for": "198.51.100.9" }), testEnv);
    expect(response.status).not.toBe(429);
    expect(limiters[group].keys).toEqual(["4:203.0.113.40"]);
  });

  it("keys an IPv6 client by its /64", async () => {
    failFetch();
    const { limiters, env: testEnv } = fakes();
    await app.fetch(request(route, { "cf-connecting-ip": "2001:db8:aa:bb:1:2:3:4" }), testEnv);
    await app.fetch(request(route, { "cf-connecting-ip": "2001:DB8:AA:BB::5" }), testEnv);
    expect(limiters[group].keys).toEqual(["6:2001:db8:aa:bb::/64", "6:2001:db8:aa:bb::/64"]);
  });
});

describe("calendar with fresh: true", () => {
  const fresh = { path: "/v1/calendar/events", init: () => json({ links: ["https://calendar.example.com/a.ics"], fresh: true }) };

  it("is counted by the calendar limiter like any other request", async () => {
    const fetchSpy = failFetch();
    const { limiters, env: testEnv } = fakes();
    const response = await app.fetch(request(fresh, { "cf-connecting-ip": "203.0.113.70" }), testEnv);
    expect(response.status).toBe(200);
    expect(limiters.calendar.keys).toEqual(["4:203.0.113.70"]);
    expect(fetchSpy).toHaveBeenCalled();
  });

  it("gets the fixed 429 over the limit, before the body is read, any fetch, or any KV use", async () => {
    const fetchSpy = failFetch();
    const kv = spyKv();
    const { limiters, env: testEnv } = fakes();
    limiters.calendar.max = 2;
    const send = () => app.fetch(request(fresh, { "cf-connecting-ip": "203.0.113.71" }), testEnv);
    expect((await send()).status).toBe(200);
    expect((await send()).status).toBe(200);
    const fetchesBefore = fetchSpy.mock.calls.length;
    const kvBefore = kv.map((spy) => spy.mock.calls.length);
    const sent = request(fresh, { "cf-connecting-ip": "203.0.113.71" });
    const response = await app.fetch(sent, testEnv);
    expect(response.status).toBe(429);
    expect(response.headers.get("retry-after")).toBe("60");
    expect(await response.json()).toEqual(RATE_LIMITED);
    expect(sent.bodyUsed).toBe(false);
    expect(fetchSpy.mock.calls.length).toBe(fetchesBefore);
    expect(kv.map((spy) => spy.mock.calls.length)).toEqual(kvBefore);
  });
});

describe("the other Google routes the app calls", () => {
  const DEVICE = "00fc13adff785122b4ad28809a3420982341241421348097878e577c991de8f0";
  const routes = [
    ["/v1/google/calendars", { headers: { "x-google-token": FAKE_GOOGLE_TOKEN } }],
    ["/v1/google/watch", json({ calendars: ["primary"], deviceToken: DEVICE, environment: "sandbox" }, { "x-google-token": FAKE_GOOGLE_TOKEN })],
    ["/v1/google/unwatch", json({ deviceToken: DEVICE }, { "x-google-token": FAKE_GOOGLE_TOKEN })],
  ] as const;

  it.each(routes)("%s is in the google group and refused before any fetch or database use", async (path, init) => {
    const fetchSpy = failFetch();
    const { limiters, env: testEnv } = fakes();
    limiters.google.mode = "refuse";
    const prepare = vi.fn(() => {
      throw new Error("no database use expected");
    });
    const sent = new Request(`https://example.com${path}`, { ...init, headers: { ...(init.headers as Record<string, string>), "cf-connecting-ip": "203.0.113.60" } });
    const response = await app.fetch(sent, { ...testEnv, DB: { prepare } } as unknown as CloudflareBindings);
    expect(response.status).toBe(429);
    expect(response.headers.get("retry-after")).toBe("60");
    expect(await response.json()).toEqual(RATE_LIMITED);
    expect(limiters.google.keys).toEqual(["4:203.0.113.60"]);
    expect(limiters.notify.keys).toEqual([]);
    expect(fetchSpy).not.toHaveBeenCalled();
    expect(prepare).not.toHaveBeenCalled();
    expect(sent.bodyUsed).toBe(false);
  });
});

describe("/v1/health", () => {
  it("is never limited", async () => {
    const { limiters, env: testEnv } = fakes();
    for (const group of GROUPS) limiters[group].mode = "refuse";
    for (let i = 0; i < 3; i++) {
      const response = await app.fetch(new Request("https://example.com/v1/health", { headers: { "cf-connecting-ip": "203.0.113.50" } }), testEnv);
      expect(response.status).toBe(200);
    }
    for (const group of GROUPS) expect(limiters[group].keys).toEqual([]);
  });
});

describe("with the real local binding from wrangler.jsonc", () => {
  // Miniflare's local limiter counts exactly, in windows aligned to the wall
  // clock, so a burst can straddle two windows. Each burst is 2 × limit + 1
  // requests from an address used nowhere else: at least one must be refused
  // whatever the alignment, and when the burst stayed inside one window
  // exactly `limit` pass, which also checks the configured number.
  let nextAddress = 100;
  const freshAddress = () => `198.51.100.${nextAddress++}`;

  it.each(GROUPS)("%s: refuses past the limit with the fixed 429", async (group) => {
    const fetchSpy = failFetch();
    const { limit, period } = RATE_LIMITS[group];
    const address = freshAddress();
    const window = () => Math.floor(Date.now() / (period * 1000));
    const startWindow = window();
    const statuses: number[] = [];
    let refused: Response | undefined;
    for (let i = 0; i < 2 * limit + 1; i++) {
      const response = await exports.default.fetch(request(INVALID[group], { "cf-connecting-ip": address }));
      statuses.push(response.status);
      if (response.status === 429 && !refused) refused = response;
      else await response.body?.cancel();
    }
    const sameWindow = window() === startWindow;
    const answer = INVALID[group].status ?? 400;
    expect(statuses[0]).toBe(answer);
    expect(refused).toBeDefined();
    expect(refused!.headers.get("retry-after")).toBe(String(period));
    expect(await refused!.json()).toEqual(RATE_LIMITED);
    const passed = statuses.filter((status) => status !== 429).length;
    if (sameWindow) {
      expect(passed).toBe(limit);
      expect(statuses.slice(0, limit).every((status) => status === answer)).toBe(true);
    }
    expect(fetchSpy).not.toHaveBeenCalled();
  }, 30_000);

  it("does not limit requests that carry no CF-Connecting-IP (how the other test files call the Worker)", async () => {
    failFetch();
    const { limit } = RATE_LIMITS.discover;
    for (let i = 0; i < 2 * limit + 1; i++) {
      const response = await exports.default.fetch(request(INVALID.discover));
      expect(response.status).toBe(400);
    }
  });
});
