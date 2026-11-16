import { OpenAPIHono, createRoute, z } from "@hono/zod-openapi";
import { HTTPException } from "hono/http-exception";
import { parseFeed } from "../lib/feed-parse.ts";
import { feedCandidates, scanPage } from "../lib/page-links.ts";
import {
  SITE_ERRORS,
  SiteFailure,
  checkedUrl,
  decodeBody,
  fetchFeed,
  fetchPage,
  isJsonContentType,
  siteErrorCode,
} from "../lib/site-reader.ts";
import { clip } from "../lib/text.ts";

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
      description: "How the site is followed: feed (an RSS or Atom feed, `feedUrl`) or links (article links read from the page itself)",
    }),
    feedUrl: z.string().optional().openapi({
      description: "Only with mode feed: the feed the page advertises, or the address itself when it is a feed",
      example: "https://news.example.com/science/feed/",
    }),
  })
  .openapi("SiteResolve");

const ErrorSchema = z
  .object({
    error: z.enum(["invalid_request", "internal_error"]).openapi({ description: "Machine-readable reason" }),
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

type Resolved = { title: string; url: string; mode: "feed" | "links"; feedUrl?: string };

const hostName = (url: URL) => url.hostname.replace(/^www\./, "");

async function resolve(input: string): Promise<Resolved> {
  const url = checkedUrl(input);
  const { kind, response } = await fetchPage(url, { timeoutMs: PAGE_TIMEOUT_MS });
  const contentType = response.headers.get("content-type");

  if (kind === "feed") {
    // The address is itself a feed.
    const feed = parseFeed(decodeBody(response.body, contentType), response.url);
    return { title: clip(feed.title ?? hostName(url), MAX_TITLE), url: url.href, mode: "feed", feedUrl: url.href };
  }
  if (kind !== "html") throw new SiteFailure("not_html");

  const scan = await scanPage(response.body, contentType);
  const title = clip(scan.title ?? scan.siteName ?? hostName(url), MAX_TITLE);

  // An advertised feed is used only if it answers with a feed now: pages
  // advertise feeds that are gone, empty of meaning (comments) or broken.
  // Each candidate passed the safe-URL check in `feedCandidates`, and
  // `fetchFeed` checks it and every redirect again.
  const started = performance.now();
  for (const candidate of feedCandidates(scan, response.url).slice(0, MAX_FEEDS_CHECKED)) {
    const remaining = FEED_CHECK_BUDGET_MS - (performance.now() - started);
    if (remaining < 250) break;
    try {
      await fetchFeed(new URL(candidate), { timeoutMs: remaining });
      return { title, url: url.href, mode: "feed", feedUrl: candidate };
    } catch {
      // Try the next one, or fall back to the page's links.
    }
  }
  return { title, url: url.href, mode: "links" };
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
