import { OpenAPIHono, createRoute, z } from "@hono/zod-openapi";
import { HTTPException } from "hono/http-exception";
import {
  CalendarParseError,
  CalendarTooLargeError,
  MAX_CALENDAR_BYTES,
  isTimeZone,
  parseCalendar,
  upcomingEvents,
  type ParsedCalendar,
  type UpcomingEvent,
} from "../lib/calendar.ts";
import { retryAfterHeader } from "../lib/rate-limit.ts";
import { SafeFetchError, parseSafeUrl, safeFetch } from "../lib/safe-fetch.ts";

// A calendar link is a credential: whoever holds a Google "secret address"
// can read the calendar. So in this file a link is never logged, never put in
// a response or an error message, and never stored. Calendars are named by
// their position in the request, and the KV key is a hash of the link.

// One minute, KV's shortest expirationTtl: an event added to a calendar shows
// within about a minute. The app asks about once a minute while Today is open.
const CALENDAR_TTL = 60;
const MAX_LINKS = 10;
const MAX_EVENTS = 50;
const MAX_LINK_LENGTH = 2048;

/** KV key of a calendar's parsed events: SHA-256 of the checked link. Exported for the tests. */
export async function calendarCacheKey(link: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(parseSafeUrl(link).href));
  const hex = [...new Uint8Array(digest)].map((byte) => byte.toString(16).padStart(2, "0")).join("");
  return `cal:v1:${hex}`;
}

const CALENDAR_ERRORS = ["invalid_link", "blocked_host", "fetch_failed", "timeout", "too_large", "not_calendar"] as const;
type CalendarErrorCode = (typeof CALENDAR_ERRORS)[number];

const instant = (description: string) =>
  z.string().openapi({ format: "date-time", description, example: "2026-11-16T15:00:00Z" });

const CalendarEventsRequestSchema = z
  .object({
    links: z
      .array(z.string())
      .min(1)
      .max(MAX_LINKS)
      .openapi({
        description:
          "Calendar links as the user pasted them: a Google \"Secret address in iCal format\", an iCloud published calendar (webcal://), or an Outlook published .ics link. https only; webcal:// is read as https://",
        example: ["https://calendar.example.com/private/calendar.ics"],
      }),
    timezone: z
      .string()
      .refine(isTimeZone)
      .optional()
      .openapi({
        description:
          "IANA time zone of the device. Decides when all-day events and events without a time zone start and end. Defaults to UTC",
        example: "America/New_York",
      }),
  })
  .openapi("CalendarEventsRequest");

/** Shared with routes/google.ts, so clients get one event type. */
export const CalendarEventSchema = z
  .object({
    calendar: z.number().int().openapi({
      description: "Index in the request of the calendar this event came from: of the link for /v1/calendar/events, of the calendar id for /v1/google/events",
      example: 0,
    }),
    title: z.string().openapi({ description: "The event's summary; empty when it has none", example: "Dentist" }),
    start: instant("Start as a UTC instant. For an all-day event, midnight at the start of `date` in the request's time zone"),
    end: instant("End as a UTC instant. Equal to `start` for an event without a length"),
    allDay: z.boolean().openapi({ description: "True for an event that covers whole days" }),
    date: z.string().optional().openapi({
      description: "Only for all-day events: the local date the event starts on, YYYY-MM-DD",
      example: "2026-11-16",
    }),
  })
  .openapi("CalendarEvent");

const CalendarStatusSchema = z
  .object({
    index: z.number().int().openapi({ description: "Index of the link in the request", example: 0 }),
    ok: z.boolean().openapi({ description: "True when the calendar was read" }),
    partial: z.boolean().openapi({
      description:
        "True when the calendar was read but some of it was left out: an event with a repeat rule that is malformed or not supported, an event that could not be read, or a calendar too large to read in full. Always false when `ok` is false",
    }),
    error: z.enum(CALENDAR_ERRORS).optional().openapi({
      description:
        "Why the calendar could not be read: invalid_link (not an https link), blocked_host (a private or local address), fetch_failed (unreachable or an error status), timeout, too_large, not_calendar (the link did not return an iCalendar file)",
    }),
  })
  .openapi("CalendarStatus");

const CalendarEventsSchema = z
  .object({
    events: z.array(CalendarEventSchema).openapi({
      description: "Events that have not ended and start within the next 7 days, soonest first, at most 50",
    }),
    calendars: z.array(CalendarStatusSchema).openapi({ description: "One entry per link, in request order" }),
  })
  .openapi("CalendarEvents");

const ErrorSchema = z
  .object({
    error: z.enum(["invalid_request", "rate_limited", "internal_error"]).openapi({ description: "Machine-readable reason" }),
    message: z.string().openapi({ description: "Human-readable explanation" }),
  })
  .openapi("CalendarError");

const postCalendarEvents = createRoute({
  method: "post",
  path: "/v1/calendar/events",
  operationId: "postCalendarEvents",
  summary: "Upcoming events from the user's calendar links",
  request: {
    body: { required: true, content: { "application/json": { schema: CalendarEventsRequestSchema } } },
  },
  responses: {
    200: {
      description: "Upcoming events from the calendars that could be read, and the state of each link",
      content: { "application/json": { schema: CalendarEventsSchema } },
    },
    400: {
      description:
        "The body is not JSON or is not sent as application/json, has no links or more than 10, or names an unknown time zone",
      content: { "application/json": { schema: ErrorSchema } },
    },
    429: {
      description: "rate_limited: too many requests from this network; wait Retry-After seconds",
      headers: retryAfterHeader(true),
      content: { "application/json": { schema: ErrorSchema } },
    },
    500: {
      description: "Something went wrong in the API; the body says nothing more",
      content: { "application/json": { schema: ErrorSchema } },
    },
  },
});

const INVALID_REQUEST = {
  error: "invalid_request" as const,
  message: "Send 1 to 10 calendar links and, optionally, an IANA time zone",
};

export const calendar = new OpenAPIHono<{ Bindings: CloudflareBindings }>({
  // A fixed message: the validator's own report could quote the body.
  defaultHook: (result, c) => {
    if (!result.success) return c.json(INVALID_REQUEST, 400);
  },
});

// Two failures happen before validation and are answered the same way as a
// bad body: JSON that does not parse (the framework's 400) and a body sent as
// anything but application/json, or with no Content-Type (its 415). Anything
// else is a bug here: report it without the error's own text, which could
// quote a link.
calendar.onError((error, c) => {
  if (error instanceof HTTPException && (error.status === 400 || error.status === 415)) {
    return c.json(INVALID_REQUEST, 400);
  }
  console.error("calendar: unexpected error");
  return c.json({ error: "internal_error" as const, message: "Something went wrong" }, 500);
});

class CalendarFailure extends Error {
  readonly code: CalendarErrorCode;
  constructor(code: CalendarErrorCode) {
    super(code);
    this.code = code;
  }
}

function failureCode(error: unknown): CalendarErrorCode {
  if (error instanceof CalendarFailure) return error.code;
  // Before its parent class: a calendar with more in it than is read is too large, not "not a calendar".
  if (error instanceof CalendarTooLargeError) return "too_large";
  if (error instanceof CalendarParseError) return "not_calendar";
  if (error instanceof SafeFetchError) {
    switch (error.code) {
      case "invalid_url":
        return "invalid_link";
      case "blocked_host":
      case "timeout":
      case "too_large":
        return error.code;
      default:
        return "fetch_failed";
    }
  }
  return "fetch_failed";
}

/** What is cached: occurrences around the time of the fetch. Holds nothing of the link. */
type CachedCalendar = { version: 1 } & ParsedCalendar;

/**
 * Fetches and parses one calendar. A function of its own so that the fetched
 * body (up to MAX_CALENDAR_BYTES) is let go when it returns, not held by the
 * caller's suspended frame while the result is written to the cache.
 */
async function fetchCalendar(link: string, now: Date): Promise<ParsedCalendar> {
  const response = await safeFetch(link, { accept: "text/calendar, text/plain;q=0.9, */*;q=0.5", maxBytes: MAX_CALENDAR_BYTES });
  // Decoding and parsing are one synchronous step, so however many links a
  // request fetches at once, one parse at a time is in memory; what adds up
  // is the fetched bodies, each at most MAX_CALENDAR_BYTES (memory/architecture.md).
  return parseCalendar(new TextDecoder().decode(response.body), now);
}

async function loadCalendar(link: string, key: string, cache: KVNamespace, now: Date): Promise<ParsedCalendar> {
  const cached = await cache.get<CachedCalendar>(key, "json");
  if (cached?.version === 1 && Array.isArray(cached.events)) return cached;

  const parsed = await fetchCalendar(link, now);
  const value: CachedCalendar = { version: 1, events: parsed.events, partial: parsed.partial };
  try {
    await cache.put(key, JSON.stringify(value), { expirationTtl: CALENDAR_TTL });
  } catch {
    // The calendar was read; failing to cache it only costs the next request a fetch.
    console.warn("calendar: cache write failed");
  }
  return parsed;
}

calendar.openapi(postCalendarEvents, async (c) => {
  // The validator only runs for a JSON content type. Anything else (text/plain,
  // a form, no header at all) is refused here, the same way as a bad body.
  const contentType = c.req.header("content-type") ?? "";
  if (!/^application\/([a-z0-9.+-]+\+)?json\s*(;|$)/i.test(contentType.trim())) return c.json(INVALID_REQUEST, 400);
  const body = c.req.valid("json") as Partial<z.infer<typeof CalendarEventsRequestSchema>> | undefined;
  if (!body || !Array.isArray(body.links)) return c.json(INVALID_REQUEST, 400);
  const { links, timezone } = body;
  const now = new Date();
  const timeZone = timezone ?? "UTC";

  // A link is loaded once per request however often and in whatever spelling
  // it is sent: `webcal://x` and `https://x` have the same cache key.
  const loads = new Map<string, Promise<ParsedCalendar>>();
  const results = await Promise.all(
    links.map(async (link, index) => {
      try {
        if (link.length > MAX_LINK_LENGTH) throw new CalendarFailure("invalid_link");
        const key = await calendarCacheKey(link);
        let load = loads.get(key);
        if (!load) loads.set(key, (load = loadCalendar(link, key, c.env.CACHE, now)));
        const parsed = await load;
        return { index, partial: parsed.partial === true, events: upcomingEvents(parsed.events, now, timeZone) };
      } catch (error) {
        // Only the code: an error's own text could hold a piece of the link or of the file.
        const code = failureCode(error);
        console.warn(`calendar: link ${index} failed: ${code}`);
        return { index, partial: false, error: code };
      }
    }),
  );

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
          ? { index: result.index, ok: false, partial: false, error: result.error }
          : { index: result.index, ok: true, partial: result.partial },
      ),
    },
    200,
  );
});
