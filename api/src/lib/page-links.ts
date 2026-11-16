import { parseFeedDate, safeLink } from "./feed-parse.ts";
import { cutSource, decodeEntities, plainText } from "./text.ts";

// Reading an HTML page with the Workers built-in HTMLRewriter: its title, the
// feeds it advertises, and the links that look like articles. A page is
// untrusted input, so everything collected is counted and cut.
//
// What HTMLRewriter does, as checked by api/test/html-rewriter.test.ts:
// handlers run only while the transformed body is read; text arrives in
// pieces that can split a word or a character reference, with references not
// decoded; attribute values are not decoded either; `onEndTag` throws for an
// element without an end tag (`<br>`, `<link>`, and a self-closing `<a/>` or
// `<title/>` inside `<svg>`), and a throw in a handler ends the whole
// transform, so it is only called through `atEnd`; an element that is never
// closed gets its end-tag call when an element around it closes, or never.
// So nothing here depends on an end tag arriving: an open `<a>` is finished by
// the next `<a>` (as a browser does) or at the end of the page, and `<main>`
// clears the count of open `<nav>` and `<footer>`.
//
// `HTMLRewriter` is named only inside `scanPage`, so this file loads in Node
// for the spec writer.

/** `<a href>` elements read on one page. Later ones are not looked at. */
export const MAX_LINKS_SCANNED = 1500;
/** Handler calls spent on one page (elements and pieces of text looked at). A large real page uses a few thousand. */
export const MAX_HANDLER_CALLS = 40_000;
/** The page is given to HTMLRewriter this many bytes at a time, so reading can stop early. */
const PIECE_BYTES = 16 * 1024;
/** Article links kept from one page. */
export const MAX_CANDIDATES = 200;
const MAX_FEED_LINKS = 20;
const MAX_HREF = 2048;
/** Raw characters of anchor text kept. */
const MAX_ANCHOR_TEXT = 600;
const MAX_TITLE = 300;
const MAX_OPEN_CARDS = 16;

/** One `<a href>` as found, before any judgement about what it is. */
export type ScannedLink = {
  /** The href attribute, references decoded, not resolved. */
  href: string;
  /** Text of the whole anchor, raw. */
  text: string;
  /** Text of an h1–h4 inside the anchor, raw; empty when there is none. */
  headingText: string;
  /** Inside `<nav>` or `<footer>`. */
  chrome: boolean;
  /** Inside `<article>`, `<main>` or a heading, or holding a heading. */
  preferred: boolean;
  /** From a `<time datetime>` inside the anchor: Unix seconds. */
  published: number | null;
  /** The `<article>` or `<li>` the link sits in, when that element holds a `<time datetime>`. */
  card: number | null;
  cardTime: number | null;
};

export type ScannedFeedLink = { href: string; title: string };

export type PageScan = {
  title: string | null;
  siteName: string | null;
  /** `<base href>`, references decoded, not resolved. */
  base: string | null;
  /** `<link rel="alternate">` elements with an RSS or Atom type, in document order. */
  feeds: ScannedFeedLink[];
  links: ScannedLink[];
};

type Card = { id: number; time: number | null; links: ScannedLink[] };

const FEED_TYPES = new Set(["application/rss+xml", "application/atom+xml", "application/rdf+xml"]);
const GENERIC_XML_TYPES = new Set(["text/xml", "application/xml"]);
const FEED_HINT = /rss|atom|feed/i;

function attributeOf(element: Element, name: string, max: number): string | null {
  const value = element.getAttribute(name);
  if (value === null || value.length > max) return null;
  return decodeEntities(value);
}

/** Reads a page's bytes. `contentType` is passed on so HTMLRewriter decodes the page's own character set. */
export async function scanPage(body: Uint8Array, contentType: string | null): Promise<PageScan> {
  const scan: PageScan = { title: null, siteName: null, base: null, feeds: [], links: [] };

  let chrome = 0; // open <nav> and <footer>
  let content = 0; // open <article> and <main>
  let headings = 0; // open h1–h3
  let scanned = 0;
  let titleText = "";
  let titleDone = false;
  let nextCard = 0;
  type OpenAnchor = { link: ScannedLink; usable: boolean; inHeading: number };
  const anchors: OpenAnchor[] = [];
  const cards: Card[] = [];

  // HTMLRewriter cannot be told to stop, and every handler call costs a few
  // microseconds, so a page of 2 MB made of nothing but tiny elements would
  // take seconds. Two things bound it: every handler call is counted, and the
  // page is fed to HTMLRewriter in pieces, which stop coming once the count or
  // the link limit is reached. What follows on the page is not read.
  let calls = 0;
  let stopped = false;
  const spent = () => {
    if (++calls > MAX_HANDLER_CALLS) stopped = true;
    return stopped;
  };

  /**
   * Runs `done` at the element's end tag. A self-closing element in inline
   * SVG or MathML (`<a href="…"/>`, `<title/>`) has none, and asking for its
   * end throws, which would end the whole scan; it is empty, so it ends at once.
   */
  const atEnd = (element: Element, done: () => void) => {
    try {
      element.onEndTag(done);
    } catch {
      done();
    }
  };

  /** Closes an anchor: at its end tag, when the next anchor starts, or at the end of the page. */
  const finish = (anchor: OpenAnchor) => {
    const at = anchors.lastIndexOf(anchor);
    if (at < 0) return; // already finished
    anchors.splice(at, 1);
    if (!anchor.usable) return;
    scan.links.push(anchor.link);
    cards[cards.length - 1]?.links.push(anchor.link);
  };
  const addText = (anchor: OpenAnchor, text: string) => {
    const link = anchor.link;
    // The text still holds its references, and a cut must not leave half of one or of a surrogate pair.
    link.text += cutSource(text, MAX_ANCHOR_TEXT - link.text.length);
    if (anchor.inHeading > 0) link.headingText += cutSource(text, MAX_ANCHOR_TEXT - link.headingText.length);
  };

  const rewriter = new HTMLRewriter()
    .on("title", {
      element(element) {
        if (spent()) return;
        if (titleDone) return;
        // An <svg><title> later in the page is not the page's title.
        try {
          element.onEndTag(() => {
            titleDone = true;
          });
        } catch {
          // <title/> inside an <svg>: it has no end and no text.
        }
      },
      text(chunk) {
        if (spent()) return;
        if (!titleDone) titleText += cutSource(chunk.text, MAX_TITLE * 12 - titleText.length);
      },
    })
    .on("base", {
      element(element) {
        if (spent()) return;
        scan.base ??= attributeOf(element, "href", MAX_HREF);
      },
    })
    .on("meta", {
      element(element) {
        if (spent()) return;
        if (scan.siteName !== null) return;
        if ((element.getAttribute("property") ?? "").toLowerCase() !== "og:site_name") return;
        const value = attributeOf(element, "content", MAX_TITLE * 12);
        if (value) scan.siteName = plainText(value, MAX_TITLE) || null;
      },
    })
    .on("link", {
      element(element) {
        if (spent()) return;
        if (scan.feeds.length >= MAX_FEED_LINKS) return;
        const rel = (element.getAttribute("rel") ?? "").toLowerCase().split(/\s+/, 8);
        // rel="alternate stylesheet" is an alternative style sheet, whatever its type says.
        if (!rel.includes("alternate") || rel.includes("stylesheet")) return;
        const type = (element.getAttribute("type") ?? "").toLowerCase().split(";", 1)[0]?.trim() ?? "";
        const href = attributeOf(element, "href", MAX_HREF);
        if (!href) return;
        const title = plainText(attributeOf(element, "title", 2000) ?? "", 200);
        // Some sites label their feed with a generic XML type; then the title or the address has to say "feed".
        const generic = GENERIC_XML_TYPES.has(type) && (FEED_HINT.test(title) || FEED_HINT.test(href.slice(0, 300)));
        if (!FEED_TYPES.has(type) && !generic) return;
        scan.feeds.push({ href, title });
      },
    })
    .on("nav, footer", {
      element(element) {
        if (spent()) return;
        chrome += 1;
        atEnd(element, () => {
          chrome = Math.max(0, chrome - 1);
        });
      },
    })
    .on("main", {
      element(element) {
        if (spent()) return;
        // A <nav> that was never closed is still "open" here (its end comes at
        // the end of the document) and would hide every link on the page.
        chrome = 0;
        content += 1;
        atEnd(element, () => {
          content = Math.max(0, content - 1);
        });
      },
    })
    .on("article, li", {
      element(element) {
        if (spent()) return;
        const isArticle = element.tagName.toLowerCase() === "article";
        if (isArticle) content += 1;
        const card: Card | null = cards.length < MAX_OPEN_CARDS ? { id: nextCard++, time: null, links: [] } : null;
        if (card) cards.push(card);
        atEnd(element, () => {
          if (isArticle) content = Math.max(0, content - 1);
          if (!card) return;
          const at = cards.lastIndexOf(card);
          if (at < 0) return;
          cards.splice(at, 1);
          if (card.time !== null) {
            for (const link of card.links) {
              link.card = card.id;
              link.cardTime = card.time;
            }
          } else {
            // No date here: the links may belong to a date in the enclosing card.
            const parent = cards[at - 1];
            if (parent && parent.links.length < MAX_LINKS_SCANNED) parent.links.push(...card.links);
          }
        });
      },
    })
    .on("h1, h2, h3, h4", {
      element(element) {
        if (spent()) return;
        const ranked = element.tagName.toLowerCase() !== "h4";
        if (ranked) headings += 1;
        const anchor = anchors[anchors.length - 1];
        if (anchor) {
          anchor.inHeading += 1;
          if (ranked) anchor.link.preferred = true;
        }
        atEnd(element, () => {
          if (ranked) headings = Math.max(0, headings - 1);
          if (anchor) anchor.inHeading = Math.max(0, anchor.inHeading - 1);
        });
      },
    })
    .on("time", {
      element(element) {
        if (spent()) return;
        const value = element.getAttribute("datetime");
        if (!value) return;
        const seconds = parseFeedDate(value);
        if (seconds === null) return;
        const anchor = anchors[anchors.length - 1];
        if (anchor) {
          anchor.link.published ??= seconds;
          return;
        }
        const card = cards[cards.length - 1];
        if (card) card.time ??= seconds;
      },
    })
    .on("a *", {
      element() {
        if (spent()) return;
        // Keep words in separate elements apart: "<h3>Title</h3><p>Summary</p>".
        const anchor = anchors[anchors.length - 1];
        if (anchor) addText(anchor, " ");
      },
    })
    .on("a", {
      element(element) {
        if (spent()) return;
        // An anchor inside an anchor is not HTML: the first one ends here.
        while (anchors.length > 0) finish(anchors[anchors.length - 1] as OpenAnchor);
        if (scanned >= MAX_LINKS_SCANNED) {
          stopped = true;
          return;
        }
        const raw = element.getAttribute("href");
        if (raw === null) return;
        scanned += 1;
        const usable = raw.length <= MAX_HREF;
        const anchor: OpenAnchor = {
          link: {
            href: usable ? decodeEntities(raw) : "",
            text: "",
            headingText: "",
            chrome: chrome > 0,
            preferred: content > 0 || headings > 0,
            published: null,
            card: null,
            cardTime: null,
          },
          usable,
          inHeading: 0,
        };
        anchors.push(anchor);
        atEnd(element, () => finish(anchor));
      },
      text(chunk) {
        if (spent()) return;
        const anchor = anchors[anchors.length - 1];
        if (anchor) addText(anchor, chunk.text);
      },
    });

  const headers = new Headers();
  if (contentType) headers.set("content-type", contentType);
  try {
    // The handlers run while the output is read; the output itself is not wanted.
    let offset = 0;
    const pieces = new ReadableStream<Uint8Array>({
      pull(controller) {
        if (stopped || offset >= body.length) {
          controller.close();
          return;
        }
        controller.enqueue(body.subarray(offset, offset + PIECE_BYTES));
        offset += PIECE_BYTES;
      },
    });
    await rewriter.transform(new Response(pieces, { headers })).arrayBuffer();
  } catch {
    // A page HTMLRewriter gives up on: keep what was read before that.
  }
  while (anchors.length > 0) finish(anchors[anchors.length - 1] as OpenAnchor);

  const title = plainText(titleText, MAX_TITLE);
  scan.title = title === "" ? null : title;
  return scan;
}

// ---------------------------------------------------------------------------
// Choosing a feed

/** Path segments that are not empty. */
const segments = (url: URL) => url.pathname.split("/").filter((part) => part !== "");

function sharedPrefix(a: string[], b: string[]): number {
  let n = 0;
  while (n < a.length && n < b.length && a[n] === b[n]) n += 1;
  return n;
}

export type FeedCandidate = {
  /** A checked https URL. */
  url: string;
  /** Leading path segments the feed's address shares with the page's. */
  shared: number;
};

/**
 * The advertised feeds as checked https URLs, best first: the feed whose path
 * shares the most leading segments with the page's (a section's own feed
 * before the site-wide one), a comments feed last, otherwise document order.
 */
export function feedCandidates(scan: PageScan, pageUrl: URL): FeedCandidate[] {
  const base = pageBase(scan, pageUrl);
  const page = segments(pageUrl);
  const found: (FeedCandidate & { comments: boolean; order: number })[] = [];
  for (const feed of scan.feeds) {
    const url = safeLink(feed.href, base);
    if (!url || found.some((other) => other.url === url)) continue;
    const parsed = new URL(url);
    const comments = /comment/i.test(parsed.pathname.slice(0, 300)) || /comment/i.test(feed.title);
    found.push({ url, shared: sharedPrefix(segments(parsed), page), comments, order: found.length });
  }
  found.sort((a, b) => Number(a.comments) - Number(b.comments) || b.shared - a.shared || a.order - b.order);
  return found.map(({ url, shared }) => ({ url, shared }));
}

/** Whether the address is a site's front page: no path beyond "/". */
export const isSiteRoot = (url: URL) => segments(url).length === 0;

function pageBase(scan: PageScan, pageUrl: URL): URL {
  if (scan.base) {
    try {
      return new URL(scan.base, pageUrl);
    } catch {
      // An unusable <base>: the page's own address is the base.
    }
  }
  return pageUrl;
}

// ---------------------------------------------------------------------------
// Choosing article links

export type ArticleLink = {
  title: string;
  link: string;
  /** Unix seconds from a `<time datetime>` by the link, or null. */
  published: number | null;
};

// A path segment that says "this is not an article", wherever it stands
// after the part of the path the link shares with the page.
const NEVER = new Set([
  "login", "log-in", "signin", "sign-in", "signup", "sign-up", "register", "logout", "subscribe", "subscription",
  "subscriptions", "account", "my-account", "profile",
  "about", "about-us", "contact", "contact-us", "privacy", "privacy-policy", "terms", "terms-of-service",
  "terms-of-use", "search", "newsletter", "newsletters", "advertise", "advertising", "careers", "jobs", "help",
  "faq", "cart", "checkout", "page", "feed", "rss", "comments", "contributors", "legal", "cookies",
  "cookie-policy", "donate", "membership", "sitemap", "accessibility", "wp-admin", "wp-login", "share",
  "print", "user", "users", "staff",
]);
// A segment that names a kind of listing (`/tag/space`, `/author/jane-doe`,
// `/category/tech`). What follows is an article only when the path carries a
// date (`/category/tech/2026/11/15/a-real-story`) or goes on for at least two
// more segments and ends in a headline-like slug.
const KIND = new Set(["tag", "tags", "author", "authors", "category", "categories"]);
// A leading segment that names a listing unless a headline-like slug or a date follows.
const LISTING = new Set(["topic", "topics", "section", "sections", "people", "events", "archive", "archives", "shop", "store", "series", "collections"]);
const NOT_PAGES = new Set(["pdf", "jpg", "jpeg", "png", "gif", "webp", "svg", "zip", "mp3", "mp4", "mov", "xml", "rss", "atom", "json", "css", "js", "ics"]);
const PAGE_FILES = new Set(["html", "htm", "shtml", "php", "asp", "aspx", "jsp"]);
// Query parameters by which sites name one article: `?p=77`, `/article?id=12345`.
const ARTICLE_PARAMETERS = new Set([
  "id", "p", "article", "articleid", "article_id", "story", "storyid", "story_id", "post", "postid", "post_id",
  "item", "itemid", "item_id", "nid", "aid", "sid", "newsid", "news_id", "doc", "docid",
]);
const NOT_HEADLINES = ["read more", "continue reading", "view all", "see all", "see more", "more from", "load more", "sign up", "sign in", "subscribe", "log in", "skip to", "click here", "learn more"];

const sameSite = (a: string, b: string) => a.replace(/^www\./, "") === b.replace(/^www\./, "");

const isDigit = (c: number) => c >= 48 && c <= 57;

/** "nasa-launches-new-probe", "story_12345", "12345678": three or more words, or five digits in a row. */
function isSlug(segment: string): boolean {
  if (segment.length > 300) return false;
  let words = 1;
  let digits = 0;
  let longestDigits = 0;
  for (let i = 0; i < segment.length; i++) {
    const c = segment.charCodeAt(i);
    if (c === 45 || c === 95) words += 1;
    digits = isDigit(c) ? digits + 1 : 0;
    if (digits > longestDigits) longestDigits = digits;
  }
  return (words >= 3 && segment.length >= 12) || longestDigits >= 5;
}

/** "a1B2c3D4e5F6": eight or more letters and digits, at least three of them digits and one a letter. */
function isOpaqueId(segment: string): boolean {
  if (segment.length < 8 || segment.length > 64) return false;
  let digits = 0;
  let letters = 0;
  for (let i = 0; i < segment.length; i++) {
    const c = segment.charCodeAt(i);
    if (isDigit(c)) digits += 1;
    else if ((c >= 65 && c <= 90) || (c >= 97 && c <= 122)) letters += 1;
    else if (c !== 45 && c !== 95) return false;
  }
  return digits >= 3 && letters >= 1;
}

/** A year segment followed by a month segment: `/2026/11/…`. */
function hasDate(path: string[]): boolean {
  for (let i = 0; i + 1 < path.length; i++) {
    const year = path[i] as string;
    const month = path[i + 1] as string;
    if (year.length === 4 && (year.startsWith("19") || year.startsWith("20")) && /^\d{4}$/.test(year) && /^\d{1,2}$/.test(month)) return true;
  }
  return false;
}

/** Whether the query names one article (`?p=77`, `?id=12345`). */
function hasArticleQuery(link: URL): boolean {
  if (link.search.length < 3 || link.search.length > 300) return false;
  for (const [name, value] of link.searchParams) {
    if (ARTICLE_PARAMETERS.has(name.toLowerCase()) && value !== "" && value.length <= 64) return true;
  }
  return false;
}

/**
 * Whether a link can be an article of the page at `page`. The rules, in
 * order:
 *
 * - The page itself or a page above it is not, unless its query names an
 *   article (`/index.php?p=77` from `/index.php?cat=2`, `/?p=5` from `/`).
 * - A file that is not a page (`.pdf`, `.jpg`) is not.
 * - After the part of the path shared with the page, no segment may name
 *   something else (sign-in, search, about, `page/2`, `index.html`), and a
 *   tag, author or category segment is allowed only with a date in the path
 *   or two more segments ending in a slug.
 * - Then one of these has to hold: the query names an article; the path is
 *   deeper than the page's; it carries a date; or its last segment is a slug
 *   of three words, has five digits in a row, is an opaque id, or is a page
 *   file (`story.html`). That lets sites keep articles beside their section
 *   pages: `/story/some-headline` next to `/category/science/`.
 */
function isArticlePath(link: URL, page: URL): boolean {
  const path = segments(link);
  const pagePath = segments(page);
  if (path.length > 20) return false;
  const byQuery = hasArticleQuery(link);
  const shared = sharedPrefix(path, pagePath);
  if (shared === path.length) return byQuery && link.pathname + link.search !== page.pathname + page.search;

  const rest = path.slice(shared).map((segment) => segment.toLowerCase());
  const last = rest[rest.length - 1] as string;
  const dot = last.lastIndexOf(".");
  const extension = dot > 0 ? last.slice(dot + 1) : "";
  if (NOT_PAGES.has(extension)) return false;
  const stem = PAGE_FILES.has(extension) ? last.slice(0, dot) : last;
  rest[rest.length - 1] = stem;
  if (rest.some((segment) => NEVER.has(segment))) return false;
  // `/news/index.html` is a listing; `/index.php?p=77` is an article.
  if (!byQuery && (stem === "index" || stem === "default")) return false;

  const dated = hasDate(path);
  const slug = isSlug(stem);
  const kind = rest.findIndex((segment) => KIND.has(segment));
  if (kind >= 0 && !dated && !(slug && rest.length - kind >= 3)) return false;
  if (LISTING.has(rest[0] as string) && !slug && !dated) return false;

  return byQuery || path.length > pagePath.length || dated || slug || isOpaqueId(stem) || PAGE_FILES.has(extension);
}

// Scripts written without spaces between words: Thai, Lao, Myanmar, Khmer,
// and Chinese, Japanese and Korean. Emoji and other symbols are not among them.
function isUnspacedScript(code: number): boolean {
  return (
    (code >= 0x0e00 && code <= 0x0eff) || // Thai, Lao
    (code >= 0x1000 && code <= 0x109f) || // Myanmar
    (code >= 0x1780 && code <= 0x17ff) || // Khmer
    (code >= 0x2e80 && code <= 0x9fff) || // CJK radicals, kana, ideographs
    (code >= 0xac00 && code <= 0xd7a3) || // Hangul syllables
    (code >= 0xf900 && code <= 0xfaff) || // CJK compatibility ideographs
    (code >= 0xff66 && code <= 0xff9f) || // half-width kana
    (code >= 0x20000 && code <= 0x3ffff) // CJK extensions
  );
}

/**
 * Headline length: 16 to 250 characters and three words; or, in a script
 * written without spaces, six characters of which four are of that script
 * (a menu entry is two to four).
 */
function isHeadline(text: string): boolean {
  if (text.length > 250) return false;
  const lower = text.toLowerCase();
  if (NOT_HEADLINES.some((phrase) => lower.startsWith(phrase))) return false;
  let words = 1;
  let unspaced = 0;
  let characters = 0;
  for (const character of text) {
    characters += 1;
    if (character === " ") words += 1;
    else if (isUnspacedScript(character.codePointAt(0) as number)) unspaced += 1;
  }
  // Characters, not UTF-16 units: an emoji is one.
  return unspaced >= 4 ? characters >= 6 : characters >= 16 && words >= 3;
}

/**
 * The article links of a scanned page, in document order, at most
 * MAX_CANDIDATES. `pageUrl` is the address the user follows; `finalUrl` is the
 * one that answered (after redirects), against which relative links resolve.
 *
 * A link is kept when it is outside `<nav>` and `<footer>`, resolves to a safe
 * https URL on the page's host (the same host name, ignoring a leading
 * `www.`; there is no public-suffix list here, so other subdomains do not
 * count), has an article-like path (`isArticlePath`) and headline-length
 * text. When three or more kept links are "preferred" (inside `<article>`,
 * `<main>` or an h1–h3), only those are returned.
 *
 * A date comes from a `<time datetime>` inside the anchor, or from one in the
 * `<article>` or `<li>` around it when that element holds no other article.
 */
export function articleLinks(scan: PageScan, pageUrl: URL, finalUrl: URL): ArticleLink[] {
  const base = pageBase(scan, finalUrl);
  type Kept = ArticleLink & { key: string; preferred: boolean; card: number | null; cardTime: number | null };
  const kept = new Map<string, Kept>();
  for (const found of scan.links) {
    if (found.chrome || found.href === "") continue;
    const link = safeLink(found.href, base);
    if (!link) continue;
    const url = new URL(link);
    if (!sameSite(url.hostname, pageUrl.hostname) && !sameSite(url.hostname, finalUrl.hostname)) continue;
    if (!isArticlePath(url, pageUrl) || !isArticlePath(url, finalUrl)) continue;
    const title = plainText(found.headingText.trim() !== "" ? found.headingText : found.text, MAX_TITLE);
    if (!isHeadline(title)) continue;

    url.hash = "";
    const key = url.href;
    const earlier = kept.get(key);
    if (earlier) {
      // The same article linked twice (image and headline): keep the better text and any date.
      if (found.preferred && !earlier.preferred) {
        earlier.title = title;
        earlier.preferred = true;
      }
      earlier.published ??= found.published;
      if (earlier.card === null) {
        earlier.card = found.card;
        earlier.cardTime = found.cardTime;
      }
      continue;
    }
    if (kept.size >= MAX_CANDIDATES * 2) break;
    kept.set(key, { key, title, link: key, published: found.published, preferred: found.preferred, card: found.card, cardTime: found.cardTime });
  }

  let links = [...kept.values()];
  if (links.filter((link) => link.preferred).length >= 3) links = links.filter((link) => link.preferred);

  // A card's date belongs to its article only when the card holds one article.
  const perCard = new Map<number, number>();
  for (const link of links) if (link.card !== null) perCard.set(link.card, (perCard.get(link.card) ?? 0) + 1);

  return links.slice(0, MAX_CANDIDATES).map((link) => ({
    title: link.title,
    link: link.link,
    published: link.published ?? (link.card !== null && perCard.get(link.card) === 1 ? link.cardTime : null),
  }));
}
