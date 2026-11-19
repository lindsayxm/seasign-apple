import { cloudflareTest, readD1Migrations } from "@cloudflare/vitest-plugin";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { defineConfig } from "vitest/config";

const here = dirname(fileURLToPath(import.meta.url));

export default defineConfig({
  plugins: [
    cloudflareTest(async () => ({
      wrangler: { configPath: "./wrangler.jsonc" },
      // The test D1 starts empty: the migrations are read here, in Node, and a
      // test file that uses the database applies them with
      // applyD1Migrations(env.DB, env.TEST_MIGRATIONS).
      miniflare: { bindings: { TEST_MIGRATIONS: await readD1Migrations(join(here, "migrations")) } },
    })),
  ],
});
