import { XMLParser } from "fast-xml-parser";
import { assertSafeUrl } from "./safe-fetch.ts";
import { clip, collapseSpace, decodeEntities, htmlToText, plainText } from "./text.ts";

// RSS 2.0, RSS 1.0 (RDF) and Atom text to a list of items. A feed is
// untrusted input:
//
// - The parser expands no entities at all (`processEntities: false`), so a
//   DOCTYPE that defines entities ("billion laughs") defines nothing; the five
//   XML references and numeric ones are decoded by `decodeEntities`, which
//   cannot grow its input. External entities make the parser throw.
// - Nesting deeper than MAX_NESTING makes the parser throw.
// - At most MAX_ITEMS_SCANNED items are read, and every field is cut before
//   it is decoded or stripped.
// - Whatever the parser throws becomes `FeedParseError` with no text of its
//   own: the parser's messages quote the input.

export const MAX_NESTING = 64;
export const MAX_ITEMS_SCANNED = 500;
export const MAX_TITLE = 300;
export const MAX_EXCERPT = 300;
export const MAX_SOURCE = 120;
const MAX_LINK_LENGTH = 2048;
/** Raw characters of one field that are looked at. */
const MAX_FIELD = 40_000;
/** Children of one element that are looked at when searching for a field. */
const MAX_CHILDREN = 2_000;

/** The text is not an RSS, RDF or Atom feed, or could not be parsed. */
export class FeedParseError extends Error {
  constructor() {
    super("Not a feed");
    this.name = "FeedParseError";
  }
}

export type FeedItem = {
  title: string;
  /** Absolute https URL that passed the safe-URL check. */
  link: string;
  /** Unix seconds, or null when the feed gives no date that can be read. */
  published: number | null;
  excerpt: string | null;
};

export type ParsedFeed = { title: string | null; items: FeedItem[] };

// ---------------------------------------------------------------------------
// Dates

const MONTHS: Record<string, number> = {
  jan: 0, feb: 1, mar: 2, apr: 3, may: 4, jun: 5, jul: 6, aug: 7, sep: 8, oct: 9, nov: 10, dec: 11,
};
// RFC 822 zone names, in minutes east of UTC.
const ZONES: Record<string, number> = {
  ut: 0, utc: 0, gmt: 0, z: 0, est: -300, edt: -240, cst: -360, cdt: -300, mst: -420, mdt: -360, pst: -480, pdt: -420,
};

// Both patterns are anchored and have no nested or adjacent unbounded
// quantifiers over the same characters; the input is cut to 64 characters first.
const ISO_DATE =
  /^(\d{4})-(\d{2})-(\d{2})(?:[Tt ](\d{2}):(\d{2})(?::(\d{2})(?:[.,]\d{1,9})?)?)?\s?(?:([Zz])|([+-])(\d{2}):?(\d{2}))?$/;
const RFC822_DATE =
  /^(?:[A-Za-z]{3,9},?\s)?(\d{1,2})\s([A-Za-z]{3})[A-Za-z]{0,6}\s(\d{2}|\d{4})\s(\d{1,2}):(\d{2})(?::(\d{2}))?(?:\s(?:([+-])(\d{2}):?(\d{2})|([A-Za-z]{1,3})))?$/;

function utcSeconds(year: number, month: number, day: number, hour: number, minute: number, second: number, offsetMinutes: number) {
  if (month < 0 || month > 11 || day < 1 || day > 31 || hour > 23 || minute > 59 || second > 60) return null;
  if (year < 1970 || year > 2200) return null;
  const date = new Date(Date.UTC(year, month, day, hour, minute, second));
  // 31 February and the like roll over into another month: not a date.
  if (date.getUTCMonth() !== month || date.getUTCDate() !== day) return null;
  if (Math.abs(offsetMinutes) > 16 * 60) return null;
  return Math.floor(date.getTime() / 1000) - offsetMinutes * 60;
}

/**
 * A feed's date as Unix seconds: ISO 8601 / RFC 3339 (`2026-11-14T09:30:00-05:00`,
 * `2026-11-14`) or RFC 822 (`Sat, 14 Nov 2026 09:30:00 GMT`). A time without a
 * zone is read as UTC. Anything else is null.
 */
export function parseFeedDate(input: string): number | null {
  const text = collapseSpace(input.slice(0, 64));
  if (text === "") return null;

  const iso = ISO_DATE.exec(text);
  if (iso) {
    const sign = iso[8] === "-" ? -1 : 1;
    const offset = iso[8] ? sign * (Number(iso[9]) * 60 + Number(iso[10])) : 0;
    return utcSeconds(Number(iso[1]), Number(iso[2]) - 1, Number(iso[3]), Number(iso[4] ?? 0), Number(iso[5] ?? 0), Number(iso[6] ?? 0), offset);
  }

  const rfc = RFC822_DATE.exec(text);
  if (rfc) {
    const month = MONTHS[(rfc[2] as string).toLowerCase()];
    if (month === undefined) return null;
    let year = Number(rfc[3]);
    if ((rfc[3] as string).length === 2) year += year < 70 ? 2000 : 1900;
    let offset = 0;
    if (rfc[7]) {
      offset = (rfc[7] === "-" ? -1 : 1) * (Number(rfc[8]) * 60 + Number(rfc[9]));
    } else if (rfc[10]) {
      const zone = ZONES[rfc[10].toLowerCase()];
      if (zone === undefined) return null;
      offset = zone;
    }
    return utcSeconds(year, month, Number(rfc[1]), Number(rfc[4]), Number(rfc[5]), Number(rfc[6] ?? 0), offset);
  }
  return null;
}

// ---------------------------------------------------------------------------
// Links

/**
 * Resolves `href` against `base` and returns it as an https URL that passes
 * the safe-URL check (no credentials, no odd port, no private or local host),
 * or null. `http:` is read as `https:`.
 */
export function safeLink(href: string, base: URL | string): string | null {
  const trimmed = href.trim();
  if (trimmed === "" || trimmed.length > MAX_LINK_LENGTH) return null;
  let url: URL;
  try {
    url = new URL(trimmed, base);
  } catch {
    return null;
  }
  if (url.protocol === "http:") url.protocol = "https:";
  try {
    assertSafeUrl(url);
  } catch {
    return null;
  }
  return url.href.length > MAX_LINK_LENGTH ? null : url.href;
}

/** `base` moved by an `xml:base` value; the old base when the value is unusable. */
function rebase(base: URL, xmlBase: string | null): URL {
  if (!xmlBase || xmlBase.length > MAX_LINK_LENGTH) return base;
  try {
    return new URL(xmlBase.trim(), base);
  } catch {
    return base;
  }
}

// ---------------------------------------------------------------------------
// The parsed tree. With `preserveOrder`, fast-xml-parser returns every element
// as `{ <tag>: children[], ":@": { "@_attr": value } }`, text as
// `{ "#text": string }` and CDATA as `{ "#cdata": [{ "#text": string }] }`,
// in document order. Text and attribute values still hold their references.

type XmlNode = Record<string, unknown>;

const parser = () =>
  new XMLParser({
    preserveOrder: true,
    ignoreAttributes: false,
    attributeNamePrefix: "@_",
    parseTagValue: false,
    parseAttributeValue: false,
    trimValues: false,
    // No entity is ever expanded by the parser; see the top of this file.
    processEntities: false,
    htmlEntities: false,
    cdataPropName: "#cdata",
    maxNestedTags: MAX_NESTING,
    ignoreDeclaration: true,
    ignorePiTags: true,
  });

function tagOf(node: XmlNode): string {
  for (const key in node) if (key !== ":@") return key;
  return "";
}

function kids(node: XmlNode): XmlNode[] {
  const value = node[tagOf(node)];
  return Array.isArray(value) ? (value as XmlNode[]) : [];
}

function attribute(node: XmlNode, name: string): string | null {
  const attributes = node[":@"];
  if (typeof attributes !== "object" || attributes === null) return null;
  const key = `@_${name}`;
  if (!Object.hasOwn(attributes, key)) return null;
  const value = (attributes as Record<string, unknown>)[key];
  return typeof value === "string" ? decodeEntities(value.slice(0, MAX_FIELD)) : null;
}

// An item is asked for a dozen fields; its children are sorted by name once.
const indexes = new WeakMap<XmlNode, Map<string, XmlNode[]>>();

function indexOf(node: XmlNode): Map<string, XmlNode[]> {
  let index = indexes.get(node);
  if (!index) {
    index = new Map();
    const all = kids(node);
    const end = Math.min(all.length, MAX_CHILDREN);
    for (let i = 0; i < end; i++) {
      const child = all[i] as XmlNode;
      const name = tagOf(child).toLowerCase();
      const list = index.get(name);
      if (list) list.push(child);
      else index.set(name, [child]);
    }
    indexes.set(node, index);
  }
  return index;
}

/** Direct children with one of the given tag names (lower case), first name first; looks at the first MAX_CHILDREN children. */
function children(node: XmlNode, ...names: string[]): XmlNode[] {
  const index = indexOf(node);
  const found: XmlNode[] = [];
  for (const name of names) {
    const list = index.get(name);
    if (list) found.push(...list);
  }
  return found;
}

const child = (node: XmlNode, ...names: string[]): XmlNode | null => children(node, ...names)[0] ?? null;

// Inline XHTML elements: no space is put where their tags stood.
const INLINE = new Set(["a", "b", "i", "em", "strong", "span", "code", "sub", "sup", "u", "small", "abbr", "cite", "q"]);

/**
 * The content of an element as one string, at most MAX_FIELD characters, in
 * document order: text (with its references decoded once when `decodeText`,
 * otherwise as written), CDATA exactly as written, and the text of nested
 * elements (Atom XHTML content) with a space at block boundaries.
 */
function markup(node: XmlNode, decodeText: boolean): string {
  let out = "";
  const walk = (nodes: XmlNode[], depth: number) => {
    for (const item of nodes) {
      if (out.length >= MAX_FIELD) return;
      const tag = tagOf(item);
      if (tag === "#text") {
        const value = item["#text"];
        if (typeof value === "string") {
          const piece = value.slice(0, MAX_FIELD - out.length);
          out += decodeText ? decodeEntities(piece) : piece;
        }
      } else if (tag === "#cdata") {
        for (const part of kids(item)) {
          const value = part["#text"];
          if (typeof value === "string") out += value.slice(0, MAX_FIELD - out.length);
        }
      } else if (depth < MAX_NESTING) {
        const inline = INLINE.has(tag.toLowerCase());
        if (!inline) out += " ";
        walk(kids(item), depth + 1);
        if (!inline) out += " ";
      }
    }
  };
  walk(kids(node), 0);
  return out;
}

/**
 * An element whose content is HTML written as text: `<description>` in RSS,
 * Atom `type="html"`. Escaped text is unescaped once to get the HTML; CDATA
 * already is the HTML.
 */
const htmlField = (node: XmlNode, max: number) => htmlToText(markup(node, true), max);

/** An element whose content is plain text: a date, a link, an Atom `type="text"` title. */
const textField = (node: XmlNode, max: number) => plainText(markup(node, false), max);

/** Atom text construct: `type` is text (the default), html or xhtml. */
function atomText(node: XmlNode, max: number): string {
  const type = (attribute(node, "type") ?? "text").toLowerCase();
  if (type === "html" || type === "text/html") return htmlField(node, max);
  // XHTML: the nested elements' text, whose references are HTML references.
  if (type === "xhtml" || type.endsWith("xhtml+xml")) return plainText(markup(node, false), max);
  return textField(node, max);
}

function firstDate(node: XmlNode, names: string[]): number | null {
  for (const name of names) {
    for (const candidate of children(node, name)) {
      const seconds = parseFeedDate(markup(candidate, false).slice(0, 80));
      if (seconds !== null) return seconds;
    }
  }
  return null;
}

/** A title, or when the item has none, the start of its excerpt. */
function titleOr(title: string, excerpt: string | null): string {
  return title !== "" ? title : excerpt ? clip(excerpt, 100) : "";
}

// ---------------------------------------------------------------------------
// RSS 2.0 and RSS 1.0 (RDF)

const RSS_DATES = ["pubdate", "dc:date", "published", "updated", "atom:published", "atom:updated", "date"];

function rssItem(item: XmlNode, base: URL): FeedItem | null {
  let link: string | null = null;
  const linkNode = child(item, "link");
  if (linkNode) link = safeLink(textField(linkNode, MAX_LINK_LENGTH), base);
  if (!link) {
    // RSS 1.0 names the item by its address.
    const about = attribute(item, "rdf:about");
    if (about) link = safeLink(about, base);
  }
  if (!link) {
    const guid = child(item, "guid");
    if (guid && (attribute(guid, "isPermaLink") ?? "true").toLowerCase() !== "false") {
      const value = textField(guid, MAX_LINK_LENGTH);
      if (/^https?:\/\//i.test(value)) link = safeLink(value, base);
    }
  }
  if (!link) {
    for (const atomLink of children(item, "atom:link")) {
      const rel = (attribute(atomLink, "rel") ?? "alternate").toLowerCase();
      const href = attribute(atomLink, "href");
      if (rel === "alternate" && href && (link = safeLink(href, base))) break;
    }
  }
  if (!link) return null;

  const description = child(item, "description") ?? child(item, "summary");
  let excerpt = description ? htmlField(description, MAX_EXCERPT) : "";
  if (excerpt === "") {
    const content = child(item, "content:encoded");
    if (content) excerpt = htmlField(content, MAX_EXCERPT);
  }
  const titleNode = child(item, "title");
  const title = titleOr(titleNode ? htmlField(titleNode, MAX_TITLE) : "", excerpt);
  if (title === "") return null;

  return { title, link, published: firstDate(item, RSS_DATES), excerpt: excerpt === "" ? null : excerpt };
}

function readRss(channel: XmlNode | null, itemParents: XmlNode[], base: URL): ParsedFeed {
  const titleNode = channel ? child(channel, "title") : null;
  const title = titleNode ? htmlField(titleNode, MAX_SOURCE) : "";
  const items: FeedItem[] = [];
  let scanned = 0;
  for (const parent of itemParents) {
    for (const node of kids(parent)) {
      if (scanned >= MAX_ITEMS_SCANNED) break;
      if (tagOf(node).toLowerCase() !== "item") continue;
      scanned += 1;
      const item = rssItem(node, base);
      if (item) items.push(item);
    }
  }
  return { title: title === "" ? null : title, items };
}

// ---------------------------------------------------------------------------
// Atom

/** Atom element names with and without the conventional prefix. */
const atom = (name: string) => [name, `atom:${name}`];

function atomLink(entry: XmlNode, base: URL): string | null {
  let fallback: string | null = null;
  for (const node of children(entry, ...atom("link"))) {
    const rel = (attribute(node, "rel") ?? "alternate").toLowerCase();
    if (rel !== "alternate") continue;
    const href = attribute(node, "href");
    if (!href) continue;
    const link = safeLink(href, rebase(base, attribute(node, "xml:base")));
    if (!link) continue;
    const type = (attribute(node, "type") ?? "text/html").toLowerCase();
    if (type.includes("html")) return link;
    fallback ??= link;
  }
  return fallback;
}

function atomEntry(entry: XmlNode, feedBase: URL): FeedItem | null {
  const base = rebase(feedBase, attribute(entry, "xml:base"));
  const link = atomLink(entry, base);
  if (!link) return null;

  const summary = child(entry, ...atom("summary"));
  let excerpt = summary ? atomText(summary, MAX_EXCERPT) : "";
  if (excerpt === "") {
    const content = child(entry, ...atom("content"));
    if (content) excerpt = atomText(content, MAX_EXCERPT);
  }
  const titleNode = child(entry, ...atom("title"));
  const title = titleOr(titleNode ? atomText(titleNode, MAX_TITLE) : "", excerpt);
  if (title === "") return null;

  const published = firstDate(entry, ["published", "atom:published", "updated", "atom:updated", "issued", "modified", "dc:date"]);
  return { title, link, published, excerpt: excerpt === "" ? null : excerpt };
}

function readAtom(feed: XmlNode, feedUrl: URL): ParsedFeed {
  const base = rebase(feedUrl, attribute(feed, "xml:base"));
  const titleNode = child(feed, ...atom("title"));
  const title = titleNode ? atomText(titleNode, MAX_SOURCE) : "";
  const items: FeedItem[] = [];
  let scanned = 0;
  for (const node of kids(feed)) {
    if (scanned >= MAX_ITEMS_SCANNED) break;
    const tag = tagOf(node).toLowerCase();
    if (tag !== "entry" && tag !== "atom:entry") continue;
    scanned += 1;
    const item = atomEntry(node, base);
    if (item) items.push(item);
  }
  return { title: title === "" ? null : title, items };
}

// ---------------------------------------------------------------------------

/**
 * Parses feed text fetched from `feedUrl` (the address that answered, used to
 * resolve relative links). Items come back in feed order, each with a title
 * and a checked link; nothing is filtered by date here. Throws
 * `FeedParseError` when the text is not RSS, RDF or Atom.
 */
export function parseFeed(text: string, feedUrl: URL): ParsedFeed {
  let tree: unknown;
  try {
    tree = parser().parse(text);
  } catch {
    throw new FeedParseError();
  }
  if (!Array.isArray(tree)) throw new FeedParseError();

  // The root is the first element; a document is a feed by its root, not by
  // having parsed (an HTML page often parses too).
  const root = (tree as XmlNode[]).find((node) => {
    const tag = tagOf(node);
    return tag !== "#text" && tag !== "#cdata" && !tag.startsWith("?") && !tag.startsWith("!");
  });
  if (!root) throw new FeedParseError();

  switch (tagOf(root).toLowerCase()) {
    case "rss": {
      const channel = child(root, "channel");
      if (!channel) throw new FeedParseError();
      return readRss(channel, [channel], feedUrl);
    }
    case "rdf:rdf": {
      const channel = child(root, "channel");
      if (!channel && children(root, "item").length === 0) throw new FeedParseError();
      // RSS 1.0 lists items beside the channel; RSS 0.90 feeds sometimes nest them.
      return readRss(channel, channel ? [root, channel] : [root], feedUrl);
    }
    case "feed":
    case "atom:feed":
      return readAtom(root, feedUrl);
    default:
      throw new FeedParseError();
  }
}
