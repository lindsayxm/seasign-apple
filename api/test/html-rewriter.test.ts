import { describe, expect, it } from "vitest";
import { MAX_CANDIDATES, MAX_HANDLER_CALLS, MAX_LINKS_SCANNED, articleLinks, feedCandidates, scanPage } from "../src/lib/page-links.ts";
// Written by hand in the shape of real pages; no real site was fetched.
import links from "./fixtures/sites/links.html?raw";
import section from "./fixtures/sites/section.html?raw";

const bytes = (text: string) => new TextEncoder().encode(text);
const at = (iso: string) => Date.parse(iso) / 1000;

/** A body delivered a few bytes at a time, as a slow network would. */
function trickle(text: string, size: number): Response {
  const data = bytes(text);
  return new Response(
    new ReadableStream({
      start(controller) {
        for (let i = 0; i < data.length; i += size) controller.enqueue(data.slice(i, i + size));
        controller.close();
      },
    }),
    { headers: { "content-type": "text/html" } },
  );
}

// src/lib/page-links.ts is written against these behaviours of the Workers
// built-in HTMLRewriter. If an upgrade of workerd changes one, this fails
// before the page reader quietly goes wrong.
describe("HTMLRewriter in the test runtime", () => {
  it("is a global, and runs its handlers only while the output is read", async () => {
    expect(typeof HTMLRewriter).toBe("function");
    let seen = 0;
    const output = new HTMLRewriter().on("a", { element: () => void seen++ }).transform(new Response("<a>x</a><a>y</a>"));
    await Promise.resolve();
    expect(seen).toBe(0);
    await output.arrayBuffer();
    expect(seen).toBe(2);
  });

  it("gives text in pieces, with character references not decoded", async () => {
    const pieces: string[] = [];
    await new HTMLRewriter()
      .on("title", { text: (chunk) => void pieces.push(chunk.text) })
      .transform(trickle("<title>Fish &amp; chips &#8217; today</title>", 7))
      .arrayBuffer();

    expect(pieces.length).toBeGreaterThan(2);
    expect(pieces.join("")).toBe("Fish &amp; chips &#8217; today");
    // A reference can be split between two pieces, so text is joined before it is decoded.
    expect(pieces.some((piece) => /&[a-z#0-9]*$/.test(piece))).toBe(true);
  });

  it("gives attribute values as written, references not decoded", async () => {
    const values: (string | null)[] = [];
    await new HTMLRewriter()
      .on("a", { element: (element) => void values.push(element.getAttribute("href"), element.getAttribute("HREF"), element.getAttribute("title")) })
      .transform(new Response('<a HREF="/a?x=1&amp;y=2">t</a>'))
      .arrayBuffer();
    expect(values).toEqual(["/a?x=1&amp;y=2", "/a?x=1&amp;y=2", null]);
  });

  it("matches the selectors the page reader uses", async () => {
    const hits: string[] = [];
    const note = (name: string) => ({ element: (element: Element) => void hits.push(`${name}:${element.tagName}`) });
    await new HTMLRewriter()
      .on("nav, footer", note("chrome"))
      .on("article, li", note("card"))
      .on("h1, h2, h3, h4", note("heading"))
      .on("a *", note("inside-a"))
      .on("time", note("time"))
      .transform(
        new Response("<NAV><ul><li>x</li></ul></NAV><article><h2><a href=/x><span>t</span></a></h2><time datetime=x></time></article><h5>no</h5><footer></footer>"),
      )
      .arrayBuffer();
    expect(hits).toEqual(["chrome:nav", "card:li", "card:article", "heading:h2", "inside-a:span", "time:time", "chrome:footer"]);
  });

  it("gives an anchor's text handler the text of nested elements, once", async () => {
    const pieces: string[] = [];
    await new HTMLRewriter()
      .on("a", { text: (chunk) => void (chunk.text && pieces.push(chunk.text)) })
      .transform(new Response("<a href=/x><img><h3>Head <b>line</b></h3><p>para</p></a> outside"))
      .arrayBuffer();
    expect(pieces).toEqual(["Head ", "line", "para"]);
  });

  it("calls onEndTag at the end tag, refuses it for an element without one, and may never call it for an unclosed element", async () => {
    const order: string[] = [];
    let voidError = "";
    await new HTMLRewriter()
      .on("nav", { element: (element) => (order.push("nav"), element.onEndTag(() => void order.push("/nav"))) })
      .on("main", { element: (element) => (order.push("main"), element.onEndTag(() => void order.push("/main"))) })
      .on("a", { element: (element) => (order.push("a"), element.onEndTag(() => void order.push("/a"))) })
      .on("br", {
        element(element) {
          try {
            element.onEndTag(() => {});
          } catch (error) {
            voidError = String((error as Error).message);
          }
        },
      })
      // The <nav> is never closed.
      .transform(new Response("<nav><a href=/x>x</a><br><main><a href=/y>y</a></main>"))
      .arrayBuffer();

    expect(order).toEqual(["nav", "a", "/a", "main", "a", "/a", "/main"]);
    expect(voidError).toContain("No end tag");
  });

  it("refuses onEndTag for a self-closing element inside <svg>, and a throw in a handler ends the transform", async () => {
    const refused: string[] = [];
    await new HTMLRewriter()
      .on("a, title, li", {
        element(element) {
          try {
            element.onEndTag(() => {});
          } catch {
            refused.push(element.tagName);
          }
        },
      })
      // Outside <svg>, "<a/>" is an ordinary start tag, and its end is asked for without complaint.
      .transform(new Response('<svg><a href="/x"/><title/></svg><a href="/y"/><li/>'))
      .arrayBuffer();
    expect(refused).toEqual(["a", "title"]);

    // The error is the handler's own; workerd also reports it as an uncaught exception on stderr.
    const thrown = new HTMLRewriter()
      .on("a", {
        element() {
          throw new Error("from the handler");
        },
      })
      .transform(new Response("<p><a>x</a></p>"))
      .arrayBuffer();
    await expect(thrown).rejects.toThrow("from the handler");
  });

  it("stops calling handlers when its input stops", async () => {
    let seen = 0;
    let sent = 0;
    const piece = new TextEncoder().encode("<li></li>".repeat(1000));
    const input = new ReadableStream<Uint8Array>({
      pull(controller) {
        // Ten pieces are on offer; the handlers say stop during the third.
        if (seen >= 2500 || sent >= 10) return controller.close();
        sent += 1;
        controller.enqueue(piece);
      },
    });
    await new HTMLRewriter().on("li", { element: () => void seen++ }).transform(new Response(input)).arrayBuffer();
    expect(sent).toBeLessThan(10);
    expect(seen).toBe(sent * 1000);
  });

  it("decodes the character set named in Content-Type", async () => {
    const page = new Uint8Array([...bytes("<title>caf"), 0xe9, ...bytes("</title>")]);
    let title = "";
    await new HTMLRewriter()
      .on("title", { text: (chunk) => void (title += chunk.text) })
      .transform(new Response(page, { headers: { "content-type": "text/html; charset=iso-8859-1" } }))
      .arrayBuffer();
    expect(title).toBe("café");
  });
});

describe("scanPage", () => {
  it("reads the title, site name and advertised feeds of a section page", async () => {
    const scan = await scanPage(bytes(section), "text/html; charset=utf-8");

    // The <svg><title> further down is not the page title.
    expect(scan.title).toBe("Science | Example News & Views");
    expect(scan.siteName).toBe("Example News");
    expect(scan.base).toBeNull();
    expect(scan.feeds).toEqual([
      { href: "/feed/", title: "Example News » Feed" },
      { href: "/comments/feed/", title: "Example News » Comments Feed" },
      { href: "/science/feed/?format=rss&v=2", title: "Example News » Science Category Feed" },
    ]);
  });

  it("prefers the feed whose path is closest to the page's, and a comments feed last", async () => {
    const scan = await scanPage(bytes(section), "text/html");
    expect(feedCandidates(scan, new URL("https://news.example.com/science/"))).toEqual([
      { url: "https://news.example.com/science/feed/?format=rss&v=2", shared: 1 },
      { url: "https://news.example.com/feed/", shared: 0 },
      { url: "https://news.example.com/comments/feed/", shared: 0 },
    ]);
    // From another section, none is closer: document order, comments last.
    expect(feedCandidates(scan, new URL("https://news.example.com/sport/")).map((feed) => feed.url)).toEqual([
      "https://news.example.com/feed/",
      "https://news.example.com/science/feed/?format=rss&v=2",
      "https://news.example.com/comments/feed/",
    ]);
  });

  it("leaves out advertised feeds that fail the safe-URL check, and honours <base>", async () => {
    const page = `<html><head><base href="https://cdn.example.com/site/">
      <link rel="alternate" type="application/atom+xml" href="https://10.0.0.5/feed.xml">
      <link rel="alternate" type="application/rss+xml" href="http://192.168.0.1/rss">
      <link rel="alternate" type="application/rss+xml" href="https://user:pw@news.example.com/rss">
      <link rel="alternate" type="application/rss+xml" href="https://localhost/rss">
      <link rel="alternate" type="application/rss+xml" href="javascript:alert(1)">
      <link rel="alternate" type="application/rss+xml" href="file:///etc/passwd">
      <link rel="alternate" type="application/atom+xml" href="atom.xml">
      <link rel="alternate" type="application/atom+xml" href="atom.xml">
      <link rel="stylesheet alternate" type="text/css" href="/alt.css">
      </head><body></body></html>`;
    const scan = await scanPage(bytes(page), "text/html");
    expect(feedCandidates(scan, new URL("https://news.example.com/"))).toEqual([{ url: "https://cdn.example.com/site/atom.xml", shared: 0 }]);
  });

  it("takes a generic XML type for a feed only when the title or the address says so", async () => {
    const page = `<html><head>
      <link rel="alternate" type="text/xml" title="RSS" href="/index.xml">
      <link rel="alternate" type="application/xml" href="/blog/feed">
      <link rel="alternate" type="application/xml" title="Atom 1.0" href="/a">
      <link rel="alternate" type="text/xml" title="Sitemap" href="/sitemap.xml">
      <link rel="alternate" type="application/xml" href="/opensearch.xml">
      <link rel="alternate" type="text/html" title="RSS" href="/rss.html">
      <link rel="alternate stylesheet" type="application/rss+xml" title="feed" href="/contrast-feed.css">
      <link rel="stylesheet alternate" type="text/xml" title="High contrast rss" href="/contrast.css">
      </head><body></body></html>`;
    const scan = await scanPage(bytes(page), "text/html");
    expect(feedCandidates(scan, new URL("https://news.example.com/")).map((feed) => feed.url)).toEqual([
      "https://news.example.com/index.xml",
      "https://news.example.com/blog/feed",
      "https://news.example.com/a",
    ]);
  });

  it("chooses article links and leaves out navigation, footer, tags, authors and other sites", async () => {
    const page = new URL("https://daily.example.org/world/");
    const scan = await scanPage(bytes(links), "text/html; charset=utf-8");

    expect(scan.title).toBe("World & Politics – The Daily Example");
    expect(scan.siteName).toBe("The Daily Example");
    expect(scan.feeds).toEqual([]);
    expect(articleLinks(scan, page, page)).toEqual([
      // The image link and the headline link are one article; the date is the <time> in its <article>.
      { title: "Harbor city votes on a new bridge & tunnel", link: "https://daily.example.org/world/2026/11/harbor-city-votes-on-new-bridge/", published: at("2026-11-16T14:30:00Z") },
      // The anchor wraps a picture, a heading and a summary: the heading is the title.
      { title: "Island ferry service resumes after storm", link: "https://daily.example.org/world/2026/11/island-ferry-service-resumes/", published: at("2026-11-14T00:00:00Z") },
      { title: "Mountain pass closes for the season early", link: "https://daily.example.org/world/2026/11/mountain-pass-closes-early/", published: at("2026-11-02T08:00:00Z") },
      { title: "Two border towns agree to share a library", link: "https://daily.example.org/world/2026/11/border-towns-share-a-library/", published: null },
      { title: "A quiet year for the river delta", link: "https://daily.example.org/story/quiet-year-for-the-river-delta", published: null },
      // Linked as http: read as https.
      { title: "Night train returns to the coast line", link: "https://daily.example.org/world/2026/11/night-train-returns/", published: null },
    ]);
  });

  it("keeps an article beside the section page only when its last segment is a headline-like slug", async () => {
    const page = new URL("https://mag.example.com/category/science/");
    const html = `<main>
      <a href="/story/the-long-road-to-fusion-power/">The long road to fusion power plants</a>
      <a href="/story/fusion/">A second fusion story with a short address</a>
      <a href="/category/space/">Everything we publish about space</a>
      <a href="/category/science/">The science section front page again</a>
      <a href="/category/">All of the sections we have</a>
      <a href="/topics/energy/">Everything filed under the energy topic</a>
      <a href="/topics/energy/grid-batteries-get-cheaper-again/">Grid batteries get cheaper again this year</a>
      <a href="/category/science/2026/deep-sea-vents/">What lives beside the deep sea vents</a>
      <a href="/category/science/?page=2">The second page of science stories</a>
      <a href="https://www.mag.example.com/story/www-host-counts-as-the-same-site/">The www host counts as the same site</a>
      <a href="https://shop.mag.example.com/story/another-subdomain-does-not-count/">Another subdomain does not count here</a>
    </main>`;
    const found = articleLinks(await scanPage(bytes(html), "text/html"), page, page).map((link) => new URL(link.link).pathname);
    expect(found).toEqual([
      "/story/the-long-road-to-fusion-power/",
      "/topics/energy/grid-batteries-get-cheaper-again/",
      "/category/science/2026/deep-sea-vents/",
      "/story/www-host-counts-as-the-same-site/",
    ]);
  });

  it.each([
    // [what, the page, the link, kept?]
    ["a numeric id at the same depth", "/news/world/", "/news/12345678", true],
    ["a short number at the same depth", "/news/world/", "/news/2026", false],
    ["a page file beside a section page", "/section/", "/story.html", true],
    ["an index file", "/section/", "/news/index.html", false],
    ["an id in the query, from a deeper page", "/a/b/", "/article?id=12345", true],
    ["a short id in the query", "/a/b/", "/item?id=4", true],
    ["a query that names no article", "/a/b/", "/list?sort=new", false],
    ["the same script with another article query", "/index.php?cat=2", "/index.php?p=77", true],
    ["the same script with another listing query", "/index.php?cat=2", "/index.php?cat=3", false],
    ["the page itself, query and all", "/index.php?p=77", "/index.php?p=77", false],
    ["an article query on the front page", "/", "/?p=123", true],
    ["a pagination query on the page itself", "/news/", "/news/?page=2", false],
    ["an opaque id at the same depth", "/news/world/", "/news/a1B2c3D4e5F6", true],
    ["a plain word at the same depth", "/news/world/", "/news/business", false],
    ["a dated path under a category", "/", "/category/tech/2026/11/15/a-real-story", true],
    ["a slug two levels under a category", "/", "/category/tech/a-real-story-about-chips", true],
    ["a category listing", "/", "/category/tech", false],
    ["a category listing with a long name", "/", "/category/science-and-technology-news", false],
    ["a tag with a three-word name", "/", "/tag/climate-change-policy", false],
    ["an author page", "/", "/author/mary-jane-smith", false],
    ["a sign-in page however deep", "/", "/account/login/return-to-the-story-page", false],
    ["an about page file", "/section/", "/about.html", false],
    ["a PDF", "/news/", "/news/2026/annual-report-for-the-year.pdf", false],
    ["a WordPress login script", "/", "/wp-login.php?id=5", false],
    ["a slug beside the section page", "/category/science/", "/story/the-long-road-to-fusion-power/", true],
    ["a deeper path", "/news/", "/news/2026/x", true],
    ["a page above", "/news/world/", "/news/", false],
  ] as [string, string, string, boolean][])("article path rule: %s", async (_name, pagePath, href, kept) => {
    const page = new URL(`https://plain.example.com${pagePath}`);
    const html = `<main><a href="${href}">A headline long enough to be one</a></main>`;
    const found = articleLinks(await scanPage(bytes(html), "text/html"), page, page);
    expect(found.map((link) => link.link)).toEqual(kept ? [new URL(href, page).href] : []);
  });

  it.each([
    ["Thai", "นายกรัฐมนตรีแถลงนโยบายใหม่", true],
    ["Chinese, seven characters", "央行宣布下调利率", true],
    ["Chinese, six characters", "股市今日大涨", true],
    ["a Chinese menu entry", "国际新闻", false],
    ["Japanese", "東京で新しい駅が開業", true],
    ["Korean", "서울에 새 도서관 개관", true],
    ["emoji only", "🎉🎉🎉🎉🎉🎉🎉🎉", false],
    ["a short phrase with emoji", "Big win 🎉🎉🎉🎉", false],
    ["an English headline", "Council approves the new bridge", true],
    ["two English words", "Latest headlines", false],
    ["a call to action", "Read more about the council vote", false],
  ] as [string, string, boolean][])("headline rule: %s", async (_name, text, kept) => {
    const page = new URL("https://plain.example.com/news/");
    const html = `<main><a href="/news/2026/some-story-address/">${text}</a></main>`;
    const found = articleLinks(await scanPage(bytes(html), "text/html"), page, page);
    expect(found.map((link) => link.title)).toEqual(kept ? [text] : []);
  });

  it("returns only links in article, main or a heading when there are at least three of them", async () => {
    const page = new URL("https://plain.example.com/news/");
    const sidebar = `<div><a href="/news/popular-story-in-the-sidebar/">A popular story in the sidebar</a></div>`;
    const heading = (n: number) => `<h3><a href="/news/headline-story-number-${n}/">Headline story number ${n} of the day</a></h3>`;

    const three = articleLinks(await scanPage(bytes(sidebar + heading(1) + heading(2) + heading(3)), "text/html"), page, page);
    expect(three.map((link) => link.title)).toEqual([1, 2, 3].map((n) => `Headline story number ${n} of the day`));

    // With fewer, a page without such markup still gives its links.
    const two = articleLinks(await scanPage(bytes(sidebar + heading(1) + heading(2)), "text/html"), page, page);
    expect(two).toHaveLength(3);
  });

  it("gives a card's date to its article only when the card holds one article", async () => {
    const page = new URL("https://plain.example.com/news/");
    const html = `<main>
      <article><time datetime="2026-11-10T10:00:00Z">Updated</time>
        <ul>
          <li><a href="/news/first-story-in-a-long-list/">The first story in a long list</a></li>
          <li><a href="/news/second-story-in-a-long-list/">The second story in a long list</a></li>
          <li><time datetime="2026-11-12T08:00:00Z"></time><a href="/news/third-story-has-its-own-date/">The third story has its own date</a></li>
          <li><a href="/news/fourth-story-date-inside-link/">The fourth story has a date inside <time datetime="2026-11-13T08:00:00Z">Nov 13</time></a></li>
          <li><a href="/news/fifth-story-with-a-bad-date/">The fifth story has a bad date</a><time datetime="last Tuesday"></time></li>
        </ul>
      </article>
      <li><article><a href="/news/sixth-story-date-in-outer-card/">The sixth story is dated by the outer card</a></article><time datetime="2026-11-14T08:00:00Z"></time></li>
    </main>`;
    const found = articleLinks(await scanPage(bytes(html), "text/html"), page, page);
    expect(found.map((link) => [link.link.split("/news/")[1], link.published])).toEqual([
      // One date above five stories says nothing about any of them.
      ["first-story-in-a-long-list/", null],
      ["second-story-in-a-long-list/", null],
      ["third-story-has-its-own-date/", at("2026-11-12T08:00:00Z")],
      ["fourth-story-date-inside-link/", at("2026-11-13T08:00:00Z")],
      ["fifth-story-with-a-bad-date/", null],
      ["sixth-story-date-in-outer-card/", at("2026-11-14T08:00:00Z")],
    ]);
  });

  it("finishes an <a> that is never closed at the next <a>, and the last one at the end of the page", async () => {
    const page = new URL("https://plain.example.com/news/");
    const html = `<main><a href="/news/the-first-unclosed-story/">The first unclosed story
      <a href="/news/the-second-unclosed-story/">The second unclosed story
      <a href="/news/the-third-unclosed-story/">The third unclosed story`;
    const found = articleLinks(await scanPage(bytes(html), "text/html"), page, page);
    expect(found.map((link) => link.title)).toEqual(["The first unclosed story", "The second unclosed story", "The third unclosed story"]);
  });

  it("reads on past self-closing elements in inline SVG and MathML", async () => {
    const page = new URL("https://plain.example.com/news/");
    const html = `<head><title>Icons &amp; news</title></head>
      <header><svg viewBox="0 0 10 10"><title/><a href="/"/><a href="/news/an-icon-link-inside-the-svg/"><path d="M0 0"/></a></svg>
      <math><a href="/y"/><li/></math><nav/><article/><h2/></header>
      <main><article><h2><a href="/news/a-story-after-the-icons/">A story after the icons in the header</a></h2>
      <time datetime="2026-11-15T08:00:00Z"></time></article></main>`;
    const scan = await scanPage(bytes(html), "text/html");
    expect(scan.title).toBe("Icons & news");
    expect(articleLinks(scan, page, page)).toEqual([
      { title: "A story after the icons in the header", link: "https://plain.example.com/news/a-story-after-the-icons/", published: at("2026-11-15T08:00:00Z") },
    ]);
  });

  it("still finds the links after a <nav> that is never closed", async () => {
    const page = new URL("https://plain.example.com/news/");
    const html = `<nav><a href="/news/a-link-in-the-navigation-bar/">A link in the navigation bar</a>
      <main><a href="/news/a-story-after-the-broken-nav/">A story after the broken navigation</a></main>`;
    const found = articleLinks(await scanPage(bytes(html), "text/html"), page, page);
    expect(found.map((link) => link.title)).toEqual(["A story after the broken navigation"]);
  });

  it("reads a page in another character set", async () => {
    const page = new URL("https://plain.example.com/news/");
    const html = new Uint8Array([...bytes('<title>Caf'), 0xe9, ...bytes('</title><main><a href="/news/le-caf'), 0xe9, ...bytes('-du-coin-ouvre/">Le caf'), 0xe9, ...bytes(" du coin ouvre ses portes</a></main>")]);
    const scan = await scanPage(html, "text/html; charset=windows-1252");
    expect(scan.title).toBe("Café");
    expect(articleLinks(scan, page, page)).toEqual([
      { title: "Le café du coin ouvre ses portes", link: "https://plain.example.com/news/le-caf%C3%A9-du-coin-ouvre/", published: null },
    ]);
  });
});

describe("scanPage on hostile input", () => {
  const page = new URL("https://plain.example.com/news/");
  const MB = 1024 * 1024;

  it(`reads at most ${MAX_LINKS_SCANNED} links and keeps at most ${MAX_CANDIDATES}`, async () => {
    let html = "<main>";
    for (let i = 0; i < 20_000; i++) html += `<a href="/news/story-number-${i}-of-many/">Story number ${i} of a great many</a>\n`;
    const scan = await scanPage(bytes(html), "text/html");
    expect(scan.links).toHaveLength(MAX_LINKS_SCANNED);
    expect(articleLinks(scan, page, page)).toHaveLength(MAX_CANDIDATES);
  });

  it(`stops reading a page after ${MAX_HANDLER_CALLS} elements and pieces of text`, async () => {
    const story = '<main><a href="/news/a-story-below-the-padding/">A story below all of the padding</a></main>';
    const padded = async (count: number) => articleLinks(await scanPage(bytes("<li></li>".repeat(count) + story), "text/html"), page, page);

    // A long page is read to its end.
    expect(await padded(5000)).toHaveLength(1);
    // Past the limit the rest is not looked at. The page comes in 16 KB pieces,
    // so reading stops within one piece (about 1,800 of these elements) of the limit.
    expect(await padded(MAX_HANDLER_CALLS - 3000)).toHaveLength(1);
    expect(await padded(MAX_HANDLER_CALLS + 3000)).toHaveLength(0);
    expect(await padded(200_000)).toHaveLength(0);
  });

  it("never returns half an emoji or half a character reference, wherever the cut falls", async () => {
    const grin = "\u{1F600}";
    for (let pad = 0; pad < 14; pad++) {
      // 600 characters of anchor text are kept and 300 of a title; emoji and references sit on both edges.
      const text = `${"a ".repeat(pad)}${`${grin}&amp;`.repeat(120)}`;
      const html = `<title>${"t".repeat(3590 + pad)}${`${grin}&eacute;`.repeat(20)}</title>
        <main><a href="/news/an-emoji-story-number-${pad}/"><h2>${text}</h2></a>
        <a href="/news/a-short-emoji-story-${pad}/">${"b ".repeat(90 + pad)}${`${grin} `.repeat(10)}</a></main>`;
      const scan = await scanPage(bytes(html), "text/html");
      const strings = [scan.title ?? "", ...scan.links.flatMap((link) => [link.text, link.headingText]), ...articleLinks(scan, page, page).map((link) => link.title)];
      expect(strings.length).toBeGreaterThan(5);
      for (const value of strings) {
        expect(value.isWellFormed(), JSON.stringify(value.slice(-12))).toBe(true);
        expect(value).not.toMatch(/&[a-z]{1,6}$/);
      }
    }
  });

  it("cuts long titles, anchor text and addresses", async () => {
    const html = `<title>${"title ".repeat(100_000)}</title><main>
      <a href="/news/a-story-with-a-very-long-text/">${"word ".repeat(100_000)}</a>
      <a href="/news/${"x".repeat(5000)}/">A story with a very long address</a>
      <a href="/news/a-normal-story-after-those/">A normal story after those two</a></main>`;
    const scan = await scanPage(bytes(html), "text/html");
    expect(scan.title?.length).toBeLessThanOrEqual(300);
    expect(scan.links.every((link) => link.text.length <= 700 && link.href.length <= 2048)).toBe(true);
    expect(articleLinks(scan, page, page).map((link) => link.title)).toEqual(["A normal story after those two"]);
  });

  // About 2 MB each, the most the fetch lets through. The bound is loose; the
  // measured times are in memory/architecture.md.
  const cases: [string, () => string][] = [
    ["130,000 links", () => `<main>${'<a href="/n/x">t</a>'.repeat(100_000)}`],
    ["60,000 links with headline text", () => `<main>${'<a href="/news/some-story-about-things/">Some story about things</a>'.repeat(30_000)}`],
    ["200,000 nested <li>", () => "<li>".repeat(200_000) + '<a href="/news/a-story-at-the-bottom/">A story at the very bottom</a>'],
    ["300,000 nested <a>", () => "<a href=/x>".repeat(150_000)],
    ["250,000 <article> with <time>", () => "<article><time datetime=2026-11-16>".repeat(50_000)],
    ["one 2 MB attribute", () => `<a href="${"x".repeat(2 * MB)}">t</a>`],
    ["2 MB of '<'", () => "<".repeat(2 * MB)],
    ["2 MB inside one <title>", () => `<title>${"&amp;".repeat(400_000)}`],
    ["100,000 feed links", () => '<link rel="alternate" type="application/rss+xml" href="/feed">'.repeat(30_000)],
    ["2 MB of text in one link", () => `<a href="/news/a-story-with-endless-text/">${"x ".repeat(MB)}</a>`],
    ["100,000 headings inside one link", () => `<a href="/news/a-story-with-many-heads/">${"<h3>h</h3>".repeat(100_000)}</a>`],
  ];

  it.each(cases)("stays fast on %s", async (_name, make) => {
    const html = bytes(make());
    const started = performance.now();
    const scan = await scanPage(html, "text/html");
    const found = articleLinks(scan, page, page);
    feedCandidates(scan, page);
    expect(performance.now() - started).toBeLessThan(3000);
    expect(scan.links.length).toBeLessThanOrEqual(MAX_LINKS_SCANNED);
    expect(scan.feeds.length).toBeLessThanOrEqual(20);
    expect(found.length).toBeLessThanOrEqual(MAX_CANDIDATES);
  });
});
