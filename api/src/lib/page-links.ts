import { parseFeedDate, safeLink } from "./feed-parse.ts";
import { decodeEntities, plainText } from "./text.ts";

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
    link.text += text.slice(0, MAX_ANCHOR_TEXT - link.text.length);
    if (anchor.inHeading > 0) link.headingText += text.slice(0, MAX_ANCHOR_TEXT - link.headingText.length);
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
        if (!titleDone) titleText += chunk.text.slice(0, MAX_TITLE * 12 - titleText.length);
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
        if (!rel.includes("alternate")) return;
        const type = (element.getAttribute("type") ?? "").toLowerCase().split(";", 1)[0]?.trim() ?? "";
        if (!FEED_TYPES.has(type)) return;
        const href = attributeOf(element, "href", MAX_HREF);
        if (!href) return;
        scan.feeds.push({ href, title: plainText(attributeOf(element, "title", 2000) ?? "", 200) });
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

/**
 * The advertised feeds as checked https URLs, best first: the feed whose path
 * shares the most leading segments with the page's (a section's own feed
 * before the site-wide one), a comments feed last, otherwise document order.
 */
export function feedCandidates(scan: PageScan, pageUrl: URL): string[] {
  const base = pageBase(scan, pageUrl);
  const page = segments(pageUrl);
  const found: { url: string; shared: number; comments: boolean; order: number }[] = [];
  for (const feed of scan.feeds) {
    const url = safeLink(feed.href, base);
    if (!url || found.some((other) => other.url === url)) continue;
    const parsed = new URL(url);
    const comments = /comment/i.test(parsed.pathname.slice(0, 300)) || /comment/i.test(feed.title);
    found.push({ url, shared: sharedPrefix(segments(parsed), page), comments, order: found.length });
  }
  found.sort((a, b) => Number(a.comments) - Number(b.comments) || b.shared - a.shared || a.order - b.order);
  return found.map((feed) => feed.url);
}

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
  "subscriptions", "account", "my-account", "profile", "tag", "tags", "author", "authors", "category", "categories",
  "about", "about-us", "contact", "contact-us", "privacy", "privacy-policy", "terms", "terms-of-service",
  "terms-of-use", "search", "newsletter", "newsletters", "advertise", "advertising", "careers", "jobs", "help",
  "faq", "cart", "checkout", "page", "feed", "rss", "comments", "contributors", "legal", "cookies",
  "cookie-policy", "donate", "membership", "sitemap", "accessibility", "wp-admin", "wp-login.php", "share",
  "print", "user", "users", "staff",
]);
// A leading segment that names a listing unless a headline-like slug follows.
const LISTING = new Set(["topic", "topics", "section", "sections", "people", "events", "archive", "archives", "shop", "store", "series", "collections"]);
const NOT_PAGES = new Set(["pdf", "jpg", "jpeg", "png", "gif", "webp", "svg", "zip", "mp3", "mp4", "mov", "xml", "rss", "atom", "json", "css", "js", "ics"]);
const NOT_HEADLINES = ["read more", "continue reading", "view all", "see all", "see more", "more from", "load more", "sign up", "sign in", "subscribe", "log in", "skip to", "click here", "learn more"];

const sameSite = (a: string, b: string) => a.replace(/^www\./, "") === b.replace(/^www\./, "");

/** "nasa-launches-new-probe", "story_12345.html": three or more words, or a long run of digits. */
function isSlug(segment: string): boolean {
  if (segment.length < 12 || segment.length > 300) return false;
  let words = 1;
  let digits = 0;
  let longestDigits = 0;
  for (let i = 0; i < segment.length; i++) {
    const c = segment.charCodeAt(i);
    if (c === 45 || c === 95) words += 1;
    digits = c >= 48 && c <= 57 ? digits + 1 : 0;
    if (digits > longestDigits) longestDigits = digits;
  }
  return words >= 3 || longestDigits >= 5;
}

/**
 * Whether a link's path can be an article of the page at `page`: not the page
 * itself or a page above it; nothing after the shared part of the path that
 * names a tag, author, sign-in and so on; and either deeper than the page or
 * ending in a headline-like slug (sites that keep articles beside their
 * section pages, `/story/some-headline` next to `/category/science`).
 */
function isArticlePath(link: URL, page: string[]): boolean {
  const path = segments(link);
  if (path.length === 0 || path.length > 20) return false;
  const shared = sharedPrefix(path, page);
  if (shared === path.length) return false; // the page itself, or above it
  const last = (path[path.length - 1] as string).toLowerCase();
  const dot = last.lastIndexOf(".");
  if (dot > 0 && NOT_PAGES.has(last.slice(dot + 1))) return false;
  for (let i = shared; i < path.length; i++) {
    if (NEVER.has((path[i] as string).toLowerCase())) return false;
  }
  const slug = isSlug(last);
  if (LISTING.has((path[shared] as string).toLowerCase()) && !slug) return false;
  return path.length > page.length || slug;
}

/** Headline length: 16 to 250 characters and three words, or 8 characters in a script written without spaces. */
function isHeadline(text: string): boolean {
  if (text.length > 250) return false;
  const lower = text.toLowerCase();
  if (NOT_HEADLINES.some((phrase) => lower.startsWith(phrase))) return false;
  let words = 1;
  let unspaced = false;
  for (let i = 0; i < text.length; i++) {
    const c = text.charCodeAt(i);
    if (c === 32) words += 1;
    else if (c >= 0x2e80) unspaced = true;
  }
  return unspaced ? text.length >= 8 : text.length >= 16 && words >= 3;
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
  const page = segments(pageUrl);
  const finalPage = segments(finalUrl);

  type Kept = ArticleLink & { key: string; preferred: boolean; card: number | null; cardTime: number | null };
  const kept = new Map<string, Kept>();
  for (const found of scan.links) {
    if (found.chrome || found.href === "") continue;
    const link = safeLink(found.href, base);
    if (!link) continue;
    const url = new URL(link);
    if (!sameSite(url.hostname, pageUrl.hostname) && !sameSite(url.hostname, finalUrl.hostname)) continue;
    if (!isArticlePath(url, page) || !isArticlePath(url, finalPage)) continue;
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
