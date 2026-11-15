// Writes ../openapi/openapi.json from the Hono routes. Run with `npm run openapi`.
// The spec is generated: change the routes, never the JSON.
import { mkdirSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { app, openAPIConfig } from "../src/app.ts";

const out = resolve(dirname(fileURLToPath(import.meta.url)), "../../openapi/openapi.json");
const document = app.getOpenAPIDocument(openAPIConfig);

mkdirSync(dirname(out), { recursive: true });
writeFileSync(out, JSON.stringify(document, null, 2) + "\n");
console.log(`wrote ${out}`);
