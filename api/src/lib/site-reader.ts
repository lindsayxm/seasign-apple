import { FeedParseError, MAX_FEED_CHARS, MAX_SOURCE, parseFeed, type ParsedFeed } from "./feed-parse.ts";
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
/** Feeds are read up to 1 MB: ordinary feeds are 20 KB to 700 KB, and the parser's memory grows with the text. */
export const MAX_FEED_BYTES = MAX_FEED_CHARS;
/** How long ago the links of a site are stamped when it is fetched for the very first time. */
export const FIRST_FETCH_AGE = 60 * 60 * 24;
/** Feed items without a readable date that are given a first-seen time. */
export const MAX_UNDATED = 100;
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
/** KV key of a site's first-seen record (a links-mode site, or a feed with undated items). Exported for the tests. */
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
  // The root element is the first thing that is not white space, a comment,
  // a processing instruction or a DOCTYPE. A comment may hold anything
  // ("<!-- <rss> -->"), so comments are stepped over, not searched.
  let root = "";
  let at = 0;
  for (;;) {
    while (at < head.length && " \t\r\n\ufeff".includes(head[at] as string)) at += 1;
    if (head.startsWith("<!--", at)) {
      const end = head.indexOf("-->", at + 4);
      if (end < 0) break;
      at = end + 3;
    } else if (head.startsWith("<?", at)) {
      const end = head.indexOf("?>", at + 2);
      if (end < 0) break;
      at = end + 2;
    } else if (head.startsWith("<!doctype html", at)) {
      root = "html";
      break;
    } else if (head.startsWith("<!", at)) {
      const end = head.indexOf(">", at + 2);
      if (end < 0) break;
      at = end + 1;
    } else {
      const c = head.charCodeAt(at + 1);
      if (head[at] === "<" && c >= 97 && c <= 122) {
        let end = at + 1;
        while (end < head.length && end - at < 16 && !" \t\r\n>/".includes(head[end] as string)) end += 1;
        root = head.slice(at + 1, end);
      } else if (at < head.length) {
        // Text before any element: neither XML nor a page that starts as one.
        root = "#text";
      }
      break;
    }
  }
  if (root === "rss" || root === "feed" || root === "rdf:rdf" || root === "atom:feed") return "feed";
  if (type.includes("html") || root === "html" || root === "head" || root === "body") return "html";
  if (type.endsWith("xml")) return "feed";
  if ((type === "" || type === "text/plain") && root !== "" && root !== "#text") return "html";
  return "other";
}

const hostName = (url: URL) => url.hostname.replace(/^www\./, "");

// ---------------------------------------------------------------------------
// Items

export type DateSource = "published" | "first_seen";

export type StoredItem = {
  title: string;
  link: string;
  /** Unix seconds. */
  published: number;
  dateSource: DateSource;
  excerpt: string | null;
};

/** What is cached for a site. The page and feed addresses are not in it; the items' own links are. */
export type StoredSite = { version: 2; source: string; items: StoredItem[] };

/** The items inside the 7-day window at `now`, newest first; equal times keep their order. */
export function inWindow(items: StoredItem[], now: number): StoredItem[] {
  return items
    .filter((item) => item.published >= now - WINDOW_SECONDS && item.published <= now + MAX_FUTURE_SECONDS)
    .sort((a, b) => b.published - a.published);
}

/** An article as found on a page or in a feed, before it has a time for certain. */
type Found = { title: string; link: string; published: number | null; excerpt: string | null };

type SeenRecord = { version: 1; seen: Record<string, number> };

/**
 * Gives every found article a time. One with a believable date of its own
 * keeps it (`published`; a date up to a day ahead of the clock counts as
 * now, so a wrong time zone cannot hold an item above everything else). One
 * without gets the time this Worker first saw its link (`first_seen`), from
 * the site's first-seen record, which is then written back.
 *
 * The record is one KV value per site: link hash to first-seen Unix seconds.
 * - A link keeps its entry for as long as it is still found, so an article
 *   that sits on a section page for a month does not come back as new;
 *   entries for links no longer found are dropped after 30 days, oldest
 *   first beyond MAX_SEEN.
 * - A link that is new to an existing record was first seen now.
 * - When there is no record yet (a site nobody has fetched before), nothing
 *   says which links are new, so they are stamped a day ago, one second
 *   apart in page order: they show in the history but do not sit above what
 *   other sites really published today.
 * - When the record cannot be read, the links are stamped the same way but
 *   nothing is written: writing would replace every remembered time with a
 *   new one for good. `cacheable` is false then, so the next request tries
 *   again instead of repeating the guess for 30 minutes.
 * - Two requests reading the same site at once can each write the record;
 *   the later write wins and at worst a link's time moves by the gap.
 */
async function withTimes(
  found: Found[],
  key: string,
  cache: KVNamespace,
  now: number,
): Promise<{ items: StoredItem[]; cacheable: boolean }> {
  let previous: Record<string, number> | null = null;
  let readable = true;
  try {
    const stored = await cache.get<SeenRecord>(key, "json");
    if (stored?.version === 1 && typeof stored.seen === "object" && stored.seen !== null) previous = stored.seen;
  } catch {
    readable = false;
  }

  const next: Record<string, number> = {};
  const items: StoredItem[] = [];
  for (const [position, entry] of found.entries()) {
    const hash = await linkHash(entry.link);
    const before = previous && Object.hasOwn(previous, hash) ? previous[hash] : undefined;
    const first = typeof before === "number" && before <= now ? before : previous ? now : now - FIRST_FETCH_AGE - position;
    next[hash] = first;
    const dated = entry.published !== null && entry.published <= now + MAX_FUTURE_SECONDS;
    items.push({
      title: entry.title,
      link: entry.link,
      published: dated ? Math.min(entry.published as number, now) : first,
      dateSource: dated ? "published" : "first_seen",
      excerpt: entry.excerpt,
    });
  }
  if (!readable) {
    console.warn("feed: first-seen read failed");
    return { items, cacheable: false };
  }

  const gone = Object.entries(previous ?? {})
    .filter(([hash, first]) => !Object.hasOwn(next, hash) && typeof first === "number" && first >= now - SEEN_TTL && first <= now)
    .sort((a, b) => b[1] - a[1])
    .slice(0, Math.max(0, MAX_SEEN - found.length));
  for (const [hash, first] of gone) next[hash] = first;

  try {
    await cache.put(key, JSON.stringify({ version: 1, seen: next } satisfies SeenRecord), { expirationTtl: SEEN_TTL });
  } catch {
    console.warn("feed: first-seen write failed");
  }
  return { items, cacheable: true };
}

/**
 * A feed's items with times. Items the feed dates need no record; only when
 * some have no readable date is the first-seen record used, for those items
 * alone (at most MAX_UNDATED of them).
 */
async function feedItems(feed: ParsedFeed, key: () => Promise<string>, cache: KVNamespace, now: number) {
  const links = new Set<string>();
  const dated: Found[] = [];
  const undated: Found[] = [];
  for (const item of feed.items) {
    if (links.has(item.link)) continue;
    links.add(item.link);
    if (item.published !== null && item.published <= now + MAX_FUTURE_SECONDS) dated.push(item);
    else if (item.published === null && undated.length < MAX_UNDATED) undated.push(item);
    // An item dated more than a day ahead is left out.
  }
  const items: StoredItem[] = dated.map((item) => ({
    title: item.title,
    link: item.link,
    published: Math.min(item.published as number, now),
    dateSource: "published",
    excerpt: item.excerpt,
  }));
  if (undated.length === 0) return { items, cacheable: true };
  const stamped = await withTimes(undated, await key(), cache, now);
  return { items: [...items, ...stamped.items], cacheable: stamped.cacheable };
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
 * MAX_ITEMS_PER_SITE items inside the 7-day window at the time of the fetch.
 * `cacheable` is false when the result rests on a guess that should not be
 * kept (see `withTimes`). Throws `SafeFetchError`, `FeedParseError` or
 * `SiteFailure`.
 */
export async function readSite(
  site: SiteSource,
  cache: KVNamespace,
  now: number,
  options: ReadOptions,
): Promise<{ site: StoredSite; cacheable: boolean }> {
  const stored = (source: string, items: StoredItem[]): StoredSite => ({
    version: 2,
    source,
    items: inWindow(items, now).slice(0, MAX_ITEMS_PER_SITE),
  });

  if (site.mode === "feed") {
    const { feed } = await fetchFeed(site.feedUrl, options);
    const { items, cacheable } = await feedItems(feed, () => seenCacheKey(site), cache, now);
    return { site: stored(clip(feed.title ?? hostName(site.url), MAX_SOURCE), items), cacheable };
  }

  const { kind, response } = await fetchPage(site.url, options);
  if (kind !== "html") throw new SiteFailure("not_html");
  const scan = await scanPage(response.body, response.headers.get("content-type"));
  const links = articleLinks(scan, site.url, response.url).map((link) => ({ ...link, excerpt: null }));
  const { items, cacheable } = await withTimes(links, await seenCacheKey(site), cache, now);
  return { site: stored(pageSource(scan, site.url), items), cacheable };
}

/** A cached site, when the value has the expected shape. */
export function asStoredSite(value: unknown): StoredSite | null {
  const site = value as Partial<StoredSite> | null;
  return site?.version === 2 && typeof site.source === "string" && Array.isArray(site.items) ? (site as StoredSite) : null;
}
