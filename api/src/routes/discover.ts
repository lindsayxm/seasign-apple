import { OpenAPIHono, createRoute, z } from "@hono/zod-openapi";
import { HTTPException } from "hono/http-exception";
import { isTimeZone } from "../lib/calendar.ts";
import { isJsonContentType } from "../lib/site-reader.ts";
import { retryAfterHeader } from "../lib/rate-limit.ts";
import { collapseSpace } from "../lib/text.ts";
import { callProvider } from "../llm/http.ts";
import { ADAPTERS } from "../llm/index.ts";
import { finalItems, holdsKeyRun, keyRuns } from "../llm/results.ts";
import { DISCOVER_ERRORS, DiscoverFailure, PROVIDERS, type DiscoverErrorCode } from "../llm/types.ts";

// The user's LLM key arrives in the X-LLM-Key header and is used for one call
// to the chosen provider's fixed host. It is never logged, stored, cached (this
// route does not touch KV at all) or echoed: every error answer is one of the
// fixed bodies below, and log lines carry only the provider and a code.

const MAX_INTERESTS = 20;
const MAX_INTEREST_CHARS = 80;
/** Bounds on the key header. Real keys are 39 to about 200 characters. */
export const MIN_KEY_LENGTH = 16;
export const MAX_KEY_LENGTH = 512;
/** Printable ASCII without spaces: every provider's keys are written this way. */
const KEY_PATTERN = /^[\x21-\x7e]+$/;

/**
 * `timezone` is an IANA zone name: `UTC`, or a name in one of the database's
 * geographic areas (`America/Chicago`, `America/Argentina/Buenos_Aires`).
 * Offsets (`+05:00`), abbreviations (`CST`), `Etc/GMT+5` and lower-case
 * spellings are refused by this shape before `isTimeZone` is asked, whatever
 * the runtime's Intl would accept. The app's rule (`SearchDay.ianaName`) sends
 * nothing outside it.
 */
const IANA_ZONE = /^(?:UTC|(?:Africa|America|Antarctica|Arctic|Asia|Atlantic|Australia|Europe|Indian|Pacific)(?:\/[A-Z][A-Za-z0-9_+-]*){1,2})$/;
export const isIanaZone = (name: string) => IANA_ZONE.test(name) && isTimeZone(name);

/** An interest as it is used: white space collapsed, controls removed; null when it is empty or too long. */
function cleanInterest(text: string): string | null {
  const clean = collapseSpace(text);
  const length = [...clean].length;
  return length >= 1 && length <= MAX_INTEREST_CHARS ? clean : null;
}

const DiscoverHeadersSchema = z.object({
  "x-llm-key": z
    .string()
    .min(MIN_KEY_LENGTH)
    .max(MAX_KEY_LENGTH)
    .regex(KEY_PATTERN)
    .openapi({
      description:
        "The user's own API key for the chosen provider, from the device's Keychain. Used for this one call and never stored or logged. 16 to 512 printable ASCII characters, no spaces",
      example: "example-key-not-real-0000",
    }),
});

const DiscoverRequestSchema = z
  .object({
    provider: z.enum(PROVIDERS).openapi({ description: "Whose API the key is for" }),
    interests: z
      .array(z.string().max(400).refine((text) => cleanInterest(text) !== null))
      .min(1)
      .max(MAX_INTERESTS)
      .openapi({
        description: "Topics to find recent publications on: 1 to 20, each 1 to 80 characters after trimming",
        example: ["tide pools", "new telescopes"],
      }),
    timezone: z
      .string()
      .refine(isIanaZone)
      .optional()
      .openapi({
        description:
          "IANA time zone name of the device (`UTC`, or Area/Location such as America/Chicago); sets what \"today\" is. Offsets such as +05:00 and abbreviations such as CST are refused. Defaults to UTC",
        example: "America/Chicago",
      }),
  })
  .openapi("DiscoverRequest");

const DiscoverItemSchema = z
  .object({
    title: z.string().openapi({ description: "Headline as plain text, at most 300 characters", example: "A new telescope sees first light" }),
    link: z.string().openapi({
      description: "The page's address as the provider's search returned it: an absolute https URL",
      example: "https://news.example.com/science/new-telescope-first-light/",
    }),
    source: z.string().openapi({ description: "Publication or site name, at most 120 characters; the host name when none is given", example: "Example News" }),
    published: z.string().nullable().openapi({
      format: "date-time",
      description: "When it was published, as a UTC instant at second precision; null when unknown. Never in the future",
      example: "2026-11-14T00:00:00Z",
    }),
    excerpt: z.string().nullable().openapi({
      description: "One sentence on what it is about, written by the model, at most 300 characters; null when it gave none",
      example: "The observatory released its first images on Friday.",
    }),
    interest: z.string().nullable().openapi({ description: "Which of the request's interests it matched, as sent; null when unclear", example: "new telescopes" }),
  })
  .openapi("DiscoverItem");

const DiscoverSchema = z
  .object({
    items: z.array(DiscoverItemSchema).openapi({
      description:
        "Recent publications found by the provider's web search, at most 20, each link once. Only pages the provider's own search results or citations include are returned; may be empty",
    }),
    provider: z.enum(PROVIDERS).openapi({ description: "The provider that was asked" }),
    searchedAt: z.string().openapi({ format: "date-time", description: "When the search was answered, UTC, second precision", example: "2026-11-15T14:00:00Z" }),
  })
  .openapi("Discover");

const ERROR_CODES = ["invalid_request", ...DISCOVER_ERRORS, "internal_error"] as const;

const DiscoverErrorSchema = z
  .object({
    error: z.enum(ERROR_CODES).openapi({ description: "Machine-readable reason" }),
    message: z.string().openapi({ description: "Fixed human-readable text for the code; never the provider's own words" }),
  })
  .openapi("DiscoverError");

const errorResponse = (description: string) => ({ description, content: { "application/json": { schema: DiscoverErrorSchema } } });

const postDiscover = createRoute({
  method: "post",
  path: "/v1/discover",
  operationId: "postDiscover",
  summary: "Recent publications on the user's interests, found by the user's own LLM provider",
  request: {
    headers: DiscoverHeadersSchema,
    body: { required: true, content: { "application/json": { schema: DiscoverRequestSchema } } },
  },
  responses: {
    200: { description: "What the search found", content: { "application/json": { schema: DiscoverSchema } } },
    400: errorResponse(
      "invalid_request: no X-LLM-Key header or one of the wrong shape, a body that is not JSON or not sent as application/json, an unknown provider, no interests or more than 20, an interest empty or over 80 characters, or a time zone that is not a known IANA name",
    ),
    401: errorResponse("invalid_key: the provider did not accept the key"),
    402: errorResponse("quota_exceeded: the key's account has no credit or quota left with the provider; retrying will not help until it is topped up"),
    429: {
      ...errorResponse(
        "rate_limited: too many requests from this network (Retry-After gives the seconds to wait), or the provider is limiting requests for this key; try again later. The body has the same shape either way",
      ),
      headers: retryAfterHeader(false),
    },
    500: errorResponse("internal_error: something went wrong in the API"),
    502: errorResponse("provider_error: the provider failed or answered in a way that could not be read"),
    504: errorResponse("timeout: the provider took more than 25 seconds"),
  },
});

const INVALID_REQUEST = {
  error: "invalid_request" as const,
  message: "Send an X-LLM-Key header and a JSON body with provider and 1 to 20 interests of 1 to 80 characters",
};

const INTERNAL_ERROR = { error: "internal_error" as const, message: "Something went wrong" };

const FAILURES: Record<DiscoverErrorCode, { status: 401 | 402 | 429 | 502 | 504; message: string }> = {
  invalid_key: { status: 401, message: "The provider did not accept the API key" },
  quota_exceeded: { status: 402, message: "The provider says the key's account has no credit or quota left" },
  rate_limited: { status: 429, message: "The provider is limiting requests for this key; try again later" },
  provider_error: { status: 502, message: "The provider could not complete the search" },
  timeout: { status: 504, message: "The provider took too long to answer" },
};

export const discover = new OpenAPIHono<{ Bindings: CloudflareBindings }>({
  // A fixed message: the validator's report could quote the body or the key.
  defaultHook: (result, c) => {
    if (!result.success) return c.json(INVALID_REQUEST, 400);
  },
});

// JSON that does not parse and a body that is not application/json are
// answered like a bad body. Anything else is a bug: reported without its text.
discover.onError((error, c) => {
  if (error instanceof HTTPException && (error.status === 400 || error.status === 415)) return c.json(INVALID_REQUEST, 400);
  console.error("discover: unexpected error");
  return c.json(INTERNAL_ERROR, 500);
});

/** Today's date in the zone, YYYY-MM-DD. */
const dateIn = (now: Date, timeZone: string) =>
  new Intl.DateTimeFormat("en-CA", { timeZone, year: "numeric", month: "2-digit", day: "2-digit" }).format(now);

discover.openapi(postDiscover, async (c) => {
  if (!isJsonContentType(c.req.header("content-type"))) return c.json(INVALID_REQUEST, 400);
  const key = c.req.valid("header")["x-llm-key"];
  const body = c.req.valid("json") as Partial<z.infer<typeof DiscoverRequestSchema>> | undefined;
  if (!body || typeof body.provider !== "string" || !Array.isArray(body.interests)) return c.json(INVALID_REQUEST, 400);
  const adapter = ADAPTERS[body.provider];

  // Cleaned, and each one once whatever its case.
  const interests: string[] = [];
  for (const raw of body.interests) {
    const interest = cleanInterest(raw);
    if (interest === null) return c.json(INVALID_REQUEST, 400);
    if (!interests.some((known) => known.toLowerCase() === interest.toLowerCase())) interests.push(interest);
  }

  const now = new Date();
  const query = { interests, today: dateIn(now, body.timezone ?? "UTC"), timezone: body.timezone };
  c.header("cache-control", "no-store");
  try {
    const output = await callProvider(adapter, key, query);
    const nowSeconds = Math.floor(Date.now() / 1000);
    // A provider or a page could put the key, or part of it, into the model's
    // text; an item holding any 8 consecutive characters of it is not returned.
    const runs = keyRuns(key);
    const items = finalItems(output, interests, nowSeconds).filter(
      (item) => !Object.values(item).some((value) => typeof value === "string" && holdsKeyRun(value, runs)),
    );
    return c.json(
      {
        items,
        provider: adapter.id,
        searchedAt: new Date(nowSeconds * 1000).toISOString().replace(/\.\d{3}Z$/, "Z"),
      },
      200,
    );
  } catch (error) {
    // Only the provider and our code: the error's own text is never written anywhere.
    if (!(error instanceof DiscoverFailure)) {
      // Every provider and network failure is a DiscoverFailure by now, so this is a bug here.
      console.error(`discover: ${adapter.id} unexpected failure`);
      return c.json(INTERNAL_ERROR, 500);
    }
    const code: DiscoverErrorCode = error.code;
    console.warn(`discover: ${adapter.id} failed: ${code}`);
    const failure = FAILURES[code];
    return c.json({ error: code, message: failure.message }, failure.status);
  }
});
