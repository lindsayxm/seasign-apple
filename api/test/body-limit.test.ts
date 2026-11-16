import { exports } from "cloudflare:workers";
import { afterEach, describe, expect, it, vi } from "vitest";
import { MAX_BODY_BYTES } from "../src/app.ts";

const TOO_LARGE = { error: "invalid_request", message: "The request body is too large" };

/** Every route that reads a body, with a body that would be valid if it were small. */
const routes: [string, (padding: string) => unknown][] = [
  ["/v1/calendar/events", (padding) => ({ links: ["https://calendar.example.com/a.ics"], padding })],
  ["/v1/sites/resolve", (padding) => ({ url: "https://news.example.com/", padding })],
  ["/v1/feed", (padding) => ({ sites: [{ url: "https://news.example.com/", mode: "links" }], padding })],
];

const send = (path: string, body: BodyInit, headers: Record<string, string> = {}) =>
  exports.default.fetch(`https://example.com${path}`, { method: "POST", headers: { "content-type": "application/json", ...headers }, body });

/** The bytes of a JSON body of exactly `size` bytes. */
function bodyOf(make: (padding: string) => unknown, size: number): Uint8Array {
  const empty = new TextEncoder().encode(JSON.stringify(make(""))).length;
  const bytes = new TextEncoder().encode(JSON.stringify(make("x".repeat(size - empty))));
  expect(bytes.length).toBe(size);
  return bytes;
}

/** A body sent in pieces, so that it has no Content-Length. */
const streamed = (bytes: Uint8Array) =>
  new ReadableStream<Uint8Array>({
    start(controller) {
      for (let i = 0; i < bytes.length; i += 8192) controller.enqueue(bytes.slice(i, i + 8192));
      controller.close();
    },
  });

afterEach(() => vi.restoreAllMocks());

describe("request body limit", () => {
  it("is 64 KB", () => {
    expect(MAX_BODY_BYTES).toBe(64 * 1024);
  });

  describe.each(routes)("POST %s", (path, make) => {
    it("refuses a body one byte over the limit, before any outbound request", async () => {
      const outbound = vi.spyOn(globalThis, "fetch").mockRejectedValue(new Error("Unexpected outbound request"));

      const response = await send(path, bodyOf(make, MAX_BODY_BYTES + 1));

      expect(response.status).toBe(400);
      expect(await response.json()).toEqual(TOO_LARGE);
      expect(outbound).not.toHaveBeenCalled();
    });

    it("refuses a large body sent without a Content-Length, by counting it", async () => {
      const outbound = vi.spyOn(globalThis, "fetch").mockRejectedValue(new Error("Unexpected outbound request"));

      const response = await send(path, streamed(bodyOf(make, 3 * 1024 * 1024)));

      expect(response.status).toBe(400);
      expect(await response.json()).toEqual(TOO_LARGE);
      expect(outbound).not.toHaveBeenCalled();
    });

    it.each(["10", "0", "-1", "abc", ""])("refuses a 3 MB body whose Content-Length says %j, by counting it", async (length) => {
      const outbound = vi.spyOn(globalThis, "fetch").mockRejectedValue(new Error("Unexpected outbound request"));
      const body = bodyOf(make, 3 * 1024 * 1024);
      const request = new Request(`https://example.com${path}`, { method: "POST", headers: { "content-type": "application/json", "content-length": length }, body });
      expect(request.headers.get("content-length")).toBe(length);

      const response = await exports.default.fetch(request);

      expect(response.status).toBe(400);
      expect(await response.json()).toEqual(TOO_LARGE);
      expect(outbound).not.toHaveBeenCalled();
    });

    it("reads a small body whose Content-Length is wrong as what it is", async () => {
      vi.spyOn(globalThis, "fetch").mockRejectedValue(new TypeError("network down"));
      for (const length of ["1", "abc"]) {
        const response = await send(path, bodyOf(make, 200), { "content-length": length });
        expect(response.status).toBe(200);
        expect(JSON.stringify(await response.json())).toContain("fetch_failed");
      }
    });

    it("refuses a body that is not JSON at all when it is too large, with the same answer", async () => {
      const response = await send(path, "{".repeat(MAX_BODY_BYTES + 1));
      expect(response.status).toBe(400);
      expect(await response.json()).toEqual(TOO_LARGE);
    });

    it("reads a body of exactly the limit, with and without a Content-Length", async () => {
      // The request is valid, so the route goes on to fetch; the host does not answer.
      vi.spyOn(globalThis, "fetch").mockRejectedValue(new TypeError("network down"));

      for (const body of [bodyOf(make, MAX_BODY_BYTES), streamed(bodyOf(make, MAX_BODY_BYTES))]) {
        const response = await send(path, body);
        expect(response.status).toBe(200);
        expect(JSON.stringify(await response.json())).toContain("fetch_failed");
      }
    });
  });

  it("leaves requests without a body alone", async () => {
    const response = await exports.default.fetch("https://example.com/v1/health");
    expect(response.status).toBe(200);
  });
});
