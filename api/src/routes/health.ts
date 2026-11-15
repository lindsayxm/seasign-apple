import { OpenAPIHono, createRoute, z } from "@hono/zod-openapi";

const HealthSchema = z
  .object({
    status: z.literal("ok").openapi({ example: "ok" }),
    service: z.string().openapi({ example: "seasign-api" }),
  })
  .openapi("Health");

const getHealth = createRoute({
  method: "get",
  path: "/v1/health",
  operationId: "getHealth",
  summary: "Report that the API is running",
  responses: {
    200: {
      description: "The API is running",
      content: { "application/json": { schema: HealthSchema } },
    },
  },
});

export const health = new OpenAPIHono<{ Bindings: CloudflareBindings }>();

health.openapi(getHealth, (c) =>
  c.json({ status: "ok" as const, service: "seasign-api" }, 200),
);
