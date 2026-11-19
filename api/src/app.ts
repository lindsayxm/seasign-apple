import { OpenAPIHono } from "@hono/zod-openapi";
import { rateLimit } from "./lib/rate-limit.ts";
import { calendar } from "./routes/calendar.ts";
import { discover } from "./routes/discover.ts";
import { feed } from "./routes/feed.ts";
import { google } from "./routes/google.ts";
import { NOTIFY_PATH, googlePush } from "./routes/google-push.ts";
import { health } from "./routes/health.ts";
import { sites } from "./routes/sites.ts";
import { sky } from "./routes/sky.ts";

// The app is built here, free of runtime-only imports, so that
// scripts/openapi.ts can load it in Node to write the spec.
export const app = new OpenAPIHono<{ Bindings: CloudflareBindings }>();

// Every answer of the Google routes, the limiter's and the body limit's
// included, says not to cache it: it is read with the user's token and is
// meant to be fresh. Registered first so that it wraps all of them.
app.use("/v1/google/*", async (c, next) => {
  await next();
  c.res.headers.set("Cache-Control", "no-store");
});

// Per-client-IP limits on the open routes (src/lib/rate-limit.ts). They are
// registered first so that a refused request costs no body read, no outbound
// fetch and no KV access. /v1/health is not limited.
app.use("/v1/sky", rateLimit("sky"));
app.use("/v1/calendar/events", rateLimit("calendar"));
app.use("/v1/sites/resolve", rateLimit("resolve"));
app.use("/v1/feed", rateLimit("feed"));
app.use("/v1/discover", rateLimit("discover"));
// Google's webhook has its own, much higher limit: its callers are Google's
// servers, which many channels share (see RATE_LIMITS.notify).
const googleLimit = rateLimit("google");
const notifyLimit = rateLimit("notify");
app.use("/v1/google/*", (c, next) => (c.req.path === NOTIFY_PATH ? notifyLimit(c, next) : googleLimit(c, next)));

/**
 * The largest request body any route reads. The biggest honest one is a
 * `/v1/feed` request of 50 sites, about 10 KB with ordinary addresses.
 */
export const MAX_BODY_BYTES = 64 * 1024;

// Before any route parses JSON, the body is read here, counting bytes as they
// come, and refused as soon as it passes the limit, so at most the limit is
// ever held; the routes then read the counted copy. Content-Length is only
// used to refuse early: a request whose header says less than it sends is
// still counted (Hono's `bodyLimit` trusts the header when there is one).
// The answer has the same shape as every route's own 400.
app.use("/v1/*", async (c, next) => {
  const body = c.req.raw.body;
  if (!body) return next();
  const tooLarge = () => c.json({ error: "invalid_request" as const, message: "The request body is too large" }, 400);
  const declared = Number(c.req.header("content-length"));
  if (Number.isFinite(declared) && declared > MAX_BODY_BYTES) {
    await body.cancel().catch(() => {});
    return tooLarge();
  }
  const reader = body.getReader();
  const buffer = new Uint8Array(MAX_BODY_BYTES);
  let size = 0;
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    if (size + value.byteLength > MAX_BODY_BYTES) {
      await reader.cancel().catch(() => {});
      return tooLarge();
    }
    buffer.set(value, size);
    size += value.byteLength;
  }
  // The header may have been wrong; the copy carries the size that was read.
  const headers = new Headers(c.req.raw.headers);
  headers.set("content-length", String(size));
  c.req.raw = new Request(c.req.raw, { body: buffer.slice(0, size), headers });
  return next();
});

app.route("/", health);
app.route("/", sky);
app.route("/", calendar);
app.route("/", sites);
app.route("/", feed);
app.route("/", discover);
app.route("/", google);
app.route("/", googlePush);

export const openAPIConfig = {
  openapi: "3.0.3",
  info: {
    title: "Seasign API",
    version: "1.0.0",
  },
};
