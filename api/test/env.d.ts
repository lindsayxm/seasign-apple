// Bindings only the tests have, added in vitest.config.ts.
declare namespace Cloudflare {
  interface Env {
    /** The D1 migrations, read in Node; apply with applyD1Migrations(env.DB, env.TEST_MIGRATIONS). */
    TEST_MIGRATIONS: import("cloudflare:test").D1Migration[];
    /** A test-only Better Auth secret, set in vitest.config.ts. Never a real one. */
    BETTER_AUTH_SECRET?: string;
  }
}
