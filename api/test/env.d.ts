// Bindings only the tests have, added in vitest.config.ts.
declare namespace Cloudflare {
  interface Env {
    /** The D1 migrations, read in Node; apply with applyD1Migrations(env.DB, env.TEST_MIGRATIONS). */
    TEST_MIGRATIONS: import("cloudflare:test").D1Migration[];
  }
}
