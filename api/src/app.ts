import { OpenAPIHono } from "@hono/zod-openapi";
import { bodyLimit } from "hono/body-limit";
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

// Before any route parses JSON: a body over the limit is refused, by its
// Content-Length when it has one and otherwise by counting while reading, so
// at most the limit is ever held. The answer has the same shape as every
// route's own 400.
app.use(
  "/v1/*",
  bodyLimit({
    maxSize: MAX_BODY_BYTES,
    onError: (c) => c.json({ error: "invalid_request" as const, message: "The request body is too large" }, 400),
  }),
);

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
