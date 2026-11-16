import { afterEach, describe, expect, it, vi } from "vitest";
import {
  SAFE_FETCH_MAX_BYTES,
  SAFE_FETCH_TIMEOUT_MS,
  SafeFetchError,
  assertSafeUrl,
  parseSafeUrl,
  safeFetch,
} from "../src/lib/safe-fetch.ts";

type Reply = (url: URL, init: RequestInit | undefined) => Response | Promise<Response>;

/** Replaces outbound fetch with a table of exact URLs. Any other request fails the test. */
function mockFetch(replies: Record<string, Reply>) {
  return vi.spyOn(globalThis, "fetch").mockImplementation(async (input, init) => {
    const url = new URL(typeof input === "string" ? input : input instanceof URL ? input.href : input.url);
    const reply = replies[url.href];
    if (!reply) throw new Error("Unexpected outbound request");
    return reply(url, init);
  });
}

const redirect = (location: string, status = 302) => new Response(null, { status, headers: { location } });

/** A body that arrives in pieces and reports no length. */
function streamOf(chunks: Uint8Array[], onCancel?: () => void): ReadableStream<Uint8Array> {
  let next = 0;
  return new ReadableStream({
    pull(controller) {
      const chunk = chunks[next++];
      if (chunk) controller.enqueue(chunk);
      else controller.close();
    },
    cancel() {
      onCancel?.();
    },
  });
}

async function codeOf(work: Promise<unknown> | (() => unknown)): Promise<string> {
  try {
    await (typeof work === "function" ? work() : work);
  } catch (error) {
    if (error instanceof SafeFetchError) return error.code;
    throw error;
  }
  return "no error";
}

afterEach(() => {
  vi.restoreAllMocks();
});

describe("parseSafeUrl", () => {
  it.each([
    ["https://calendar.example.com/a/b.ics?x=1", "https://calendar.example.com/a/b.ics?x=1"],
    ["https://calendar.example.com:443/a.ics", "https://calendar.example.com/a.ics"],
    ["  https://calendar.example.com/a.ics\n", "https://calendar.example.com/a.ics"],
    ["https://calendar.example.com/a.ics#section", "https://calendar.example.com/a.ics"],
    ["webcal://p01-caldav.example.com/published/2/abc", "https://p01-caldav.example.com/published/2/abc"],
    ["WEBCAL://p01-caldav.example.com/published/2/abc", "https://p01-caldav.example.com/published/2/abc"],
    ["webcals://p01-caldav.example.com/published/2/abc", "https://p01-caldav.example.com/published/2/abc"],
    ["https://93.184.216.34/a.ics", "https://93.184.216.34/a.ics"],
    ["https://[2606:2800:220:1:248:1893:25c8:1946]/a.ics", "https://[2606:2800:220:1:248:1893:25c8:1946]/a.ics"],
  ])("accepts %s", (input, href) => {
    expect(parseSafeUrl(input).href).toBe(href);
  });

  it.each([
    ["not a url at all"],
    [""],
    ["http://calendar.example.com/a.ics"],
    ["ftp://calendar.example.com/a.ics"],
    ["file:///etc/passwd"],
    ["data:text/calendar,BEGIN:VCALENDAR"],
    ["javascript:alert(1)"],
    ["//calendar.example.com/a.ics"],
    ["https://user:secret@calendar.example.com/a.ics"],
    ["https://user@calendar.example.com/a.ics"],
    ["https://calendar.example.com:8443/a.ics"],
    ["https://calendar.example.com:80/a.ics"],
    ["webcal://calendar.example.com:8080/a.ics"],
  ])("refuses %s as invalid_url", async (input) => {
    expect(await codeOf(() => parseSafeUrl(input))).toBe("invalid_url");
  });

  it.each([
    // Names that only resolve inside a network.
    ["https://localhost/a.ics"],
    ["https://LOCALHOST/a.ics"],
    ["https://localhost./a.ics"],
    ["https://app.localhost/a.ics"],
    ["https://printer.local/a.ics"],
    ["https://nas.local./a.ics"],
    ["https://metadata.google.internal/computeMetadata/v1/"],
    ["https://wiki.corp.internal/a.ics"],
    ["https://router.lan/a.ics"],
    ["https://box.home.arpa/a.ics"],
    ["https://intranet/a.ics"],
    ["https://metadata/a.ics"],
    // IPv4: loopback, private, link-local, carrier NAT, unspecified, multicast, broadcast.
    ["https://127.0.0.1/a.ics"],
    ["https://127.8.9.10/a.ics"],
    ["https://10.0.0.5/a.ics"],
    ["https://172.16.0.1/a.ics"],
    ["https://172.31.255.255/a.ics"],
    ["https://192.168.1.1/a.ics"],
    ["https://169.254.169.254/latest/meta-data/"],
    ["https://100.64.0.1/a.ics"],
    ["https://0.0.0.0/a.ics"],
    ["https://224.0.0.1/a.ics"],
    ["https://255.255.255.255/a.ics"],
    ["https://192.0.2.10/a.ics"],
    // IPv4 written another way: the URL parser turns these into dotted decimal.
    ["https://2130706433/a.ics"],
    ["https://0x7f000001/a.ics"],
    ["https://0x7f.0.0.1/a.ics"],
    ["https://0177.0.0.1/a.ics"],
    ["https://127.1/a.ics"],
    ["https://10.1/a.ics"],
    // IPv6: loopback, unspecified, unique local, link-local, multicast, and IPv4 carried inside IPv6.
    ["https://[::1]/a.ics"],
    ["https://[::]/a.ics"],
    ["https://[0:0:0:0:0:0:0:1]/a.ics"],
    ["https://[fc00::1]/a.ics"],
    ["https://[fd12:3456:789a::1]/a.ics"],
    ["https://[fe80::1]/a.ics"],
    ["https://[febf::1]/a.ics"],
    ["https://[fec0::1]/a.ics"],
    ["https://[ff02::1]/a.ics"],
    ["https://[::ffff:127.0.0.1]/a.ics"],
    ["https://[::ffff:7f00:1]/a.ics"],
    ["https://[::ffff:10.0.0.1]/a.ics"],
    ["https://[::ffff:169.254.169.254]/a.ics"],
    ["https://[::127.0.0.1]/a.ics"],
    ["https://[64:ff9b::7f00:1]/a.ics"],
    ["https://[2002:7f00:1::]/a.ics"],
    ["https://[2002:a00:1::1]/a.ics"],
    ["https://[2001:db8::1]/a.ics"],
    ["webcal://192.168.0.10/calendar.ics"],
  ])("refuses %s as blocked_host", async (input) => {
    expect(await codeOf(() => parseSafeUrl(input))).toBe("blocked_host");
  });

  it.each([
    ["https://172.15.0.1/a.ics"],
    ["https://172.32.0.1/a.ics"],
    ["https://100.63.0.1/a.ics"],
    ["https://100.128.0.1/a.ics"],
    ["https://169.253.0.1/a.ics"],
    ["https://192.167.1.1/a.ics"],
    ["https://[::ffff:93.184.216.34]/a.ics"],
    ["https://[2002:5db8:d822::1]/a.ics"],
    ["https://[fbff::1]/a.ics"],
    ["https://local.example.com/a.ics"],
    ["https://internal.example.com/a.ics"],
    ["https://localhost.example.com/a.ics"],
  ])("accepts the public neighbour %s", (input) => {
    expect(() => parseSafeUrl(input)).not.toThrow();
  });

  it("does not rewrite webcal when checking a URL that is already parsed", async () => {
    expect(await codeOf(() => assertSafeUrl(new URL("webcal://calendar.example.com/a.ics")))).toBe("invalid_url");
  });

  it("never puts the URL in the error message", () => {
    for (const input of ["http://secret-host.example.com/private-token-123.ics", "https://10.0.0.5/private-token-123.ics"]) {
      try {
        parseSafeUrl(input);
        expect.unreachable();
      } catch (error) {
        const text = `${(error as Error).message} ${(error as Error).stack ?? ""} ${JSON.stringify(error)}`;
        expect(text).not.toContain("private-token-123");
        expect(text).not.toContain("secret-host");
        expect(text).not.toContain("10.0.0.5");
      }
    }
  });
});

describe("safeFetch", () => {
  it("has an 8 second deadline and a 2 MB cap by default", () => {
    expect(SAFE_FETCH_TIMEOUT_MS).toBe(8000);
    expect(SAFE_FETCH_MAX_BYTES).toBe(2 * 1024 * 1024);
  });

  it("returns the body, status, headers and final URL", async () => {
    mockFetch({
      "https://calendar.example.com/a.ics": () =>
        new Response("BEGIN:VCALENDAR", { headers: { "content-type": "text/calendar" } }),
    });

    const result = await safeFetch("https://calendar.example.com/a.ics");

    expect(result.status).toBe(200);
    expect(result.url.href).toBe("https://calendar.example.com/a.ics");
    expect(result.headers.get("content-type")).toBe("text/calendar");
    expect(new TextDecoder().decode(result.body)).toBe("BEGIN:VCALENDAR");
  });

  it("sends a plain GET with a bare user agent and follows no redirect itself", async () => {
    const spy = mockFetch({ "https://calendar.example.com/a.ics": () => new Response("ok") });

    await safeFetch("https://calendar.example.com/a.ics", { accept: "text/calendar" });

    const [, init] = spy.mock.calls[0]!;
    expect(init?.method).toBe("GET");
    expect(init?.redirect).toBe("manual");
    expect(init?.body).toBeUndefined();
    expect(new Headers(init?.headers).get("user-agent")).toBe("SeasignBot/1.0");
    expect(new Headers(init?.headers).get("accept")).toBe("text/calendar");
    expect([...new Headers(init?.headers).keys()].sort()).toEqual(["accept", "user-agent"]);
  });

  it("fetches a webcal link over https", async () => {
    const spy = mockFetch({ "https://p01-caldav.example.com/published/2/abc": () => new Response("ok") });

    const result = await safeFetch("webcal://p01-caldav.example.com/published/2/abc");

    expect(result.status).toBe(200);
    expect(spy).toHaveBeenCalledTimes(1);
  });

  it.each([
    ["http://calendar.example.com/a.ics", "invalid_url"],
    ["https://user:pw@calendar.example.com/a.ics", "invalid_url"],
    ["https://calendar.example.com:8443/a.ics", "invalid_url"],
    ["https://127.0.0.1/a.ics", "blocked_host"],
    ["https://192.168.1.20/a.ics", "blocked_host"],
    ["https://[::1]/a.ics", "blocked_host"],
    ["https://localhost/a.ics", "blocked_host"],
    ["https://nas.local/a.ics", "blocked_host"],
  ])("refuses %s without any request", async (input, code) => {
    const spy = mockFetch({});

    expect(await codeOf(safeFetch(input))).toBe(code);
    expect(spy).not.toHaveBeenCalled();
  });

  describe("redirects", () => {
    it("follows up to three, relative ones included", async () => {
      const spy = mockFetch({
        "https://a.example.com/start": () => redirect("https://b.example.com/one", 301),
        "https://b.example.com/one": () => redirect("/two", 307),
        "https://b.example.com/two": () => redirect("https://c.example.com/three#frag", 308),
        "https://c.example.com/three": () => new Response("arrived"),
      });

      const result = await safeFetch("https://a.example.com/start");

      expect(new TextDecoder().decode(result.body)).toBe("arrived");
      expect(result.url.href).toBe("https://c.example.com/three");
      expect(spy).toHaveBeenCalledTimes(4);
    });

    it("gives up on the fourth", async () => {
      const spy = mockFetch({
        "https://a.example.com/0": () => redirect("/1"),
        "https://a.example.com/1": () => redirect("/2"),
        "https://a.example.com/2": () => redirect("/3"),
        "https://a.example.com/3": () => redirect("/4"),
        "https://a.example.com/4": () => new Response("too far"),
      });

      expect(await codeOf(safeFetch("https://a.example.com/0"))).toBe("bad_redirect");
      expect(spy).toHaveBeenCalledTimes(4);
    });

    it.each([
      ["a private address", "https://10.0.0.5/internal.ics", "blocked_host"],
      ["the metadata address", "https://169.254.169.254/latest/meta-data/", "blocked_host"],
      ["loopback over IPv6", "https://[::1]/a.ics", "blocked_host"],
      ["localhost", "https://localhost/a.ics", "blocked_host"],
      ["plain http", "http://calendar.example.com/a.ics", "invalid_url"],
      ["webcal", "webcal://calendar.example.com/a.ics", "invalid_url"],
      ["another port", "https://calendar.example.com:8443/a.ics", "invalid_url"],
      ["a URL with credentials", "https://user:pw@calendar.example.com/a.ics", "invalid_url"],
    ])("refuses a redirect to %s and does not request it", async (_name, location, code) => {
      const spy = mockFetch({ "https://a.example.com/start": () => redirect(location) });

      expect(await codeOf(safeFetch("https://a.example.com/start"))).toBe(code);
      expect(spy).toHaveBeenCalledTimes(1);
    });

    it("refuses a private address on the second hop too", async () => {
      const spy = mockFetch({
        "https://a.example.com/start": () => redirect("https://b.example.com/next"),
        "https://b.example.com/next": () => redirect("https://192.168.0.1/admin"),
      });

      expect(await codeOf(safeFetch("https://a.example.com/start"))).toBe("blocked_host");
      expect(spy).toHaveBeenCalledTimes(2);
    });

    it("refuses a redirect without a Location", async () => {
      mockFetch({ "https://a.example.com/start": () => new Response(null, { status: 302 }) });

      expect(await codeOf(safeFetch("https://a.example.com/start"))).toBe("bad_redirect");
    });
  });

  describe("size cap", () => {
    it("accepts a body of exactly the cap", async () => {
      mockFetch({ "https://a.example.com/a": () => new Response(streamOf([new Uint8Array(600), new Uint8Array(400)])) });

      const result = await safeFetch("https://a.example.com/a", { maxBytes: 1000 });

      expect(result.body.byteLength).toBe(1000);
    });

    it("stops reading a stream that passes the cap, with no Content-Length to go by", async () => {
      let cancelled = false;
      const chunks = Array.from({ length: 50 }, () => new Uint8Array(400));
      let served = 0;
      const body = new ReadableStream<Uint8Array>({
        pull(controller) {
          const chunk = chunks[served++];
          if (chunk) controller.enqueue(chunk);
          else controller.close();
        },
        cancel() {
          cancelled = true;
        },
      });
      mockFetch({ "https://a.example.com/a": () => new Response(body) });

      expect(await codeOf(safeFetch("https://a.example.com/a", { maxBytes: 1000 }))).toBe("too_large");
      expect(cancelled).toBe(true);
      // Three chunks pass 1000 bytes; the stream may have one more queued.
      expect(served).toBeLessThan(10);
    });

    it("does not trust a Content-Length that understates the body", async () => {
      mockFetch({
        "https://a.example.com/a": () =>
          new Response(streamOf([new Uint8Array(800), new Uint8Array(800)]), { headers: { "content-length": "10" } }),
      });

      expect(await codeOf(safeFetch("https://a.example.com/a", { maxBytes: 1000 }))).toBe("too_large");
    });

    it("refuses at once when Content-Length already exceeds the cap", async () => {
      let cancelled = false;
      mockFetch({
        "https://a.example.com/a": () =>
          new Response(streamOf([new Uint8Array(10)], () => (cancelled = true)), {
            headers: { "content-length": "5000" },
          }),
      });

      expect(await codeOf(safeFetch("https://a.example.com/a", { maxBytes: 1000 }))).toBe("too_large");
      expect(cancelled).toBe(true);
    });

    it("refuses a real body over the default 2 MB", async () => {
      mockFetch({ "https://a.example.com/a": () => new Response(new Uint8Array(SAFE_FETCH_MAX_BYTES + 1)) });

      expect(await codeOf(safeFetch("https://a.example.com/a"))).toBe("too_large");
    });
  });

  describe("deadline", () => {
    it("gives up on a host that never answers, and aborts the request", async () => {
      let signal: AbortSignal | undefined;
      mockFetch({
        "https://slow.example.com/a": (_url, init) => {
          signal = init?.signal ?? undefined;
          return new Promise<Response>(() => {});
        },
      });

      expect(await codeOf(safeFetch("https://slow.example.com/a", { timeoutMs: 30 }))).toBe("timeout");
      expect(signal?.aborted).toBe(true);
    });

    it("gives up on a body that stalls part-way", async () => {
      let cancelled = false;
      const body = new ReadableStream<Uint8Array>({
        start(controller) {
          controller.enqueue(new Uint8Array(10));
        },
        // Never enqueues again and never closes.
        cancel() {
          cancelled = true;
        },
      });
      mockFetch({ "https://slow.example.com/a": () => new Response(body) });

      expect(await codeOf(safeFetch("https://slow.example.com/a", { timeoutMs: 30 }))).toBe("timeout");
      expect(cancelled).toBe(true);
    });

    it("spends one deadline across redirects", async () => {
      // Each hop answers within the deadline; the two together do not. Timers
      // only ever fire late, so a loaded machine cannot make this fail. (It
      // used to need three 40 ms hops to start within 100 ms, 20 ms of slack;
      // task 22.) The second hop's wait falls due after the deadline, so it is
      // the last fetch.
      const wait = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));
      const spy = mockFetch({
        "https://a.example.com/0": async () => (await wait(70), redirect("/1")),
        "https://a.example.com/1": async () => (await wait(70), new Response("late")),
      });

      expect(await codeOf(safeFetch("https://a.example.com/0", { timeoutMs: 100 }))).toBe("timeout");
      expect(spy).toHaveBeenCalledTimes(2);
    });
  });

  it("reports an unreachable host as network", async () => {
    mockFetch({ "https://down.example.com/a": () => Promise.reject(new TypeError("connection refused")) });

    expect(await codeOf(safeFetch("https://down.example.com/a"))).toBe("network");
  });

  it.each([401, 403, 404, 410, 500, 503])("reports status %i as http_status", async (status) => {
    mockFetch({ "https://a.example.com/a": () => new Response("nope", { status }) });

    try {
      await safeFetch("https://a.example.com/a");
      expect.unreachable();
    } catch (error) {
      expect(error).toBeInstanceOf(SafeFetchError);
      expect((error as SafeFetchError).code).toBe("http_status");
      expect((error as SafeFetchError).status).toBe(status);
    }
  });

  it("keeps the URL out of every error it throws", async () => {
    const secret = "https://secret-host.example.com/private-token-123.ics";
    const cases: Reply[] = [
      () => Promise.reject(new TypeError(`failed to fetch ${secret}`)),
      () => new Response("nope", { status: 404 }),
      () => redirect("https://10.0.0.5/private-token-123"),
      () => new Response(new Uint8Array(2000)),
      () => new Promise<Response>(() => {}),
    ];
    for (const reply of cases) {
      vi.restoreAllMocks();
      mockFetch({ [secret]: reply });
      try {
        await safeFetch(secret, { maxBytes: 1000, timeoutMs: 30 });
        expect.unreachable();
      } catch (error) {
        expect(error).toBeInstanceOf(SafeFetchError);
        const text = `${(error as Error).message} ${(error as Error).stack ?? ""} ${JSON.stringify(error)} ${String((error as Error).cause ?? "")}`;
        expect(text).not.toContain("private-token-123");
        expect(text).not.toContain("secret-host");
      }
    }
  });
});
