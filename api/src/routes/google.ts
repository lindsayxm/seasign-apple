import { OpenAPIHono, createRoute, z } from "@hono/zod-openapi";
import { HTTPException } from "hono/http-exception";
import {
  UPCOMING_DAYS,
  dayBounds,
  dayEvents,
  dayInRange,
  isTimeZone,
  overlapsDay,
  upcomingEvents,
  type StoredEvent,
  type UpcomingEvent,
} from "../lib/calendar.ts";
import {
  GOOGLE_ACCESS_ROLES,
  GOOGLE_EVENT_TYPES,
  GoogleFailure,
  calendarOf,
  getGoogleJson,
  storedEventOf,
  withGoogleDeadline,
  type GoogleCalendar,
  type GoogleFailureCode,
} from "../lib/google.ts";
import { retryAfterHeader } from "../lib/rate-limit.ts";
import { isJsonContentType } from "../lib/site-reader.ts";
import { CalendarEventSchema, DaySchema } from "./calendar.ts";

// Google Calendar read with the user's own OAuth access token (plan
// plans/2026-11-19-google-calendar-push.md, task A). The token arrives in the
// X-Google-Token header and is used for this request's calls to
// https://www.googleapis.com only. It is never stored, cached (these routes do
// not touch KV: the point is freshness), logged or echoed: every error answer
// is one of the fixed bodies below, and log lines carry only an index and a
// code. Calendar ids are often e-mail addresses, so they are not logged either.
// Every answer carries Cache-Control: no-store (set in app.ts, so that the
// body-limit and rate-limit answers carry it too).

export const MAX_CALENDARS = 10;
const MAX_EVENTS = 50;
export const MAX_ID_LENGTH = 512;
/** events.list page size (Google allows up to 2500) and pages read per calendar. */
const PAGE_SIZE = 250;
const MAX_PAGES = 4;
/** Occurrences kept per calendar, as for a pasted link; more in nine days (or one day) is not a personal calendar. */
const MAX_KEPT = 500;
/** calendarList.list page size (Google's maximum) and pages read. */
const LIST_PAGE_SIZE = 250;
const MAX_LIST_PAGES = 4;
const DAY = 86400;

/** Bounds on the token header. Google says access tokens are at most 2048 bytes. */
export const MIN_TOKEN_LENGTH = 16;
export const MAX_TOKEN_LENGTH = 2048;
/** RFC 6750 b64token: what a bearer token may be made of. Nothing that could break a header. */
const TOKEN_PATTERN = /^[A-Za-z0-9\-._~+/]+=*$/;
/** Printable ASCII without spaces; `.` and `..` would change the request path. */
const ID_PATTERN = /^[\x21-\x7e]+$/;
export const isCalendarId = (id: string) => ID_PATTERN.test(id) && id !== "." && id !== "..";

/** Only what is read, so that descriptions, attendees and the like never reach the Worker. */
const EVENT_FIELDS = "items(status,summary,start,end,endTimeUnspecified),nextPageToken";
const LIST_FIELDS = "items(id,summary,summaryOverride,primary,selected,backgroundColor,deleted,accessRole),nextPageToken";

export const GoogleHeadersSchema = z.object({
  "x-google-token": z
    .string()
    .min(MIN_TOKEN_LENGTH)
    .max(MAX_TOKEN_LENGTH)
    .regex(TOKEN_PATTERN)
    .openapi({
      description:
        "The user's Google OAuth access token, without \"Bearer \". Used for this request's calls to the Google Calendar API and never stored or logged. 16 to 2048 characters of the RFC 6750 token alphabet",
      example: "ya29.example-token-not-real",
    }),
});

const GoogleCalendarSchema = z
  .object({
    id: z.string().openapi({ description: "Google's calendar id; send it back in /v1/google/events", example: "user@example.com" }),
    name: z.string().openapi({ description: "The user's own name for the calendar if set, else its title; empty when it has neither", example: "Family" }),
    primary: z.boolean().openapi({ description: "True for the user's primary calendar" }),
    selected: z.boolean().openapi({ description: "True when the calendar is shown in Google Calendar's own app" }),
    color: z.string().optional().openapi({ description: "The calendar's colour in Google Calendar as #rrggbb, when Google gives one", example: "#0088aa" }),
    accessRole: z.enum(GOOGLE_ACCESS_ROLES).optional().openapi({
      description:
        "The user's access to the calendar, as Google's calendar list gives it: owner, writer and writerWithoutPrivateAccess can add events; reader sees the events; freeBusyReader sees only when the user is busy. Left out when Google gives none or another value",
      example: "owner",
    }),
  })
  .openapi("GoogleCalendar");

const GoogleCalendarsSchema = z
  .object({
    calendars: z.array(GoogleCalendarSchema).openapi({
      description: "The calendars on the user's Google calendar list, hidden and deleted ones left out, the primary calendar first, then in Google's order",
    }),
  })
  .openapi("GoogleCalendars");

const GOOGLE_CALENDAR_ERRORS = ["forbidden", "not_found", "rate_limited", "fetch_failed", "timeout", "too_large"] as const;
type GoogleCalendarErrorCode = (typeof GOOGLE_CALENDAR_ERRORS)[number];

const GoogleEventsRequestSchema = z
  .object({
    calendars: z
      .array(z.string().min(1).max(MAX_ID_LENGTH).refine(isCalendarId))
      .min(1)
      .max(MAX_CALENDARS)
      .openapi({
        description: "Google calendar ids from /v1/google/calendars (or \"primary\"): 1 to 10, each 1 to 512 printable ASCII characters",
        example: ["primary"],
      }),
    timezone: z
      .string()
      .refine(isTimeZone)
      .optional()
      .openapi({
        description: "IANA time zone of the device. Decides when all-day events start and end. Defaults to UTC",
        example: "America/New_York",
      }),
    day: DaySchema.optional(),
  })
  .openapi("GoogleEventsRequest");

const GoogleCalendarStatusSchema = z
  .object({
    index: z.number().int().openapi({ description: "Index of the calendar id in the request", example: 0 }),
    ok: z.boolean().openapi({ description: "True when the calendar was read" }),
    partial: z.boolean().openapi({
      description: "True when the calendar was read but some of it was left out: an event that could not be read, or more events than are read. Always false when `ok` is false",
    }),
    error: z.enum(GOOGLE_CALENDAR_ERRORS).optional().openapi({
      description:
        "Why the calendar could not be read: forbidden (Google refused access to it, or the token lacks the scope), not_found (no such calendar for this user), rate_limited (Google is limiting requests; try later), fetch_failed (Google unreachable, an error status or an unreadable answer), timeout, too_large",
    }),
  })
  .openapi("GoogleCalendarStatus");

const GoogleEventsSchema = z
  .object({
    events: z.array(CalendarEventSchema).openapi({
      description:
        "Events that have not ended and start within the next 7 days, soonest first, at most 50. With `day`: the events that overlap that day in `timezone`, ended ones included, in the same order and under the same cap. Cancelled events are left out",
    }),
    calendars: z.array(GoogleCalendarStatusSchema).openapi({ description: "One entry per calendar id, in request order" }),
  })
  .openapi("GoogleEvents");

const ERROR_CODES = ["invalid_request", "google_auth", "google_forbidden", "google_unavailable", "rate_limited", "internal_error"] as const;

const GoogleErrorSchema = z
  .object({
    error: z.enum(ERROR_CODES).openapi({ description: "Machine-readable reason" }),
    message: z.string().openapi({ description: "Fixed human-readable text for the code; never Google's own words" }),
  })
  .openapi("GoogleError");

const errorResponse = (description: string) => ({ description, content: { "application/json": { schema: GoogleErrorSchema } } });

const rateLimited = {
  ...errorResponse("rate_limited: too many requests from this network; wait Retry-After seconds"),
  headers: retryAfterHeader(true),
};
const googleAuth = errorResponse("google_auth: Google did not accept the token (expired or revoked). Refresh the access token and ask again");

const getGoogleCalendars = createRoute({
  method: "get",
  path: "/v1/google/calendars",
  operationId: "getGoogleCalendars",
  summary: "The user's Google calendars, read with their own access token",
  request: { headers: GoogleHeadersSchema },
  responses: {
    200: { description: "The user's calendar list", content: { "application/json": { schema: GoogleCalendarsSchema } } },
    400: errorResponse("invalid_request: no X-Google-Token header, or one of the wrong shape"),
    401: googleAuth,
    403: errorResponse(
      "google_forbidden: Google refused the calendar list for a reason other than the token being invalid, usually because the token lacks the calendar list scope. Refreshing will not help; the user must connect again",
    ),
    429: rateLimited,
    500: errorResponse("internal_error: something went wrong in the API"),
    502: errorResponse("google_unavailable: Google failed, is limiting requests, took more than 8 seconds, or answered in a way that could not be read"),
  },
});

const postGoogleEvents = createRoute({
  method: "post",
  path: "/v1/google/events",
  operationId: "postGoogleEvents",
  summary: "Upcoming events from the user's Google calendars, read with their own access token",
  request: {
    headers: GoogleHeadersSchema,
    body: { required: true, content: { "application/json": { schema: GoogleEventsRequestSchema } } },
  },
  responses: {
    200: {
      description: "Upcoming events from the calendars that could be read, and the state of each calendar",
      content: { "application/json": { schema: GoogleEventsSchema } },
    },
    400: errorResponse(
      "invalid_request: no X-Google-Token header or one of the wrong shape, a body that is not JSON or not sent as application/json, no calendar ids or more than 10, an id of the wrong shape, an unknown time zone, or a `day` that is not a date from today to six days on in the time zone",
    ),
    401: googleAuth,
    429: rateLimited,
    500: errorResponse("internal_error: something went wrong in the API"),
  },
});

const INVALID_REQUEST = {
  error: "invalid_request" as const,
  message: "Send an X-Google-Token header and, for events, a JSON body with 1 to 10 calendar ids and, optionally, an IANA time zone",
};
const INTERNAL_ERROR = { error: "internal_error" as const, message: "Something went wrong" };
const GOOGLE_AUTH = { error: "google_auth" as const, message: "Google did not accept the access token; refresh it and try again" };
const GOOGLE_FORBIDDEN = { error: "google_forbidden" as const, message: "Google refused access to the calendar list; connect Google Calendar again" };
const GOOGLE_UNAVAILABLE = { error: "google_unavailable" as const, message: "Google Calendar could not be read; try again later" };

export const google = new OpenAPIHono<{ Bindings: CloudflareBindings }>({
  // A fixed message: the validator's report could quote the body or the token.
  defaultHook: (result, c) => {
    if (!result.success) return c.json(INVALID_REQUEST, 400);
  },
});

// JSON that does not parse and a body that is not application/json are
// answered like a bad body. Anything else is a bug: reported without its text.
google.onError((error, c) => {
  if (error instanceof HTTPException && (error.status === 400 || error.status === 415)) return c.json(INVALID_REQUEST, 400);
  console.error("google: unexpected error");
  return c.json(INTERNAL_ERROR, 500);
});

// `webhook_refused` belongs to events.watch (routes/google-push.ts); on a read it can only be noise.
const failureCode = (error: unknown): GoogleFailureCode =>
  error instanceof GoogleFailure && error.code !== "webhook_refused" ? error.code : "fetch_failed";

/** RFC 3339 in UTC, second precision. */
const rfc3339 = (seconds: number) => new Date(seconds * 1000).toISOString().replace(/\.\d{3}Z$/, "Z");

/**
 * Every page of one calendar's events that end after `from` and start before
 * `to` (Unix seconds; Google's timeMin and timeMax). Recurring events come
 * expanded into their instances. With `keep`, only the events it accepts are
 * kept and counted against MAX_KEPT.
 */
async function readCalendar(
  id: string,
  token: string,
  from: number,
  to: number,
  keep?: (event: StoredEvent) => boolean,
): Promise<{ events: StoredEvent[]; partial: boolean }> {
  const path = `/calendar/v3/calendars/${encodeURIComponent(id)}/events`;
  return withGoogleDeadline(async (signal) => {
    const events: StoredEvent[] = [];
    let partial = false;
    let pageToken: string | undefined;
    for (let page = 0; ; page++) {
      if (page === MAX_PAGES) {
        partial = true;
        break;
      }
      const params = new URLSearchParams({
        singleEvents: "true",
        orderBy: "startTime",
        timeMin: rfc3339(from),
        timeMax: rfc3339(to),
        maxResults: String(PAGE_SIZE),
        fields: EVENT_FIELDS,
      });
      // Ordinary events and ones Google made from mail (flights, bookings). Working
      // location, focus time, out of office and birthdays are left out: the
      // pasted-link feed does not carry them either (task 155).
      for (const type of GOOGLE_EVENT_TYPES) params.append("eventTypes", type);
      if (pageToken) params.set("pageToken", pageToken);
      const body = await getGoogleJson(path, params, token, signal);
      // With `fields`, Google leaves `items` out of an empty page.
      if (body.items !== undefined && !Array.isArray(body.items)) throw new GoogleFailure("fetch_failed");
      for (const item of (body.items as unknown[] | undefined) ?? []) {
        const event = storedEventOf(item);
        if (event === "cancelled") continue;
        if (event === null) partial = true;
        else if (!keep || keep(event)) events.push(event);
      }
      pageToken = typeof body.nextPageToken === "string" && body.nextPageToken !== "" ? body.nextPageToken : undefined;
      if (!pageToken) break;
      if (events.length >= MAX_KEPT) {
        partial = true;
        break;
      }
    }
    // Pages come soonest first, so what is cut is the latest.
    if (events.length > MAX_KEPT) {
      events.length = MAX_KEPT;
      partial = true;
    }
    return { events, partial };
  });
}

google.openapi(getGoogleCalendars, async (c) => {
  const token = c.req.valid("header")["x-google-token"];
  let calendars: GoogleCalendar[];
  try {
    calendars = await withGoogleDeadline(async (signal) => {
      const found: GoogleCalendar[] = [];
      let pageToken: string | undefined;
      for (let page = 0; page < MAX_LIST_PAGES; page++) {
        const params = new URLSearchParams({ maxResults: String(LIST_PAGE_SIZE), fields: LIST_FIELDS });
        if (pageToken) params.set("pageToken", pageToken);
        const body = await getGoogleJson("/calendar/v3/users/me/calendarList", params, token, signal);
        if (body.items !== undefined && !Array.isArray(body.items)) throw new GoogleFailure("fetch_failed");
        for (const item of (body.items as unknown[] | undefined) ?? []) {
          const calendar = calendarOf(item);
          if (calendar) found.push(calendar);
        }
        pageToken = typeof body.nextPageToken === "string" && body.nextPageToken !== "" ? body.nextPageToken : undefined;
        if (!pageToken) break;
      }
      return found;
    });
  } catch (error) {
    const code = failureCode(error);
    console.warn(`google: calendar list failed: ${code}`);
    if (code === "auth") return c.json(GOOGLE_AUTH, 401);
    if (code === "forbidden") return c.json(GOOGLE_FORBIDDEN, 403);
    return c.json(GOOGLE_UNAVAILABLE, 502);
  }
  // A stable sort: the primary calendar first, the rest in Google's order.
  calendars.sort((a, b) => Number(b.primary) - Number(a.primary));
  return c.json({ calendars }, 200);
});

type CalendarResult = { index: number; partial: boolean; events?: UpcomingEvent[]; error?: GoogleFailureCode };

google.openapi(postGoogleEvents, async (c) => {
  if (!isJsonContentType(c.req.header("content-type"))) return c.json(INVALID_REQUEST, 400);
  const token = c.req.valid("header")["x-google-token"];
  const body = c.req.valid("json") as Partial<z.infer<typeof GoogleEventsRequestSchema>> | undefined;
  if (!body || !Array.isArray(body.calendars)) return c.json(INVALID_REQUEST, 400);
  const now = new Date();
  const timeZone = body.timezone ?? "UTC";
  const nowSeconds = Math.floor(now.getTime() / 1000);

  // Without `day`: a day before now to eight days after (the exact seven-day
  // rule is applied by `upcomingEvents`, once all-day events are placed in the
  // request's time zone, which may not be the calendar's). With `day`: that
  // day in the request's zone with a day of margin either side, since Google
  // places an all-day event in the calendar's own zone and leaves out an
  // event without a length at timeMin; only what overlaps the day is kept
  // (and counted against the cap), and `dayEvents` answers it. Checked
  // before Google is called.
  let day: number | null = null;
  let from = nowSeconds - DAY;
  let to = nowSeconds + (UPCOMING_DAYS + 1) * DAY;
  let keep: ((event: StoredEvent) => boolean) | undefined;
  if (body.day !== undefined) {
    day = dayInRange(body.day, now, timeZone);
    if (day === null) return c.json(INVALID_REQUEST, 400);
    const bounds = dayBounds(day, timeZone);
    from = bounds.from - DAY;
    to = bounds.to + DAY;
    keep = overlapsDay(day, timeZone);
  }
  const select = (events: StoredEvent[]) => (day === null ? upcomingEvents(events, now, timeZone) : dayEvents(events, day, timeZone));

  // An id sent twice is read once.
  const reads = new Map<string, Promise<{ events: StoredEvent[]; partial: boolean }>>();
  const results: CalendarResult[] = await Promise.all(
    body.calendars.map(async (id, index) => {
      try {
        let read = reads.get(id);
        if (!read) reads.set(id, (read = readCalendar(id, token, from, to, keep)));
        const { events, partial } = await read;
        return { index, partial, events: select(events) };
      } catch (error) {
        // Only the index and the code: never the id, the token or Google's words.
        const code = failureCode(error);
        console.warn(`google: calendar ${index} failed: ${code}`);
        return { index, partial: false, error: code };
      }
    }),
  );

  // One token reads every calendar: if Google refused it once, it is not valid.
  if (results.some((result) => result.error === "auth")) return c.json(GOOGLE_AUTH, 401);

  const events: (UpcomingEvent & { calendar: number })[] = [];
  for (const result of results) {
    for (const event of result.events ?? []) events.push({ calendar: result.index, ...event });
  }
  events.sort(
    (a, b) =>
      a.start.localeCompare(b.start) ||
      Number(b.allDay) - Number(a.allDay) ||
      a.calendar - b.calendar ||
      a.title.localeCompare(b.title),
  );

  return c.json(
    {
      events: events.slice(0, MAX_EVENTS),
      calendars: results.map((result) =>
        result.error
          ? { index: result.index, ok: false, partial: false, error: result.error as GoogleCalendarErrorCode }
          : { index: result.index, ok: true, partial: result.partial },
      ),
    },
    200,
  );
});
