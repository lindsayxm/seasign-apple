import { FeedParseError, MAX_SOURCE, parseFeed, type ParsedFeed } from "./feed-parse.ts";
import { articleLinks, scanPage, type PageScan } from "./page-links.ts";
import { SafeFetchError, parseSafeUrl, safeFetch, type SafeFetchResult } from "./safe-fetch.ts";
import { clip } from "./text.ts";

// Reading one followed site: fetch its feed or its page, turn it into items,
// and remember them in KV. Shared by /v1/sites/resolve and /v1/feed.
//
// A site's address is not a credential the way a calendar link is, but the
// same discipline holds: it is never logged or put in an error, and KV keys
// are hashes. Sites are named by their index in the request.

export const SITE_TTL = 60 * 30;
export const SEEN_TTL = 60 * 60 * 24 * 30;
export const WINDOW_SECONDS = 60 * 60 * 24 * 7;
/** A date this far ahead of the clock is not believed; the item is left out. */
export const MAX_FUTURE_SECONDS = 60 * 60 * 24;
export const MAX_ITEMS_PER_SITE = 30;
export const MAX_URL_LENGTH = 2048;
export const MAX_PAGE_BYTES = 2 * 1024 * 1024;
export const MAX_FEED_BYTES = 2 * 1024 * 1024;
/** Links remembered per site in the first-seen record. */
export const MAX_SEEN = 600;

export const FEED_ACCEPT = "application/rss+xml, application/atom+xml, application/rdf+xml, application/xml;q=0.9, text/xml;q=0.9, */*;q=0.5";
export const PAGE_ACCEPT = "text/html, application/xhtml+xml;q=0.9, */*;q=0.5";

export const SITE_ERRORS = ["invalid_url", "blocked_host", "fetch_failed", "timeout", "too_large", "not_feed", "not_html"] as const;
export type SiteErrorCode = (typeof SITE_ERRORS)[number];

export class SiteFailure extends Error {
  readonly code: SiteErrorCode;
  constructor(code: SiteErrorCode) {
    super(code);
    this.code = code;
  }
}

/** The fixed code for anything thrown while reading a site. Never the error's own text. */
export function siteErrorCode(error: unknown): SiteErrorCode {
  if (error instanceof SiteFailure) return error.code;
  if (error instanceof FeedParseError) return "not_feed";
  if (error instanceof SafeFetchError) {
    switch (error.code) {
      case "invalid_url":
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

/** A user-supplied address, checked. Throws `SiteFailure` (`invalid_url` or `blocked_host`). */
export function checkedUrl(input: string): URL {
  if (input.length > MAX_URL_LENGTH) throw new SiteFailure("invalid_url");
  try {
    return parseSafeUrl(input);
  } catch (error) {
    throw new SiteFailure(siteErrorCode(error));
  }
}

export const isJsonContentType = (value: string | undefined) =>
  /^application\/([a-z0-9.+-]+\+)?json\s*(;|$)/i.test((value ?? "").trim());

// ---------------------------------------------------------------------------
// Keys

async function sha256Hex(text: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text));
  return [...new Uint8Array(digest)].map((byte) => byte.toString(16).padStart(2, "0")).join("");
}

export type SiteMode = "feed" | "links";

/** What a site is read from. In feed mode the items come from `feedUrl`, so it is part of the identity. */
export type SiteSource = { url: URL; mode: "links" } | { url: URL; mode: "feed"; feedUrl: URL };

/**
 * SHA-256 of the checked page URL, the mode and, in feed mode, the checked
 * feed URL. The feed URL has to be in it: the endpoint is open, and a key
 * made of page URL and mode alone would let anyone store another feed's items
 * under a well-known page.
 */
const siteHash = (site: SiteSource) =>
  sha256Hex(JSON.stringify([site.mode, site.url.href, site.mode === "feed" ? site.feedUrl.href : null]));

/** KV key of a site's items. Holds no part of any URL. Exported for the tests. */
export const siteCacheKey = async (site: SiteSource) => `feed:site:v1:${await siteHash(site)}`;
/** KV key of a links-mode site's first-seen record. Exported for the tests. */
export const seenCacheKey = async (site: SiteSource) => `feed:seen:v1:${await siteHash(site)}`;

/** The first 16 hex digits of a link's SHA-256: how the first-seen record names a link. */
export const linkHash = async (link: string) => (await sha256Hex(link)).slice(0, 16);

// ---------------------------------------------------------------------------
// Bodies

/** The `charset` of a Content-Type, a byte-order mark, or the encoding an XML declaration names; UTF-8 otherwise. */
export function decodeBody(body: Uint8Array, contentType: string | null): string {
  let label = /charset\s*=\s*"?([A-Za-z0-9._:-]{1,40})/i.exec((contentType ?? "").slice(0, 200))?.[1];
  if (body[0] === 0xff && body[1] === 0xfe) label = "utf-16le";
  else if (body[0] === 0xfe && body[1] === 0xff) label = "utf-16be";
  else if (!label) {
    const head = String.fromCharCode(...body.subarray(0, 120));
    label = /^\s*<\?xml[^>]{0,80}encoding\s*=\s*["']([A-Za-z0-9._:-]{1,40})["']/.exec(head)?.[1];
  }
  if (label) {
    try {
      return new TextDecoder(label).decode(body);
    } catch {
      // An encoding this runtime does not know: read it as UTF-8.
    }
  }
  return new TextDecoder().decode(body);
}

export type BodyKind = "feed" | "html" | "other";

/**
 * What a response is, by its first element when that is telling (feeds are
 * often served as text/html, and HTML as text/plain), otherwise by its
 * Content-Type.
 */
export function bodyKind(body: Uint8Array, contentType: string | null): BodyKind {
  const type = (contentType ?? "").split(";", 1)[0]?.trim().toLowerCase() ?? "";
  const head = decodeBody(body.subarray(0, 4096), contentType).toLowerCase();
  // The first "<" followed by a letter starts the root element, past any
  // declaration, comment or DOCTYPE.
  let root = "";
  for (let at = head.indexOf("<"); at >= 0; at = head.indexOf("<", at + 1)) {
    if (head.startsWith("<!doctype html", at)) {
      root = "html";
      break;
    }
    const c = head.charCodeAt(at + 1);
    if (c >= 97 && c <= 122) {
      let end = at + 1;
      while (end < head.length && end - at < 16 && !" \t\r\n>/".includes(head[end] as string)) end += 1;
      root = head.slice(at + 1, end);
      break;
    }
  }
  if (root === "rss" || root === "feed" || root === "rdf:rdf" || root === "atom:feed") return "feed";
  if (type.includes("html") || root === "html" || root === "head" || root === "body") return "html";
  if (type.endsWith("xml")) return "feed";
  if ((type === "" || type === "text/plain") && root !== "") return "html";
  return "other";
}

const hostName = (url: URL) => url.hostname.replace(/^www\./, "");

// ---------------------------------------------------------------------------
// Items

export type DateSource = "published" | "first_seen" | "none";

export type StoredItem = {
  title: string;
  link: string;
  /** Unix seconds. Null only with `dateSource: "none"`. */
  published: number | null;
  dateSource: DateSource;
  excerpt: string | null;
};

/** What is cached for a site. The page and feed addresses are not in it; the items' own links are. */
export type StoredSite = { version: 1; source: string; items: StoredItem[] };

/** Dated items inside the window, newest first, then undated ones in their own order. */
export function inWindow(items: StoredItem[], now: number): StoredItem[] {
  const dated = items.filter(
    (item) => item.published !== null && item.published >= now - WINDOW_SECONDS && item.published <= now + MAX_FUTURE_SECONDS,
  );
  dated.sort((a, b) => (b.published as number) - (a.published as number));
  return [...dated, ...items.filter((item) => item.published === null)];
}

function feedItems(feed: ParsedFeed, now: number): StoredItem[] {
  const seen = new Set<string>();
  const items: StoredItem[] = [];
  for (const item of feed.items) {
    if (seen.has(item.link)) continue;
    seen.add(item.link);
    items.push({
      title: item.title,
      link: item.link,
      // A date a little ahead of the clock (a wrong time zone) counts as now,
      // so the item cannot sit above everything else for hours.
      published: item.published !== null && item.published <= now + MAX_FUTURE_SECONDS ? Math.min(item.published, now) : item.published,
      dateSource: item.published === null ? "none" : "published",
      excerpt: item.excerpt,
    });
  }
  return inWindow(items, now).slice(0, MAX_ITEMS_PER_SITE);
}

type SeenRecord = { version: 1; seen: Record<string, number> };

/**
 * Gives every link without a date of its own the time this Worker first saw
 * it, and writes the record back.
 *
 * The record is one KV value per site: link hash to first-seen Unix seconds.
 * A link on the page keeps its entry for as long as it stays there, so an
 * article that sits on a section page for a month does not come back as new;
 * entries for links no longer on the page are dropped after 30 days, oldest
 * first beyond MAX_SEEN. Two requests reading the same site at once can each
 * write the record; the later write wins and at worst a link's first-seen
 * time moves by the gap between them.
 */
async function withFirstSeen(
  links: { title: string; link: string; published: number | null }[],
  key: string,
  cache: KVNamespace,
  now: number,
): Promise<StoredItem[]> {
  let previous: Record<string, number> = {};
  try {
    const stored = await cache.get<SeenRecord>(key, "json");
    if (stored?.version === 1 && typeof stored.seen === "object" && stored.seen !== null) previous = stored.seen;
  } catch {
    // Without the record every link counts as seen now.
  }

  const next: Record<string, number> = {};
  const items: StoredItem[] = [];
  for (const link of links) {
    const hash = await linkHash(link.link);
    const before = Object.hasOwn(previous, hash) ? previous[hash] : undefined;
    const first = typeof before === "number" && before <= now ? before : now;
    next[hash] = first;
    items.push(
      link.published !== null && link.published <= now + MAX_FUTURE_SECONDS
        ? { title: link.title, link: link.link, published: Math.min(link.published, now), dateSource: "published", excerpt: null }
        : { title: link.title, link: link.link, published: first, dateSource: "first_seen", excerpt: null },
    );
  }

  const gone = Object.entries(previous)
    .filter(([hash, first]) => !Object.hasOwn(next, hash) && typeof first === "number" && first >= now - SEEN_TTL && first <= now)
    .sort((a, b) => b[1] - a[1])
    .slice(0, Math.max(0, MAX_SEEN - links.length));
  for (const [hash, first] of gone) next[hash] = first;

  try {
    await cache.put(key, JSON.stringify({ version: 1, seen: next } satisfies SeenRecord), { expirationTtl: SEEN_TTL });
  } catch {
    console.warn("feed: first-seen write failed");
  }
  return items;
}

// ---------------------------------------------------------------------------
// Reading

export type ReadOptions = { timeoutMs: number };

export async function fetchFeed(feedUrl: URL, options: ReadOptions): Promise<{ feed: ParsedFeed; response: SafeFetchResult }> {
  const response = await safeFetch(feedUrl, { timeoutMs: options.timeoutMs, maxBytes: MAX_FEED_BYTES, accept: FEED_ACCEPT });
  const contentType = response.headers.get("content-type");
  return { feed: parseFeed(decodeBody(response.body, contentType), response.url), response };
}

export async function fetchPage(pageUrl: URL, options: ReadOptions): Promise<{ kind: BodyKind; response: SafeFetchResult }> {
  const response = await safeFetch(pageUrl, { timeoutMs: options.timeoutMs, maxBytes: MAX_PAGE_BYTES, accept: PAGE_ACCEPT });
  return { kind: bodyKind(response.body, response.headers.get("content-type")), response };
}

/** The name shown for a page: its site name, its title, or its host. */
export function pageSource(scan: PageScan, pageUrl: URL): string {
  return clip(scan.siteName ?? scan.title ?? hostName(pageUrl), MAX_SOURCE);
}

/**
 * Fetches a site and returns what is cached for it: at most
 * MAX_ITEMS_PER_SITE items, dated ones inside the 7-day window at the time of
 * the fetch. Throws `SafeFetchError`, `FeedParseError` or `SiteFailure`.
 */
export async function readSite(site: SiteSource, cache: KVNamespace, now: number, options: ReadOptions): Promise<StoredSite> {
  if (site.mode === "feed") {
    const { feed } = await fetchFeed(site.feedUrl, options);
    return { version: 1, source: clip(feed.title ?? hostName(site.url), MAX_SOURCE), items: feedItems(feed, now) };
  }

  const { kind, response } = await fetchPage(site.url, options);
  if (kind !== "html") throw new SiteFailure("not_html");
  const scan = await scanPage(response.body, response.headers.get("content-type"));
  const links = articleLinks(scan, site.url, response.url);
  const items = await withFirstSeen(links, await seenCacheKey(site), cache, now);
  return { version: 1, source: pageSource(scan, site.url), items: inWindow(items, now).slice(0, MAX_ITEMS_PER_SITE) };
}

/** A cached site, when the value has the expected shape. */
export function asStoredSite(value: unknown): StoredSite | null {
  const site = value as Partial<StoredSite> | null;
  return site?.version === 1 && typeof site.source === "string" && Array.isArray(site.items) ? (site as StoredSite) : null;
}
