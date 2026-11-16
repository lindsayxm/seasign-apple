// Turning a provider's answer into items. Nothing that comes back is trusted:
// the model's JSON may be fenced, wrapped in prose, cut off or wrong, its URLs
// may be invented, and its text may hold markup or control characters.
import { z } from "@hono/zod-openapi";
import { parseFeedDate } from "../lib/feed-parse.ts";
import { SafeFetchError, assertSafeUrl } from "../lib/safe-fetch.ts";
import { plainText, wellFormed } from "../lib/text.ts";
import { MAX_ITEMS } from "./prompt.ts";
import type { Citation, ProviderOutput } from "./types.ts";

export const MAX_TITLE = 300;
export const MAX_SOURCE = 120;
export const MAX_EXCERPT = 300;
const MAX_LINK = 2048;
/** Model text scanned for JSON. 20 items are about 10 KB. */
const MAX_TEXT_SCANNED = 200_000;
/** Item objects looked at, valid or not, across all fences. */
const MAX_CANDIDATES = 100;
/** Code fences looked inside. */
const MAX_FENCES = 20;
/** An item holding this many consecutive characters of the key is not returned. */
export const KEY_RUN = 8;
/** Citations kept from one answer. */
const MAX_CITATIONS = 500;
/** A date up to a day ahead counts as now (a date without a time is midnight UTC, and zones run ahead). */
const MAX_FUTURE_SECONDS = 24 * 60 * 60;
/** Items older than this are left out: the app shows the last 7 days, and a day is allowed for dates without a time. */
const MAX_AGE_SECONDS = 8 * 24 * 60 * 60;
/** Google's grounding redirect links are not the article's address and expire. */
const REDIRECT_HOSTS = new Set(["vertexaisearch.cloud.google.com"]);

export type DiscoverItem = {
  title: string;
  link: string;
  source: string;
  /** UTC instant at second precision, or null. */
  published: string | null;
  excerpt: string | null;
  interest: string | null;
};

// One item as the model was asked to write it. Every field is checked again
// below. Title and URL must be right; a wrong optional field only loses that field.
const ModelItem = z.object({
  title: z.string().max(4000),
  url: z.string().max(MAX_LINK * 2),
  source: z.string().max(4000).nullish().catch(null),
  published: z.string().max(200).nullish().catch(null),
  description: z.string().max(8000).nullish().catch(null),
  interest: z.union([z.number(), z.string().max(400)]).nullish().catch(null),
});
type ModelItem = z.infer<typeof ModelItem>;

// ---------------------------------------------------------------------------
// JSON in model text

/**
 * The places JSON may be, in the order they are tried: the inside of each
 * ``` fence (a fence left open at the end, as in an answer cut off by the
 * token limit, runs to the end of the text), then the text outside the
 * fences. Fences past MAX_FENCES are left out. One pass of `indexOf`, so the
 * pieces together are never longer than the text.
 */
function textBlocks(text: string): string[] {
  const blocks: string[] = [];
  const outside: string[] = [];
  let at = 0;
  while (blocks.length < MAX_FENCES) {
    const open = text.indexOf("```", at);
    if (open < 0) break;
    const lineEnd = text.indexOf("\n", open);
    if (lineEnd < 0) break;
    outside.push(text.slice(at, open));
    const close = text.indexOf("```", lineEnd);
    if (close < 0) {
      blocks.push(text.slice(lineEnd + 1));
      at = text.length;
      break;
    }
    blocks.push(text.slice(lineEnd + 1, close));
    at = close + 3;
  }
  if (blocks.length < MAX_FENCES) outside.push(text.slice(at));
  blocks.push(outside.join("\n"));
  return blocks;
}

/**
 * The objects in the text that sit where items would: inside `{"items": [...]}`
 * or a bare `[...]`. One forward scan that knows about strings, so braces in
 * titles do not count. Each complete object is parsed on its own, so an answer
 * cut off in the middle (out of output tokens) still gives its whole items,
 * and one broken item does not lose the others. Objects nested deeper than an
 * item are not parsed separately, so the work stays linear.
 */
function candidateObjects(text: string, budget: { left: number }): unknown[] {
  const found: unknown[] = [];
  const opens: { char: number; at: number }[] = [];
  let inString = false;
  let escaped = false;
  for (let i = 0; i < text.length && budget.left > 0; i++) {
    const c = text.charCodeAt(i);
    if (inString) {
      if (escaped) escaped = false;
      else if (c === 92) escaped = true; // backslash
      else if (c === 34) inString = false;
      continue;
    }
    if (c === 34) {
      // A quote outside any brace is prose ("Here are the results"), not JSON.
      if (opens.length > 0) inString = true;
    } else if (c === 123 || c === 91) {
      opens.push({ char: c, at: i });
    } else if (c === 125 || c === 93) {
      const open = opens.pop();
      if (!open || (open.char === 123) !== (c === 125)) {
        // Unbalanced: start again from here.
        opens.length = 0;
        continue;
      }
      // Items are objects one level inside an array that is at most two deep: `[{…}]` or `{"items":[{…}]}`.
      const parent = opens[opens.length - 1];
      if (c === 125 && parent?.char === 91 && opens.length <= 2) {
        try {
          found.push(JSON.parse(text.slice(open.at, i + 1)));
          budget.left -= 1;
        } catch {
          // Not JSON after all; skipped.
        }
      }
    }
  }
  return found;
}

/**
 * The item objects the model wrote, each checked on its own; malformed ones
 * are dropped. The model may put prose or an example in one fence and its
 * answer in another, so each fence is tried in order and then the text
 * outside them, and the first that holds at least one valid item is used.
 * The candidate cap is shared by all of them, so many fences cost no more
 * than one.
 */
export function modelItems(text: string): ModelItem[] {
  const budget = { left: MAX_CANDIDATES };
  for (const block of textBlocks(text.slice(0, MAX_TEXT_SCANNED))) {
    if (budget.left <= 0) break;
    const items: ModelItem[] = [];
    for (const candidate of candidateObjects(block, budget)) {
      const parsed = ModelItem.safeParse(candidate);
      if (parsed.success) items.push(parsed.data);
    }
    if (items.length > 0) return items;
  }
  return [];
}

// ---------------------------------------------------------------------------
// Links

const TRACKING = /^(utm_[a-z]+|fbclid|gclid|mc_cid|mc_eid)$/i;

/** A provider URL as a link we may return: https (http is read as https), a public host, no credentials, not a redirect service. */
export function safeLink(input: string): URL | null {
  if (input.length > MAX_LINK) return null;
  let url: URL;
  try {
    url = new URL(input.trim());
  } catch {
    return null;
  }
  if (url.protocol === "http:") url.protocol = "https:";
  url.hash = "";
  try {
    assertSafeUrl(url);
  } catch (error) {
    if (error instanceof SafeFetchError) return null;
    throw error;
  }
  if (REDIRECT_HOSTS.has(url.hostname.toLowerCase())) return null;
  return url.href.length > MAX_LINK ? null : url;
}

/**
 * What two spellings of one page have in common, for matching a URL the model
 * wrote with one the provider gave: the scheme, a leading `www.`, the
 * fragment, a trailing slash and tracking parameters do not count.
 */
export function matchKey(input: string): string | null {
  let url: URL;
  try {
    url = new URL(input.trim());
  } catch {
    return null;
  }
  const host = url.hostname.toLowerCase().replace(/^www\./, "");
  const params = [...url.searchParams].filter(([name]) => !TRACKING.test(name));
  params.sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0));
  const query = params.length > 0 ? `?${new URLSearchParams(params).toString()}` : "";
  // Trailing slashes are dropped with a loop: a pattern anchored at the end would rescan long runs of slashes.
  let end = url.pathname.length;
  while (end > 1 && url.pathname.charCodeAt(end - 1) === 47) end -= 1;
  const path = end > 1 ? url.pathname.slice(0, end) : "";
  return `${host}${path}${query}`;
}

// ---------------------------------------------------------------------------
// Dates

const MONTHS = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"];
/** "April 30, 2025" or "Apr 30 2025", as some search results give a page's age. */
const MONTH_DAY_YEAR = /^([A-Za-z]{3,9})\.?\s(\d{1,2}),?\s(\d{4})$/;

/** Unix seconds for a date written in one of the usual ways, or null when unsure ("2 days ago", "Spring 2026"). */
export function lenientDate(input: string | null | undefined): number | null {
  if (!input) return null;
  const text = input.trim().slice(0, 64);
  const known = parseFeedDate(text);
  if (known !== null) return known;
  const match = MONTH_DAY_YEAR.exec(text);
  if (!match) return null;
  const month = MONTHS.indexOf((match[1] as string).slice(0, 3).toLowerCase());
  if (month < 0) return null;
  return parseFeedDate(`${match[3]}-${String(month + 1).padStart(2, "0")}-${(match[2] as string).padStart(2, "0")}`);
}

// ---------------------------------------------------------------------------
// The key in returned text

/** Every run of KEY_RUN consecutive characters of the key, for `holdsKeyRun`. */
export function keyRuns(key: string): Set<string> {
  const runs = new Set<string>();
  for (let i = 0; i + KEY_RUN <= key.length; i++) runs.add(key.slice(i, i + KEY_RUN));
  return runs;
}

/**
 * Whether the text holds any KEY_RUN consecutive characters of the key
 * (case-sensitive): one look-up per position, so the work is the text's
 * length whatever the key's.
 */
export function holdsKeyRun(text: string, runs: Set<string>): boolean {
  for (let i = 0; i + KEY_RUN <= text.length; i++) if (runs.has(text.slice(i, i + KEY_RUN))) return true;
  return false;
}

const instantOf = (seconds: number) => new Date(seconds * 1000).toISOString().replace(/\.\d{3}Z$/, "Z");

// ---------------------------------------------------------------------------
// Items

/** The interest an item matched: an index into the request's list, or the same text; anything else is null. */
function interestOf(value: ModelItem["interest"], interests: string[]): string | null {
  if (typeof value === "number") return Number.isInteger(value) ? (interests[value] ?? null) : null;
  if (typeof value === "string") {
    const wanted = value.trim().toLowerCase();
    if (/^\d{1,2}$/.test(wanted)) return interests[Number(wanted)] ?? null;
    return interests.find((interest) => interest.toLowerCase() === wanted) ?? null;
  }
  return null;
}

/**
 * The items to return. An item is kept only when its URL is one the
 * provider's own metadata says its search returned or cited (the provider's
 * spelling of the URL is returned, never the model's), the URL is a safe
 * https link, and it has a title. Then: text is cleaned and cut, the date is
 * the provider's publication date for the page, else the model's, else the
 * provider's last-updated date; a date in the future is dropped, an item
 * older than the window is dropped, a link is returned once, and at most 20
 * items are returned. The route then drops any item holding a run of the key.
 */
export function finalItems(output: ProviderOutput, interests: string[], nowSeconds: number): DiscoverItem[] {
  const cited = new Map<string, { url: URL; citation: Citation }>();
  for (const citation of output.citations.slice(0, MAX_CITATIONS)) {
    const url = safeLink(citation.url);
    const key = url ? matchKey(url.href) : null;
    if (!url || !key) continue;
    const known = cited.get(key);
    if (!known) cited.set(key, { url, citation });
    else
      known.citation = {
        ...known.citation,
        title: known.citation.title ?? citation.title,
        published: known.citation.published ?? citation.published,
        updated: known.citation.updated ?? citation.updated,
      };
  }

  const items: DiscoverItem[] = [];
  const seen = new Set<string>();
  for (const item of modelItems(output.text)) {
    if (items.length >= MAX_ITEMS) break;
    const key = matchKey(item.url.replace(/^http:/i, "https:"));
    const match = key ? cited.get(key) : undefined;
    if (!key || !match || seen.has(key)) continue;

    const title = plainText(item.title, MAX_TITLE) || plainText(match.citation.title ?? "", MAX_TITLE);
    if (title === "") continue;
    const host = match.url.hostname.replace(/^www\./, "");
    const source = plainText(item.source ?? "", MAX_SOURCE) || host;
    const excerpt = plainText(item.description ?? "", MAX_EXCERPT);

    // A publication date the provider gives wins; then the model's, when it
    // reads as a date that is not ahead; then when the provider says the page
    // last changed, which is later than its publication or the same.
    const stated = lenientDate(item.published);
    let published =
      lenientDate(match.citation.published) ??
      (stated !== null && stated <= nowSeconds + MAX_FUTURE_SECONDS ? stated : null) ??
      lenientDate(match.citation.updated);
    if (published !== null && published > nowSeconds + MAX_FUTURE_SECONDS) published = null;
    if (published !== null && published < nowSeconds - MAX_AGE_SECONDS) continue;

    seen.add(key);
    items.push({
      title: wellFormed(title),
      link: match.url.href,
      source: wellFormed(source),
      published: published === null ? null : instantOf(Math.min(published, nowSeconds)),
      excerpt: excerpt === "" ? null : wellFormed(excerpt),
      interest: interestOf(item.interest, interests),
    });
  }
  return items;
}
