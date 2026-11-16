import { env, exports } from "cloudflare:workers";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { linkHash, readSite, seenCacheKey, siteCacheKey, type SiteSource } from "../src/lib/site-reader.ts";
// Written by hand in the shape of real feeds and pages; no real site was fetched.
import atom from "./fixtures/sites/atom.xml?raw";
import badDates from "./fixtures/sites/bad-dates.xml?raw";
import links from "./fixtures/sites/links.html?raw";
import rdf from "./fixtures/sites/rdf.xml?raw";
import rss2 from "./fixtures/sites/rss2.xml?raw";
import { startWorker } from "./start-worker.ts";

startWorker();

/** Monday 16 November 2026, 15:00 UTC. The fixtures' dates are written around it. */
const NOW = new Date("2026-11-16T15:00:00Z");
const MINUTE = 60 * 1000;
const DAY = 24 * 60 * MINUTE;

const NEWS = { url: "https://news.example.com/science/", mode: "feed", feedUrl: "https://news.example.com/science/feed/" } as const;
const BLOG = { url: "https://blog.example.org/notes/", mode: "feed", feedUrl: "https://blog.example.org/notes/atom.xml" } as const;
const JOURNAL = { url: "https://journal.example.net/", mode: "feed", feedUrl: "https://journal.example.net/rss" } as const;
const CARELESS = { url: "https://careless.example.com/", mode: "feed", feedUrl: "https://careless.example.com/feed" } as const;
const WORLD = { url: "https://daily.example.org/world/", mode: "links" } as const;
const BROKEN = { url: "https://broken.example.com/section/tok-5550123/", mode: "feed", feedUrl: "https://broken.example.com/feeds/tok-5550123.xml" } as const;

type Site = { url: string; mode: string; feedUrl?: string };
type Reply = () => Response | Promise<Response>;
const html = (text: string): Reply => () => new Response(text, { headers: { "content-type": "text/html; charset=utf-8" } });
const xml = (text: string): Reply => () => new Response(text, { headers: { "content-type": "application/xml" } });

/** Replaces outbound fetch with a table of exact URLs. Any other request fails, so nothing reaches the network. */
function mockWeb(replies: Record<string, Reply>) {
  return vi.spyOn(globalThis, "fetch").mockImplementation(async (input, init) => {
    const request = new Request(input, init);
    const reply = replies[request.url];
    if (!reply) throw new Error("Unexpected outbound request");
    return reply();
  });
}

const web = {
  [NEWS.feedUrl]: xml(rss2),
  [BLOG.feedUrl]: xml(atom),
  [JOURNAL.feedUrl]: xml(rdf),
  [CARELESS.feedUrl]: xml(badDates),
  [WORLD.url]: html(links),
};

const requested = (spy: ReturnType<typeof mockWeb>) => spy.mock.calls.map(([input]) => String(input));

const post = (body: unknown) =>
  exports.default.fetch("https://example.com/v1/feed", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: typeof body === "string" ? body : JSON.stringify(body),
  });

type Item = { site: number; title: string; link: string; source: string; published: string; dateSource: string; excerpt: string | null };
type Body = { items: Item[]; sites: { index: number; ok: boolean; error?: string }[] };

async function feed(sites: Site[]): Promise<Body> {
  const response = await post({ sites });
  expect(response.status).toBe(200);
  return (await response.json()) as Body;
}

const source = (site: Site): SiteSource =>
  site.mode === "feed"
    ? { url: new URL(site.url), mode: "feed", feedUrl: new URL(site.feedUrl as string) }
    : { url: new URL(site.url), mode: "links" };

async function clearCache() {
  for (;;) {
    const { keys } = await env.CACHE.list({ prefix: "feed:" });
    if (keys.length === 0) return;
    for (const { name } of keys) await env.CACHE.delete(name);
  }
}

/** A feed of `count` items, the first published at NOW and each next one a minute earlier. */
function manyItems(host: string, count: number): string {
  let items = "";
  for (let i = 0; i < count; i++) {
    const date = new Date(NOW.getTime() - i * MINUTE).toUTCString();
    items += `<item><title>Story ${i} from ${host}</title><link>https://${host}/story/${i}</link><pubDate>${date}</pubDate></item>`;
  }
  return `<rss version="2.0"><channel><title>${host}</title>${items}</channel></rss>`;
}

beforeEach(async () => {
  // Only Date is faked: timers keep running, so the fetch deadline still works.
  vi.useFakeTimers({ toFake: ["Date"], now: NOW });
  await clearCache();
});

afterEach(() => {
  vi.useRealTimers();
  vi.restoreAllMocks();
});

describe("POST /v1/feed", () => {
  describe("feed mode", () => {
    it("reads an RSS 2.0 feed: newest first, plain-text excerpts, nothing older than 7 days", async () => {
      mockWeb(web);

      const body = await feed([NEWS]);

      expect(body.sites).toEqual([{ index: 0, ok: true }]);
      expect(body.items).toEqual([
        {
          site: 0,
          title: "A new telescope sees first light — and it’s sharp",
          link: "https://news.example.com/science/new-telescope-first-light/",
          source: "Example News » Science",
          published: "2026-11-16T13:45:00Z",
          dateSource: "published",
          excerpt:
            "The observatory released its first images on Friday. Astronomers say the mirror & its coating performed “better than modelled”. Read more",
        },
        {
          site: 0,
          title: "Why tide pools are getting warmer & saltier",
          link: "https://news.example.com/science/tide-pools-warmer/?utm_source=rss&utm_medium=feed",
          source: "Example News » Science",
          published: "2026-11-13T13:15:30Z",
          dateSource: "published",
          excerpt: "Researchers sampled forty pools along the coast. They found temperatures two degrees above the ten-year mean.",
        },
        {
          site: 0,
          title: "Soil microbes & the 3 < 5 rule",
          link: "https://news.example.com/science/soil-microbes-rule/",
          source: "Example News » Science",
          published: "2026-11-10T22:00:00Z",
          dateSource: "published",
          excerpt: "Escaped markup: A field study & a lab study agree.",
        },
        // "Last week's story about glaciers" (8 November) is older than 7 days.
      ]);
    });

    it("reads an Atom feed with relative links and xml:base", async () => {
      mockWeb(web);

      const body = await feed([BLOG]);

      expect(body.items.map((item) => [item.title, item.link, item.published, item.excerpt])).toEqual([
        ["Mapping the old canal & its locks", "https://blog.example.org/notes/2026/canal-locks/", "2026-11-15T17:20:00Z", "Three days on the towpath with a notebook."],
        ["Sketching herons at dusk", "https://blog.example.org/sketches/heron-dusk.html", "2026-11-12T07:05:09Z", "Grey herons stand very still. Draw fast & lightly."],
        ["Plain text with <b> in it stays as written", "https://blog.example.org/notes/2026/plain-text/", "2026-11-11T00:00:00Z", null],
      ]);
      expect(new Set(body.items.map((item) => item.source))).toEqual(new Set(["Field Notes & Sketches"]));
    });

    it("reads an RSS 1.0 (RDF) feed", async () => {
      mockWeb(web);

      const body = await feed([JOURNAL]);

      expect(body.items.map((item) => [item.title, item.link, item.published, item.source])).toEqual([
        ["Sediment transport in braided rivers", "https://journal.example.net/papers/2026-0142", "2026-11-14T00:00:00Z", "Example Journal: Latest Papers"],
        ["A note on lichen growth rates", "https://journal.example.net/papers/2026-0139", "2026-11-12T00:00:00Z", "Example Journal: Latest Papers"],
      ]);
    });

    it("gives an item whose date cannot be read a first-seen time, and leaves out far-future ones", async () => {
      mockWeb(web);

      const body = await feed([CARELESS]);

      expect(body.items.map((item) => [item.link.split("/posts/")[1], item.published, item.dateSource])).toEqual([
        // Stamped three hours ahead: counted as now, so it cannot sit on top for hours.
        ["ahead", "2026-11-16T15:00:00Z", "published"],
        // No readable date, and nobody has fetched this feed before: nothing says
        // these are new, so they are placed a day back, in feed order.
        ["yesterday", "2026-11-15T15:00:00Z", "first_seen"],
        ["thirty-second", "2026-11-15T14:59:59Z", "first_seen"],
        ["none", "2026-11-15T14:59:58Z", "first_seen"],
        ["thirteen", "2026-11-15T14:59:57Z", "first_seen"],
        ["number", "2026-11-15T14:59:56Z", "first_seen"],
        ["good", "2026-11-15T10:00:00Z", "published"],
        ["second-date", "2026-11-13T04:00:00Z", "published"],
        // "future" (2031) is left out.
      ]);
      expect(body.items.every((item) => typeof item.published === "string")).toBe(true);
    });

    it("lets an undated feed item age out after 7 days, and stamps a later one when it appears", async () => {
      mockWeb(web);
      await feed([CARELESS]);
      const cacheKey = await siteCacheKey(source(CARELESS));

      // Three hours on, the feed has one more undated item.
      vi.setSystemTime(new Date(NOW.getTime() + 180 * MINUTE));
      await env.CACHE.delete(cacheKey);
      vi.restoreAllMocks();
      const added = badDates.replace("<item>", "<item><title>Added later without a date</title><link>https://careless.example.com/posts/later</link></item><item>");
      mockWeb({ [CARELESS.feedUrl]: xml(added) });
      const later = await feed([CARELESS]);
      expect(later.items.slice(0, 3).map((item) => [item.link.split("/posts/")[1], item.published, item.dateSource])).toEqual([
        // "ahead" says 18:00 itself, which has now come.
        ["ahead", "2026-11-16T18:00:00Z", "published"],
        // New to a feed we already know: first seen now.
        ["later", "2026-11-16T18:00:00Z", "first_seen"],
        ["yesterday", "2026-11-15T15:00:00Z", "first_seen"],
      ]);

      // Six days and a minute after the first fetch the undated items of that
      // day are 7 days old by their stamps and are gone, though the feed still lists them.
      vi.setSystemTime(new Date(NOW.getTime() + 6 * DAY + MINUTE));
      await env.CACHE.delete(cacheKey);
      const week = await feed([CARELESS]);
      expect(week.items.map((item) => item.link.split("/posts/")[1])).toEqual(["ahead", "later"]);

      // And they do not come back.
      vi.setSystemTime(new Date(NOW.getTime() + 20 * DAY));
      await env.CACHE.delete(cacheKey);
      expect((await feed([CARELESS])).items).toEqual([]);
    });

    it("drops an item dated long ago instead of stamping it, and leaves out one dated after 2200", async () => {
      const OLD = { url: "https://old.example.com/", mode: "feed", feedUrl: "https://old.example.com/index.xml" } as const;
      const entry = (slug: string, date: string) =>
        `<item><title>The ${slug} item of this feed</title><link>https://old.example.com/posts/${slug}/</link><pubDate>${date}</pubDate></item>`;
      const text = `<?xml version="1.0"?><!doctype rss><rss version="2.0"><channel><title>Old Site</title>${[
        // What Hugo writes for a page with no date.
        entry("hugo", "Mon, 01 Jan 0001 00:00:00 +0000"),
        entry("sixties", "Wed, 31 Dec 1969 23:00:00 GMT"),
        entry("far", "Sat, 15 Nov 2300 10:00:00 GMT"),
        entry("no-time", "Sat, 14 Nov 2026"),
        entry("offset", "Sun, 15 Nov 2026 10:00:00 GMT+1"),
      ].join("")}</channel></rss>`;
      mockWeb({ [OLD.feedUrl]: xml(text) });

      const body = await feed([OLD]);

      expect(body.sites).toEqual([{ index: 0, ok: true }]);
      expect(body.items.map((item) => [item.link.split("/posts/")[1], item.published, item.dateSource])).toEqual([
        ["offset/", "2026-11-15T09:00:00Z", "published"],
        ["no-time/", "2026-11-14T00:00:00Z", "published"],
      ]);
      // Every item had a date, so none needed a first-seen time.
      expect((await env.CACHE.list({ prefix: "feed:seen:" })).keys).toEqual([]);
    });

    it("uses no first-seen record for a feed whose items all have dates", async () => {
      mockWeb(web);
      await feed([NEWS, BLOG, JOURNAL]);
      expect((await env.CACHE.list({ prefix: "feed:seen:" })).keys).toEqual([]);
    });

    it("merges sites newest first and names each item's site by index", async () => {
      mockWeb(web);

      const body = await feed([JOURNAL, NEWS, BLOG]);

      expect(body.sites).toEqual([0, 1, 2].map((index) => ({ index, ok: true })));
      expect(body.items.map((item) => [item.site, item.published])).toEqual([
        [1, "2026-11-16T13:45:00Z"],
        [2, "2026-11-15T17:20:00Z"],
        [0, "2026-11-14T00:00:00Z"],
        [1, "2026-11-13T13:15:30Z"],
        [2, "2026-11-12T07:05:09Z"],
        [0, "2026-11-12T00:00:00Z"],
        [2, "2026-11-11T00:00:00Z"],
        [1, "2026-11-10T22:00:00Z"],
      ]);
    });

    it("takes the item exactly 7 days old and not the one a second older", async () => {
      const edge = (seconds: number) => new Date(NOW.getTime() - 7 * DAY + seconds * 1000).toUTCString();
      mockWeb({
        [NEWS.feedUrl]: xml(
          `<rss version="2.0"><channel><title>Edge</title>
            <item><title>Exactly seven days old</title><link>https://news.example.com/edge/in</link><pubDate>${edge(0)}</pubDate></item>
            <item><title>Seven days and a second</title><link>https://news.example.com/edge/out</link><pubDate>${edge(-1)}</pubDate></item>
          </channel></rss>`,
        ),
      });

      const body = await feed([NEWS]);

      expect(body.items.map((item) => item.title)).toEqual(["Exactly seven days old"]);
    });

    it("returns at most 30 items per site, the newest", async () => {
      mockWeb({ [NEWS.feedUrl]: xml(manyItems("news.example.com", 45)) });

      const body = await feed([NEWS]);

      expect(body.items).toHaveLength(30);
      expect(body.items[0]?.title).toBe("Story 0 from news.example.com");
      expect(body.items[29]?.title).toBe("Story 29 from news.example.com");
    });

    it("returns at most 300 items in all", async () => {
      const sites: Site[] = [];
      const replies: Record<string, Reply> = {};
      for (let i = 0; i < 12; i++) {
        const host = `site${i}.example.com`;
        sites.push({ url: `https://${host}/`, mode: "feed", feedUrl: `https://${host}/feed` });
        replies[`https://${host}/feed`] = xml(manyItems(host, 30));
      }
      mockWeb(replies);

      const body = await feed(sites);

      expect(body.sites.every((site) => site.ok)).toBe(true);
      expect(body.items).toHaveLength(300);
      // Newest first across sites: the 25 newest of each of the 12 sites.
      expect(body.items.filter((item) => item.site === 11)).toHaveLength(25);
    });

    it("returns a link once, under the first site that has it", async () => {
      const other = { url: "https://news.example.com/", mode: "feed", feedUrl: "https://news.example.com/feed/" } as const;
      mockWeb({ ...web, [other.feedUrl]: xml(rss2) });

      const body = await feed([BLOG, other, NEWS]);

      expect(body.sites).toEqual([0, 1, 2].map((index) => ({ index, ok: true })));
      expect(body.items.filter((item) => item.site === 1)).toHaveLength(3);
      expect(body.items.filter((item) => item.site === 2)).toHaveLength(0);
      expect(new Set(body.items.map((item) => item.link)).size).toBe(body.items.length);
    });

    it("reports mode feed without feedUrl for that site only", async () => {
      const spy = mockWeb(web);

      const body = await feed([{ url: NEWS.url, mode: "feed" }, BLOG]);

      expect(body.sites).toEqual([{ index: 0, ok: false, error: "invalid_url" }, { index: 1, ok: true }]);
      expect(requested(spy)).toEqual([BLOG.feedUrl]);
    });
  });

  describe("links mode", () => {
    it("reads article links from a page that has no feed", async () => {
      mockWeb(web);

      const body = await feed([WORLD]);

      expect(body.sites).toEqual([{ index: 0, ok: true }]);
      const item = (title: string, path: string, published: string, dateSource: string) => ({
        site: 0,
        title,
        link: `https://daily.example.org${path}`,
        source: "The Daily Example",
        published,
        dateSource,
        excerpt: null,
      });
      expect(body.items).toEqual([
        // A <time datetime> by the link.
        item("Harbor city votes on a new bridge & tunnel", "/world/2026/11/harbor-city-votes-on-new-bridge/", "2026-11-16T14:30:00Z", "published"),
        // No date in the markup, and nobody has fetched this page before, so
        // nothing says these are new: they are placed a day back, a second
        // apart in page order (they are the 4th, 5th and 6th article links).
        item("Two border towns agree to share a library", "/world/2026/11/border-towns-share-a-library/", "2026-11-15T14:59:57Z", "first_seen"),
        item("A quiet year for the river delta", "/story/quiet-year-for-the-river-delta", "2026-11-15T14:59:56Z", "first_seen"),
        item("Night train returns to the coast line", "/world/2026/11/night-train-returns/", "2026-11-15T14:59:55Z", "first_seen"),
        item("Island ferry service resumes after storm", "/world/2026/11/island-ferry-service-resumes/", "2026-11-14T00:00:00Z", "published"),
        // "Mountain pass closes…" carries <time datetime="2026-11-02">: older than 7 days.
      ]);
    });

    it("drops a link whose <time> is long ago, and stamps one whose <time> is after 2200 as first seen", async () => {
      const ARCHIVE = { url: "https://archive.example.com/world/", mode: "links" } as const;
      const card = (slug: string, title: string, time: string) =>
        `<article><a href="/world/2026/11/${slug}/">${title}</a>${time ? `<time datetime="${time}">x</time>` : ""}</article>`;
      const page = `<!doctype html><html><head><title>Archive</title></head><body><main>${[
        card("hugo-zero-date", "A page whose date was never filled in", "0001-01-01T00:00:00Z"),
        card("far-future-date", "A page dated three centuries ahead", "2300-01-01"),
        card("no-date-at-all", "A page with no date in the markup", ""),
      ].join("")}</main></body></html>`;
      mockWeb({ [ARCHIVE.url]: html(page) });

      const body = await feed([ARCHIVE]);

      expect(body.sites).toEqual([{ index: 0, ok: true }]);
      expect(body.items.map((item) => [item.link.split("/2026/11/")[1], item.published, item.dateSource])).toEqual([
        ["far-future-date/", "2026-11-15T14:59:59Z", "first_seen"],
        ["no-date-at-all/", "2026-11-15T14:59:58Z", "first_seen"],
      ]);
    });

    it("does not let a newly followed page push in above what other sites published today", async () => {
      mockWeb(web);

      const body = await feed([WORLD, NEWS]);

      // The news feed's item of 13:45 today stays above the page's undated links.
      expect(body.items.slice(0, 3).map((item) => [item.site, item.published, item.dateSource])).toEqual([
        [0, "2026-11-16T14:30:00Z", "published"],
        [1, "2026-11-16T13:45:00Z", "published"],
        [0, "2026-11-15T14:59:57Z", "first_seen"],
      ]);
    });

    it("stamps a link that appears later as seen now, keeps every stamp across fetches, and drops a link 7 days after its stamp", async () => {
      mockWeb(web);
      await feed([WORLD]);
      const cacheKey = await siteCacheKey(source(WORLD));

      // Two hours on the page has one more story. The site's cached answer is
      // removed to stand for its 30 minutes having passed.
      vi.setSystemTime(new Date(NOW.getTime() + 120 * MINUTE));
      await env.CACHE.delete(cacheKey);
      vi.restoreAllMocks();
      const added = links.replace(
        '<ul class="more">',
        '<ul class="more"><li><a href="/world/2026/11/lighthouse-keeper-retires/">The last lighthouse keeper retires</a></li>',
      );
      mockWeb({ [WORLD.url]: html(added) });

      const later = await feed([WORLD]);

      expect(later.items.map((item) => [item.title, item.published, item.dateSource])).toEqual([
        // New to a page we already know: really first seen now, so it goes to the top.
        ["The last lighthouse keeper retires", "2026-11-16T17:00:00Z", "first_seen"],
        ["Harbor city votes on a new bridge & tunnel", "2026-11-16T14:30:00Z", "published"],
        // The stamps of the first fetch, unchanged although the links moved down the page.
        ["Two border towns agree to share a library", "2026-11-15T14:59:57Z", "first_seen"],
        ["A quiet year for the river delta", "2026-11-15T14:59:56Z", "first_seen"],
        ["Night train returns to the coast line", "2026-11-15T14:59:55Z", "first_seen"],
        ["Island ferry service resumes after storm", "2026-11-14T00:00:00Z", "published"],
      ]);

      // Six days and a minute after the first fetch, the page unchanged: the
      // links stamped at the first fetch are 7 days old and have fallen out.
      vi.setSystemTime(new Date(NOW.getTime() + 6 * DAY + MINUTE));
      await env.CACHE.delete(cacheKey);
      const week = await feed([WORLD]);
      expect(week.items.map((item) => [item.title, item.published])).toEqual([
        ["The last lighthouse keeper retires", "2026-11-16T17:00:00Z"],
        ["Harbor city votes on a new bridge & tunnel", "2026-11-16T14:30:00Z"],
      ]);

      // A month on, the same links are still on the page: they do not come back as new.
      vi.setSystemTime(new Date(NOW.getTime() + 29 * DAY));
      await env.CACHE.delete(cacheKey);
      const month = await feed([WORLD]);
      expect(month.sites).toEqual([{ index: 0, ok: true }]);
      expect(month.items).toEqual([]);
    });

    it("keeps the first-seen record under a hashed key, as link hashes and times only", async () => {
      mockWeb(web);
      await feed([WORLD]);

      const key = await seenCacheKey(source(WORLD));
      expect(key).toMatch(/^feed:seen:v1:[0-9a-f]{64}$/);
      const stored = (await env.CACHE.get(key)) ?? "";
      const record = JSON.parse(stored) as { version: number; seen: Record<string, number> };

      // Every article link on the page, dated or not, including the one outside the window.
      expect(Object.keys(record.seen)).toHaveLength(6);
      // The sixth article link of a page never fetched before: a day back, less five seconds.
      expect(record.seen[await linkHash("https://daily.example.org/world/2026/11/night-train-returns/")]).toBe(NOW.getTime() / 1000 - 86_400 - 5);
      expect(Object.keys(record.seen).every((hash) => /^[0-9a-f]{16}$/.test(hash))).toBe(true);
      expect(stored).not.toContain("example.org");
      expect(stored).not.toContain("night-train");

      const { keys } = await env.CACHE.list({ prefix: "feed:seen:" });
      const expected = Math.floor(vi.getRealSystemTime() / 1000) + 30 * 24 * 60 * 60;
      expect(Math.abs((keys[0]?.expiration ?? 0) - expected)).toBeLessThan(60);
    });

    it("forgets a link that left the page 30 days ago, and ignores a damaged record", async () => {
      mockWeb(web);
      const key = await seenCacheKey(source(WORLD));
      const nightTrain = await linkHash("https://daily.example.org/world/2026/11/night-train-returns/");
      const seconds = NOW.getTime() / 1000;
      await env.CACHE.put(
        key,
        JSON.stringify({
          version: 1,
          seen: {
            [nightTrain]: seconds - 3 * 86400,
            aaaaaaaaaaaaaaaa: seconds - 10 * 86400, // gone from the page 10 days ago: kept
            bbbbbbbbbbbbbbbb: seconds - 31 * 86400, // gone 31 days ago: forgotten
            cccccccccccccccc: seconds + 5000, // a time in the future: not believed
            dddddddddddddddd: "soon",
          },
        }),
      );

      const body = await feed([WORLD]);

      expect(body.items.find((item) => item.title.startsWith("Night train"))?.published).toBe("2026-11-13T15:00:00Z");
      // The record exists, so a link it does not hold is new: seen now.
      expect(body.items.find((item) => item.title.startsWith("Two border towns"))?.published).toBe("2026-11-16T15:00:00Z");
      const record = JSON.parse((await env.CACHE.get(key)) ?? "") as { seen: Record<string, number> };
      expect(Object.keys(record.seen).sort()).toContain("aaaaaaaaaaaaaaaa");
      expect(Object.keys(record.seen)).not.toContain("bbbbbbbbbbbbbbbb");
      expect(Object.keys(record.seen)).not.toContain("cccccccccccccccc");
      expect(Object.keys(record.seen)).not.toContain("dddddddddddddddd");
      expect(Object.keys(record.seen)).toHaveLength(7);

      // A record that is not what we wrote counts as no record.
      await env.CACHE.put(key, '{"version":1,"seen":"__proto__"}');
      await env.CACHE.delete(await siteCacheKey(source(WORLD)));
      expect((await feed([WORLD])).sites).toEqual([{ index: 0, ok: true }]);
    });

    it("does not write the record or cache the site when the record cannot be read", async () => {
      mockWeb(web);
      const site = source(WORLD);
      const nightTrain = await linkHash("https://daily.example.org/world/2026/11/night-train-returns/");
      const seconds = NOW.getTime() / 1000;
      const remembered = JSON.stringify({ version: 1, seen: { [nightTrain]: seconds - 3 * 86_400 } });
      await env.CACHE.put(await seenCacheKey(site), remembered);

      // A KV namespace whose reads fail, and which notes every write.
      const writes: string[] = [];
      const failing = {
        get: () => Promise.reject(new Error("KV is down")),
        put: (key: string) => {
          writes.push(key);
          return Promise.resolve();
        },
      } as unknown as KVNamespace;

      const result = await readSite(site, failing, seconds, { timeoutMs: 5000 });

      // The items are served, placed a day back like a first fetch, so nothing jumps to the top.
      expect(result.cacheable).toBe(false);
      expect(result.site.items.find((item) => item.title.startsWith("Night train"))).toMatchObject({ published: seconds - 86_400 - 5, dateSource: "first_seen" });
      expect(writes).toEqual([]);
      // Through the route nothing was stored either, and the remembered times survive.
      expect(await env.CACHE.get(await seenCacheKey(site))).toBe(remembered);

      // With KV back, the remembered time is used again.
      const body = await feed([WORLD]);
      expect(body.items.find((item) => item.title.startsWith("Night train"))?.published).toBe("2026-11-13T15:00:00Z");
    });

    it("reports a links-mode address that is not a web page", async () => {
      mockWeb({ [WORLD.url]: xml(rss2), [BLOG.feedUrl]: xml(atom) });

      const body = await feed([WORLD, BLOG]);

      expect(body.sites).toEqual([{ index: 0, ok: false, error: "not_html" }, { index: 1, ok: true }]);
    });
  });

  describe("one site failing", () => {
    const failures: [string, Reply, string][] = [
      ["answers 404", () => new Response("Not Found", { status: 404 }), "fetch_failed"],
      ["answers 500", () => new Response("oops", { status: 500 }), "fetch_failed"],
      ["is unreachable", () => Promise.reject(new TypeError("network down")), "fetch_failed"],
      ["returns a web page instead of a feed", html("<!doctype html><html><body>Sign in</body></html>"), "not_feed"],
      ["returns a picture", () => new Response(new Uint8Array([0x89, 0x50, 0x4e, 0x47]), { headers: { "content-type": "image/png" } }), "not_feed"],
      ["returns XML that is cut off", xml("<rss><channel><item><title>x</tit"), "not_feed"],
      ["returns more than 1 MB", xml("<rss><channel>" + "<item><title>padding</title></item>".repeat(32_000)), "too_large"],
      ["returns a shape the parser could not hold in memory", xml("<rss><channel>" + "<item a= ".repeat(100_000)), "not_feed"],
      ["redirects to a private address", () => new Response(null, { status: 302, headers: { location: "https://10.0.0.5/feed.xml" } }), "blocked_host"],
      ["redirects to plain http", () => new Response(null, { status: 301, headers: { location: "http://broken.example.com/feed" } }), "invalid_url"],
      ["redirects for ever", () => new Response(null, { status: 302, headers: { location: BROKEN.feedUrl } }), "fetch_failed"],
    ];

    it.each(failures)("does not fail the others when it %s", async (_name, reply, code) => {
      mockWeb({ ...web, [BROKEN.feedUrl]: reply });

      const body = await feed([NEWS, BROKEN, WORLD]);

      expect(body.sites).toEqual([
        { index: 0, ok: true },
        { index: 1, ok: false, error: code },
        { index: 2, ok: true },
      ]);
      expect(body.items.map((item) => item.site).sort()).toEqual([0, 0, 0, 2, 2, 2, 2, 2]);

      // The failure is not cached: the next request asks that host again, and only that one.
      expect(await env.CACHE.get(await siteCacheKey(source(BROKEN)))).toBeNull();
      vi.restoreAllMocks();
      const retry = mockWeb({ ...web, [BROKEN.feedUrl]: xml(atom) });
      const again = await feed([NEWS, BROKEN, WORLD]);
      expect(again.sites[1]).toEqual({ index: 1, ok: true });
      expect(requested(retry)).toEqual([BROKEN.feedUrl]);
    });

    it("reports a host that never answers as timeout, after 6 seconds", async () => {
      vi.useFakeTimers({ toFake: ["Date", "setTimeout", "clearTimeout"], now: NOW });
      let aborted = false;
      vi.spyOn(globalThis, "fetch").mockImplementation(
        (_input, init) =>
          new Promise<Response>((_resolve, reject) => {
            init?.signal?.addEventListener("abort", () => {
              aborted = true;
              reject(new DOMException("aborted", "AbortError"));
            });
            queueMicrotask(() => vi.advanceTimersByTime(5999));
            queueMicrotask(() => expect(aborted).toBe(false));
            queueMicrotask(() => vi.advanceTimersByTime(1));
          }),
      );

      const body = await feed([BROKEN]);

      expect(body).toEqual({ items: [], sites: [{ index: 0, ok: false, error: "timeout" }] });
      expect(aborted).toBe(true);
    });

    it.each([
      ["plain http", { url: "http://news.example.com/", mode: "links" }, "invalid_url"],
      ["not an address", { url: "the science page", mode: "links" }, "invalid_url"],
      ["an absurdly long address", { url: `https://news.example.com/${"a".repeat(3000)}`, mode: "links" }, "invalid_url"],
      ["a private page address", { url: "https://192.168.1.10/news/", mode: "links" }, "blocked_host"],
      ["a private feed address", { url: NEWS.url, mode: "feed", feedUrl: "https://10.0.0.5/feed" }, "blocked_host"],
      ["a feed address with credentials", { url: NEWS.url, mode: "feed", feedUrl: "https://a:b@news.example.com/feed" }, "invalid_url"],
      ["a private page address in feed mode", { url: "https://localhost/", mode: "feed", feedUrl: NEWS.feedUrl }, "blocked_host"],
      ["the cloud metadata address", { url: "https://169.254.169.254/latest/meta-data/", mode: "links" }, "blocked_host"],
    ])("refuses %s without a request", async (_name, site, code) => {
      const spy = mockWeb(web);

      const body = await feed([site, BLOG]);

      expect(body.sites).toEqual([{ index: 0, ok: false, error: code }, { index: 1, ok: true }]);
      expect(requested(spy)).toEqual([BLOG.feedUrl]);
      expect((await env.CACHE.list({ prefix: "feed:" })).keys).toHaveLength(1);
    });
  });

  describe("cache", () => {
    it("stores each site for 30 minutes under a hash, with no address in the key", async () => {
      mockWeb(web);
      await feed([NEWS, WORLD]);

      const { keys } = await env.CACHE.list({ prefix: "feed:site:" });

      expect(keys.map((key) => key.name).sort()).toEqual([await siteCacheKey(source(NEWS)), await siteCacheKey(source(WORLD))].sort());
      for (const key of keys) {
        expect(key.name).toMatch(/^feed:site:v1:[0-9a-f]{64}$/);
        // KV reports the expiry in Unix seconds, by the real clock, not the faked Date.
        const expected = Math.floor(vi.getRealSystemTime() / 1000) + 30 * 60;
        expect(Math.abs((key.expiration ?? 0) - expected)).toBeLessThan(60);
      }
    });

    it("answers a second request without fetching, and a site sent twice with one fetch", async () => {
      const spy = mockWeb(web);
      const first = await feed([NEWS, WORLD, BLOG, NEWS, { ...NEWS, url: "HTTPS://NEWS.example.com/science/#top" }]);
      expect(requested(spy).sort()).toEqual([BLOG.feedUrl, WORLD.url, NEWS.feedUrl].sort());
      expect(first.sites).toEqual([0, 1, 2, 3, 4].map((index) => ({ index, ok: true })));

      const second = await feed([NEWS, WORLD, BLOG, NEWS, NEWS]);

      expect(spy).toHaveBeenCalledTimes(3);
      expect(second).toEqual(first);
    });

    it("applies the 7-day window again when it answers from the cache", async () => {
      const edge = new Date(NOW.getTime() - 7 * DAY + 10 * MINUTE).toUTCString();
      const spy = mockWeb({
        [NEWS.feedUrl]: xml(
          `<rss version="2.0"><channel><title>Edge</title>
            <item><title>Ten minutes from falling out</title><link>https://news.example.com/edge/soon</link><pubDate>${edge}</pubDate></item>
            <item><title>Published an hour ago</title><link>https://news.example.com/edge/fresh</link><pubDate>${new Date(NOW.getTime() - 60 * MINUTE).toUTCString()}</pubDate></item>
          </channel></rss>`,
        ),
      });
      expect((await feed([NEWS])).items).toHaveLength(2);

      vi.setSystemTime(new Date(NOW.getTime() + 20 * MINUTE));
      const later = await feed([NEWS]);

      expect(spy).toHaveBeenCalledTimes(1);
      expect(later.items.map((item) => item.title)).toEqual(["Published an hour ago"]);
    });

    it("keys feed mode by the feed address too, so one page's cache cannot be filled from another feed", async () => {
      const impostor = { url: NEWS.url, mode: "feed", feedUrl: "https://elsewhere.example.net/fake.xml" } as const;
      const spy = mockWeb({ ...web, [impostor.feedUrl]: xml(manyItems("elsewhere.example.net", 3)) });

      const fake = await feed([impostor]);
      expect(fake.items.every((item) => item.link.startsWith("https://elsewhere.example.net/"))).toBe(true);

      // The real pairing is fetched for itself and gets its own items.
      const real = await feed([NEWS]);
      expect(requested(spy)).toEqual([impostor.feedUrl, NEWS.feedUrl]);
      expect(real.items.every((item) => item.link.startsWith("https://news.example.com/"))).toBe(true);
      expect(await siteCacheKey(source(impostor))).not.toBe(await siteCacheKey(source(NEWS)));
      // And links mode for the same page is a third key.
      expect(await siteCacheKey(source({ url: NEWS.url, mode: "links" }))).not.toBe(await siteCacheKey(source(NEWS)));
    });

    it("ignores a cached value that is not what it wrote", async () => {
      const spy = mockWeb(web);
      await env.CACHE.put(await siteCacheKey(source(NEWS)), '{"version":0,"items":"no"}');

      const body = await feed([NEWS]);

      expect(spy).toHaveBeenCalledTimes(1);
      expect(body.items).toHaveLength(3);
    });
  });

  describe("many sites", () => {
    const sitesOf = (count: number): Site[] =>
      Array.from({ length: count }, (_value, i) => ({ url: `https://site${i}.example.com/`, mode: "feed", feedUrl: `https://site${i}.example.com/feed` }));

    it("fetches at most 6 sites at a time", async () => {
      let inFlight = 0;
      let most = 0;
      vi.spyOn(globalThis, "fetch").mockImplementation(async (input) => {
        inFlight += 1;
        most = Math.max(most, inFlight);
        await new Promise((resolve) => setTimeout(resolve, 5));
        inFlight -= 1;
        return new Response(manyItems(new URL(String(input)).hostname, 2), { headers: { "content-type": "application/rss+xml" } });
      });

      const body = await feed(sitesOf(50));

      expect(body.sites).toHaveLength(50);
      expect(body.sites.every((site) => site.ok)).toBe(true);
      expect(body.items).toHaveLength(100);
      expect(most).toBe(6);
    });

    it("stops starting sites when the request's 20 seconds are used up", async () => {
      // Every host hangs. Each fetch that starts moves the faked clock on by a
      // second, so six of them together use up the 6 seconds a site is given.
      vi.useFakeTimers({ toFake: ["Date", "setTimeout", "clearTimeout", "performance"], now: NOW });
      const spy = vi.spyOn(globalThis, "fetch").mockImplementation(
        (_input, init) =>
          new Promise<Response>((_resolve, reject) => {
            init?.signal?.addEventListener("abort", () => reject(new DOMException("aborted", "AbortError")));
            queueMicrotask(() => vi.advanceTimersByTime(1000));
          }),
      );

      const body = await feed(sitesOf(50));

      expect(body.items).toEqual([]);
      expect(body.sites).toEqual(sitesOf(50).map((_site, index) => ({ index, ok: false, error: "timeout" })));
      // Six at a time for 6 seconds each: three full rounds, then a round with the 2 seconds left, then none.
      expect(spy.mock.calls.length).toBe(24);
    });
  });

  it("returns well-formed strings when a site's text is cut inside an emoji", async () => {
    const grin = "\u{1F600}";
    for (let pad = 0; pad < 3; pad++) {
      await clearCache();
      vi.restoreAllMocks();
      const date = NOW.toUTCString();
      mockWeb({
        [NEWS.feedUrl]: xml(
          `<rss version="2.0"><channel><title>${"s".repeat(117 + pad)}${grin.repeat(4)}</title><item><link>https://news.example.com/e</link>
            <title>${"a".repeat(297 + pad)}${grin.repeat(4)}</title><pubDate>${date}</pubDate>
            <description>${"b".repeat(297 + pad)}${grin.repeat(4)}</description></item></channel></rss>`,
        ),
        [WORLD.url]: html(`<title>${"w".repeat(117 + pad)}${grin.repeat(4)}</title><main><a href="/world/2026/an-emoji-headline/">${"word ".repeat(38)}${"x".repeat(47 + pad)}${grin.repeat(4)}</a>
          <a href="/world/2026/a-lone-surrogate/">A headline with half an emoji \ud83d in it</a></main>`),
      });

      const response = await post({ sites: [NEWS, WORLD] });
      const text = await response.text();
      const body = JSON.parse(text) as Body;

      expect(body.items).toHaveLength(3);
      // No escaped lone surrogate in the JSON, and none in any string.
      expect(text).not.toMatch(/\\ud[89ab][0-9a-f]{2}(?!\\ud[c-f])/i);
      for (const entry of body.items) {
        for (const value of [entry.title, entry.source, entry.excerpt ?? ""]) expect(value.isWellFormed()).toBe(true);
      }
      expect(body.items.find((entry) => entry.link.endsWith("a-lone-surrogate/"))?.title).toMatch(/^A headline with half an emoji \ufffd+ in it$/);
    }
  });

  it("never puts a site's address in a log line, a KV key or an error answer", async () => {
    const logged: string[] = [];
    for (const method of ["log", "info", "warn", "error", "debug", "trace"] as const) {
      vi.spyOn(console, method).mockImplementation((...args: unknown[]) => {
        logged.push(args.map((arg) => (arg instanceof Error ? `${arg.message} ${arg.stack}` : String(arg))).join(" "));
      });
    }
    const answers: string[] = [];
    const run = async (body: unknown) => {
      const response = await post(body);
      answers.push(await response.text());
      return response.status;
    };
    const quoted = { url: "https://broken.example.com/quoted/tok-5550123", mode: "links" };
    const redirecting = { url: "https://broken.example.com/redirect/tok-5550123", mode: "links" };

    mockWeb({
      ...web,
      [BROKEN.feedUrl]: () => Promise.reject(new TypeError(`fetch failed: ${BROKEN.feedUrl}`)),
      // A parser error would quote this text.
      [quoted.url]: () => new Response(`<rss><channel><item>${quoted.url}` + "<b ".repeat(50), { headers: { "content-type": "application/pdf" } }),
      [redirecting.url]: () => new Response(null, { status: 302, headers: { location: "https://10.0.0.5/tok-5550123" } }),
    });
    expect(await run({ sites: [BROKEN, quoted, redirecting, { ...quoted, mode: "feed", feedUrl: quoted.url }] })).toBe(200);
    expect(
      await run({
        sites: [
          { url: "http://broken.example.com/tok-5550123", mode: "links" },
          { url: "https://someone:tok-5550123@broken.example.com/", mode: "links" },
          { url: "not a url tok-5550123", mode: "links" },
          { url: BROKEN.url, mode: "feed" },
          { url: BROKEN.url, mode: "feed", feedUrl: "https://10.0.0.5/tok-5550123" },
        ],
      }),
    ).toBe(200);
    expect(await run({ sites: Array(51).fill(BROKEN) })).toBe(400);
    expect(await run({ sites: [{ url: BROKEN.url, mode: "tok-5550123" }] })).toBe(400);
    expect(await run({ sites: BROKEN.url })).toBe(400);
    expect(await run(`{"sites": [{"url": "${BROKEN.url}"`)).toBe(400);

    // Good sites in the same request as a failing one: the keys and logs of a mixed request.
    expect(await run({ sites: [NEWS, BROKEN, WORLD] })).toBe(200);
    answers.pop(); // That answer holds the good sites' article links, as it should.

    const keys = (await env.CACHE.list({ prefix: "feed:" })).keys.map((key) => key.name);

    // The checks below are not vacuous: sites were cached, and failures were logged.
    expect(keys).toHaveLength(3);
    expect(logged).toContain("feed: site 0 failed: fetch_failed");
    expect(logged).toContain("feed: site 1 failed: not_html");
    expect(logged).toContain("feed: site 2 failed: blocked_host");
    expect(logged).toContain("feed: site 3 failed: not_feed");
    expect(logged).toContain("feed: site 1 failed: invalid_url");
    for (const secret of ["tok-5550123", "broken.example.com", "/section/", "10.0.0.5", "someone", "news.example.com", "daily.example.org", "/world/"]) {
      expect(logged.join("\n"), `logs hold ${secret}`).not.toContain(secret);
      expect(keys.join("\n"), `a KV key holds ${secret}`).not.toContain(secret);
    }
    for (const secret of ["tok-5550123", "broken.example.com", "/section/", "10.0.0.5", "someone"]) {
      expect(answers.join("\n"), `an answer holds ${secret}`).not.toContain(secret);
    }
    // The cached values hold the items (and so the articles' own links), never the address of the page or feed they came from.
    const news = (await env.CACHE.get(await siteCacheKey(source(NEWS)))) ?? "";
    expect(news).toContain("new-telescope-first-light");
    expect(news).not.toContain(NEWS.feedUrl);
    expect(news).not.toContain(`"${NEWS.url}"`);
  });

  describe("invalid requests", () => {
    const INVALID = { error: "invalid_request", message: "Send 1 to 50 sites, each with url and mode (feed or links)" };

    it.each([
      ["no body", ""],
      ["malformed JSON", '{"sites": ['],
      ["no sites field", {}],
      ["an empty list", { sites: [] }],
      ["fifty-one sites", { sites: Array(51).fill(NEWS) }],
      ["sites that is not a list", { sites: NEWS }],
      ["a site that is a string", { sites: [NEWS.url] }],
      ["a site without mode", { sites: [{ url: NEWS.url }] }],
      ["a site without url", { sites: [{ mode: "links" }] }],
      ["an unknown mode", { sites: [{ url: NEWS.url, mode: "scrape" }] }],
      ["a feedUrl that is not a string", { sites: [{ url: NEWS.url, mode: "feed", feedUrl: 5 }] }],
      ["a url that is not a string", { sites: [{ url: 5, mode: "links" }] }],
    ])("answers 400 to %s, with a fixed message and no outbound request", async (_name, body) => {
      const spy = mockWeb(web);

      const response = await post(body);

      expect(response.status).toBe(400);
      expect(await response.json()).toEqual(INVALID);
      expect(spy).not.toHaveBeenCalled();
    });

    it.each([
      ["text/plain", "text/plain"],
      ["a form", "application/x-www-form-urlencoded"],
      ["no Content-Type", null],
      ["something that only looks like JSON", "application/jsonp"],
    ])("answers 400 to a JSON body sent as %s", async (_name, contentType) => {
      const spy = mockWeb(web);

      const response = await exports.default.fetch("https://example.com/v1/feed", {
        method: "POST",
        headers: contentType === null ? {} : { "content-type": contentType },
        // A stream, so that no Content-Type is added on our behalf.
        body: new Blob([JSON.stringify({ sites: [NEWS] })]).stream(),
      });

      expect(response.status).toBe(400);
      expect(await response.json()).toEqual(INVALID);
      expect(spy).not.toHaveBeenCalled();
    });

    it("accepts fifty sites", async () => {
      mockWeb(web);

      const body = await feed(Array(50).fill(BLOG));

      expect(body.sites).toHaveLength(50);
      expect(body.sites.every((site) => site.ok)).toBe(true);
      expect(body.items).toHaveLength(3);
    });
  });
});
