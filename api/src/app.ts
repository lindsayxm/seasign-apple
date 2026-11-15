import { OpenAPIHono } from "@hono/zod-openapi";
import { health } from "./routes/health.ts";

// The app is built here, free of runtime-only imports, so that
// scripts/openapi.ts can load it in Node to write the spec.
export const app = new OpenAPIHono<{ Bindings: CloudflareBindings }>();

app.route("/", health);

export const openAPIConfig = {
  openapi: "3.0.3",
  info: {
    title: "Seasign API",
    version: "1.0.0",
  },
};
