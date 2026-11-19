import { OpenAPIHono, createRoute, z } from "@hono/zod-openapi";
import { and, eq, inArray, lte, notInArray } from "drizzle-orm";
import { drizzle } from "drizzle-orm/d1";
import type { Context } from "hono";
import { HTTPException } from "hono/http-exception";
import { calendarChannels, type CalendarChannel } from "../db/schema.ts";
import { sendBackgroundPush, type PushOutcome } from "../lib/apns.ts";
import { GOOGLE_EVENT_TYPES, GoogleFailure, postGoogleJson, withGoogleDeadline, type GoogleFailureCode } from "../lib/google.ts";
import { retryAfterHeader } from "../lib/rate-limit.ts";
import { isJsonContentType } from "../lib/site-reader.ts";
import { GoogleHeadersSchema, MAX_CALENDARS, MAX_ID_LENGTH, isCalendarId } from "./google.ts";

// Google Calendar change notifications (plan plans/2026-11-19-google-calendar-push.md,
// task C; task 156).
//
// - POST /v1/google/watch: the app sends its Google access token, the chosen
//   calendar ids and its APNs device token. For each calendar the Worker asks
//   Google (events.watch) to call our webhook on every change, with a random
//   channel id and a random channel token, and keeps one row per channel:
//   channel id, SHA-256 of the token, Google's resource id, device token,
//   APNs environment, expiry. No Google token, calendar id, user id or event
//   data is kept.
// - POST /v1/google/unwatch: stops the device's channels and forgets them.
// - POST /v1/google/notify: Google's call. It carries no event data and no
//   Google token; the channel row alone says which phone to wake. The Worker
//   checks the channel token and sends one background push.
//
// The access token is used for this request's calls to www.googleapis.com
// only, as in routes/google.ts: never stored, logged or echoed. Log lines here
// carry fixed text, an index and a code; never a token, a device token, a
// channel id or a calendar id.

/** events.watch `params.ttl`: Google's default and, per the push guide, the most it grants for events. */
export const CHANNEL_TTL_SECONDS = 7 * 24 * 60 * 60;
const CHANNEL_TTL_MS = CHANNEL_TTL_SECONDS * 1000;
/** An expiry Google gives further out than this is not believed. */
const MAX_EXPIRY_MS = 31 * 24 * 60 * 60 * 1000;
/** Bounds on an APNs device token in hex. Apple's are 32 bytes today, but it says not to assume a size. */
const MIN_DEVICE_TOKEN_HEX = 32;
const MAX_DEVICE_TOKEN_HEX = 400;
const DEVICE_TOKEN_PATTERN = /^(?:[0-9a-fA-F]{2})+$/;
/** Our channel ids are lowercase UUIDs; anything else at the webhook is not ours and costs no database read. */
const CHANNEL_ID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
/** The longest channel token header looked at; ours are 43 characters. */
const MAX_CHANNEL_TOKEN_LENGTH = 256;
/** Google's resource ids are short opaque strings; anything longer is not stored. */
const MAX_RESOURCE_ID_LENGTH = 512;

export const NOTIFY_PATH = "/v1/google/notify";

const DeviceTokenSchema = z
  .string()
  .min(MIN_DEVICE_TOKEN_HEX)
  .max(MAX_DEVICE_TOKEN_HEX)
  .regex(DEVICE_TOKEN_PATTERN)
  .openapi({
    description:
      "The APNs device token from application(_:didRegisterForRemoteNotificationsWithDeviceToken:), as hex (an even number of 32 to 400 hex digits, either case)",
    example: "00fc13adff785122b4ad28809a3420982341241421348097878e577c991de8f0",
  });

const GoogleWatchRequestSchema = z
  .object({
    calendars: z
      .array(z.string().min(1).max(MAX_ID_LENGTH).refine(isCalendarId))
      .min(1)
      .max(MAX_CALENDARS)
      .openapi({
        description: "Google calendar ids from /v1/google/calendars (or \"primary\"): 1 to 10. Every calendar the device should be woken for, not only new ones",
        example: ["primary"],
      }),
    deviceToken: DeviceTokenSchema,
    environment: z.enum(["sandbox", "production"]).openapi({
      description: "Which APNs the device token belongs to: sandbox for development builds (aps-environment development), production for TestFlight and App Store builds",
      example: "production",
    }),
  })
  .openapi("GoogleWatchRequest");

const WATCH_ERRORS = ["forbidden", "not_found", "rate_limited", "fetch_failed", "timeout", "too_large", "webhook_refused"] as const;
type WatchErrorCode = (typeof WATCH_ERRORS)[number];

const GoogleWatchStatusSchema = z
  .object({
    index: z.number().int().openapi({ description: "Index of the calendar id in the request", example: 0 }),
    ok: z.boolean().openapi({ description: "True when Google now notifies us of changes to this calendar" }),
    error: z.enum(WATCH_ERRORS).optional().openapi({
      description:
        "Why the calendar could not be watched: forbidden (Google refused access, or the token lacks the scope), not_found, rate_limited (Google is limiting requests; try later), fetch_failed (Google unreachable, an error status or an unreadable answer), timeout, too_large, webhook_refused (Google refused the API's webhook address: a server setting, not the user's; trying again will not help until it is fixed)",
    }),
  })
  .openapi("GoogleWatchStatus");

const GoogleWatchSchema = z
  .object({
    calendars: z.array(GoogleWatchStatusSchema).openapi({ description: "One entry per calendar id, in request order" }),
    expiresAt: z.string().nullable().openapi({
      description:
        "When the first of the new channels ends (RFC 3339, UTC), or null when none was made. Channels cannot be renewed: watch again before this, for example when the app opens and less than two days are left",
      example: "2026-11-26T15:00:00Z",
    }),
  })
  .openapi("GoogleWatch");

const GoogleUnwatchRequestSchema = z.object({ deviceToken: DeviceTokenSchema }).openapi("GoogleUnwatchRequest");

const GoogleUnwatchSchema = z
  .object({
    removed: z.number().int().openapi({ description: "How many channels this device had; all are now forgotten, and each was stopped at Google if Google allowed it", example: 2 }),
  })
  .openapi("GoogleUnwatch");

const ERROR_CODES = ["invalid_request", "google_auth", "rate_limited", "push_unavailable", "internal_error"] as const;

const GooglePushErrorSchema = z
  .object({
    error: z.enum(ERROR_CODES).openapi({ description: "Machine-readable reason" }),
    message: z.string().openapi({ description: "Fixed human-readable text for the code; never Google's own words" }),
  })
  .openapi("GooglePushError");

const errorResponse = (description: string) => ({ description, content: { "application/json": { schema: GooglePushErrorSchema } } });
const rateLimited = {
  ...errorResponse("rate_limited: too many requests from this network; wait Retry-After seconds"),
  headers: retryAfterHeader(true),
};

const postGoogleWatch = createRoute({
  method: "post",
  path: "/v1/google/watch",
  operationId: "postGoogleWatch",
  summary: "Wake this device with a background push whenever one of these Google calendars changes",
  description:
    "Replaces the device's earlier channels: they are stopped at Google and forgotten once at least one new channel is made. When none could be made, the earlier channels are kept. The push is {\"aps\":{\"content-available\":1},\"type\":\"calendar-changed\"}: it carries no event data, so the app reloads with /v1/google/events",
  request: {
    headers: GoogleHeadersSchema,
    body: { required: true, content: { "application/json": { schema: GoogleWatchRequestSchema } } },
  },
  responses: {
    200: { description: "The state of each calendar and when the new channels end", content: { "application/json": { schema: GoogleWatchSchema } } },
    400: errorResponse(
      "invalid_request: no X-Google-Token header or one of the wrong shape, a body that is not JSON or not sent as application/json, no calendar ids or more than 10, an id of the wrong shape, a device token that is not hex of 32 to 400 digits, or an unknown environment",
    ),
    401: errorResponse("google_auth: Google did not accept the token (expired or revoked). Nothing was changed. Refresh the access token and ask again"),
    429: rateLimited,
    500: errorResponse("internal_error: something went wrong in the API; nothing was changed"),
    503: errorResponse("push_unavailable: this server has no webhook address configured, so Google cannot be asked to notify it"),
  },
});

const postGoogleUnwatch = createRoute({
  method: "post",
  path: "/v1/google/unwatch",
  operationId: "postGoogleUnwatch",
  summary: "Stop waking this device for Google calendar changes",
  description: "For sign-out and Disconnect. The device's channels are forgotten even when Google refuses to stop them (they then end by themselves within 7 days, and their calls are ignored)",
  request: {
    headers: GoogleHeadersSchema,
    body: { required: true, content: { "application/json": { schema: GoogleUnwatchRequestSchema } } },
  },
  responses: {
    200: { description: "The device's channels are gone", content: { "application/json": { schema: GoogleUnwatchSchema } } },
    400: errorResponse("invalid_request: no X-Google-Token header or one of the wrong shape, a body that is not JSON or not sent as application/json, or a device token that is not hex of 32 to 400 digits"),
    429: rateLimited,
    500: errorResponse("internal_error: something went wrong in the API"),
  },
});

const INVALID_REQUEST = {
  error: "invalid_request" as const,
  message: "Send an X-Google-Token header and a JSON body with 1 to 10 calendar ids, the APNs device token in hex and the APNs environment",
};
const INTERNAL_ERROR = { error: "internal_error" as const, message: "Something went wrong" };
const GOOGLE_AUTH = { error: "google_auth" as const, message: "Google did not accept the access token; refresh it and try again" };
const PUSH_UNAVAILABLE = { error: "push_unavailable" as const, message: "Calendar change notifications are not set up on this server" };

export const googlePush = new OpenAPIHono<{ Bindings: CloudflareBindings }>({
  // A fixed message: the validator's report could quote the body or the token.
  defaultHook: (result, c) => {
    if (!result.success) return c.json(INVALID_REQUEST, 400);
  },
});

googlePush.onError((error, c) => {
  // The webhook answers Google with an empty status only; see notify below.
  if (c.req.path === NOTIFY_PATH) return c.body(null, 503);
  if (error instanceof HTTPException && (error.status === 400 || error.status === 415)) return c.json(INVALID_REQUEST, 400);
  console.error("google-push: unexpected error");
  return c.json(INTERNAL_ERROR, 500);
});

// ───────────────────────── helpers ─────────────────────────

const failureCode = (error: unknown): GoogleFailureCode => (error instanceof GoogleFailure ? error.code : "fetch_failed");

const hex = (bytes: ArrayBuffer | Uint8Array) => [...new Uint8Array(bytes)].map((byte) => byte.toString(16).padStart(2, "0")).join("");

/** Lowercase hex SHA-256 of a string. */
export async function sha256Hex(text: string): Promise<string> {
  return hex(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text)));
}

/** 32 random bytes as base64url: the channel token. 43 characters, under Google's 256. */
function randomToken(): string {
  const bytes = crypto.getRandomValues(new Uint8Array(32));
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

/** The configured webhook address, or null when it is missing or not https. */
function webhookAddress(env: Partial<CloudflareBindings> | undefined): string | null {
  const value = env?.GOOGLE_WEBHOOK_URL;
  if (typeof value !== "string") return null;
  try {
    const url = new URL(value);
    return url.protocol === "https:" ? url.toString() : null;
  } catch {
    return null;
  }
}

/** Google's `expiration` (Unix ms, sent as an int64 string or a number), believed only when it is ahead and within a month. */
function readExpiration(value: unknown, now: number): number {
  const ms = typeof value === "string" && /^\d{1,16}$/.test(value) ? Number(value) : typeof value === "number" ? value : NaN;
  if (Number.isSafeInteger(ms) && ms > now && ms - now <= MAX_EXPIRY_MS) return ms;
  return now + CHANNEL_TTL_MS;
}

type NewChannel = Pick<CalendarChannel, "id" | "tokenHash" | "resourceId" | "expiresAt">;

/** events.watch on one calendar: a new channel pointing at `address`. */
function openChannel(calendarId: string, token: string, address: string, now: number): Promise<NewChannel> {
  return withGoogleDeadline(async (signal) => {
    const id = crypto.randomUUID();
    const channelToken = randomToken();
    const params = new URLSearchParams();
    for (const type of GOOGLE_EVENT_TYPES) params.append("eventTypes", type);
    const body = await postGoogleJson(
      `/calendar/v3/calendars/${encodeURIComponent(calendarId)}/events/watch`,
      params,
      { id, type: "web_hook", address, token: channelToken, params: { ttl: String(CHANNEL_TTL_SECONDS) } },
      token,
      signal,
    );
    const resourceId = body.resourceId;
    if (body.id !== undefined && body.id !== id) throw new GoogleFailure("fetch_failed");
    if (typeof resourceId !== "string" || resourceId.length === 0 || resourceId.length > MAX_RESOURCE_ID_LENGTH) throw new GoogleFailure("fetch_failed");
    return { id, tokenHash: await sha256Hex(channelToken), resourceId, expiresAt: readExpiration(body.expiration, now) };
  });
}

/** channels.stop for each channel, all at once; failures are ignored (the channel ends by itself). Returns how many Google confirmed. */
async function stopChannels(channels: Pick<CalendarChannel, "id" | "resourceId">[], token: string): Promise<number> {
  const results = await Promise.all(
    channels.map((channel) =>
      withGoogleDeadline((signal) => postGoogleJson("/calendar/v3/channels/stop", new URLSearchParams(), { id: channel.id, resourceId: channel.resourceId }, token, signal)).then(
        () => true,
        () => false,
      ),
    ),
  );
  return results.filter(Boolean).length;
}

const rfc3339 = (ms: number) => new Date(ms).toISOString().replace(/\.\d{3}Z$/, "Z");

// ───────────────────────── watch ─────────────────────────

type WatchResult = { index: number; channel?: NewChannel; error?: GoogleFailureCode };

googlePush.openapi(postGoogleWatch, async (c) => {
  if (!isJsonContentType(c.req.header("content-type"))) return c.json(INVALID_REQUEST, 400);
  const token = c.req.valid("header")["x-google-token"];
  const body = c.req.valid("json") as Partial<z.infer<typeof GoogleWatchRequestSchema>> | undefined;
  if (!body || !Array.isArray(body.calendars) || typeof body.deviceToken !== "string" || !body.environment) return c.json(INVALID_REQUEST, 400);
  const address = webhookAddress(c.env);
  if (!address) {
    console.error("google-watch: GOOGLE_WEBHOOK_URL is missing or not https");
    return c.json(PUSH_UNAVAILABLE, 503);
  }
  const deviceToken = body.deviceToken.toLowerCase();
  const environment = body.environment;
  const now = Date.now();

  // An id sent twice is watched once.
  const opened = new Map<string, Promise<NewChannel>>();
  const results: WatchResult[] = await Promise.all(
    body.calendars.map(async (calendarId, index) => {
      try {
        let open = opened.get(calendarId);
        if (!open) opened.set(calendarId, (open = openChannel(calendarId, token, address, now)));
        return { index, channel: await open };
      } catch (error) {
        const code = failureCode(error);
        console.warn(`google-watch: calendar ${index} failed: ${code}`);
        return { index, error: code };
      }
    }),
  );
  const made = [...new Map(results.flatMap((result) => (result.channel ? [[result.channel.id, result.channel] as const] : []))).values()];

  // One token watches every calendar: if Google refused it once, it is not
  // valid. Nothing changes: channels just made are stopped, old ones stay.
  if (results.some((result) => result.error === "auth")) {
    await stopChannels(made, token);
    return c.json(GOOGLE_AUTH, 401);
  }

  const db = drizzle(c.env.DB);
  let replaced: Pick<CalendarChannel, "id" | "resourceId">[] = [];
  try {
    if (made.length > 0) {
      await db.insert(calendarChannels).values(made.map((channel) => ({ ...channel, deviceToken, environment, createdAt: now })));
      // Every other channel of this device, including one a concurrent watch
      // just made: the last watch wins.
      replaced = await db
        .select({ id: calendarChannels.id, resourceId: calendarChannels.resourceId })
        .from(calendarChannels)
        .where(and(eq(calendarChannels.deviceToken, deviceToken), notInArray(calendarChannels.id, made.map((channel) => channel.id))));
      if (replaced.length > 0) await db.delete(calendarChannels).where(inArray(calendarChannels.id, replaced.map((channel) => channel.id)));
    }
    // Rows Google no longer calls would otherwise stay for good.
    await db.delete(calendarChannels).where(lte(calendarChannels.expiresAt, now));
  } catch {
    console.error("google-watch: database failed");
    // A channel without a row would only be ignored, but stop them anyway.
    await stopChannels(made, token);
    return c.json(INTERNAL_ERROR, 500);
  }
  await stopChannels(replaced, token);

  const soonest = made.length > 0 ? Math.min(...made.map((channel) => channel.expiresAt)) : null;
  return c.json(
    {
      calendars: results.map((result) =>
        result.channel ? { index: result.index, ok: true } : { index: result.index, ok: false, error: (result.error ?? "fetch_failed") as WatchErrorCode },
      ),
      expiresAt: soonest === null ? null : rfc3339(soonest),
    },
    200,
  );
});

// ───────────────────────── unwatch ─────────────────────────

googlePush.openapi(postGoogleUnwatch, async (c) => {
  if (!isJsonContentType(c.req.header("content-type"))) return c.json(INVALID_REQUEST, 400);
  const token = c.req.valid("header")["x-google-token"];
  const body = c.req.valid("json") as Partial<z.infer<typeof GoogleUnwatchRequestSchema>> | undefined;
  if (!body || typeof body.deviceToken !== "string") return c.json(INVALID_REQUEST, 400);
  const deviceToken = body.deviceToken.toLowerCase();

  const db = drizzle(c.env.DB);
  let rows: Pick<CalendarChannel, "id" | "resourceId">[];
  try {
    rows = await db
      .select({ id: calendarChannels.id, resourceId: calendarChannels.resourceId })
      .from(calendarChannels)
      .where(eq(calendarChannels.deviceToken, deviceToken));
    if (rows.length > 0) await db.delete(calendarChannels).where(eq(calendarChannels.deviceToken, deviceToken));
  } catch {
    console.error("google-unwatch: database failed");
    return c.json(INTERNAL_ERROR, 500);
  }
  await stopChannels(rows, token);
  return c.json({ removed: rows.length }, 200);
});

// ───────────────────────── notify (Google's webhook) ─────────────────────────

// Each fixed line is written once per isolate, so a missing secret does not
// write a line per change.
const loggedOnce = new Set<string>();
function logOnce(line: string): void {
  if (loggedOnce.has(line)) return;
  loggedOnce.add(line);
  console.error(line);
}

/** For the tests: forget which one-time lines were written. */
export function resetNotifyLogs(): void {
  loggedOnce.clear();
}

/** Equal in time that does not depend on where they differ. Both are SHA-256 hex, so the same length. */
function sameHash(a: string, b: string): boolean {
  const left = new TextEncoder().encode(a);
  const right = new TextEncoder().encode(b);
  if (left.byteLength !== right.byteLength) return false;
  return crypto.subtle.timingSafeEqual(left, right);
}

function logPush(outcome: PushOutcome): void {
  switch (outcome) {
    case "sent":
      return;
    case "not_configured":
      logOnce("google-notify: APNs is not configured; no push sent");
      return;
    case "bad_key":
      logOnce("google-notify: APNS_KEY is not a P-256 PKCS#8 key; no push sent");
      return;
    default:
      console.warn(`google-notify: push ${outcome}`);
  }
}

/**
 * Google's call on a channel change. Not in the OpenAPI spec: no client of
 * ours calls it. Every outcome but a database failure is the same bare 200,
 * so a caller learns nothing about which channels exist (and Google does not
 * retry); a database failure is 503, which Google may retry. It never calls
 * Google, and the one outbound call, to APNs, has a 3 second deadline.
 *
 * Headers read (push guide): X-Goog-Channel-ID, X-Goog-Channel-Token,
 * X-Goog-Resource-ID, X-Goog-Resource-State (sync, exists, not_exists),
 * X-Goog-Channel-Expiration (informational; the row's expiry is used). The
 * body is empty and not read.
 */
async function notify(c: Context<{ Bindings: CloudflareBindings }>): Promise<Response> {
  const done = () => c.body(null, 200);
  const channelId = c.req.header("x-goog-channel-id") ?? "";
  const channelToken = c.req.header("x-goog-channel-token") ?? "";
  const state = c.req.header("x-goog-resource-state") ?? "";
  const resourceId = c.req.header("x-goog-resource-id");

  // The first message on a new channel says only that it exists.
  if (state === "sync") return done();
  if (!CHANNEL_ID_PATTERN.test(channelId) || channelToken.length === 0 || channelToken.length > MAX_CHANNEL_TOKEN_LENGTH) return done();

  const db = drizzle(c.env.DB);
  const now = Date.now();
  let row: CalendarChannel | undefined;
  try {
    [row] = await db.select().from(calendarChannels).where(eq(calendarChannels.id, channelId)).limit(1);
  } catch {
    console.error("google-notify: database failed");
    return c.body(null, 503);
  }
  if (!row) return done();
  if (!sameHash(await sha256Hex(channelToken), row.tokenHash)) return done();
  if (resourceId !== undefined && resourceId !== row.resourceId) return done();

  if (row.expiresAt <= now) {
    try {
      await db.delete(calendarChannels).where(eq(calendarChannels.id, row.id));
    } catch {
      console.error("google-notify: database failed");
    }
    return done();
  }

  const outcome = await sendBackgroundPush(c.env, row.deviceToken, row.environment);
  logPush(outcome);
  if (outcome === "unregistered") {
    // The phone uninstalled the app or the token changed: none of its channels can reach it.
    try {
      await db.delete(calendarChannels).where(eq(calendarChannels.deviceToken, row.deviceToken));
    } catch {
      console.error("google-notify: database failed");
    }
  }
  return done();
}

googlePush.post(NOTIFY_PATH, async (c) => {
  try {
    return await notify(c);
  } catch {
    console.error("google-notify: unexpected error");
    return c.body(null, 503);
  }
});
