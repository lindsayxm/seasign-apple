import { OpenAPIHono, createRoute, z } from "@hono/zod-openapi";
import { HTTPException } from "hono/http-exception";
import { parseFeed } from "../lib/feed-parse.ts";
import { articleLinks, feedCandidates, isSiteRoot, scanPage } from "../lib/page-links.ts";
import {
  MAX_FEED_BYTES,
  SITE_ERRORS,
  SiteFailure,
  checkedUrl,
  decodeBody,
  fetchFeed,
  fetchPage,
  isJsonContentType,
  siteErrorCode,
} from "../lib/site-reader.ts";
import { retryAfterHeader } from "../lib/rate-limit.ts";
import { clip, wellFormed } from "../lib/text.ts";

// The address the user typed is never logged and never put in an error. The
// answer carries the checked address back to the client that sent it, nothing
// else does.

const PAGE_TIMEOUT_MS = 8000;
/** Time for checking the advertised feeds, all of them together. */
const FEED_CHECK_BUDGET_MS = 6000;
/** Advertised feeds that are tried before settling for the page's links. */
const MAX_FEEDS_CHECKED = 2;
const MAX_TITLE = 120;

const SiteResolveRequestSchema = z
  .object({
    url: z.string().openapi({
      description: "The page the user wants to follow, as typed: a section page of a site, a blog's front page, or a feed. https only",
      example: "https://news.example.com/science/",
    }),
  })
  .openapi("SiteResolveRequest");

const SiteResolveSchema = z
  .object({
    ok: z.boolean().openapi({ description: "True when the page was read. The other fields are present only then, `error` only otherwise" }),
    error: z.enum(SITE_ERRORS).optional().openapi({
      description:
        "Why the page could not be read: invalid_url (not an https address), blocked_host (a private or local address), fetch_failed (unreachable or an error status), timeout, too_large, not_html (neither a web page nor a feed), not_feed (XML that is not RSS or Atom)",
    }),
    title: z.string().optional().openapi({ description: "The page's title, or the feed's when the address is a feed", example: "Science | Example News" }),
    url: z.string().optional().openapi({
      description: "The address in normal form. Store this and send it to /v1/feed",
      example: "https://news.example.com/science/",
    }),
    mode: z.enum(["feed", "links"]).optional().openapi({
      description:
        "How the site is followed: feed (an RSS or Atom feed, `feedUrl`) or links (article links read from the page itself). A section page that advertises only a feed for the whole site is followed by its links, so that the user gets the section they asked for",
    }),
    feedUrl: z.string().optional().openapi({
      description: "Only with mode feed: the feed the page advertises, or the address itself when it is a feed",
      example: "https://news.example.com/science/feed/",
    }),
    linkCount: z.number().int().optional().openapi({
      description:
        "How many article links the page itself shows right now, at most 200. Present when the address is a web page, absent when it is a feed. With mode links and 0, following this page will give nothing: tell the user",
      example: 24,
    }),
  })
  .openapi("SiteResolve");

const ErrorSchema = z
  .object({
    error: z.enum(["invalid_request", "rate_limited", "internal_error"]).openapi({ description: "Machine-readable reason" }),
    message: z.string().openapi({ description: "Human-readable explanation" }),
  })
  .openapi("SitesError");

const postSitesResolve = createRoute({
  method: "post",
  path: "/v1/sites/resolve",
  operationId: "postSitesResolve",
  summary: "How to follow a page: its feed, or its own links",
  request: {
    body: { required: true, content: { "application/json": { schema: SiteResolveRequestSchema } } },
  },
  responses: {
    200: {
      description: "The page's title and how to follow it, or why it could not be read",
      content: { "application/json": { schema: SiteResolveSchema } },
    },
    400: {
      description: "The body is not JSON, is not sent as application/json, or has no url string",
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

const INVALID_REQUEST = { error: "invalid_request" as const, message: "Send the address of one page as url" };

export const sites = new OpenAPIHono<{ Bindings: CloudflareBindings }>({
  // A fixed message: the validator's own report could quote the body.
  defaultHook: (result, c) => {
    if (!result.success) return c.json(INVALID_REQUEST, 400);
  },
});

sites.onError((error, c) => {
  if (error instanceof HTTPException && (error.status === 400 || error.status === 415)) {
    return c.json(INVALID_REQUEST, 400);
  }
  console.error("sites: unexpected error");
  return c.json({ error: "internal_error" as const, message: "Something went wrong" }, 500);
});

type Resolved = { title: string; url: string; mode: "feed" | "links"; feedUrl?: string; linkCount?: number };

const hostName = (url: URL) => url.hostname.replace(/^www\./, "");

async function resolve(input: string): Promise<Resolved> {
  const url = checkedUrl(input);
  const { kind, response } = await fetchPage(url, { timeoutMs: PAGE_TIMEOUT_MS });
  const contentType = response.headers.get("content-type");

  if (kind === "feed") {
    // The address is itself a feed. It was fetched as a page, so the feed limit is applied here.
    if (response.body.length > MAX_FEED_BYTES) throw new SiteFailure("too_large");
    const feed = parseFeed(decodeBody(response.body, contentType), response.url);
    return { title: wellFormed(clip(feed.title ?? hostName(url), MAX_TITLE)), url: url.href, mode: "feed", feedUrl: url.href };
  }
  if (kind !== "html") throw new SiteFailure("not_html");

  const scan = await scanPage(response.body, contentType);
  const title = wellFormed(clip(scan.title ?? scan.siteName ?? hostName(url), MAX_TITLE));
  const linkCount = articleLinks(scan, url, response.url).length;

  // Which advertised feeds are worth asking for. A feed whose address starts
  // with the page's own first path segment (`/science/feed/` for `/science/`)
  // is the page's feed. One that shares nothing with a page below the site's
  // root is most likely the feed of the whole site: following a section
  // through it would bring in every section, so the page's own links are
  // preferred, as long as it has any.
  const candidates = feedCandidates(scan, response.url);
  const own = candidates.filter((candidate) => candidate.shared > 0);
  const wanted = isSiteRoot(response.url) || linkCount === 0 ? candidates : own;

  // An advertised feed is used only if it answers with a feed now: pages
  // advertise feeds that are gone or broken. Each candidate passed the
  // safe-URL check in `feedCandidates`, and `fetchFeed` checks it and every
  // redirect again.
  const started = performance.now();
  for (const candidate of wanted.slice(0, MAX_FEEDS_CHECKED)) {
    const remaining = FEED_CHECK_BUDGET_MS - (performance.now() - started);
    if (remaining < 250) break;
    try {
      await fetchFeed(new URL(candidate.url), { timeoutMs: remaining });
      return { title, url: url.href, mode: "feed", feedUrl: candidate.url, linkCount };
    } catch {
      // Try the next one, or fall back to the page's links.
    }
  }
  return { title, url: url.href, mode: "links", linkCount };
}

sites.openapi(postSitesResolve, async (c) => {
  // The validator only runs for a JSON content type; anything else is refused the same way as a bad body.
  if (!isJsonContentType(c.req.header("content-type"))) return c.json(INVALID_REQUEST, 400);
  const body = c.req.valid("json") as Partial<z.infer<typeof SiteResolveRequestSchema>> | undefined;
  if (!body || typeof body.url !== "string") return c.json(INVALID_REQUEST, 400);

  try {
    return c.json({ ok: true, ...(await resolve(body.url)) }, 200);
  } catch (error) {
    // Only the code: an error's own text could hold a piece of the address or of the page.
    const code = siteErrorCode(error);
    console.warn(`sites: resolve failed: ${code}`);
    return c.json({ ok: false, error: code }, 200);
  }
});
