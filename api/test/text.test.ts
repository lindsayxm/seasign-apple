import { describe, expect, it } from "vitest";
import { clip, collapseSpace, cut, cutSource, decodeEntities, htmlToText, plainText, wellFormed } from "../src/lib/text.ts";

describe("decodeEntities", () => {
  it.each([
    ["Fish &amp; chips", "Fish & chips"],
    ["&lt;b&gt; &quot;x&quot; &apos;y&apos;", "<b> \"x\" 'y'"],
    ["it&#8217;s &#x2014; fine &#X2014;", "it’s — fine —"],
    ["caf&eacute; &nbsp;&hellip;&raquo;", "café \u00a0…»"],
    // Decoded once, not twice.
    ["&amp;lt;p&amp;gt;", "&lt;p&gt;"],
    // Old Windows references mean the cp1252 characters.
    ["&#146;quoted&#148;", "’quoted”"],
    // Not references: left as written.
    ["AT&T, a & b, &unknown; &#; &#x; &#12a; &toolongtobeanentityname;", "AT&T, a & b, &unknown; &#; &#x; &#12a; &toolongtobeanentityname;"],
    ["trailing &", "trailing &"],
    ["&amp", "&amp"],
    // Out of range, surrogates and NUL become the replacement character; controls become a space.
    ["&#x110000;&#xD800;&#0;&#99999999;", "����"],
    ["a&#7;b", "a b"],
    ["&#x1F600;", "😀"],
    // Names are looked up as own keys only.
    ["&constructor; &__proto__; &toString;", "&constructor; &__proto__; &toString;"],
  ])("%s", (input, expected) => {
    expect(decodeEntities(input)).toBe(expected);
  });

  it("never makes text longer", () => {
    const input = "&amp;&lt;&#65;&bogus;&".repeat(1000);
    expect(decodeEntities(input).length).toBeLessThanOrEqual(input.length);
  });
});

describe("htmlToText", () => {
  it.each([
    ["<p>One <b>two</b> three.</p><p>Four</p>", "One two three. Four"],
    ["line<br>break<br/>again", "line break again"],
    ["a &lt; b &amp;&amp; c > d", "a < b && c > d"],
    ["3 < 5 and 5 > 3", "3 < 5 and 5 > 3"],
    ["<a href=\"/x?a=1&amp;b=2\" title=\"a > b\">link</a> text", "link text"],
    ["before<!-- a <b>comment</b> -->after", "beforeafter"],
    ["x<script>var a = '</p>'; if (a < b) {}</script>y<STYLE>p { color: red }</STYLE>z", "x y z"],
    ["<p>entity in text: &lt;script&gt;alert(1)&lt;/script&gt;</p>", "entity in text: <script>alert(1)</script>"],
    ["  spaced \n\t out ​ text  ", "spaced out text"],
    ["<img src=x alt='a'>caption", "caption"],
    ["<![CDATA[kept as nothing]]>after", "after"],
    // An unclosed tag, comment or script ends the text there.
    ["shown <a href='x", "shown"],
    ["shown <!-- never closed", "shown"],
    ["shown <script>never closed", "shown"],
    ["", ""],
  ])("%s", (input, expected) => {
    expect(htmlToText(input, 300)).toBe(expected);
  });

  it("cuts at a word boundary and marks the cut", () => {
    const text = htmlToText(`<p>${"word ".repeat(200)}</p>`, 300);
    expect(text.length).toBeLessThanOrEqual(300);
    expect(text.endsWith("word…")).toBe(true);
  });

  it("does not cut a surrogate pair in half", () => {
    const text = clip("😀".repeat(50), 20);
    expect(text.length).toBeLessThanOrEqual(20);
    expect(text).toBe(`${"😀".repeat(9)}…`);
  });

  it("collapses and trims", () => {
    expect(collapseSpace(" a \r\n b\t\tc ")).toBe("a b c");
    expect(plainText("  A &amp;  B <b> ", 50)).toBe("A & B <b>");
  });
});

describe("cutting text", () => {
  const GRIN = "\u{1F600}"; // two UTF-16 units

  it("never cuts a surrogate pair in half", () => {
    expect(cut(`ab${GRIN}`, 3)).toBe("ab");
    expect(cut(`ab${GRIN}`, 4)).toBe(`ab${GRIN}`);
    expect(cut(`ab${GRIN}cd`, 10)).toBe(`ab${GRIN}cd`);
    expect(cut(GRIN, 1)).toBe("");
    expect(cut("abc", 0)).toBe("");
    for (let max = 0; max <= 12; max++) expect(cut(GRIN.repeat(6), max).isWellFormed()).toBe(true);
  });

  it("drops a character reference the cut went through", () => {
    expect(cutSource("fish &amp; chips", 8)).toBe("fish ");
    expect(cutSource("fish &amp; chips", 9)).toBe("fish ");
    expect(cutSource("fish &amp; chips", 10)).toBe("fish &amp;");
    expect(cutSource("it&#8217;s", 5)).toBe("it");
    expect(cutSource("it&#8217;s", 9)).toBe("it&#8217;");
    // Not a reference: an ampersand followed by a space, or one that is too far back.
    expect(cutSource("a & b and more", 5)).toBe("a & b");
    expect(cutSource("a &abcdefghijklmnop", 16)).toBe("a &abcdefghijklm");
    expect(cutSource(`ab${GRIN}`, 3)).toBe("ab");
    expect(cutSource("short", 50)).toBe("short");
  });

  it("replaces a lone surrogate that the site itself sent", () => {
    expect(wellFormed("a\ud83db")).toBe("a\ufffdb");
    expect(wellFormed("a\ude00")).toBe("a\ufffd");
    expect(wellFormed(`ok ${GRIN}`)).toBe(`ok ${GRIN}`);
    expect(collapseSpace("a\ud83d b")).toBe("a\ufffd b");
    expect(plainText("title \ud83d", 50)).toBe("title \ufffd");
    expect(htmlToText("<p>title \ud83d</p>", 50)).toBe("title \ufffd");
  });

  it("gives well-formed text at every length", () => {
    const html = `<p>${`caf&eacute; ${GRIN} &amp; `.repeat(40)}</p>`;
    for (let max = 1; max <= 60; max++) {
      for (const text of [htmlToText(html, max), plainText(html, max), clip(`${GRIN} `.repeat(30), max)]) {
        expect(text.length).toBeLessThanOrEqual(max);
        expect(text.isWellFormed()).toBe(true);
      }
    }
  });

  it("does not leave half a reference when the scan stops inside one", () => {
    // 300 characters are wanted, so 3,664 are scanned; the reference straddles that point.
    const padded = `start${" ".repeat(3657)}&amp;after`;
    expect(padded.indexOf("&")).toBe(3662);
    expect(htmlToText(padded, 300)).toBe("start");
    expect(plainText(padded, 300)).toBe("start");
    // The same at the 40,000-character limit of the HTML scan.
    const long = `<p>start</p>${"<i></i>".repeat(5712)}  &amp;after`;
    expect(long.indexOf("&")).toBe(39_998);
    expect(htmlToText(long, 300)).toBe("start");
  });

  it("removes control and direction characters, and keeps the joiners emoji need", () => {
    // C1 controls, and the override that makes "gnp.exe" read "exe.png".
    expect(collapseSpace("a\u0085b\u009fc")).toBe("abc");
    expect(collapseSpace("invoice\u202egnp.exe")).toBe("invoicegnp.exe");
    expect(collapseSpace("a\u202ab\u202bc\u202cd\u202de\u2066f\u2067g\u2068h\u2069i")).toBe("abcdefghi");
    expect(collapseSpace("a\u200eb\u200fc\ufeffd\u0000e\u007ff")).toBe("abcdef");
    const family = "\u{1F468}\u200d\u{1F469}\u200d\u{1F467}";
    expect(collapseSpace(` ${family} `)).toBe(family);
    expect(collapseSpace("می\u200cخواهم")).toBe("می\u200cخواهم");
    // White space of every kind is still one space.
    expect(collapseSpace("a\u00a0\u2003\u2028\t\n b")).toBe("a b");
    expect(htmlToText("<p>pay\u202eload</p>", 50)).toBe("payload");
  });
});

// Each of these would take seconds or minutes with a backtracking pattern
// such as /<[^>]*>/ or /<script[\s\S]*?<\/script>/ applied in a loop.
describe("htmlToText on hostile input", () => {
  const MB = 1024 * 1024;
  const cases: [string, () => string][] = [
    ["2 MB of '<'", () => "<".repeat(2 * MB)],
    ["2 MB of '<a '", () => "<a ".repeat((2 * MB) / 3)],
    ["2 MB of '<!--'", () => "<!--".repeat(MB / 2)],
    ["2 MB of '<script>'", () => "<script>".repeat(MB / 4)],
    ["2 MB of '</'", () => "<script>" + "</".repeat(MB)],
    ["2 MB of '&'", () => "&".repeat(2 * MB)],
    ["2 MB of '&#'", () => "&#".repeat(MB)],
    ["2 MB of spaces", () => " ".repeat(2 * MB) + "x"],
    ["2 MB of quotes in a tag", () => "<a " + "\"'".repeat(MB)],
    ["2 MB of tags", () => "<b>x</b>".repeat(MB / 4)],
  ];

  it.each(cases)("%s", (_name, make) => {
    const input = make();
    const started = performance.now();
    const text = htmlToText(input, 300);
    const plain = plainText(input, 300);
    const decoded = decodeEntities(input);
    const elapsed = performance.now() - started;
    expect(text.length).toBeLessThanOrEqual(300);
    expect(plain.length).toBeLessThanOrEqual(300);
    expect(decoded.length).toBeLessThanOrEqual(input.length);
    expect(elapsed).toBeLessThan(1000);
  });
});
