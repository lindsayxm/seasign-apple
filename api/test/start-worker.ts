// The first request a test file makes to the worker loads it, which took about
// 3 s on a loaded machine and once went past Vitest's 5 s test timeout, failing
// whichever test happened to come first (task 22). Calling this at the top of a
// file makes that first request before its tests, with time to spare, so each
// test's own timeout covers only its own work.
import { exports } from "cloudflare:workers";
import { beforeAll } from "vitest";

export function startWorker(): void {
  beforeAll(async () => {
    const response = await exports.default.fetch("https://example.com/v1/health");
    await response.text();
  }, 60_000);
}
