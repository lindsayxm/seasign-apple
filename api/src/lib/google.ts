// Calls to the Google Calendar API with the user's own OAuth access token, for
// routes/google.ts. Plain fetch to one fixed origin; no SDK.
//
// Reference read on 2026-11-19:
// - events.list: https://developers.google.com/workspace/calendar/api/v3/reference/events/list
// - Event resource: https://developers.google.com/workspace/calendar/api/v3/reference/events
// - calendarList.list: https://developers.google.com/workspace/calendar/api/v3/reference/calendarList/list
// - errors: https://developers.google.com/workspace/calendar/api/guides/errors
// - partial responses (`fields`): https://developers.google.com/workspace/calendar/api/guides/performance
//
// Read on 2026-11-19 for the push channels (task 156):
// - push guide: https://developers.google.com/workspace/calendar/api/guides/push
// - events.watch: https://developers.google.com/workspace/calendar/api/v3/reference/events/watch
// - channels.stop: https://developers.google.com/workspace/calendar/api/v3/reference/channels/stop
//
// The token goes into one place only, the Authorization header of a request to
// GOOGLE_ORIGIN. It is never put into an error, a log line or a return value.
// Nothing Google sends back in an error (status text, message, headers) is
// passed on either: a failure is one of the fixed codes below.
//
// Nothing here imports `cloudflare:*`, so the spec writer can load it in Node.
import { cleanTitle, type StoredEvent } from "./calendar.ts";

export const GOOGLE_ORIGIN = "https://www.googleapis.com";
/** One deadline per calendar (or per calendar list), covering every page and every body. */
export const GOOGLE_TIMEOUT_MS = 8000;
/** The largest successful page read. 250 events with only the fields asked for are well under 100 KB. */
export const GOOGLE_MAX_BYTES = 1024 * 1024;
/** The largest error body read; it is only parsed to tell a rate limit from other 403s. */
export const GOOGLE_ERROR_MAX_BYTES = 64 * 1024;

/**
 * The event types read and watched: ordinary events and ones Google made from
 * mail (flights, bookings). Working location, focus time, out of office and
 * birthdays are left out, as the pasted-link feed does not carry them either
 * (task 155); watching the same set keeps their changes from waking the phone.
 */
export const GOOGLE_EVENT_TYPES = ["default", "fromGmail"] as const;

/** The deadline the routes use. Only the tests change it, to see a timeout without waiting 8 s. */
export const googleDeadline = { ms: GOOGLE_TIMEOUT_MS };

export type GoogleFailureCode =
  /** 401: the token is not valid (expired, revoked or malformed). The app must refresh it. */
  | "auth"
  /** 403 that is not a rate limit: no access to this calendar, or the token lacks the scope. */
  | "forbidden"
  /** 404 or 410: no such calendar for this user. */
  | "not_found"
  /** 429, or a 403 whose reason is a rate limit or quota. */
  | "rate_limited"
  /** Unreachable, a redirect, a 5xx or another status, or a body that could not be read. */
  | "fetch_failed"
  /** The deadline passed. */
  | "timeout"
  /** A body over the cap. */
  | "too_large"
  /**
   * events.watch only: Google refused our webhook address (an error reason
   * starting `push.`, such as push.webhookUrlUnauthorized). A server setting,
   * not the user's token, so it must not read as `auth`.
   */
  | "webhook_refused";

export class GoogleFailure extends Error {
  readonly code: GoogleFailureCode;
  constructor(code: GoogleFailureCode) {
    super(code);
    this.name = "GoogleFailure";
    this.code = code;
  }
}

const isRecord = (value: unknown): value is Record<string, unknown> => typeof value === "object" && value !== null && !Array.isArray(value);

/** Google's reasons for a 403 that means "slow down", not "no access". */
const RATE_LIMIT_REASONS = new Set(["rateLimitExceeded", "userRateLimitExceeded", "quotaExceeded", "dailyLimitExceeded"]);

/** True when an error body says the request was refused for rate or quota. */
export function isRateLimitBody(body: unknown): boolean {
  if (!isRecord(body) || !isRecord(body.error)) return false;
  if (body.error.status === "RESOURCE_EXHAUSTED") return true;
  const errors = Array.isArray(body.error.errors) ? body.error.errors : [];
  return errors.some(
    (entry) => isRecord(entry) && typeof entry.reason === "string" && RATE_LIMIT_REASONS.has(entry.reason),
  );
}

/** True when an error body names a push-channel problem (reason `push.*`), not the token. */
export function isWebhookRefusal(body: unknown): boolean {
  if (!isRecord(body) || !isRecord(body.error)) return false;
  const errors = Array.isArray(body.error.errors) ? body.error.errors : [];
  return errors.some((entry) => isRecord(entry) && typeof entry.reason === "string" && entry.reason.startsWith("push."));
}

function classify(status: number, body: unknown): GoogleFailureCode {
  if (status >= 400 && status < 500 && isWebhookRefusal(body)) return "webhook_refused";
  if (status === 401) return "auth";
  if (status === 429) return "rate_limited";
  if (status === 403) return isRateLimitBody(body) ? "rate_limited" : "forbidden";
  if (status === 404 || status === 410) return "not_found";
  return "fetch_failed";
}

/**
 * Runs `work` with an abort signal that fires after `googleDeadline.ms`; a
 * failure after that is `timeout`.
 */
export async function withGoogleDeadline<T>(work: (signal: AbortSignal) => Promise<T>): Promise<T> {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), googleDeadline.ms);
  try {
    return await work(controller.signal);
  } catch (error) {
    if (controller.signal.aborted) throw new GoogleFailure("timeout");
    throw error instanceof GoogleFailure ? error : new GoogleFailure("fetch_failed");
  } finally {
    clearTimeout(timer);
  }
}

/**
 * GETs one Google Calendar API path and returns the parsed JSON object.
 * `path` must start with `/calendar/v3/`; anything that would leave
 * GOOGLE_ORIGIN is refused before a request is made. Redirects are not
 * followed (one would carry the token wherever it points).
 */
export async function getGoogleJson(path: string, params: URLSearchParams, token: string, signal: AbortSignal): Promise<Record<string, unknown>> {
  const response = await sendGoogle("GET", path, params, undefined, token, signal);
  return readGoogleJson(response, signal);
}

/**
 * POSTs a JSON body to one Google Calendar API path (events.watch,
 * channels.stop) under the same rules as getGoogleJson. Returns the parsed
 * JSON object, or an empty object for a 2xx with an empty body (channels.stop
 * answers 204 or 200 with nothing).
 */
export async function postGoogleJson(path: string, params: URLSearchParams, body: unknown, token: string, signal: AbortSignal): Promise<Record<string, unknown>> {
  const response = await sendGoogle("POST", path, params, JSON.stringify(body), token, signal);
  return readGoogleJson(response, signal, true);
}

/** The request itself, origin and path checked first; a non-2xx is thrown as its failure code. */
async function sendGoogle(
  method: "GET" | "POST",
  path: string,
  params: URLSearchParams,
  body: string | undefined,
  token: string,
  signal: AbortSignal,
): Promise<Response> {
  if (!path.startsWith("/calendar/v3/")) throw new GoogleFailure("fetch_failed");
  const url = new URL(path, GOOGLE_ORIGIN);
  if (url.origin !== GOOGLE_ORIGIN || !url.pathname.startsWith("/calendar/v3/")) throw new GoogleFailure("fetch_failed");
  url.search = params.toString();

  const headers: Record<string, string> = { authorization: `Bearer ${token}`, accept: "application/json" };
  if (body !== undefined) headers["content-type"] = "application/json";
  let response: Response;
  try {
    response = await fetch(url, { method, headers, body, redirect: "manual", signal });
  } catch {
    throw new GoogleFailure(signal.aborted ? "timeout" : "fetch_failed");
  }

  if (response.status < 200 || response.status >= 300) {
    if (response.status >= 300 && response.status < 400) {
      void response.body?.cancel().catch(() => {});
      throw new GoogleFailure("fetch_failed");
    }
    let parsed: unknown = null;
    try {
      parsed = JSON.parse(new TextDecoder().decode(await readCapped(response, GOOGLE_ERROR_MAX_BYTES, signal)));
    } catch {
      if (signal.aborted) throw new GoogleFailure("timeout");
      // Unreadable or too large: classified by the status alone.
    }
    throw new GoogleFailure(classify(response.status, parsed));
  }
  return response;
}

/** A 2xx body as a JSON object; with `emptyIsOk`, no body at all is an empty object. */
async function readGoogleJson(response: Response, signal: AbortSignal, emptyIsOk = false): Promise<Record<string, unknown>> {
  const bytes = await readCapped(response, GOOGLE_MAX_BYTES, signal);
  if (emptyIsOk && new TextDecoder().decode(bytes).trim() === "") return {};
  let body: unknown;
  try {
    body = JSON.parse(new TextDecoder().decode(bytes));
  } catch {
    throw new GoogleFailure("fetch_failed");
  }
  if (!isRecord(body)) throw new GoogleFailure("fetch_failed");
  return body;
}

/** The body, counted while it is read; past `maxBytes` it is cancelled and `too_large` is thrown. */
async function readCapped(response: Response, maxBytes: number, signal: AbortSignal): Promise<Uint8Array> {
  const declared = Number(response.headers.get("content-length"));
  if (Number.isFinite(declared) && declared > maxBytes) {
    void response.body?.cancel().catch(() => {});
    throw new GoogleFailure("too_large");
  }
  if (!response.body) return new Uint8Array(0);
  const reader = response.body.getReader();
  // A body stalled after the headers is ended by the deadline too.
  const onAbort = () => void reader.cancel().catch(() => {});
  signal.addEventListener("abort", onAbort);
  const chunks: Uint8Array[] = [];
  let total = 0;
  try {
    for (;;) {
      let chunk: ReadableStreamReadResult<Uint8Array>;
      try {
        chunk = await reader.read();
      } catch {
        throw new GoogleFailure(signal.aborted ? "timeout" : "fetch_failed");
      }
      if (signal.aborted) throw new GoogleFailure("timeout");
      if (chunk.done) break;
      total += chunk.value.byteLength;
      if (total > maxBytes) {
        void reader.cancel().catch(() => {});
        throw new GoogleFailure("too_large");
      }
      chunks.push(chunk.value);
    }
  } finally {
    signal.removeEventListener("abort", onAbort);
  }
  const body = new Uint8Array(total);
  let offset = 0;
  for (const chunk of chunks) {
    body.set(chunk, offset);
    offset += chunk.byteLength;
  }
  return body;
}

// ───────────────────────── events ─────────────────────────

const DAY = 86400;
const RFC3339 = /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(\.\d{1,9})?(Z|[+-]\d{2}:\d{2})$/i;
const DATE = /^(\d{4})-(\d{2})-(\d{2})$/;

/** Unix seconds of an RFC 3339 time with an offset, or null. */
function readDateTime(value: unknown): number | null {
  if (typeof value !== "string" || !RFC3339.test(value)) return null;
  const ms = Date.parse(value);
  return Number.isFinite(ms) ? Math.floor(ms / 1000) : null;
}

/** Wall-clock seconds of midnight at the start of a YYYY-MM-DD date, or null. */
function readDate(value: unknown): number | null {
  if (typeof value !== "string") return null;
  const match = DATE.exec(value);
  if (!match) return null;
  const [year, month, day] = [Number(match[1]), Number(match[2]), Number(match[3])];
  const ms = Date.UTC(year, month - 1, day);
  const back = new Date(ms);
  // 2026-02-30 is not a date.
  if (back.getUTCFullYear() !== year || back.getUTCMonth() !== month - 1 || back.getUTCDate() !== day) return null;
  return ms / 1000;
}

/**
 * One item of an events.list answer as a StoredEvent, the form the pasted-link
 * route caches, so the same `upcomingEvents` rule answers both routes.
 * - a timed event (`dateTime`, always with an offset) is an instant;
 * - an all-day event (`date`) keeps wall-clock midnights; Google's end date is
 *   exclusive, like an iCalendar DTEND, so a one-day event ends the next midnight.
 * Returns "cancelled" for a cancelled event and null for one that cannot be read.
 */
export function storedEventOf(item: unknown): StoredEvent | "cancelled" | null {
  if (!isRecord(item)) return null;
  if (item.status === "cancelled") return "cancelled";
  const start = isRecord(item.start) ? item.start : null;
  const end = isRecord(item.end) ? item.end : null;
  if (!start) return null;
  const title = cleanTitle(typeof item.summary === "string" ? item.summary : "");

  if (start.dateTime !== undefined) {
    const from = readDateTime(start.dateTime);
    if (from === null) return null;
    // "endTimeUnspecified": the end Google returns is not meaningful; the event has no length.
    if (item.endTimeUnspecified === true || !end || end.dateTime === undefined) return { kind: "instant", title, start: from, end: from };
    const to = readDateTime(end.dateTime);
    if (to === null || to < from) return null;
    return { kind: "instant", title, start: from, end: to };
  }

  const from = readDate(start.date);
  if (from === null) return null;
  let to: number | null = null;
  if (end && (end.date !== undefined || end.dateTime !== undefined)) {
    // An all-day start with a timed end is not something Google writes.
    to = readDate(end.date);
    if (to === null) return null;
  }
  return { kind: "allDay", title, start: from, end: to !== null && to > from ? to : from + DAY };
}

// ───────────────────────── calendar list ─────────────────────────

export type GoogleCalendar = {
  id: string;
  name: string;
  primary: boolean;
  selected: boolean;
  color?: string;
};

const HEX_COLOR = /^#[0-9a-fA-F]{6}$/;

/** One calendarList item, or null for a deleted entry or one without an id. */
export function calendarOf(item: unknown): GoogleCalendar | null {
  if (!isRecord(item) || item.deleted === true) return null;
  if (typeof item.id !== "string" || item.id.length === 0) return null;
  const own = typeof item.summaryOverride === "string" ? cleanTitle(item.summaryOverride) : "";
  const name = own || (typeof item.summary === "string" ? cleanTitle(item.summary) : "");
  return {
    id: item.id,
    name,
    primary: item.primary === true,
    selected: item.selected === true,
    ...(typeof item.backgroundColor === "string" && HEX_COLOR.test(item.backgroundColor) ? { color: item.backgroundColor.toLowerCase() } : {}),
  };
}
