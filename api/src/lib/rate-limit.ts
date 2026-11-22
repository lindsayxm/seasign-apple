import type { MiddlewareHandler } from "hono";

// Per-client-IP rate limits on the routes that need no account (task 19),
// using Cloudflare's Workers Rate Limiting binding. The binding is read from
// the environment on every request, so tests can hand in a fake.
//
// What the binding guarantees (docs read 2026-11-16,
// https://developers.cloudflare.com/workers/runtime-apis/bindings/rate-limit/):
// the count is kept separately in each Cloudflare location and is eventually
// consistent there, so a burst can get somewhat past a limit, and a client
// reaching several locations gets each location's allowance. It is a brake on
// abuse and cost, not an exact quota.
//
// The client's address is used only as the limiter's key: it is never logged
// and never put in a response.

/**
 * The limits, per client per window. Each must equal its binding's `simple`
 * block under "ratelimits" in wrangler.jsonc (test/rate-limit.test.ts checks):
 * the binding enforces the numbers, this table names them and gives the
 * Retry-After value. `period` can only be 10 or 60 seconds. Reasons for each
 * number: memory/decisions/2026-11-16-rate-limits-and-deploy-limits.md.
 */
export const RATE_LIMITS = {
  /** Cheap and cached; the app asks at most every 10 minutes. */
  sky: { binding: "RATE_LIMIT_SKY", namespaceId: "19001", limit: 60, period: 60 },
  /** Up to 10 outbound fetches and seconds of CPU each; scheduled checks every 5 minutes, plus pulls and adding a link. */
  calendar: { binding: "RATE_LIMIT_CALENDAR", namespaceId: "19002", limit: 20, period: 60 },
  /** Up to 50 sites, each with redirects; asked at most every 15 minutes. */
  feed: { binding: "RATE_LIMIT_FEED", namespaceId: "19003", limit: 15, period: 60 },
  /** Only used while adding a site. */
  resolve: { binding: "RATE_LIMIT_RESOLVE", namespaceId: "19004", limit: 10, period: 60 },
  /** Relays the user's paid key, and its 401 says whether a key works. */
  discover: { binding: "RATE_LIMIT_DISCOVER", namespaceId: "19005", limit: 5, period: 60 },
  /**
   * The /v1/google routes the app calls (calendars, events, watch, unwatch;
   * not Google's webhook, which has `notify`). Until push exists the app polls events about
   * every 5 seconds while Today is open (12 a minute); 600 leaves room for
   * about fifty such phones behind one shared address (task 155, was 120). Each request is up to 10
   * calendars of at most 4 pages, short JSON, against the caller's own Google
   * quota.
   */
  google: { binding: "RATE_LIMIT_GOOGLE", namespaceId: "19006", limit: 600, period: 60 },
  /**
   * POST /v1/google/notify, Google's webhook (task 156). Its callers are
   * Google's servers, shared by every channel, so a per-address limit sized
   * for one phone would refuse Google itself; 1200 a minute per address is
   * far above one change notification per calendar edit at this scale. A
   * refused call is a lost wake-up, not lost data (the app reloads when it
   * opens). A forged call costs one header check, or one D1 read by primary
   * key when its channel id has our shape; it cannot send a push without the
   * channel token.
   */
  notify: { binding: "RATE_LIMIT_NOTIFY", namespaceId: "19007", limit: 1200, period: 60 },
} as const satisfies Record<string, { binding: keyof CloudflareBindings; namespaceId: string; limit: number; period: 10 | 60 }>;

export type RateLimitGroup = keyof typeof RATE_LIMITS;

/** The fixed answer past a limit. Every limited route declares it as its 429. */
export const RATE_LIMITED = {
  error: "rate_limited" as const,
  message: "Too many requests from this network; try again in a minute",
};

/** The 429's Retry-After header, for the route definitions. */
export const retryAfterHeader = (required: boolean) => ({
  "Retry-After": {
    description: "Seconds to wait before asking again",
    required,
    schema: { type: "integer" as const, example: 60 },
  },
});

/**
 * The limiter's key for a `CF-Connecting-IP` value. IPv4 is the whole
 * address. IPv6 is cut to its /64, the block one home or phone is usually
 * given, so one host cannot step through its own addresses to dodge the limit;
 * an IPv4-mapped IPv6 address counts as the IPv4 address. Anything that is not
 * an address (Cloudflare sets this header, so this should not happen) is used
 * as it came, shortened. Never throws.
 */
export function clientKey(value: string): string {
  const text = value.trim();
  const v4 = parseIpv4(text);
  if (v4) return `4:${v4.join(".")}`;
  const v6 = parseIpv6(text);
  if (v6) {
    const mapped = v6.slice(0, 5).every((group) => group === 0) && v6[5] === 0xffff;
    if (mapped) return `4:${v6[6]! >> 8}.${v6[6]! & 0xff}.${v6[7]! >> 8}.${v6[7]! & 0xff}`;
    return `6:${v6
      .slice(0, 4)
      .map((group) => group.toString(16))
      .join(":")}::/64`;
  }
  return `x:${text.slice(0, 64)}`;
}

function parseIpv4(text: string): number[] | null {
  const parts = text.split(".");
  if (parts.length !== 4) return null;
  const bytes: number[] = [];
  for (const part of parts) {
    if (!/^\d{1,3}$/.test(part)) return null;
    const byte = Number(part);
    if (byte > 255) return null;
    bytes.push(byte);
  }
  return bytes;
}

/** The eight 16-bit groups of an IPv6 address, or null. Accepts `::` and a dotted IPv4 tail; drops a `%zone`. */
function parseIpv6(text: string): number[] | null {
  let address = text.toLowerCase();
  const zone = address.indexOf("%");
  if (zone >= 0) address = address.slice(0, zone);
  if (!address.includes(":")) return null;
  // A dotted IPv4 tail (`::ffff:192.0.2.1`) becomes two groups.
  const lastColon = address.lastIndexOf(":");
  const tail = address.slice(lastColon + 1);
  if (tail.includes(".")) {
    const v4 = parseIpv4(tail);
    if (!v4) return null;
    address = `${address.slice(0, lastColon + 1)}${((v4[0]! << 8) | v4[1]!).toString(16)}:${((v4[2]! << 8) | v4[3]!).toString(16)}`;
  }
  const halves = address.split("::");
  if (halves.length > 2) return null;
  const read = (part: string | undefined) => (part ? part.split(":") : []);
  const head = read(halves[0]);
  const rest = read(halves[1]);
  const groups = [...head, ...rest];
  if (!groups.every((group) => /^[0-9a-f]{1,4}$/.test(group))) return null;
  if (halves.length === 1 ? groups.length !== 8 : groups.length > 7) return null;
  const zeros = new Array<string>(8 - groups.length).fill("0");
  return [...head, ...zeros, ...rest].map((group) => parseInt(group, 16));
}

// Each fixed log line is written once per isolate, so a misconfiguration is
// visible without one line per request.
const loggedOnce = new Set<string>();
function logOnce(line: string): void {
  if (loggedOnce.has(line)) return;
  loggedOnce.add(line);
  console.error(line);
}

/** For the tests: forget which one-time lines were written. */
export function resetRateLimitLogs(): void {
  loggedOnce.clear();
}

/**
 * Middleware that counts the request against its group's limit for the
 * client's address and answers the fixed 429 past it. It must run before the
 * body is read and before any outbound fetch or KV access, so `app.ts`
 * registers it ahead of everything else on the route.
 *
 * - No `CF-Connecting-IP` (local tests calling the Worker directly; `wrangler
 *   dev` sets it to the local address, and Cloudflare is expected to set it on
 *   every request from the internet, which is checked after the first deploy):
 *   there is no client to count, so the request is served unlimited.
 * - The binding is missing from the environment (misconfiguration): served,
 *   one line logged.
 * - The binding throws or answers something unreadable: served, a fixed line
 *   logged each time. Only an explicit `success: false` refuses.
 */
export function rateLimit(group: RateLimitGroup): MiddlewareHandler<{ Bindings: CloudflareBindings }> {
  const { binding, period } = RATE_LIMITS[group];
  return async (c, next) => {
    const address = c.req.header("cf-connecting-ip");
    // Not logged: every test file reaches this, and a line here would land in
    // the tests that check a route's exact log lines. Whether production
    // requests carry the header is checked after the first deploy instead.
    if (!address) return next();
    const limiter = (c.env as Partial<CloudflareBindings> | undefined)?.[binding];
    if (!limiter || typeof limiter.limit !== "function") {
      logOnce(`rate-limit: binding ${binding} is missing; ${group} is not limited`);
      return next();
    }
    let outcome: RateLimitOutcome | undefined;
    try {
      outcome = await limiter.limit({ key: clientKey(address) });
    } catch {
      console.error(`rate-limit: ${group} limiter failed; request served`);
      return next();
    }
    if (outcome?.success === false) {
      c.header("Retry-After", String(period));
      c.header("Cache-Control", "no-store");
      return c.json(RATE_LIMITED, 429);
    }
    return next();
  };
}
