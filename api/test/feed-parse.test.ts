import { describe, expect, it } from "vitest";
import {
  FeedParseError,
  MAX_ATTRIBUTES,
  MAX_FEED_CHARS,
  MAX_ITEMS_SCANNED,
  MAX_MARKUP,
  MAX_TAG_CHARS,
  checkShape,
  parseFeed,
  parseFeedDate,
  safeLink,
} from "../src/lib/feed-parse.ts";
// Written by hand in the shape of real feeds; no real site was fetched.
import atom from "./fixtures/sites/atom.xml?raw";
import badDates from "./fixtures/sites/bad-dates.xml?raw";
import rdf from "./fixtures/sites/rdf.xml?raw";
import rss2 from "./fixtures/sites/rss2.xml?raw";
import section from "./fixtures/sites/section.html?raw";

const at = (iso: string) => Date.parse(iso) / 1000;
const FEED = new URL("https://news.example.com/science/feed/");

describe("parseFeedDate", () => {
  it.each([
    ["Mon, 16 Nov 2026 13:45:00 +0000", "2026-11-16T13:45:00Z"],
    ["Fri, 13 Nov 2026 08:15:30 -0500", "2026-11-13T13:15:30Z"],
    ["Tue, 10 Nov 2026 22:00:00 GMT", "2026-11-10T22:00:00Z"],
    ["10 Nov 2026 22:00 EST", "2026-11-11T03:00:00Z"],
    ["Tue, 10 Nov 26 22:00:00 PDT", "2026-11-11T05:00:00Z"],
    ["Tuesday, 10 November 2026 22:00:00 Z", "2026-11-10T22:00:00Z"],
    ["Tue,  3 Nov 2026 07:05:09 UT", "2026-11-03T07:05:09Z"],
    // No zone: read as UTC.
    ["Tue, 10 Nov 2026 22:00:00", "2026-11-10T22:00:00Z"],
    ["2026-11-15T18:20:00+01:00", "2026-11-15T17:20:00Z"],
    ["2026-11-12T07:05:09.250Z", "2026-11-12T07:05:09Z"],
    ["2026-11-12T07:05:09-0800", "2026-11-12T15:05:09Z"],
    ["2026-11-12 07:05", "2026-11-12T07:05:00Z"],
    ["2026-11-11", "2026-11-11T00:00:00Z"],
    ["  2026-11-11T00:00:00z\n", "2026-11-11T00:00:00Z"],
    // Zone names beyond RFC 822.
    ["Sat, 14 Nov 2026 10:30:00 CET", "2026-11-14T09:30:00Z"],
    ["Sat, 14 Aug 2026 10:30:00 CEST", "2026-08-14T08:30:00Z"],
    ["Sat, 14 Aug 2026 10:30:00 BST", "2026-08-14T09:30:00Z"],
    ["Sat, 14 Nov 2026 10:30:00 IST", "2026-11-14T05:00:00Z"],
    ["Sat, 14 Nov 2026 10:30:00 JST", "2026-11-14T01:30:00Z"],
    ["Sat, 14 Nov 2026 10:30:00 AEST", "2026-11-14T00:30:00Z"],
    ["Sat, 14 Nov 2026 10:30:00 AEDT", "2026-11-13T23:30:00Z"],
    ["Sat, 14 Nov 2026 10:30:00 nzdt", "2026-11-13T21:30:00Z"],
    // A zone name that is not known is read as UTC rather than losing the date.
    ["Tue, 10 Nov 2026 22:00:00 XYZ", "2026-11-10T22:00:00Z"],
    ["Tue, 10 Nov 2026 22:00:00 LOCAL", "2026-11-10T22:00:00Z"],
    // A comment after the zone, and no space after the comma.
    ["Sat, 14 Nov 2026 09:30:00 +0000 (UTC)", "2026-11-14T09:30:00Z"],
    ["Sat, 14 Nov 2026 09:30:00 -0500 (Eastern Standard Time)", "2026-11-14T14:30:00Z"],
    ["Sat, 14 Nov 2026 09:30:00 GMT (GMT)", "2026-11-14T09:30:00Z"],
    ["Sat,14 Nov 2026 09:30:00 +0100", "2026-11-14T08:30:00Z"],
    ["Sat,14 Nov 2026 09:30:00 GMT", "2026-11-14T09:30:00Z"],
  ])("reads %s", (input, expected) => {
    expect(parseFeedDate(input)).toBe(at(expected));
  });

  it.each([
    "",
    "yesterday afternoon",
    "Wed, 32 Foo 2026 10:00:00 GMT",
    "Wed, 31 Feb 2026 10:00:00 GMT",
    "2026-13-45T10:00:00Z",
    "2026-02-30",
    "2026-11-12T25:00:00Z",
    "1794000000",
    "12",
    "Nov 2026",
    "Tue, 10 Nov 2026 22:00:00 TOOLONGZONE",
    "Tue, 10 Nov 2026 22:00:00 GMT (unclosed",
    "Tue, 10 Nov 2026 22:00:00 GMT ((nested))",
    "Tue, 10 Nov 2026 22:00:00 constructor",
    "2026-11-12T07:05:09+99:00",
    "0000-00-00T00:00:00Z",
    "1066-10-14",
    "2026-11-11T00:00:00Z and more text after the date",
    "9".repeat(5000),
  ])("refuses %s", (input) => {
    expect(parseFeedDate(input)).toBeNull();
  });
});

describe("safeLink", () => {
  it.each([
    ["https://news.example.com/a?b=1#c", "https://news.example.com/a?b=1#c"],
    ["/a/b", "https://news.example.com/a/b"],
    ["story.html", "https://news.example.com/science/feed/story.html"],
    ["//cdn.example.com/x", "https://cdn.example.com/x"],
    ["http://news.example.com/a", "https://news.example.com/a"],
    ["  https://news.example.com/a  ", "https://news.example.com/a"],
  ])("accepts %s", (href, expected) => {
    expect(safeLink(href, FEED)).toBe(expected);
  });

  it.each([
    "",
    "javascript:alert(1)",
    "data:text/html,<p>x",
    "mailto:someone@example.com",
    "ftp://news.example.com/a",
    "https://user:pw@news.example.com/a",
    "https://news.example.com:8443/a",
    "http://news.example.com:8080/a",
    "https://192.168.1.20/admin",
    "https://[::1]/",
    "https://localhost/a",
    "https://printer.local/a",
    "https://169.254.169.254/latest/meta-data/",
    `https://news.example.com/${"a".repeat(3000)}`,
    "https://",
  ])("refuses %s", (href) => {
    expect(safeLink(href, FEED)).toBeNull();
  });
});

describe("parseFeed", () => {
  it("reads RSS 2.0 with CDATA, content:encoded and escaped markup", () => {
    const feed = parseFeed(rss2, FEED);

    expect(feed.title).toBe("Example News » Science");
    expect(feed.items).toEqual([
      {
        title: "A new telescope sees first light — and it’s sharp",
        link: "https://news.example.com/science/new-telescope-first-light/",
        published: at("2026-11-16T13:45:00Z"),
        excerpt:
          "The observatory released its first images on Friday. Astronomers say the mirror & its coating performed “better than modelled”. Read more",
      },
      {
        // CDATA is markup as written; the http link is read as https and its &#038; decoded.
        title: "Why tide pools are getting warmer & saltier",
        link: "https://news.example.com/science/tide-pools-warmer/?utm_source=rss&utm_medium=feed",
        published: at("2026-11-13T13:15:30Z"),
        // The description is empty, so content:encoded gives the excerpt.
        excerpt: "Researchers sampled forty pools along the coast. They found temperatures two degrees above the ten-year mean.",
      },
      {
        // No <link>: the guid is the address. Escaped text is unescaped once, then stripped.
        title: "Soil microbes & the 3 < 5 rule",
        link: "https://news.example.com/science/soil-microbes-rule/",
        published: at("2026-11-10T22:00:00Z"),
        excerpt: "Escaped markup: A field study & a lab study agree.",
      },
      {
        title: "Last week’s story about glaciers",
        link: "https://news.example.com/science/glaciers-last-week/",
        published: at("2026-11-08T09:00:00Z"),
        excerpt: "Older than seven days; must not be returned.",
      },
      // "An item with nowhere to go" has no usable address, and the last item
      // links to a private address: both are left out.
    ]);
  });

  it("reads Atom with xml:base, relative links and the three kinds of text", () => {
    const feed = parseFeed(atom, new URL("https://blog.example.org/notes/atom.xml"));

    expect(feed.title).toBe("Field Notes & Sketches");
    expect(feed.items).toEqual([
      {
        title: "Mapping the old canal & its locks",
        // The link without rel, not the replies or enclosure link, against the feed's xml:base.
        link: "https://blog.example.org/notes/2026/canal-locks/",
        // <published> wins over <updated>.
        published: at("2026-11-15T17:20:00Z"),
        excerpt: "Three days on the towpath with a notebook.",
      },
      {
        title: "Sketching herons at dusk",
        // The entry's own xml:base.
        link: "https://blog.example.org/sketches/heron-dusk.html",
        published: at("2026-11-12T07:05:09Z"),
        excerpt: "Grey herons stand very still. Draw fast & lightly.",
      },
      {
        title: "Plain text with <b> in it stays as written",
        link: "https://blog.example.org/notes/2026/plain-text/",
        published: at("2026-11-11T00:00:00Z"),
        excerpt: null,
      },
      {
        title: "An entry from October",
        link: "https://blog.example.org/notes/2026/october/",
        published: at("2026-10-20T12:00:00Z"),
        excerpt: null,
      },
    ]);
  });

  it("reads RSS 1.0 (RDF), where items sit beside the channel", () => {
    const feed = parseFeed(rdf, new URL("https://journal.example.net/rss"));

    expect(feed.title).toBe("Example Journal: Latest Papers");
    expect(feed.items).toEqual([
      {
        title: "Sediment transport in braided rivers",
        link: "https://journal.example.net/papers/2026-0142",
        published: at("2026-11-14T00:00:00Z"),
        excerpt: "We measure bedload over two flood seasons.",
      },
      {
        // No <link>: rdf:about is the address.
        title: "A note on lichen growth rates",
        link: "https://journal.example.net/papers/2026-0139",
        published: at("2026-11-12T00:00:00Z"),
        excerpt: "Growth is slower than assumed.",
      },
      {
        title: "A paper from the summer",
        link: "https://journal.example.net/papers/2026-0101",
        published: at("2026-07-01T00:00:00Z"),
        excerpt: null,
      },
    ]);
  });

  it("gives null for a date it cannot read, and takes the first one it can", () => {
    const feed = parseFeed(badDates, new URL("https://careless.example.com/feed"));

    expect(feed.items.map((item) => [item.link.split("/posts/")[1], item.published])).toEqual([
      ["yesterday", null],
      ["thirty-second", null],
      ["good", at("2026-11-15T10:00:00Z")],
      ["none", null],
      ["thirteen", null],
      ["future", at("2031-11-15T10:00:00Z")],
      ["ahead", at("2026-11-16T18:00:00Z")],
      ["number", null],
      ["second-date", at("2026-11-13T04:00:00Z")],
    ]);
  });

  it("honours xml:base in RSS: on the root, the channel and the item", () => {
    const feed = parseFeed(
      `<rss version="2.0" xml:base="https://cdn.example.com/site/"><channel xml:base="blog/"><title>Based</title>
        <item><title>Against the channel</title><link>posts/one</link></item>
        <item xml:base="/elsewhere/"><title>Against the item</title><link>two</link></item>
        <item xml:base="javascript:alert(1)"><title>A base that is not an address is ignored</title><link>three</link></item>
        <item><title>Absolute stays absolute</title><link>https://news.example.com/four</link></item>
      </channel></rss>`,
      FEED,
    );
    expect(feed.items.map((entry) => entry.link)).toEqual([
      "https://cdn.example.com/site/blog/posts/one",
      "https://cdn.example.com/elsewhere/two",
      "https://news.example.com/four",
    ]);
  });

  it("cuts fields without splitting an emoji or a character reference", () => {
    const grin = "\u{1F600}";
    for (let pad = 0; pad < 4; pad++) {
      const feed = parseFeed(
        `<rss version="2.0"><channel><title>${"t".repeat(118 + pad)}${grin}${grin}</title>
          <item><link>https://news.example.com/e</link><title>${"a".repeat(297 + pad)}${grin}${grin}</title>
          <description>${"b".repeat(39_996 + pad)}${grin}&amp;${grin}</description></item></channel></rss>`,
        FEED,
      );
      for (const text of [feed.title, feed.items[0]?.title, feed.items[0]?.excerpt]) {
        expect(text?.isWellFormed()).toBe(true);
        expect(text).not.toMatch(/&[a-z]*$/);
      }
    }
  });

  it("uses the start of the text for an item without a title", () => {
    const feed = parseFeed(
      `<rss version="2.0"><channel><title>Micro</title><item><link>https://micro.example.com/1</link><description>${"A short post without any title. ".repeat(8)}</description></item></channel></rss>`,
      FEED,
    );
    expect(feed.items).toHaveLength(1);
    expect(feed.items[0]?.title.length).toBeLessThanOrEqual(100);
    expect(feed.items[0]?.title.startsWith("A short post without any title.")).toBe(true);
  });

  it.each([
    ["an HTML page", section],
    ["plain text", "Just some words."],
    ["nothing", ""],
    ["JSON", '{"version":"https://jsonfeed.org/version/1.1","items":[]}'],
    ["another XML vocabulary", '<?xml version="1.0"?><urlset><url><loc>https://example.com/</loc></url></urlset>'],
    ["an rss element without a channel", "<rss version='2.0'><item><title>x</title></item></rss>"],
    ["XML that is cut off", "<rss><channel><title>x</title><item><title>y</tit"],
    ["XML with a reserved element name", "<rss><channel><constructor>x</constructor></channel></rss>"],
  ])("refuses %s", (_name, text) => {
    expect(() => parseFeed(text, FEED)).toThrow(FeedParseError);
  });

  it("puts nothing of the input in the error", () => {
    try {
      // The parser's own message for this input quotes the text around the fault.
      parseFeed("<rss><channel><item>secret-token-123" + "<b ".repeat(50), FEED);
      expect.unreachable();
    } catch (error) {
      expect(error).toBeInstanceOf(FeedParseError);
      expect(String((error as Error).message)).toBe("Not a feed");
      expect(String((error as Error).stack)).not.toContain("secret-token-123");
    }
  });
});

describe("parseFeed on hostile input", () => {
  const item = (n: number) => `<item><title>Item ${n}</title><link>https://news.example.com/i/${n}</link></item>`;
  const wrap = (inner: string, prolog = "") => `<?xml version="1.0"?>${prolog}<rss version="2.0"><channel><title>T</title>${inner}</channel></rss>`;

  it("refuses a DOCTYPE that defines entities (billion laughs), at once", () => {
    let doctype = '<!DOCTYPE lolz [<!ENTITY lol "lol">';
    for (let i = 1; i < 10; i++) doctype += `<!ENTITY lol${i} "${`&lol${i === 1 ? "" : i - 1};`.repeat(10)}">`;
    doctype += "]>";
    const xml = wrap(`<item><title>Laughing &lol9; out loud</title><link>https://news.example.com/i/1</link></item>`, doctype);

    const started = performance.now();
    expect(() => parseFeed(xml, FEED)).toThrow(FeedParseError);
    expect(() => parseFeed(wrap(item(1), `<!DOCTYPE r [<!ENTITY big "${"B".repeat(9000)}">]>`), FEED)).toThrow(FeedParseError);
    expect(() => parseFeed(wrap(item(1), "<!DOCTYPE r []>"), FEED)).toThrow(FeedParseError);
    expect(performance.now() - started).toBeLessThan(500);
  });

  it("reads a feed with a DOCTYPE that defines nothing, and leaves unknown references as written", () => {
    const xml = wrap(
      `<item><title>Laughing &lol9; out loud</title><link>https://news.example.com/i/1</link><description>&lol9;&lol9; &amp; done</description></item>`,
      '<!DOCTYPE rss PUBLIC "-//Netscape Communications//DTD RSS 0.91//EN" "http://my.netscape.com/publish/formats/rss-0.91.dtd">',
    );
    expect(parseFeed(xml, FEED).items).toEqual([
      { title: "Laughing &lol9; out loud", link: "https://news.example.com/i/1", published: null, excerpt: "&lol9;&lol9; & done" },
    ]);
  });

  it("refuses a document that names an external entity", () => {
    const xml = wrap(item(1), '<!DOCTYPE r [<!ENTITY xxe SYSTEM "file:///etc/passwd">]>');
    expect(() => parseFeed(xml, FEED)).toThrow(FeedParseError);
  });

  it("refuses nesting deeper than 64 elements, at once", () => {
    const started = performance.now();
    expect(() => parseFeed("<a>".repeat(200_000) + "x" + "</a>".repeat(200_000), FEED)).toThrow(FeedParseError);
    expect(() => parseFeed(wrap(`<item><title>${"<b>".repeat(70)}deep${"</b>".repeat(70)}</title></item>`), FEED)).toThrow(FeedParseError);
    expect(performance.now() - started).toBeLessThan(500);
    // Sixty levels inside an item are read.
    const ok = parseFeed(wrap(`<item><link>https://news.example.com/i/1</link><title>${"<b>".repeat(55)}deep${"</b>".repeat(55)}</title></item>`), FEED);
    expect(ok.items[0]?.title).toBe("deep");
  });

  it(`reads at most ${MAX_ITEMS_SCANNED} items`, () => {
    let inner = "";
    for (let i = 0; i < 9000; i++) inner += item(i);
    const feed = parseFeed(wrap(inner), FEED);
    expect(feed.items).toHaveLength(MAX_ITEMS_SCANNED);
    expect(feed.items[MAX_ITEMS_SCANNED - 1]?.title).toBe(`Item ${MAX_ITEMS_SCANNED - 1}`);
  });

  it("cuts long fields", () => {
    const feed = parseFeed(
      wrap(`<item><title>${"long title ".repeat(5000)}</title><link>https://news.example.com/i/1</link><description>${"&lt;p&gt;text&lt;/p&gt; ".repeat(30_000)}</description></item>`),
      FEED,
    );
    expect(feed.items[0]?.title.length).toBeLessThanOrEqual(300);
    expect(feed.items[0]?.excerpt?.length).toBeLessThanOrEqual(300);
  });

  // The parser needs memory in proportion to the number of tags and
  // attributes, and for some shapes far more than a Worker has. The test
  // runtime does not enforce a Worker's 128 MB, so these assert that the text
  // is refused before the parser sees it; the heap each shape would need is
  // measured in Node and recorded in memory/architecture.md.
  describe("checkShape", () => {
    const KB = 1024;
    const refused: [string, () => string][] = [
      ["1 MB of '< '", () => "< ".repeat(512 * KB)],
      ["20 KB of '< '", () => "< ".repeat(10 * KB)],
      ["one '< ' inside a feed", () => wrap(`<item><title>a < b</title></item>`)],
      ["1 MB of '<a '", () => "<a ".repeat(340 * KB)],
      ["1 MB of '<'", () => "<".repeat(1000 * KB)],
      ["one element with 300,000 unquoted attributes", () => `<item ${"a= ".repeat(300_000)}/>`],
      ["one element with 80,000 quoted attributes", () => `<rss ${Array.from({ length: 80_000 }, (_v, i) => `a${i}="v"`).join(" ")}><channel/></rss>`],
      [`an element with ${MAX_ATTRIBUTES + 1} attributes`, () => wrap(`<item ${Array.from({ length: MAX_ATTRIBUTES + 1 }, (_v, i) => `a${i}="v"`).join(" ")}/>`)],
      [`a tag of ${MAX_TAG_CHARS + 1} characters`, () => wrap(`<item a="${"x".repeat(MAX_TAG_CHARS - 10)}"/>`)],
      [`a closing tag of ${MAX_TAG_CHARS + 1} characters`, () => wrap(`<item></item${" ".repeat(MAX_TAG_CHARS)}>`)],
      [`a processing instruction of ${MAX_TAG_CHARS + 1} characters`, () => wrap(`<?x ${"y".repeat(MAX_TAG_CHARS)}?>`)],
      [`${MAX_MARKUP + 1} empty elements`, () => wrap("<a/>".repeat(MAX_MARKUP))],
      [`${MAX_MARKUP + 1} comments`, () => wrap("<!--x-->".repeat(MAX_MARKUP))],
      [`${MAX_MARKUP + 1} CDATA sections`, () => wrap("<![CDATA[x]]>".repeat(MAX_MARKUP))],
      ["a tag that is never closed", () => "<rss><channel><item><title"],
      ["a quote that is never closed", () => wrap(`<item a="${"x".repeat(100)}></item>`)],
      ["a comment that is never closed", () => wrap("<!-- " + "x".repeat(100))],
      ["a CDATA section that is never closed", () => wrap("<item><title><![CDATA[ x </title></item>")],
      ["a declaration that is not a DOCTYPE", () => wrap(item(1), '<!ENTITY a "b">')],
      ["a DOCTYPE with an internal subset", () => wrap(item(1), "<!DOCTYPE rss [ <!ELEMENT rss ANY> ]>")],
      ["more than 1 MB of text", () => wrap(`<item><link>https://news.example.com/i/1</link><title>${"x".repeat(MAX_FEED_CHARS)}</title></item>`)],
    ];

    it.each(refused)("refuses %s", (_name, make) => {
      const xml = make();
      const started = performance.now();
      expect(() => checkShape(xml)).toThrow(FeedParseError);
      expect(() => parseFeed(xml, FEED)).toThrow(FeedParseError);
      expect(performance.now() - started).toBeLessThan(500);
    });

    it("lets through everything a real feed does, at the edge of each limit", () => {
      const attributes = Array.from({ length: MAX_ATTRIBUTES }, (_v, i) => `a${i}="v"`).join(" ");
      const xml = wrap(
        [
          `<item ${attributes}><link>https://news.example.com/i/edge</link><title>Edge of the limits</title>`,
          // A ">" and a "<" inside quotes, and both kinds of quote.
          `<media:content url="https://news.example.com/a?b=1&amp;c=>" title='a "quoted" < b' note="it's"/>`,
          `<enclosure url="https://news.example.com/${"x".repeat(MAX_TAG_CHARS - 100)}"/>`,
          // Comments and CDATA may hold anything.
          `<!-- < <a <b c= d= ${"< ".repeat(5000)} -->`,
          `<description><![CDATA[<p>1 < 2 and <a href="x">y</a> ${"<br ".repeat(5000)}]]></description>`,
          `<?xml-stylesheet href="a>b.xsl" type='text/xsl'?>`,
          `</item>`,
        ].join(""),
        '<!DOCTYPE rss PUBLIC "-//Example//DTD RSS 0.91//EN" "http://example.com/rss-0.91.dtd">',
      );

      expect(() => checkShape(xml)).not.toThrow();
      const feed = parseFeed(xml, FEED);
      expect(feed.items).toHaveLength(1);
      expect(feed.items[0]).toMatchObject({ title: "Edge of the limits", link: "https://news.example.com/i/edge" });
      expect(feed.items[0]?.excerpt?.startsWith("1 < 2 and y")).toBe(true);
    });

    it(`lets through ${MAX_MARKUP} pieces of markup`, () => {
      // The wrapper has nine tags of its own.
      const xml = wrap("<a/>".repeat(MAX_MARKUP - 9));
      expect(() => checkShape(xml)).not.toThrow();
      expect(parseFeed(xml, FEED).items).toEqual([]);
    });

    it("lets the four fixtures through", () => {
      for (const text of [rss2, atom, rdf, badDates]) expect(() => checkShape(text)).not.toThrow();
    });
  });

  // About 1 MB each, the most the fetch lets through. The bound is loose; the
  // measured times are in memory/architecture.md.
  const MB = 1024 * 1024;
  const big: [string, () => string][] = [
    ["14,000 small items", () => wrap(Array.from({ length: 14_000 }, (_v, i) => `<item><title>t${i}</title></item>`).join(""))],
    ["one element with 150,000 attributes", () => `<rss ${Array.from({ length: 150_000 }, (_v, i) => `a${i}="v"`).join(" ")}><channel/></rss>`],
    ["400,000 empty elements", () => wrap(" <a/>".repeat(400_000))],
    ["200,000 references in one title", () => wrap(`<item><link>https://news.example.com/i/1</link><title>${"&amp;".repeat(200_000)}</title></item>`)],
    ["59,000 empty elements", () => wrap("<a/>".repeat(59_000))],
    ["59,000 one-character text nodes", () => wrap("x<a/>".repeat(59_000))],
    ["3,000 elements of 64 attributes", () => wrap(`<a ${Array.from({ length: 64 }, (_v, i) => `a${i}="v"`).join(" ")}/>`.repeat(3000))],
    ["2 MB of '<' in a title", () => wrap(`<item><title>${"<".repeat(2 * MB)}</title></item>`)],
    ["a 2 MB DOCTYPE of entities", () => wrap(item(1), `<!DOCTYPE r [${'<!ENTITY a "b">'.repeat(130_000)}]>`)],
    ["500 items with 100 children each", () => wrap(`<item><link>https://news.example.com/i/1</link>${"<x/>".repeat(100)}<title>late</title></item>`.repeat(500))],
    ["500 items each with a 2 KB escaped description", () => wrap(`<item><title>t</title><link>https://news.example.com/i/1</link><description>${"&lt;p&gt;x&lt;/p&gt;".repeat(100)}</description></item>`.repeat(500))],
    ["unclosed CDATA", () => wrap(`<item><title>${"<![CDATA[".repeat(200_000)}`)],
    ["unclosed comments", () => wrap("<!--".repeat(500_000))],
  ];

  it.each(big)("stays fast on %s", (_name, make) => {
    const xml = make();
    const started = performance.now();
    try {
      parseFeed(xml, FEED);
    } catch (error) {
      expect(error).toBeInstanceOf(FeedParseError);
    }
    expect(performance.now() - started).toBeLessThan(3000);
  });
});
