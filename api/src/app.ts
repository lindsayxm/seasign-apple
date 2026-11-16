import { OpenAPIHono } from "@hono/zod-openapi";
import { calendar } from "./routes/calendar.ts";
import { feed } from "./routes/feed.ts";
import { health } from "./routes/health.ts";
import { sites } from "./routes/sites.ts";
import { sky } from "./routes/sky.ts";

// The app is built here, free of runtime-only imports, so that
// scripts/openapi.ts can load it in Node to write the spec.
export const app = new OpenAPIHono<{ Bindings: CloudflareBindings }>();

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

export const openAPIConfig = {
  openapi: "3.0.3",
  info: {
    title: "Seasign API",
    version: "1.0.0",
  },
};
