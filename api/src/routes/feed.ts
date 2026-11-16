import { OpenAPIHono, createRoute, z } from "@hono/zod-openapi";
import { HTTPException } from "hono/http-exception";
import {
  SITE_ERRORS,
  SITE_TTL,
  SiteFailure,
  asStoredSite,
  checkedUrl,
  inWindow,
  isJsonContentType,
  readSite,
  siteCacheKey,
  siteErrorCode,
  type SiteErrorCode,
  type SiteSource,
  type StoredItem,
  type StoredSite,
} from "../lib/site-reader.ts";
import { wellFormed } from "../lib/text.ts";

// Site addresses are never logged and never put in a response or an error:
// sites are named by their index in the request, log lines carry the index
// and a code, and KV keys are hashes.

const MAX_SITES = 50;
const MAX_ITEMS = 300;
/** Sites fetched at the same time. */
const CONCURRENCY = 6;
/** Time for one site: every redirect hop plus the body. */
const SITE_TIMEOUT_MS = 6000;
/** Time for all the fetching of one request. A site not started by then is reported as `timeout`. */
const REQUEST_BUDGET_MS = 20_000;
/** A site is not started with less than this left. */
const MIN_SITE_MS = 500;

const FeedSiteSchema = z
  .object({
    url: z.string().openapi({ description: "The page the user follows, as /v1/sites/resolve returned it", example: "https://news.example.com/science/" }),
    mode: z.enum(["feed", "links"]).openapi({ description: "How the site is read, as /v1/sites/resolve returned it" }),
    feedUrl: z.string().optional().openapi({
      description: "Required with mode feed: the feed's address",
      example: "https://news.example.com/science/feed/",
    }),
  })
  .openapi("FeedSite");

const FeedRequestSchema = z
  .object({
    sites: z.array(FeedSiteSchema).min(1).max(MAX_SITES).openapi({ description: "The sites the user follows, 1 to 50" }),
  })
  .openapi("FeedRequest");

const FeedItemSchema = z
  .object({
    site: z.number().int().openapi({ description: "Index in the request of the site this item came from", example: 0 }),
    title: z.string().openapi({ description: "Headline as plain text", example: "A new telescope sees first light" }),
    link: z.string().openapi({ description: "The article's address: an absolute https URL", example: "https://news.example.com/science/new-telescope-first-light/" }),
    source: z.string().openapi({ description: "Title of the feed or of the site", example: "Example News" }),
    published: z.string().openapi({
      format: "date-time",
      description:
        "A UTC instant at second precision: when the item was published (`dateSource` published), or when this API first saw its link (first_seen)",
      example: "2026-11-15T11:42:55Z",
    }),
    dateSource: z.enum(["published", "first_seen"]).openapi({
      description:
        "Where `published` comes from: published (the feed's or the page's own date), first_seen (the site gives no readable date for this item, so it is the time this API first found the link; for a site nobody has asked for before, a day before that first fetch)",
    }),
    excerpt: z.string().nullable().openapi({
      description: "The site's own summary as plain text, about 300 characters at most; null when it gives none (always null in links mode)",
      example: "The observatory released its first images on Friday…",
    }),
  })
  .openapi("FeedItem");

const FeedSiteStatusSchema = z
  .object({
    index: z.number().int().openapi({ description: "Index of the site in the request", example: 0 }),
    ok: z.boolean().openapi({ description: "True when the site was read" }),
    error: z.enum(SITE_ERRORS).optional().openapi({
      description:
        "Why the site could not be read: invalid_url (not an https address, or mode feed without feedUrl), blocked_host (a private or local address), fetch_failed (unreachable or an error status), timeout (the site, or the request as a whole, ran out of time), too_large, not_feed (mode feed, but the address did not return RSS or Atom), not_html (mode links, but the address did not return a web page)",
    }),
  })
  .openapi("FeedSiteStatus");

const FeedSchema = z
  .object({
    items: z.array(FeedItemSchema).openapi({
      description:
        "Items of the last 7 days from the sites that could be read, newest first; at most 30 per site and 300 in all. A link appears once, under the first site that has it",
    }),
    sites: z.array(FeedSiteStatusSchema).openapi({ description: "One entry per site, in request order" }),
  })
  .openapi("Feed");

const ErrorSchema = z
  .object({
    error: z.enum(["invalid_request", "internal_error"]).openapi({ description: "Machine-readable reason" }),
    message: z.string().openapi({ description: "Human-readable explanation" }),
  })
  .openapi("FeedError");

const postFeed = createRoute({
  method: "post",
  path: "/v1/feed",
  operationId: "postFeed",
  summary: "Recent articles from the sites the user follows",
  request: {
    body: { required: true, content: { "application/json": { schema: FeedRequestSchema } } },
  },
  responses: {
    200: {
      description: "Recent items from the sites that could be read, and the state of each site",
      content: { "application/json": { schema: FeedSchema } },
    },
    400: {
      description: "The body is not JSON or is not sent as application/json, has no sites or more than 50, or a site without url or mode",
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
  message: "Send 1 to 50 sites, each with url and mode (feed or links)",
};

export const feed = new OpenAPIHono<{ Bindings: CloudflareBindings }>({
  // A fixed message: the validator's own report could quote the body.
  defaultHook: (result, c) => {
    if (!result.success) return c.json(INVALID_REQUEST, 400);
  },
});

feed.onError((error, c) => {
  if (error instanceof HTTPException && (error.status === 400 || error.status === 415)) {
    return c.json(INVALID_REQUEST, 400);
  }
  console.error("feed: unexpected error");
  return c.json({ error: "internal_error" as const, message: "Something went wrong" }, 500);
});

/** Runs the jobs at most `limit` at a time, in order. */
async function runLimited(jobs: (() => Promise<void>)[], limit: number): Promise<void> {
  let next = 0;
  const worker = async () => {
    while (next < jobs.length) await (jobs[next++] as () => Promise<void>)();
  };
  await Promise.all(Array.from({ length: Math.min(limit, jobs.length) }, worker));
}

const instantOf = (seconds: number) => new Date(seconds * 1000).toISOString().replace(/\.\d{3}Z$/, "Z");

type Outcome = { site: StoredSite } | { error: SiteErrorCode };

feed.openapi(postFeed, async (c) => {
  // The validator only runs for a JSON content type; anything else is refused the same way as a bad body.
  if (!isJsonContentType(c.req.header("content-type"))) return c.json(INVALID_REQUEST, 400);
  const body = c.req.valid("json") as Partial<z.infer<typeof FeedRequestSchema>> | undefined;
  if (!body || !Array.isArray(body.sites)) return c.json(INVALID_REQUEST, 400);
  const cache = c.env.CACHE;
  const now = Math.floor(Date.now() / 1000);

  // Check every site and find its key. A site sent twice is read once.
  const keys: (string | null)[] = [];
  const outcomes = new Map<string, Outcome>();
  const sources = new Map<string, SiteSource>();
  const refused: (SiteErrorCode | null)[] = [];
  for (const entry of body.sites) {
    try {
      const url = checkedUrl(entry.url);
      let source: SiteSource;
      if (entry.mode === "feed") {
        if (typeof entry.feedUrl !== "string") throw new SiteFailure("invalid_url");
        source = { url, mode: "feed", feedUrl: checkedUrl(entry.feedUrl) };
      } else {
        source = { url, mode: "links" };
      }
      const key = await siteCacheKey(source);
      sources.set(key, source);
      keys.push(key);
      refused.push(null);
    } catch (error) {
      keys.push(null);
      refused.push(siteErrorCode(error));
    }
  }

  // Answer from the cache where possible.
  const missing: string[] = [];
  await Promise.all(
    [...sources.keys()].map(async (key) => {
      try {
        const cached = asStoredSite(await cache.get(key, "json"));
        if (cached) {
          outcomes.set(key, { site: cached });
          return;
        }
      } catch {
        // An unreadable cache entry is a miss.
      }
      missing.push(key);
    }),
  );
  // Fetch in request order whatever order the cache answered in.
  const order = [...sources.keys()];
  missing.sort((a, b) => order.indexOf(a) - order.indexOf(b));

  // Fetch the rest, a few at a time, inside one budget for the whole request.
  // The clock is `performance.now()`: like `Date.now()` it moves on with I/O
  // in a Worker, and the tests can leave it running while they fix the date.
  const started = performance.now();
  await runLimited(
    missing.map((key) => async () => {
      try {
        const remaining = REQUEST_BUDGET_MS - (performance.now() - started);
        if (remaining < MIN_SITE_MS) throw new SiteFailure("timeout");
        const { site, cacheable } = await readSite(sources.get(key) as SiteSource, cache, now, {
          timeoutMs: Math.min(SITE_TIMEOUT_MS, remaining),
        });
        outcomes.set(key, { site });
        if (!cacheable) return;
        try {
          await cache.put(key, JSON.stringify(site), { expirationTtl: SITE_TTL });
        } catch {
          // The site was read; failing to cache it only costs the next request a fetch.
          console.warn("feed: cache write failed");
        }
      } catch (error) {
        // Failures are not cached.
        outcomes.set(key, { error: siteErrorCode(error) });
      }
    }),
    CONCURRENCY,
  );

  // Merge. The cached items were chosen at fetch time; the window is applied
  // again for this moment.
  type Item = StoredItem & { site: number; source: string; position: number };
  const items: Item[] = [];
  const links = new Set<string>();
  const statuses = body.sites.map((_entry, index) => {
    const key = keys[index];
    const outcome = key ? outcomes.get(key) : undefined;
    const error = refused[index] ?? (outcome && "error" in outcome ? outcome.error : outcome ? null : "fetch_failed");
    if (error || !outcome || !("site" in outcome)) {
      // Only the index and the code.
      console.warn(`feed: site ${index} failed: ${error}`);
      return { index, ok: false, error: error ?? ("fetch_failed" as const) };
    }
    inWindow(outcome.site.items, now).forEach((item, position) => {
      if (links.has(item.link)) return;
      links.add(item.link);
      items.push({ ...item, site: index, source: outcome.site.source, position });
    });
    return { index, ok: true };
  });

  items.sort((a, b) => b.published - a.published || a.site - b.site || a.position - b.position);

  return c.json(
    {
      items: items.slice(0, MAX_ITEMS).map((item) => ({
        site: item.site,
        // Cut and cleaned when they were read; checked once more on the way out.
        title: wellFormed(item.title),
        link: item.link,
        source: wellFormed(item.source),
        published: instantOf(item.published),
        dateSource: item.dateSource,
        excerpt: item.excerpt === null ? null : wellFormed(item.excerpt),
      })),
      sites: statuses,
    },
    200,
  );
});
