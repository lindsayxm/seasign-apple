import { OpenAPIHono, createRoute, z } from "@hono/zod-openapi";
import { HTTPException } from "hono/http-exception";
import { dayWall, isTimeZone, placeEvent } from "../lib/calendar.ts";
import { GoogleFailure, postGoogleJson, storedEventOf, withGoogleDeadline } from "../lib/google.ts";
import { retryAfterHeader } from "../lib/rate-limit.ts";
import { isJsonContentType } from "../lib/site-reader.ts";
import { CalendarEventSchema } from "./calendar.ts";
import { GoogleHeadersSchema, MAX_ID_LENGTH, isCalendarId } from "./google.ts";

// Creating one event in a Google calendar the user owns (plan
// plans/2026-11-22-day-calendar-and-voice.md, task 3; task 168).
//
// The app sends what the user confirmed: a calendar id, a title, and either a
// start and end or an all-day date, with a time zone and an event id it made
// itself. The Worker calls Google's events.insert once with the user's token
// from X-Google-Token. The event has a title and times only: no attendees, so
// nobody is invited or notified (`sendUpdates` is left at Google's default;
// with no guests there is no one to send to), and no location, description,
// recurrence, reminders or conferencing; any other body field is the 400.
//
// The client-made id makes a retry safe: when a try timed out or failed on
// the way back, the app sends the same request again, and Google answers 409
// `duplicate` if the first one was made. That is answered as success with
// `created: false` and no `event`: Google's 409 does not include the event,
// and reading it back would be a second request that reads its content. The
// app has the draft it sent. Google's reference says it "cannot guarantee
// that ID collisions will be detected at event creation time", so this is
// best effort.
//
// The token is used for this one call to www.googleapis.com only; it is never
// stored, logged or echoed. Neither the title, the times, nor the calendar id
// appear in a log line or an error body: log lines are fixed text and a code.
// Every answer carries Cache-Control: no-store and the route is in the
// `google` rate-limit group (both set in app.ts for /v1/google/*).

/** A Google event id this route accepts: 32 lowercase hex digits (a UUID without dashes), a subset of Google's base32hex rule. */
const EVENT_ID_PATTERN = /^[0-9a-f]{32}$/;
const MAX_TITLE = 200;
/** No control characters (C0 such as newlines and tabs, DEL, C1) in a title. No `u` flag, so the spec carries the pattern as written. */
const TITLE_PATTERN = /^[^\x00-\x1f\x7f-\x9f]*$/;
const DAY = 86400;
/** The longest timed event: one day. */
const MAX_TIMED_SECONDS = DAY;
/** A time with its offset, to the second: 2026-11-22T15:00:00-05:00 or 2026-11-22T20:00:00Z. */
const INSTANT_PATTERN = /^(\d{4}-\d{2}-\d{2})T(\d{2}):(\d{2}):(\d{2})(?:Z|([+-])(\d{2}):(\d{2}))$/;
const DATE_PATTERN = /^\d{4}-\d{2}-\d{2}$/;
/**
 * The fields Google echoes back: what `storedEventOf` reads, so nothing else
 * the calendar adds (organizer, creator, links) reaches the Worker.
 */
const INSERT_FIELDS = "status,summary,start,end,endTimeUnspecified";

/** Unix seconds of a time with its offset, or null when it is not a real time. */
function readInstant(text: string): number | null {
  const match = INSTANT_PATTERN.exec(text);
  if (!match) return null;
  const midnight = dayWall(match[1]!);
  const [hour, minute, second] = [Number(match[2]), Number(match[3]), Number(match[4])];
  if (midnight === null || hour > 23 || minute > 59 || second > 59) return null;
  let offset = 0;
  if (match[5] !== undefined) {
    const [offsetHour, offsetMinute] = [Number(match[6]), Number(match[7])];
    if (offsetHour > 23 || offsetMinute > 59) return null;
    offset = (match[5] === "-" ? -1 : 1) * (offsetHour * 3600 + offsetMinute * 60);
  }
  return midnight + hour * 3600 + minute * 60 + second - offset;
}

const isInstant = (text: string) => readInstant(text) !== null;
const isDate = (text: string) => DATE_PATTERN.test(text) && dayWall(text) !== null;

/** RFC 3339 in UTC, second precision. */
const rfc3339 = (seconds: number) => new Date(seconds * 1000).toISOString().replace(/\.\d{3}Z$/, "Z");

const instantField = (description: string, example: string) => z.string().refine(isInstant).optional().openapi({ description, example });

const GoogleCreateEventRequestSchema = z
  .strictObject({
    calendar: z.string().min(1).max(MAX_ID_LENGTH).refine(isCalendarId).openapi({
      description: "The Google calendar id to add the event to, from /v1/google/calendars (or \"primary\"): 1 to 512 printable ASCII characters. The user must be able to write to it",
      example: "primary",
    }),
    id: z.string().regex(EVENT_ID_PATTERN).openapi({
      description:
        "An event id the app makes once per confirmed event: 32 lowercase hex digits (a random UUID without its dashes). Send the same id again when retrying the same event, so a retry after a timeout cannot add it twice",
      example: "3f2b8c9d4e5f40718293a4b5c6d7e8f9",
    }),
    title: z.string().trim().min(1).max(MAX_TITLE).regex(TITLE_PATTERN).openapi({
      description: "The event's title, 1 to 200 characters once white space at either end is removed; no control characters such as line breaks",
      example: "Meeting with Rahaf",
    }),
    timezone: z.string().refine(isTimeZone).openapi({
      description:
        "IANA time zone the event is meant in. Google keeps it with a timed event; the answer places an all-day event's midnights in it",
      example: "America/New_York",
    }),
    start: instantField("For a timed event: when it starts, RFC 3339 to the second with Z or an offset. Send `end` with it and leave out `date`", "2026-11-22T15:00:00-05:00"),
    end: instantField("For a timed event: when it ends, after `start` and at most 24 hours after it", "2026-11-22T16:00:00-05:00"),
    date: z.string().refine(isDate).optional().openapi({
      description: "For an all-day event: its date, YYYY-MM-DD. The event covers that one day. Leave out `start` and `end`",
      example: "2026-11-22",
    }),
  })
  .openapi("GoogleCreateEventRequest");

const GoogleCreatedEventSchema = z
  .object({
    id: z.string().openapi({ description: "The event id the request sent", example: "3f2b8c9d4e5f40718293a4b5c6d7e8f9" }),
    created: z.boolean().openapi({
      description:
        "True when this request added the event. False when Google already had an event with this id in the calendar: an earlier try of the same request added it, and nothing was added now",
    }),
    // No description of its own here, so the spec has a plain $ref (one with
    // a description becomes allOf, which the Swift client wraps).
    event: CalendarEventSchema.optional(),
  })
  .openapi("GoogleCreatedEvent", {
    description:
      "The event is in the calendar. `event` is the event as Google stored it, in the shape /v1/google/events answers (`calendar` is 0); it is left out when `created` is false, since Google's answer then does not include the event, and when Google's answer could not be read. The event exists in both cases: show the draft that was sent",
  });

const ERROR_CODES = [
  "invalid_request",
  "google_auth",
  "insufficient_scope",
  "forbidden",
  "not_found",
  "rate_limited",
  "fetch_failed",
  "timeout",
  "internal_error",
] as const;

const GoogleCreateErrorSchema = z
  .object({
    error: z.enum(ERROR_CODES).openapi({ description: "Machine-readable reason" }),
    message: z.string().openapi({ description: "Fixed human-readable text for the code; never Google's own words, and never the title or times sent" }),
  })
  .openapi("GoogleCreateError");

const errorResponse = (description: string) => ({ description, content: { "application/json": { schema: GoogleCreateErrorSchema } } });

const postGoogleCreateEvent = createRoute({
  method: "post",
  path: "/v1/google/events/create",
  operationId: "postGoogleCreateEvent",
  summary: "Add one event to a Google calendar the user can write to, with their own access token",
  description:
    "The event has the title and times sent and nothing else: no guests, no invitations, no location, description, repetition, reminders or conferencing. After a timeout or fetch_failed the event may or may not have been added: retry with the same `id`, and an event already added is answered as success with `created: false`",
  request: {
    headers: GoogleHeadersSchema,
    body: { required: true, content: { "application/json": { schema: GoogleCreateEventRequestSchema } } },
  },
  responses: {
    200: { description: "The event is in the calendar", content: { "application/json": { schema: GoogleCreatedEventSchema } } },
    400: errorResponse(
      "invalid_request: no X-Google-Token header or one of the wrong shape, a body that is not JSON or not sent as application/json, a field of the wrong shape or one not listed, both or neither of start/end and date, an end not after the start or more than 24 hours after it",
    ),
    401: errorResponse("google_auth: Google did not accept the token (expired or revoked). Nothing was added. Refresh the access token and try again"),
    403: errorResponse(
      "insufficient_scope: the token was granted without write access to events; the user must connect Google again and allow adding events. forbidden: Google refused to add events to this calendar (the user cannot write to it, or another refusal); choose another calendar. Nothing was added in either case",
    ),
    404: errorResponse("not_found: Google has no such calendar for this user. Nothing was added"),
    429: {
      ...errorResponse(
        "rate_limited: too many requests from this network (Retry-After is sent), or Google is limiting requests (no Retry-After). Nothing was added",
      ),
      headers: retryAfterHeader(false),
    },
    500: errorResponse("internal_error: something went wrong in the API"),
    502: errorResponse(
      "fetch_failed: Google could not be reached, failed, or answered in a way that could not be read. timeout: Google did not answer within 8 seconds. In both cases the event may have been added: retry with the same id",
    ),
  },
});

const INVALID_REQUEST = {
  error: "invalid_request" as const,
  message:
    "Send an X-Google-Token header and a JSON body with a calendar id, an event id of 32 lowercase hex digits, a title of 1 to 200 characters, an IANA time zone, and either a start and end up to 24 hours apart or an all-day date",
};
const INTERNAL_ERROR = { error: "internal_error" as const, message: "Something went wrong" };
const GOOGLE_AUTH = { error: "google_auth" as const, message: "Google did not accept the access token; refresh it and try again" };
const INSUFFICIENT_SCOPE = { error: "insufficient_scope" as const, message: "Google Calendar was connected without permission to add events; connect it again" };
const FORBIDDEN = { error: "forbidden" as const, message: "Google did not allow adding events to this calendar" };
const NOT_FOUND = { error: "not_found" as const, message: "Google has no such calendar for this account" };
const RATE_LIMITED = { error: "rate_limited" as const, message: "Google is limiting requests; try again later" };
const FETCH_FAILED = { error: "fetch_failed" as const, message: "Google Calendar could not be reached; try again with the same event id" };
const TIMEOUT = { error: "timeout" as const, message: "Google Calendar did not answer in time; the event may have been added. Try again with the same event id" };

export const googleCreate = new OpenAPIHono<{ Bindings: CloudflareBindings }>({
  // A fixed message: the validator's report could quote the title, the times or the token.
  defaultHook: (result, c) => {
    if (!result.success) return c.json(INVALID_REQUEST, 400);
  },
});

googleCreate.onError((error, c) => {
  if (error instanceof HTTPException && (error.status === 400 || error.status === 415)) return c.json(INVALID_REQUEST, 400);
  console.error("google-create: unexpected error");
  return c.json(INTERNAL_ERROR, 500);
});

type CreateRequest = z.infer<typeof GoogleCreateEventRequestSchema>;

/** The events.insert body: id, summary, start and end, nothing else. Null when the times do not make one event. */
function insertBody(request: CreateRequest): Record<string, unknown> | null {
  const { id, title, timezone, start, end, date } = request;
  if (date !== undefined) {
    if (start !== undefined || end !== undefined) return null;
    // Google's end date is exclusive: a one-day event ends the next day.
    const next = rfc3339(dayWall(date)! + DAY).slice(0, 10);
    return { id, summary: title, start: { date }, end: { date: next } };
  }
  if (start === undefined || end === undefined) return null;
  const from = readInstant(start);
  const to = readInstant(end);
  if (from === null || to === null || to <= from || to - from > MAX_TIMED_SECONDS) return null;
  return {
    id,
    summary: title,
    start: { dateTime: rfc3339(from), timeZone: timezone },
    end: { dateTime: rfc3339(to), timeZone: timezone },
  };
}

googleCreate.openapi(postGoogleCreateEvent, async (c) => {
  if (!isJsonContentType(c.req.header("content-type"))) return c.json(INVALID_REQUEST, 400);
  const token = c.req.valid("header")["x-google-token"];
  const request = c.req.valid("json") as CreateRequest | undefined;
  if (!request || typeof request.id !== "string" || typeof request.calendar !== "string") return c.json(INVALID_REQUEST, 400);
  const body = insertBody(request);
  if (!body) return c.json(INVALID_REQUEST, 400);

  let echoed: Record<string, unknown>;
  try {
    echoed = await withGoogleDeadline((signal) =>
      postGoogleJson(
        `/calendar/v3/calendars/${encodeURIComponent(request.calendar)}/events`,
        new URLSearchParams({ fields: INSERT_FIELDS }),
        body,
        token,
        signal,
      ),
    );
  } catch (error) {
    const failure = error instanceof GoogleFailure ? error : new GoogleFailure("fetch_failed");
    if (failure.reason === "duplicate") {
      console.warn("google-create: event id already exists; answered as added");
      return c.json({ id: request.id, created: false }, 200);
    }
    // Only fixed text and a code: never the token, the calendar id, the title or the times.
    console.warn(`google-create: failed: ${failure.code}${failure.reason ? ` (${failure.reason})` : ""}`);
    switch (failure.code) {
      case "auth":
        return c.json(GOOGLE_AUTH, 401);
      case "forbidden":
        return failure.reason === "insufficient_scope" ? c.json(INSUFFICIENT_SCOPE, 403) : c.json(FORBIDDEN, 403);
      case "not_found":
        return c.json(NOT_FOUND, 404);
      case "rate_limited":
        return c.json(RATE_LIMITED, 429);
      case "timeout":
        return c.json(TIMEOUT, 502);
      default:
        return c.json(FETCH_FAILED, 502);
    }
  }

  // Google answered 2xx: the event exists. Its echo is placed like a read
  // event; one that cannot be read still answers success, without `event`.
  const stored = storedEventOf(echoed);
  if (stored === null || stored === "cancelled") {
    console.warn("google-create: added, but the answer could not be read");
    return c.json({ id: request.id, created: true }, 200);
  }
  return c.json({ id: request.id, created: true, event: { calendar: 0, ...placeEvent(stored, request.timezone) } }, 200);
});
