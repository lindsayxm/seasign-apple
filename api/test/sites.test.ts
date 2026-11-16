import { env, exports } from "cloudflare:workers";
import { afterEach, describe, expect, it, vi } from "vitest";
// Written by hand in the shape of real feeds and pages; no real site was fetched.
import atom from "./fixtures/sites/atom.xml?raw";
import links from "./fixtures/sites/links.html?raw";
import rss2 from "./fixtures/sites/rss2.xml?raw";
import section from "./fixtures/sites/section.html?raw";

const SECTION = "https://news.example.com/science/";
const SECTION_FEED = "https://news.example.com/science/feed/?format=rss&v=2";
const SITE_FEED = "https://news.example.com/feed/";
const COMMENTS_FEED = "https://news.example.com/comments/feed/";
const WORLD = "https://daily.example.org/world/";
const BROKEN = "https://broken.example.com/section/tok-5550123/";

type Reply = () => Response | Promise<Response>;
const html = (text: string): Reply => () => new Response(text, { headers: { "content-type": "text/html; charset=utf-8" } });
const rss = (text: string): Reply => () => new Response(text, { headers: { "content-type": "application/rss+xml; charset=utf-8" } });
const status = (code: number): Reply => () => new Response("no", { status: code });

/** Replaces outbound fetch with a table of exact URLs. Any other request fails, so nothing reaches the network. */
function mockWeb(replies: Record<string, Reply>) {
  return vi.spyOn(globalThis, "fetch").mockImplementation(async (input, init) => {
    const request = new Request(input, init);
    const reply = replies[request.url];
    if (!reply) throw new Error("Unexpected outbound request");
    return reply();
  });
}

const requested = (spy: ReturnType<typeof mockWeb>) => spy.mock.calls.map(([input]) => String(input));

const post = (body: unknown, contentType: string | null = "application/json") =>
  exports.default.fetch("https://example.com/v1/sites/resolve", {
    method: "POST",
    headers: contentType === null ? {} : { "content-type": contentType },
    body: contentType === "application/json" ? (typeof body === "string" ? body : JSON.stringify(body)) : new Blob([JSON.stringify(body)]).stream(),
  });

async function resolve(url: string): Promise<Record<string, unknown>> {
  const response = await post({ url });
  expect(response.status).toBe(200);
  return (await response.json()) as Record<string, unknown>;
}

afterEach(() => {
  vi.useRealTimers();
  vi.restoreAllMocks();
});

describe("POST /v1/sites/resolve", () => {
  it("finds the feed a section page advertises, preferring the section's own", async () => {
    const spy = mockWeb({ [SECTION]: html(section), [SECTION_FEED]: rss(rss2) });

    // Typed with capitals, a fragment and spaces around it.
    const body = await resolve("  HTTPS://News.Example.com/science/#latest ");

    expect(body).toEqual({
      ok: true,
      title: "Science | Example News & Views",
      url: SECTION,
      mode: "feed",
      feedUrl: SECTION_FEED,
    });
    expect(requested(spy)).toEqual([SECTION, SECTION_FEED]);
  });

  it("fetches as a plain GET that names no one", async () => {
    const spy = mockWeb({ [SECTION]: html(section), [SECTION_FEED]: rss(rss2) });

    await resolve(SECTION);

    for (const [, init] of spy.mock.calls) {
      expect(init?.method).toBe("GET");
      expect(init?.redirect).toBe("manual");
      const headers = new Headers(init?.headers);
      expect(headers.get("user-agent")).toBe("SeasignBot/1.0");
      expect([...headers.keys()].sort()).toEqual(["accept", "user-agent"]);
    }
  });

  it("tries the next advertised feed when the best one does not answer with a feed", async () => {
    const spy = mockWeb({ [SECTION]: html(section), [SECTION_FEED]: status(404), [SITE_FEED]: rss(rss2) });

    const body = await resolve(SECTION);

    expect(body).toMatchObject({ ok: true, mode: "feed", feedUrl: SITE_FEED });
    expect(requested(spy)).toEqual([SECTION, SECTION_FEED, SITE_FEED]);
  });

  it("falls back to the page's links when no advertised feed works, after trying two", async () => {
    const spy = mockWeb({
      [SECTION]: html(section),
      // A web page where the feed should be, and a feed address that is gone.
      [SECTION_FEED]: html("<!doctype html><html><body>Sign in</body></html>"),
      [SITE_FEED]: status(410),
      [COMMENTS_FEED]: rss(rss2),
    });

    const body = await resolve(SECTION);

    expect(body).toEqual({ ok: true, title: "Science | Example News & Views", url: SECTION, mode: "links" });
    expect(requested(spy)).toEqual([SECTION, SECTION_FEED, SITE_FEED]);
  });

  it("answers links for a page that advertises no feed", async () => {
    const spy = mockWeb({ [WORLD]: html(links) });

    const body = await resolve(WORLD);

    expect(body).toEqual({ ok: true, title: "World & Politics – The Daily Example", url: WORLD, mode: "links" });
    expect(requested(spy)).toEqual([WORLD]);
  });

  it("never requests an advertised feed on a private address", async () => {
    const page = `<html><head><title>Intranet bait</title>
      <link rel="alternate" type="application/rss+xml" href="https://10.0.0.5/feed">
      <link rel="alternate" type="application/rss+xml" href="http://169.254.169.254/latest/meta-data/">
      <link rel="alternate" type="application/atom+xml" href="https://localhost/atom.xml">
      </head><body></body></html>`;
    const spy = mockWeb({ [WORLD]: html(page) });

    const body = await resolve(WORLD);

    expect(body).toEqual({ ok: true, title: "Intranet bait", url: WORLD, mode: "links" });
    expect(requested(spy)).toEqual([WORLD]);
  });

  it("does not follow an advertised feed that redirects to a private address", async () => {
    const spy = mockWeb({
      [SECTION]: html(section),
      [SECTION_FEED]: () => new Response(null, { status: 302, headers: { location: "https://192.168.1.1/feed" } }),
      [SITE_FEED]: rss(rss2),
    });

    const body = await resolve(SECTION);

    expect(body).toMatchObject({ ok: true, mode: "feed", feedUrl: SITE_FEED });
    expect(requested(spy)).toEqual([SECTION, SECTION_FEED, SITE_FEED]);
  });

  it.each([
    ["RSS served as application/rss+xml", rss(rss2), "Example News » Science"],
    ["RSS served as text/html", html(rss2), "Example News » Science"],
    ["RSS served without a Content-Type", () => new Response(new TextEncoder().encode(rss2)), "Example News » Science"],
    ["Atom served as application/atom+xml", () => new Response(atom, { headers: { "content-type": "application/atom+xml" } }), "Field Notes & Sketches"],
    ["Atom served as text/xml", () => new Response(atom, { headers: { "content-type": "text/xml" } }), "Field Notes & Sketches"],
  ] as [string, Reply, string][])("answers feed for an address that is itself a feed: %s", async (_name, reply, title) => {
    const address = "https://news.example.com/science/feed/";
    const spy = mockWeb({ [address]: reply });

    const body = await resolve(address);

    expect(body).toEqual({ ok: true, title, url: address, mode: "feed", feedUrl: address });
    expect(requested(spy)).toEqual([address]);
  });

  it("uses the host as the title of a page without one", async () => {
    mockWeb({ "https://www.bare.example.com/": html("<html><body><p>Hello</p></body></html>") });
    expect(await resolve("https://www.bare.example.com")).toEqual({
      ok: true,
      title: "bare.example.com",
      url: "https://www.bare.example.com/",
      mode: "links",
    });
  });

  it("follows a redirect and resolves the feed against the address that answered", async () => {
    const spy = mockWeb({
      "https://example.com/science": () => new Response(null, { status: 301, headers: { location: SECTION } }),
      [SECTION]: html(section),
      [SECTION_FEED]: rss(rss2),
    });

    const body = await resolve("https://example.com/science");

    // The address the user typed is what the app stores.
    expect(body).toMatchObject({ ok: true, url: "https://example.com/science", mode: "feed", feedUrl: SECTION_FEED });
    expect(requested(spy)).toEqual(["https://example.com/science", SECTION, SECTION_FEED]);
  });

  describe("failures", () => {
    const failures: [string, Reply, string][] = [
      ["a picture", () => new Response(new Uint8Array([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a]), { headers: { "content-type": "image/png" } }), "not_html"],
      ["a PDF", () => new Response("%PDF-1.7 ...", { headers: { "content-type": "application/pdf" } }), "not_html"],
      ["JSON", () => new Response('{"a":1}', { headers: { "content-type": "application/json" } }), "not_html"],
      ["plain text", () => new Response("just words", { headers: { "content-type": "text/plain" } }), "not_html"],
      ["XML that is not a feed", () => new Response('<?xml version="1.0"?><urlset><url/></urlset>', { headers: { "content-type": "application/xml" } }), "not_feed"],
      ["more than 2 MB", () => new Response("<html><body>" + "<p>padding</p>".repeat(170_000), { headers: { "content-type": "text/html" } }), "too_large"],
      ["more than 2 MB by its Content-Length", () => new Response("<html>", { headers: { "content-type": "text/html", "content-length": "3000000" } }), "too_large"],
      ["a redirect to a private address", () => new Response(null, { status: 302, headers: { location: "https://10.0.0.5/internal" } }), "blocked_host"],
      ["a redirect to plain http", () => new Response(null, { status: 301, headers: { location: "http://broken.example.com/" } }), "invalid_url"],
      ["a redirect for ever", () => new Response(null, { status: 302, headers: { location: BROKEN } }), "fetch_failed"],
      ["404", status(404), "fetch_failed"],
      ["503", status(503), "fetch_failed"],
      ["no answer", () => Promise.reject(new TypeError(`fetch failed: ${BROKEN}`)), "fetch_failed"],
    ];

    it.each(failures)("answers ok:false for %s", async (_name, reply, code) => {
      mockWeb({ [BROKEN]: reply });
      expect(await resolve(BROKEN)).toEqual({ ok: false, error: code });
    });

    it("reports a host that never answers as timeout", async () => {
      vi.useFakeTimers({ toFake: ["setTimeout", "clearTimeout"] });
      let aborted = false;
      vi.spyOn(globalThis, "fetch").mockImplementation(
        (_input, init) =>
          new Promise<Response>((_resolve, reject) => {
            init?.signal?.addEventListener("abort", () => {
              aborted = true;
              reject(new DOMException("aborted", "AbortError"));
            });
            queueMicrotask(() => vi.advanceTimersByTime(7999));
            queueMicrotask(() => expect(aborted).toBe(false));
            queueMicrotask(() => vi.advanceTimersByTime(1));
          }),
      );

      expect(await resolve(BROKEN)).toEqual({ ok: false, error: "timeout" });
      expect(aborted).toBe(true);
    });

    it.each([
      ["plain http", "http://news.example.com/science/", "invalid_url"],
      ["another scheme", "ftp://news.example.com/science/", "invalid_url"],
      ["not an address", "the science page", "invalid_url"],
      ["an empty string", "", "invalid_url"],
      ["credentials in the address", "https://someone:hunter2@news.example.com/", "invalid_url"],
      ["another port", "https://news.example.com:8443/", "invalid_url"],
      ["an absurdly long address", `https://news.example.com/${"a".repeat(3000)}`, "invalid_url"],
      ["a private address", "https://192.168.1.10/", "blocked_host"],
      ["loopback", "https://127.0.0.1/", "blocked_host"],
      ["loopback over IPv6", "https://[::1]/", "blocked_host"],
      ["the cloud metadata address", "https://169.254.169.254/latest/meta-data/", "blocked_host"],
      ["localhost", "https://localhost/", "blocked_host"],
      ["a .internal name", "https://wiki.corp.internal/", "blocked_host"],
    ])("refuses %s without a request", async (_name, url, code) => {
      const spy = mockWeb({});
      expect(await resolve(url)).toEqual({ ok: false, error: code });
      expect(spy).not.toHaveBeenCalled();
    });
  });

  it("stores nothing", async () => {
    mockWeb({ [SECTION]: html(section), [SECTION_FEED]: rss(rss2), [WORLD]: html(links) });
    const before = (await env.CACHE.list()).keys.length;
    await resolve(SECTION);
    await resolve(WORLD);
    expect((await env.CACHE.list()).keys.length).toBe(before);
  });

  it("never puts the address in a log line or an error answer", async () => {
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

    mockWeb({
      [BROKEN]: () => Promise.reject(new TypeError(`fetch failed: ${BROKEN}`)),
      "https://broken.example.com/quoted/tok-5550123": () => new Response(`<urlset>${BROKEN}</urlset>`, { headers: { "content-type": "text/xml" } }),
      "https://broken.example.com/redirect/tok-5550123": () => new Response(null, { status: 302, headers: { location: "https://10.0.0.5/tok-5550123" } }),
    });
    expect(await run({ url: BROKEN })).toBe(200);
    expect(await run({ url: "https://broken.example.com/quoted/tok-5550123" })).toBe(200);
    expect(await run({ url: "https://broken.example.com/redirect/tok-5550123" })).toBe(200);
    expect(await run({ url: "http://broken.example.com/tok-5550123" })).toBe(200);
    expect(await run({ url: "https://someone:tok-5550123@broken.example.com/" })).toBe(200);
    expect(await run({ url: "not a url tok-5550123" })).toBe(200);
    expect(await run({ url: ["https://broken.example.com/tok-5550123"] })).toBe(400);
    expect(await run(`{"url": "${BROKEN}"`)).toBe(400);

    expect(logged).toContain("sites: resolve failed: fetch_failed");
    expect(logged).toContain("sites: resolve failed: not_feed");
    expect(logged).toContain("sites: resolve failed: blocked_host");
    expect(logged).toContain("sites: resolve failed: invalid_url");
    for (const secret of ["tok-5550123", "broken.example.com", "/section/", "10.0.0.5", "hunter2", "someone"]) {
      expect(logged.join("\n"), `logs hold ${secret}`).not.toContain(secret);
      expect(answers.join("\n"), `an answer holds ${secret}`).not.toContain(secret);
    }
  });

  describe("invalid requests", () => {
    const INVALID = { error: "invalid_request", message: "Send the address of one page as url" };

    it.each([
      ["no body", ""],
      ["malformed JSON", '{"url": '],
      ["no url field", {}],
      ["a url that is not a string", { url: 5 }],
      ["a list of urls", { url: [SECTION] }],
      ["a list", [SECTION]],
      ["null", "null"],
    ])("answers 400 to %s, with a fixed message and no outbound request", async (_name, body) => {
      const spy = mockWeb({ [SECTION]: html(section) });

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
      const spy = mockWeb({ [SECTION]: html(section) });

      const response = await post({ url: SECTION }, contentType);

      expect(response.status).toBe(400);
      expect(await response.json()).toEqual(INVALID);
      expect(spy).not.toHaveBeenCalled();
    });
  });
});
