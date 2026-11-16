import { XMLParser } from "fast-xml-parser";
import { assertSafeUrl } from "./safe-fetch.ts";
import { clip, collapseSpace, cut, cutSource, decodeEntities, htmlToText, plainText } from "./text.ts";

// RSS 2.0, RSS 1.0 (RDF) and Atom text to a list of items. A feed is
// untrusted input:
//
// - Entities: a DOCTYPE with an internal subset, the only place a document
//   can define entities ("billion laughs", external entities), is refused
//   before parsing, any other DOCTYPE is removed before parsing, and the
//   parser is told to expand none (`processEntities: false`). The five XML
//   references and numeric ones are decoded by `decodeEntities`, which
//   cannot grow its input.
// - Nesting deeper than MAX_NESTING makes the parser throw.
// - Memory: fast-xml-parser builds strings and objects per tag and per
//   attribute, and builds each run of text one character at a time; some
//   shapes of 2 MB (one endless tag, an element with a hundred thousand
//   attributes, half a million empty elements) need more than the 128 MB a
//   Worker has, and one 1 MB run of text needs over 60 MB. `checkShape` reads
//   the text once before the parser sees it and refuses those shapes; see the
//   limits below.
// - At most MAX_ITEMS_SCANNED items are read, and every field is cut before
//   it is decoded or stripped.
// - Whatever the parser throws becomes `FeedParseError` with no text of its
//   own: the parser's messages quote the input.

export const MAX_NESTING = 64;
/** Characters of feed text accepted. The fetch stops at the same number of bytes. */
export const MAX_FEED_CHARS = 1024 * 1024;
/** Characters of one tag, from "<" to ">". Real tags with long URLs in attributes stay under 3,000. */
export const MAX_TAG_CHARS = 8192;
/** Attributes on one element or processing instruction, counted as the parser finds them. A root element with every namespace has about 20. */
export const MAX_ATTRIBUTES = 64;
/**
 * Characters of text in one run between tags. The parser builds such a run
 * one character at a time, and one run of 1M two-byte characters needed
 * 64 to 68 MB of heap where the same text split into runs of this length
 * needed 24. An article's full text is rarely a tenth of this.
 */
export const MAX_TEXT_RUN = 131_072;
/** Tags, comments, CDATA sections and processing instructions in one document. 500 items of 40 elements each are 40,000 tags. */
export const MAX_MARKUP = 60_000;
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
// Zone names feeds use, in minutes east of UTC: the RFC 822 ones and the
// common ones elsewhere. Where a name is used for more than one zone, the
// one more feeds mean is taken (CST and EST are North American, IST is India).
// A name that is not here is read as UTC: a date a few hours out is better
// than an item with no date.
const ZONES: Record<string, number> = {
  ut: 0, utc: 0, gmt: 0, z: 0, est: -300, edt: -240, cst: -360, cdt: -300, mst: -420, mdt: -360, pst: -480, pdt: -420,
  akst: -540, akdt: -480, hst: -600, ast: -240, adt: -180, nst: -210, ndt: -150, brt: -180, art: -180,
  wet: 0, west: 60, bst: 60, cet: 60, cest: 120, met: 60, mest: 120, eet: 120, eest: 180, msk: 180, trt: 180,
  sast: 120, cat: 120, eat: 180, wat: 60, gst: 240, pkt: 300, ist: 330, ict: 420, wib: 420, sgt: 480, hkt: 480,
  awst: 480, pht: 480, jst: 540, kst: 540, acst: 570, acdt: 630, aest: 600, aedt: 660, nzst: 720, nzdt: 780,
};

// Both patterns are anchored and have no nested or adjacent unbounded
// quantifiers over the same characters; the input is cut to 64 characters first.
const ISO_DATE =
  /^(\d{4})-(\d{2})-(\d{2})(?:[Tt ](\d{2}):(\d{2})(?::(\d{2})(?:[.,]\d{1,9})?)?)?\s?(?:([Zz])|([+-])(\d{2}):?(\d{2}))?$/;
// Optional weekday ("Sat, " or "Sat,"), day, month name, year, time, then an
// offset or a zone name, then an optional comment such as "(UTC)".
// The time may be left out (midnight). The zone is an offset (`+0100`,
// `+01:00`), GMT/UTC/UT with an offset (`GMT+1`, `UTC+01:00`, `GMT-0530`),
// or a name.
const RFC822_DATE =
  /^(?:[A-Za-z]{3,9},?\s?)?(\d{1,2})\s([A-Za-z]{3})[A-Za-z]{0,6}\s(\d{2}|\d{4})(?:\s(\d{1,2}):(\d{2})(?::(\d{2}))?)?(?:\s?(?:([+-])(\d{2}):?(\d{2})|(?:GMT|UTC|UT)([+-])(\d{1,2})(?::?(\d{2}))?|([A-Za-z]{1,5})))?(?:\s?\([^()]{0,40}\))?$/i;

/**
 * Unix seconds for a date and time in a zone `offsetMinutes` east of UTC, or
 * null when the parts are not a date. Any year a pattern can read counts,
 * 0000 to 9999: a date long past is old, not missing (Hugo writes
 * `Mon, 01 Jan 0001` for undated pages), and one far ahead is ahead. Whether
 * either is shown is the caller's 7-day window.
 */
function utcSeconds(year: number, month: number, day: number, hour: number, minute: number, second: number, offsetMinutes: number) {
  if (month < 0 || month > 11 || day < 1 || day > 31 || hour > 23 || minute > 59 || second > 60) return null;
  if (Math.abs(offsetMinutes) > 16 * 60) return null;
  // setUTCFullYear, not Date.UTC, which reads years 0 to 99 as 1900 to 1999.
  const date = new Date(0);
  date.setUTCFullYear(year, month, day);
  // 31 February and the like roll over into another month: not a date.
  if (date.getUTCFullYear() !== year || date.getUTCMonth() !== month || date.getUTCDate() !== day) return null;
  return Math.floor(date.getTime() / 1000) + hour * 3600 + minute * 60 + second - offsetMinutes * 60;
}

/**
 * A feed's date as Unix seconds: ISO 8601 / RFC 3339 (`2026-11-14T09:30:00-05:00`,
 * `2026-11-14`) or RFC 822 (`Sat, 14 Nov 2026 09:30:00 GMT`, `Sat, 14 Nov 2026`).
 * A time without a zone is read as UTC, a date without a time as midnight.
 * Anything else is null. The result may be long before 1970 (negative) or
 * long after now.
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
      // "GMT+1" means one hour east of UTC, as feeds write it (not the POSIX reading).
      offset = (rfc[10] === "-" ? -1 : 1) * (Number(rfc[11]) * 60 + Number(rfc[12] ?? 0));
    } else if (rfc[13]) {
      const name = rfc[13].toLowerCase();
      offset = Object.hasOwn(ZONES, name) ? (ZONES[name] as number) : 0;
    }
    return utcSeconds(year, month, Number(rfc[1]), Number(rfc[4] ?? 0), Number(rfc[5] ?? 0), Number(rfc[6] ?? 0), offset);
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
  return typeof value === "string" ? decodeEntities(cutSource(value, MAX_FIELD)) : null;
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
          const piece = cutSource(value, MAX_FIELD - out.length);
          out += decodeText ? decodeEntities(piece) : piece;
        }
      } else if (tag === "#cdata") {
        for (const part of kids(item)) {
          const value = part["#text"];
          if (typeof value === "string") out += cutSource(value, MAX_FIELD - out.length);
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
      const seconds = parseFeedDate(cut(markup(candidate, false), 80));
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

function readRss(channel: XmlNode | null, itemParents: XmlNode[], feedBase: URL): ParsedFeed {
  const titleNode = channel ? child(channel, "title") : null;
  const title = titleNode ? htmlField(titleNode, MAX_SOURCE) : "";
  const items: FeedItem[] = [];
  let scanned = 0;
  for (const parent of itemParents) {
    for (const node of kids(parent)) {
      if (scanned >= MAX_ITEMS_SCANNED) break;
      if (tagOf(node).toLowerCase() !== "item") continue;
      scanned += 1;
      // xml:base may stand on the channel (or the RDF root) and on the item.
      const base = rebase(rebase(feedBase, attribute(parent, "xml:base")), attribute(node, "xml:base"));
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
// The shape check

/** The index of the quote that closes the one at `at`, or -1. */
const closingQuote = (text: string, at: number) => text.indexOf(text[at] as string, at + 1);

// fast-xml-parser 5.12's attribute pattern (`attrsRegx` in OrderedObjParser),
// copied so that attributes are counted the way the parser finds them. A
// match is an attribute when it has a value; a bare word is dropped.
const PARSER_ATTRIBUTE = /([^\s=]+)\s*(=\s*(?:"([^"]*)"|'([^']*)'))?/g;

/**
 * The attributes the parser will build from the tag or processing
 * instruction whose text between "<" and ">" (or "?>") is `body`: the text
 * after the name, read with the parser's own pattern. Quotes do not hide
 * anything from it: `<x "a='' b=''"/>` has two.
 */
function attributeCount(body: string): number {
  const space = body.search(/\s/);
  if (space < 0) return 0;
  const rest = body.slice(space + 1);
  let count = 0;
  PARSER_ATTRIBUTE.lastIndex = 0;
  for (let match = PARSER_ATTRIBUTE.exec(rest); match; match = PARSER_ATTRIBUTE.exec(rest)) {
    if (match[3] !== undefined || match[4] !== undefined) count += 1;
  }
  return count;
}

/** Where a DOCTYPE stands in a text that passed `checkShape`: `text.slice(start, end)`. */
export type Shape = { doctype: { start: number; end: number } | null };

/**
 * Reads the text once and throws `FeedParseError` unless every piece of
 * markup is closed and small, and no text is one long run:
 *
 * - a tag or processing instruction is at most MAX_TAG_CHARS long, with at
 *   most MAX_ATTRIBUTES attributes as the parser counts them (its own
 *   pattern, which quotes do not stop: see `attributeCount`);
 * - there are at most MAX_MARKUP tags, comments, CDATA sections and
 *   processing instructions;
 * - a "<" starts one of those (never "< " or "<<") and does not stand inside
 *   one outside quotes;
 * - the only declaration is one DOCTYPE, in any letter case, with no internal
 *   subset (which is where entities are defined);
 * - text between markup is at most MAX_TEXT_RUN characters. The parser adds
 *   text to a string one character at a time and only starts a new one at a
 *   tag, a processing instruction or CDATA, so text either side of a comment
 *   or the DOCTYPE counts as one run. CDATA is taken in one piece and has no
 *   such limit.
 *
 * It finds the end of each piece the way fast-xml-parser 5 does (quotes hide
 * a ">" in an opening tag and in a processing instruction, not in a closing
 * tag), so what is one small tag here is one small tag there. Comments and
 * CDATA are skipped, whatever they hold. Each step moves forward: linear.
 *
 * Returns where the DOCTYPE is, so that `parseFeed` can leave it out: the
 * parser reads only an upper-case `<!DOCTYPE` as one.
 */
export function checkShape(text: string): Shape {
  if (text.length > MAX_FEED_CHARS) throw new FeedParseError();
  let doctype: Shape["doctype"] = null;
  let markupCount = 0;
  // Characters of text the parser has gathered since it last started anew.
  let run = 0;
  let textFrom = 0;
  let at = text.indexOf("<");
  while (at >= 0) {
    run += at - textFrom;
    if (run > MAX_TEXT_RUN) throw new FeedParseError();
    if (++markupCount > MAX_MARKUP) throw new FeedParseError();
    let end: number;
    // A comment or the DOCTYPE does not end the run of text around it.
    let endsRun = true;
    if (text.startsWith("<!--", at)) {
      end = text.indexOf("-->", at + 4);
      if (end < 0) throw new FeedParseError();
      end += 3;
      endsRun = false;
    } else if (text.startsWith("<![CDATA[", at)) {
      end = text.indexOf("]]>", at + 9);
      if (end < 0) throw new FeedParseError();
      end += 3;
    } else if (text.charCodeAt(at + 1) === 47) {
      // A closing tag: the parser takes the next ">", quotes or not.
      end = text.indexOf(">", at + 2);
      if (end < 0 || end - at > MAX_TAG_CHARS) throw new FeedParseError();
      end += 1;
    } else {
      const next = text.charCodeAt(at + 1);
      const instruction = next === 63; // "<?"
      const declaration = next === 33; // "<!"
      if (declaration && (doctype !== null || !/^<!doctype\s/i.test(text.slice(at, at + 10)))) throw new FeedParseError();
      const nameStart = (next >= 65 && next <= 90) || (next >= 97 && next <= 122) || next === 95 || next === 58 || next >= 0x80;
      if (!instruction && !declaration && !nameStart) throw new FeedParseError();

      const limit = Math.min(text.length, at + MAX_TAG_CHARS);
      end = -1;
      for (let i = at + 2; i < limit; i++) {
        const c = text.charCodeAt(i);
        if (c === 34 || c === 39) {
          i = closingQuote(text, i);
          if (i < 0 || i >= limit) throw new FeedParseError();
        } else if (c === 60) {
          // A "<" outside quotes is never part of a tag. In a DOCTYPE the
          // parser's reader takes "<!--" there as a way into a subset.
          throw new FeedParseError();
        } else if (c === 91 && declaration) {
          // "<!DOCTYPE x [": an internal subset.
          throw new FeedParseError();
        } else if (c === 62 && (!instruction || text.charCodeAt(i - 1) === 63)) {
          end = i + 1;
          break;
        }
      }
      if (end < 0) throw new FeedParseError();
      if (declaration) {
        doctype = { start: at, end };
        endsRun = false;
      } else if (attributeCount(text.slice(at + 1, instruction ? end - 2 : end - 1)) > MAX_ATTRIBUTES) {
        throw new FeedParseError();
      }
    }
    if (endsRun) run = 0;
    textFrom = end;
    at = text.indexOf("<", end);
  }
  // Text after the last piece of markup is gathered too.
  if (run + text.length - textFrom > MAX_TEXT_RUN) throw new FeedParseError();
  return { doctype };
}

// ---------------------------------------------------------------------------

/**
 * Parses feed text fetched from `feedUrl` (the address that answered, used to
 * resolve relative links). Items come back in feed order, each with a title
 * and a checked link; nothing is filtered by date here. Throws
 * `FeedParseError` when the text is not RSS, RDF or Atom.
 */
export function parseFeed(text: string, feedUrl: URL): ParsedFeed {
  const { doctype } = checkShape(text);
  // The DOCTYPE declares nothing here (a subset is refused, and no external
  // DTD is read), and the parser takes a lower-case `<!doctype rss>` for an
  // element that holds the whole feed. So the parser does not see it.
  const xml = doctype ? text.slice(0, doctype.start) + text.slice(doctype.end) : text;
  let tree: unknown;
  try {
    tree = parser().parse(xml);
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
      return readRss(channel, [channel], rebase(feedUrl, attribute(root, "xml:base")));
    }
    case "rdf:rdf": {
      const channel = child(root, "channel");
      if (!channel && children(root, "item").length === 0) throw new FeedParseError();
      // RSS 1.0 lists items beside the channel; RSS 0.90 feeds sometimes nest them.
      return readRss(channel, channel ? [root, channel] : [root], rebase(feedUrl, attribute(root, "xml:base")));
    }
    case "feed":
    case "atom:feed":
      return readAtom(root, feedUrl);
    default:
      throw new FeedParseError();
  }
}
