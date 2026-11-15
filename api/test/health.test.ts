import { exports } from "cloudflare:workers";
import { describe, expect, it } from "vitest";

describe("GET /v1/health", () => {
  it("returns 200 and status ok", async () => {
    const response = await exports.default.fetch("https://example.com/v1/health");
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ status: "ok", service: "seasign-api" });
  });
});
