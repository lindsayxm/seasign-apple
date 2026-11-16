// Turning text from feeds and pages into plain text. Everything here reads
// attacker-controlled input, so every function is a single forward scan: no
// regular expression runs over the input except ones made of one character
// class (which cannot backtrack), and each loop moves forward on every step.

/** HTML is not scanned past this many characters; an excerpt needs far less. */
const MAX_HTML_SCAN = 40_000;

// The named references feeds and pages actually use: the XML five, Latin-1,
// and common punctuation and symbols. An unknown name is left as written.
const NAMED = new Map<string, string>(
  Object.entries({
    amp: "&", lt: "<", gt: ">", quot: '"', apos: "'",
    nbsp: "\u00a0", iexcl: "¡", cent: "¢", pound: "£", curren: "¤", yen: "¥", brvbar: "¦", sect: "§", uml: "¨",
    copy: "©", ordf: "ª", laquo: "«", not: "¬", shy: "", reg: "®", macr: "¯", deg: "°", plusmn: "±",
    sup2: "²", sup3: "³", acute: "´", micro: "µ", para: "¶", middot: "·", cedil: "¸", sup1: "¹", ordm: "º",
    raquo: "»", frac14: "¼", frac12: "½", frac34: "¾", iquest: "¿",
    Agrave: "À", Aacute: "Á", Acirc: "Â", Atilde: "Ã", Auml: "Ä", Aring: "Å", AElig: "Æ", Ccedil: "Ç",
    Egrave: "È", Eacute: "É", Ecirc: "Ê", Euml: "Ë", Igrave: "Ì", Iacute: "Í", Icirc: "Î", Iuml: "Ï",
    ETH: "Ð", Ntilde: "Ñ", Ograve: "Ò", Oacute: "Ó", Ocirc: "Ô", Otilde: "Õ", Ouml: "Ö", times: "×",
    Oslash: "Ø", Ugrave: "Ù", Uacute: "Ú", Ucirc: "Û", Uuml: "Ü", Yacute: "Ý", THORN: "Þ", szlig: "ß",
    agrave: "à", aacute: "á", acirc: "â", atilde: "ã", auml: "ä", aring: "å", aelig: "æ", ccedil: "ç",
    egrave: "è", eacute: "é", ecirc: "ê", euml: "ë", igrave: "ì", iacute: "í", icirc: "î", iuml: "ï",
    eth: "ð", ntilde: "ñ", ograve: "ò", oacute: "ó", ocirc: "ô", otilde: "õ", ouml: "ö", divide: "÷",
    oslash: "ø", ugrave: "ù", uacute: "ú", ucirc: "û", uuml: "ü", yacute: "ý", thorn: "þ", yuml: "ÿ",
    OElig: "Œ", oelig: "œ", Scaron: "Š", scaron: "š", Yuml: "Ÿ", fnof: "ƒ", circ: "ˆ", tilde: "˜",
    ensp: "\u2002", emsp: "\u2003", thinsp: "\u2009", zwnj: "", zwj: "", lrm: "", rlm: "",
    ndash: "–", mdash: "—", lsquo: "‘", rsquo: "’", sbquo: "‚", ldquo: "“", rdquo: "”", bdquo: "„",
    dagger: "†", Dagger: "‡", bull: "•", hellip: "…", permil: "‰", prime: "′", Prime: "″",
    lsaquo: "‹", rsaquo: "›", oline: "‾", frasl: "⁄", euro: "€", trade: "™",
    larr: "←", uarr: "↑", rarr: "→", darr: "↓", harr: "↔", minus: "−", ne: "≠", le: "≤", ge: "≥",
    asymp: "≈", infin: "∞",
  }),
);

// Numeric references 128–159 are written by old Windows software meaning
// these characters; browsers read them the same way.
const CP1252 = [
  0x20ac, 0xfffd, 0x201a, 0x0192, 0x201e, 0x2026, 0x2020, 0x2021, 0x02c6, 0x2030, 0x0160, 0x2039, 0x0152, 0xfffd, 0x017d, 0xfffd,
  0xfffd, 0x2018, 0x2019, 0x201c, 0x201d, 0x2022, 0x2013, 0x2014, 0x02dc, 0x2122, 0x0161, 0x203a, 0x0153, 0xfffd, 0x017e, 0x0178,
];

/** The longest reference read: "&" plus 10 characters plus ";". */
const MAX_REFERENCE = 12;

function fromCodePoint(code: number): string {
  if (!Number.isFinite(code) || code <= 0 || code > 0x10ffff) return "\ufffd";
  if (code >= 0xd800 && code <= 0xdfff) return "\ufffd";
  if (code >= 0x80 && code <= 0x9f) return String.fromCodePoint(CP1252[code - 0x80] as number);
  if (code < 0x20 || code === 0x7f) return " ";
  return String.fromCodePoint(code);
}

/** The reference starting at `input[at] === "&"`, or null when there is none. */
function readReference(input: string, at: number): { text: string; end: number } | null {
  const limit = Math.min(input.length, at + MAX_REFERENCE);
  let end = -1;
  for (let i = at + 1; i < limit; i++) {
    const c = input.charCodeAt(i);
    if (c === 59) {
      end = i;
      break;
    }
    const alnum = (c >= 48 && c <= 57) || (c >= 65 && c <= 90) || (c >= 97 && c <= 122);
    if (!alnum && !(c === 35 && i === at + 1)) return null;
  }
  if (end < at + 2) return null;
  const name = input.slice(at + 1, end);
  if (name.charCodeAt(0) === 35) {
    const hex = name.charCodeAt(1) === 120 || name.charCodeAt(1) === 88;
    const digits = name.slice(hex ? 2 : 1);
    if (digits === "" || !(hex ? /^[0-9a-fA-F]+$/ : /^[0-9]+$/).test(digits)) return null;
    return { text: fromCodePoint(parseInt(digits, hex ? 16 : 10)), end: end + 1 };
  }
  const value = NAMED.get(name);
  return value === undefined ? null : { text: value, end: end + 1 };
}

/**
 * Replaces character references (`&amp;`, `&#8217;`, `&#x2019;`, `&eacute;`)
 * once. Unknown names and stray ampersands stay as written. There are no
 * user-defined entities, so the output is never longer than the input.
 */
export function decodeEntities(input: string): string {
  let at = input.indexOf("&");
  if (at < 0) return input;
  let out = "";
  let from = 0;
  while (at >= 0) {
    out += input.slice(from, at);
    const reference = readReference(input, at);
    if (reference) {
      out += reference.text;
      from = reference.end;
    } else {
      out += "&";
      from = at + 1;
    }
    at = input.indexOf("&", from);
  }
  return out + input.slice(from);
}

/** Runs of white space, control and zero-width characters become one space; the ends are trimmed. */
export function collapseSpace(text: string): string {
  return text.replace(/[\s\u0000-\u001f\u007f\u00a0\u200b-\u200f\u2028\u2029\ufeff]+/g, " ").trim();
}

/** Cuts text to at most `max` characters, at a word boundary when one is near, and marks the cut with "…". */
export function clip(text: string, max: number): string {
  if (text.length <= max) return text;
  let end = max - 1;
  const space = text.lastIndexOf(" ", end);
  if (space >= end - 40 && space > 0) end = space;
  // Do not cut a surrogate pair in half.
  const last = text.charCodeAt(end - 1);
  if (last >= 0xd800 && last <= 0xdbff) end -= 1;
  return `${text.slice(0, end).trimEnd()}…`;
}

// Tags that end a line or a block: a space is put where they stood.
const BREAKING = new Set([
  "p", "br", "div", "li", "ul", "ol", "tr", "td", "th", "table", "h1", "h2", "h3", "h4", "h5", "h6",
  "blockquote", "section", "article", "figure", "figcaption", "hr", "pre", "dd", "dt", "img",
]);
/** Elements whose content is not text for a reader. */
const SKIPPED = new Set(["script", "style", "noscript", "template", "svg", "iframe"]);

const isLetter = (c: number) => (c >= 65 && c <= 90) || (c >= 97 && c <= 122);

/** The index just past the `>` that closes the tag opening at `lt`, or -1. Quoted attribute values may hold `>`. */
function tagEnd(input: string, lt: number): number {
  let quote = 0;
  for (let i = lt + 1; i < input.length; i++) {
    const c = input.charCodeAt(i);
    if (quote !== 0) {
      if (c === quote) quote = 0;
    } else if (c === 34 || c === 39) {
      quote = c;
    } else if (c === 62) {
      return i + 1;
    }
  }
  return -1;
}

/** The lower-case name of the tag at `lt` ("p" for both `<p>` and `</p>`); at most 12 letters are read. */
function tagName(input: string, lt: number): string {
  let i = lt + 1;
  if (input.charCodeAt(i) === 47) i += 1;
  const start = i;
  while (i < input.length && i - start < 12) {
    const c = input.charCodeAt(i);
    if (!isLetter(c) && !(c >= 48 && c <= 57)) break;
    i += 1;
  }
  return input.slice(start, i).toLowerCase();
}

/** The index of `</name` at or after `from`, compared without regard to case, or -1. */
function closingTag(input: string, name: string, from: number): number {
  let at = input.indexOf("</", from);
  while (at >= 0) {
    if (input.slice(at + 2, at + 2 + name.length).toLowerCase() === name) return at;
    at = input.indexOf("</", at + 2);
  }
  return -1;
}

/**
 * HTML to plain text: tags, comments, scripts and styles are dropped,
 * character references are decoded, white space is collapsed, and the result
 * is cut to `max` characters. One forward scan; an unclosed tag, comment or
 * script ends the text there.
 */
export function htmlToText(html: string, max: number): string {
  const input = html.length > MAX_HTML_SCAN ? html.slice(0, MAX_HTML_SCAN) : html;
  // A reference is at most MAX_REFERENCE characters for one of output.
  const enough = max * MAX_REFERENCE + 64;
  let out = "";
  let i = 0;
  while (i < input.length && out.length < enough) {
    const lt = input.indexOf("<", i);
    if (lt < 0) {
      out += input.slice(i, i + enough);
      break;
    }
    out += input.slice(i, Math.min(lt, i + enough));
    const next = input.charCodeAt(lt + 1);
    if (!isLetter(next) && next !== 47 && next !== 33 && next !== 63) {
      // "a < b": not a tag.
      out += "<";
      i = lt + 1;
      continue;
    }
    if (input.startsWith("<!--", lt)) {
      const end = input.indexOf("-->", lt + 4);
      if (end < 0) break;
      i = end + 3;
      continue;
    }
    const end = tagEnd(input, lt);
    if (end < 0) break;
    const name = tagName(input, lt);
    if (SKIPPED.has(name) && input.charCodeAt(lt + 1) !== 47 && input.charCodeAt(end - 2) !== 47) {
      const close = closingTag(input, name, end);
      if (close < 0) break;
      const closeEnd = tagEnd(input, close);
      if (closeEnd < 0) break;
      out += " ";
      i = closeEnd;
      continue;
    }
    if (BREAKING.has(name)) out += " ";
    i = end;
  }
  return clip(collapseSpace(decodeEntities(out)), max);
}

/** Text that is not HTML (an Atom `type="text"` title, a page's `<title>`): references decoded, space collapsed, cut to `max`. */
export function plainText(text: string, max: number): string {
  const input = text.length > max * MAX_REFERENCE + 64 ? text.slice(0, max * MAX_REFERENCE + 64) : text;
  return clip(collapseSpace(decodeEntities(input)), max);
}
