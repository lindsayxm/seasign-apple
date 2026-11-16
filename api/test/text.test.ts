import { describe, expect, it } from "vitest";
import { clip, collapseSpace, decodeEntities, htmlToText, plainText } from "../src/lib/text.ts";

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
