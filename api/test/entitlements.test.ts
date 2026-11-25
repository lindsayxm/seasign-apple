import { applyD1Migrations } from "cloudflare:test";
import { env } from "cloudflare:workers";
import { eq } from "drizzle-orm";
import { drizzle } from "drizzle-orm/d1";
import { Hono } from "hono";
import { afterEach, beforeAll, beforeEach, describe, expect, it, vi } from "vitest";
import { account, entitlements, session, user, verification, type Entitlement } from "../src/db/schema.ts";
import {
  ENTITLEMENT_UNAVAILABLE,
  SUBSCRIPTION_PRODUCT_ID,
  SUBSCRIPTION_REQUIRED,
  activeEntitlement,
  entitlementGate,
  isActive,
  recordVerifiedSubscription,
  requireEntitlement,
  type VerifiedSubscriptionFacts,
} from "../src/lib/entitlements.ts";
import { UNAUTHORIZED, requireSession, type SessionVariables } from "../src/lib/session.ts";
import { signInAs } from "./apple-sign-in.ts";
import { startWorker } from "./start-worker.ts";

startWorker();

// The entitlement record and the one check paid routes use (task 221).
// The project's hard rule: nothing that costs money for a subscription that is
// not active, and a state that cannot be determined is not active. A failed
// renewal (grace period, billing retry) is not active.

const NOW = Date.UTC(2026, 10, 24, 12, 0, 0);
const HOUR = 3_600_000;
const BASE = "https://api.seasign.app";

const db = () => drizzle(env.DB);

beforeAll(async () => {
  await applyD1Migrations(env.DB, env.TEST_MIGRATIONS);
});

beforeEach(async () => {
  await db().delete(entitlements);
  await db().delete(verification);
  await db().delete(session);
  await db().delete(account);
  await db().delete(user);
});

afterEach(() => {
  vi.restoreAllMocks();
});

/** A user with its account row, as a sign-in leaves them (a user without an account is never left behind). */
async function makeUser(id: string) {
  await db().insert(user).values({ id, name: "", email: `${id}@apple.seasign.invalid`, emailVerified: false, updatedAt: new Date(NOW) });
  await db().insert(account).values({ id: `acc-${id}`, accountId: `sub-${id}`, providerId: "apple", userId: id, updatedAt: new Date(NOW) });
  return id;
}

function row(extra: Partial<Entitlement> = {}): Entitlement {
  return {
    originalTransactionId: "2000000123456789",
    userId: "user-a",
    productId: SUBSCRIPTION_PRODUCT_ID,
    environment: "Production",
    state: "active",
    expiresAt: NOW + 30 * 24 * HOUR,
    revokedAt: null,
    signedAt: NOW - HOUR,
    updatedAt: NOW - HOUR,
    ...extra,
  };
}

function facts(extra: Partial<VerifiedSubscriptionFacts> = {}): VerifiedSubscriptionFacts {
  return {
    originalTransactionId: "2000000123456789",
    productId: SUBSCRIPTION_PRODUCT_ID,
    environment: "Production",
    state: "active",
    expiresAt: NOW + 30 * 24 * HOUR,
    revokedAt: null,
    signedAt: NOW - HOUR,
    ...extra,
  };
}

/**
 * A D1 binding that answers like env.DB except for statements naming the
 * entitlements table, which fail: the session read works and the entitlement
 * read does not. `mode` says whether prepare itself throws or the query rejects.
 */
function brokenEntitlementsDB(mode: "prepare" | "execute" = "execute"): D1Database {
  const real = env.DB;
  const fail = () => {
    throw new Error("D1_ERROR: simulated failure");
  };
  return new Proxy(real, {
    get(target, property) {
      if (property === "prepare") {
        return (query: string) => {
          if (!/entitlements/i.test(query)) return target.prepare(query);
          if (mode === "prepare") fail();
          const statement = {
            bind: () => statement,
            all: async () => fail(),
            raw: async () => fail(),
            first: async () => fail(),
            run: async () => fail(),
          };
          return statement;
        };
      }
      const value = Reflect.get(target, property, target);
      return typeof value === "function" ? value.bind(target) : value;
    },
  });
}

// ───────────────────────── isActive ─────────────────────────

describe("isActive (pure)", () => {
  it("is true for the subscribed state with an expiry later than now and no revocation", () => {
    expect(isActive(row(), NOW)).toBe(true);
  });

  it("is false at exactly the expiry, true one second before it, false one second after it", () => {
    expect(isActive(row({ expiresAt: NOW }), NOW)).toBe(false);
    expect(isActive(row({ expiresAt: NOW + 1000 }), NOW)).toBe(true);
    expect(isActive(row({ expiresAt: NOW - 1000 }), NOW)).toBe(false);
  });

  it("is false for an expired subscription", () => {
    expect(isActive(row({ state: "expired", expiresAt: NOW - HOUR }), NOW)).toBe(false);
    // The state wins even when the expiry is still ahead.
    expect(isActive(row({ state: "expired" }), NOW)).toBe(false);
  });

  it("is false in Apple's billing grace period, even with an expiry ahead (no grace for a failed renewal)", () => {
    expect(isActive(row({ state: "grace_period" }), NOW)).toBe(false);
  });

  it("is false in billing retry, even with an expiry ahead", () => {
    expect(isActive(row({ state: "billing_retry" }), NOW)).toBe(false);
  });

  it("is false for a revoked subscription, by state or by a revocation date alone", () => {
    expect(isActive(row({ state: "revoked" }), NOW)).toBe(false);
    expect(isActive(row({ revokedAt: NOW - HOUR }), NOW)).toBe(false);
    // A revocation dated in the future still revokes: any revocation date is a revocation.
    expect(isActive(row({ revokedAt: NOW + HOUR }), NOW)).toBe(false);
    expect(isActive(row({ revokedAt: 0 }), NOW)).toBe(false);
  });

  it("is false for a state it does not know, however close to the subscribed one", () => {
    for (const state of ["Active", "ACTIVE", " active", "active ", "subscribed", "1", "", "unknown", "activ"]) {
      expect(isActive(row({ state }), NOW), JSON.stringify(state)).toBe(false);
    }
  });

  it("is false with no row", () => {
    expect(isActive(undefined, NOW)).toBe(false);
  });

  it("is false with a missing or unusable expiry", () => {
    expect(isActive(row({ expiresAt: null }), NOW)).toBe(false);
    for (const expiresAt of [Number.NaN, Number.POSITIVE_INFINITY, "2099-01-01", "9999999999999"] as unknown[]) {
      expect(isActive(row({ expiresAt: expiresAt as number }), NOW), String(expiresAt)).toBe(false);
    }
  });

  it("is false when the clock itself is unusable", () => {
    expect(isActive(row(), Number.NaN)).toBe(false);
  });

  it("is false for a revocation value that is not a clean null (fail closed on odd data)", () => {
    expect(isActive(row({ revokedAt: "x" as unknown as number }), NOW)).toBe(false);
  });
});

// ───────────────────────── activeEntitlement ─────────────────────────

describe("activeEntitlement (loader)", () => {
  it("finds this user's active entitlement", async () => {
    await makeUser("user-a");
    await db().insert(entitlements).values(row());
    const check = await activeEntitlement(db(), "user-a", NOW);
    expect(check.status).toBe("active");
    if (check.status === "active") expect(check.entitlement.originalTransactionId).toBe("2000000123456789");
  });

  it("answers inactive with no row", async () => {
    await makeUser("user-a");
    expect(await activeEntitlement(db(), "user-a", NOW)).toEqual({ status: "inactive" });
  });

  it("answers by the injected clock: inactive at exactly the stored expiry, active one second before, inactive one second after", async () => {
    await makeUser("user-a");
    await db().insert(entitlements).values(row({ expiresAt: NOW }));
    expect((await activeEntitlement(db(), "user-a", NOW)).status).toBe("inactive");
    expect((await activeEntitlement(db(), "user-a", NOW - 1000)).status).toBe("active");
    expect((await activeEntitlement(db(), "user-a", NOW + 1000)).status).toBe("inactive");
  });

  it("answers inactive for grace period, billing retry, expired, revoked, an unknown state and a missing expiry", async () => {
    await makeUser("user-a");
    const cases: Partial<Entitlement>[] = [
      { state: "grace_period" },
      { state: "billing_retry" },
      { state: "expired", expiresAt: NOW - HOUR },
      { state: "revoked", revokedAt: NOW - HOUR },
      { revokedAt: NOW - HOUR },
      { state: "something_apple_adds_later" },
      { expiresAt: null },
    ];
    for (const extra of cases) {
      await db().delete(entitlements);
      await db().insert(entitlements).values(row(extra));
      expect((await activeEntitlement(db(), "user-a", NOW)).status, JSON.stringify(extra)).toBe("inactive");
    }
  });

  it("is not helped by another user's active row", async () => {
    await makeUser("user-a");
    await makeUser("user-b");
    await db().insert(entitlements).values(row({ userId: "user-b" }));
    expect(await activeEntitlement(db(), "user-a", NOW)).toEqual({ status: "inactive" });
    expect((await activeEntitlement(db(), "user-b", NOW)).status).toBe("active");
  });

  it("is active when any of this user's subscriptions is active (a lapsed one beside a new one)", async () => {
    await makeUser("user-a");
    await db().insert(entitlements).values(row({ originalTransactionId: "1000000000000001", state: "expired", expiresAt: NOW - 40 * 24 * HOUR }));
    await db().insert(entitlements).values(row({ originalTransactionId: "1000000000000002" }));
    const check = await activeEntitlement(db(), "user-a", NOW);
    expect(check.status).toBe("active");
    if (check.status === "active") expect(check.entitlement.originalTransactionId).toBe("1000000000000002");
  });

  it("answers unreadable, and does not throw, when D1 fails (both when preparing and when running)", async () => {
    await makeUser("user-a");
    await db().insert(entitlements).values(row());
    vi.spyOn(console, "error").mockImplementation(() => {});
    for (const mode of ["prepare", "execute"] as const) {
      expect(await activeEntitlement(drizzle(brokenEntitlementsDB(mode)), "user-a", NOW), mode).toEqual({ status: "unreadable" });
    }
  });
});

// ───────────────────────── the table ─────────────────────────

describe("the entitlements table", () => {
  it("refuses a second user holding the same original transaction ID", async () => {
    await makeUser("user-a");
    await makeUser("user-b");
    await db().insert(entitlements).values(row({ userId: "user-a" }));
    await expect(db().insert(entitlements).values(row({ userId: "user-b" }))).rejects.toThrow();
    const rows = await db().select().from(entitlements);
    expect(rows).toHaveLength(1);
    expect(rows[0]!.userId).toBe("user-a");
  });

  it("refuses a row for a user that does not exist", async () => {
    await expect(db().insert(entitlements).values(row({ userId: "nobody" }))).rejects.toThrow();
  });

  it("loses a user's rows when the user is deleted, and only that user's", async () => {
    await makeUser("user-a");
    await makeUser("user-b");
    await db().insert(entitlements).values(row({ userId: "user-a", originalTransactionId: "1" }));
    await db().insert(entitlements).values(row({ userId: "user-b", originalTransactionId: "2" }));
    await db().delete(user).where(eq(user.id, "user-a"));
    const rows = await db().select().from(entitlements);
    expect(rows.map((r) => r.userId)).toEqual(["user-b"]);
  });
});

// ───────────────────────── recordVerifiedSubscription ─────────────────────────

describe("recordVerifiedSubscription (the interface the Apple work will call)", () => {
  it("stores a new subscription for the user, stamped with the injected clock", async () => {
    await makeUser("user-a");
    expect(await recordVerifiedSubscription(db(), "user-a", facts(), NOW)).toEqual({ outcome: "stored" });
    const rows = await db().select().from(entitlements);
    expect(rows).toEqual([{ ...row(), updatedAt: NOW }]);
    expect((await activeEntitlement(db(), "user-a", NOW)).status).toBe("active");
  });

  it("applies newer facts over older ones: a revocation turns access off", async () => {
    await makeUser("user-a");
    await recordVerifiedSubscription(db(), "user-a", facts(), NOW);
    expect(await recordVerifiedSubscription(db(), "user-a", facts({ state: "revoked", revokedAt: NOW - 1000, signedAt: NOW - 1000 }), NOW + 5)).toEqual({ outcome: "stored" });
    const [stored] = await db().select().from(entitlements);
    expect(stored).toMatchObject({ state: "revoked", revokedAt: NOW - 1000, signedAt: NOW - 1000, updatedAt: NOW + 5 });
    expect((await activeEntitlement(db(), "user-a", NOW)).status).toBe("inactive");
  });

  it("ignores facts signed before the ones stored, so a late 'active' cannot undo a revocation", async () => {
    await makeUser("user-a");
    await recordVerifiedSubscription(db(), "user-a", facts({ state: "revoked", revokedAt: NOW - 1000, signedAt: NOW - 1000 }), NOW);
    expect(await recordVerifiedSubscription(db(), "user-a", facts({ signedAt: NOW - HOUR }), NOW + 5)).toEqual({ outcome: "stale" });
    const [stored] = await db().select().from(entitlements);
    expect(stored).toMatchObject({ state: "revoked", signedAt: NOW - 1000, updatedAt: NOW });
    expect((await activeEntitlement(db(), "user-a", NOW)).status).toBe("inactive");
  });

  it("ignores facts with the same signed date as the ones stored (a retried notification changes nothing)", async () => {
    await makeUser("user-a");
    await recordVerifiedSubscription(db(), "user-a", facts({ state: "billing_retry" }), NOW);
    expect(await recordVerifiedSubscription(db(), "user-a", facts(), NOW + 5)).toEqual({ outcome: "stale" });
    expect((await db().select().from(entitlements))[0]).toMatchObject({ state: "billing_retry", updatedAt: NOW });
  });

  it("never moves a subscription to another account, and leaves the owner's row as it was", async () => {
    await makeUser("user-a");
    await makeUser("user-b");
    await recordVerifiedSubscription(db(), "user-a", facts(), NOW);
    expect(await recordVerifiedSubscription(db(), "user-b", facts({ signedAt: NOW }), NOW + 5)).toEqual({ outcome: "other_account" });
    const rows = await db().select().from(entitlements);
    expect(rows).toEqual([{ ...row(), updatedAt: NOW }]);
    expect(await activeEntitlement(db(), "user-b", NOW)).toEqual({ status: "inactive" });
  });

  it("refuses facts it cannot vouch for, writing nothing", async () => {
    await makeUser("user-a");
    const bad: Partial<VerifiedSubscriptionFacts>[] = [
      { state: "subscribed" as never },
      { state: "" as never },
      { productId: "technology.artisan.seasign.yearly" },
      { environment: "sandbox" as never },
      { environment: "Xcode" as never },
      { originalTransactionId: "" },
      { originalTransactionId: 123 as never },
      { expiresAt: Number.NaN },
      { expiresAt: "soon" as never },
      { revokedAt: Number.NaN },
      { signedAt: Number.NaN },
      { signedAt: undefined as never },
    ];
    for (const extra of bad) {
      expect(await recordVerifiedSubscription(db(), "user-a", facts(extra), NOW), JSON.stringify(extra)).toEqual({ outcome: "invalid" });
    }
    expect(await db().select().from(entitlements)).toEqual([]);
  });

  it("refuses to record for a user that does not exist (the foreign key), by throwing to its caller", async () => {
    await expect(recordVerifiedSubscription(db(), "nobody", facts(), NOW)).rejects.toThrow();
    expect(await db().select().from(entitlements)).toEqual([]);
  });

  it("stores a missing expiry as missing, which is never active", async () => {
    await makeUser("user-a");
    expect(await recordVerifiedSubscription(db(), "user-a", facts({ expiresAt: null }), NOW)).toEqual({ outcome: "stored" });
    expect(await activeEntitlement(db(), "user-a", NOW)).toEqual({ status: "inactive" });
  });
});

// ───────────────────────── requireEntitlement ─────────────────────────

/** A paid route that exists only in this test file. `handled` counts the times its handler ran. */
function paidRoute(gate = entitlementGate(() => NOW)) {
  const state = { handled: 0 };
  const probe = new Hono<{ Bindings: CloudflareBindings; Variables: SessionVariables }>();
  probe.post("/v1/paid-probe", requireSession, gate, (c) => {
    state.handled += 1;
    return c.json({ ok: true, userId: c.get("userId") });
  });
  const ask = (headers: Record<string, string> = {}, bindings: Partial<CloudflareBindings> = {}) =>
    probe.request(`${BASE}/v1/paid-probe`, { method: "POST", headers }, { ...env, ...bindings } as unknown as CloudflareBindings);
  return { state, ask };
}

describe("requireEntitlement (middleware)", () => {
  it("lets a signed-in user with an active entitlement through", async () => {
    const { bearer, userId } = await signInAs("001111.aaaa.0001");
    await db().insert(entitlements).values(row({ userId }));
    const { state, ask } = paidRoute();
    const response = await ask({ authorization: `Bearer ${bearer}` });
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ ok: true, userId });
    expect(state.handled).toBe(1);
  });

  it("answers 403 with the fixed body and does not run the route, for each state that is not active", async () => {
    const { bearer, userId } = await signInAs("001111.aaaa.0001");
    const { state, ask } = paidRoute();
    const cases: (Partial<Entitlement> | undefined)[] = [
      undefined,
      { state: "grace_period" },
      { state: "billing_retry" },
      { state: "expired", expiresAt: NOW - HOUR },
      { state: "revoked", revokedAt: NOW - HOUR },
      { state: "Active" },
      { expiresAt: null },
      { expiresAt: NOW },
    ];
    for (const extra of cases) {
      await db().delete(entitlements);
      if (extra) await db().insert(entitlements).values(row({ userId, ...extra }));
      const response = await ask({ authorization: `Bearer ${bearer}` });
      expect(response.status, JSON.stringify(extra)).toBe(403);
      expect(await response.json()).toEqual(SUBSCRIPTION_REQUIRED);
      expect(response.headers.get("cache-control")).toBe("no-store");
    }
    expect(state.handled).toBe(0);
  });

  it("follows the injected clock: one second before the expiry passes, one second after does not", async () => {
    const { bearer, userId } = await signInAs("001111.aaaa.0001");
    await db().insert(entitlements).values(row({ userId, expiresAt: NOW }));
    const before = paidRoute(entitlementGate(() => NOW - 1000));
    expect((await before.ask({ authorization: `Bearer ${bearer}` })).status).toBe(200);
    const after = paidRoute(entitlementGate(() => NOW + 1000));
    expect((await after.ask({ authorization: `Bearer ${bearer}` })).status).toBe(403);
    expect(after.state.handled).toBe(0);
  });

  it("is not opened by another user's active subscription, and the answer says nothing about it", async () => {
    const a = await signInAs("001111.aaaa.0001");
    const b = await signInAs("002222.bbbb.0002");
    const { state, ask } = paidRoute();
    const lone = await ask({ authorization: `Bearer ${a.bearer}` });
    const loneBody = await lone.text();
    await db().insert(entitlements).values(row({ userId: b.userId }));
    const response = await ask({ authorization: `Bearer ${a.bearer}` });
    expect(response.status).toBe(403);
    const body = await response.text();
    // Byte for byte the answer a user gets when nobody has a subscription.
    expect(body).toBe(loneBody);
    expect(body).not.toContain(b.userId);
    expect(body).not.toContain("2000000123456789");
    expect(state.handled).toBe(0);
    // And B is let through on B's own session.
    expect((await ask({ authorization: `Bearer ${b.bearer}` })).status).toBe(200);
  });

  it("ignores anything the client sends about whose subscription to check", async () => {
    const a = await signInAs("001111.aaaa.0001");
    const b = await signInAs("002222.bbbb.0002");
    await db().insert(entitlements).values(row({ userId: b.userId }));
    const { state, ask } = paidRoute();
    const response = await ask({ authorization: `Bearer ${a.bearer}`, "x-user-id": b.userId, "x-original-transaction-id": "2000000123456789" });
    expect(response.status).toBe(403);
    expect(state.handled).toBe(0);
  });

  it("answers 503 entitlement_unavailable (never the route, never a bare 500) when D1 fails reading entitlements", async () => {
    const { bearer, userId } = await signInAs("001111.aaaa.0001");
    await db().insert(entitlements).values(row({ userId }));
    const errors = vi.spyOn(console, "error").mockImplementation(() => {});
    const { state, ask } = paidRoute();
    for (const mode of ["prepare", "execute"] as const) {
      const response = await ask({ authorization: `Bearer ${bearer}` }, { DB: brokenEntitlementsDB(mode) });
      expect(response.status, mode).toBe(503);
      expect(await response.json()).toEqual(ENTITLEMENT_UNAVAILABLE);
      expect(response.headers.get("cache-control")).toBe("no-store");
    }
    expect(state.handled).toBe(0);
    // A fixed line: no user ID and no error text in the log.
    const logged = errors.mock.calls.map((call) => call.join(" ")).join("\n");
    expect(logged).not.toContain(userId);
    expect(logged).not.toContain("simulated");
  });

  it("answers 401 without a session, before looking at any entitlement", async () => {
    const { state, ask } = paidRoute();
    const response = await ask();
    expect(response.status).toBe(401);
    expect(await response.json()).toEqual(UNAUTHORIZED);
    expect(state.handled).toBe(0);
  });

  it("refuses when mounted without requireSession in front (no user ID on the context)", async () => {
    let handled = 0;
    const probe = new Hono<{ Bindings: CloudflareBindings; Variables: SessionVariables }>();
    probe.post("/v1/misordered", entitlementGate(() => NOW), (c) => {
      handled += 1;
      return c.json({ ok: true });
    });
    const response = await probe.request(`${BASE}/v1/misordered`, { method: "POST" }, env as unknown as CloudflareBindings);
    expect(response.status).toBe(401);
    expect(await response.json()).toEqual(UNAUTHORIZED);
    expect(handled).toBe(0);
  });

  it("refuses when the clock gives something unusable", async () => {
    const { bearer, userId } = await signInAs("001111.aaaa.0001");
    await db().insert(entitlements).values(row({ userId }));
    const { state, ask } = paidRoute(entitlementGate(() => Number.NaN));
    expect((await ask({ authorization: `Bearer ${bearer}` })).status).toBe(403);
    const throwing = paidRoute(
      entitlementGate(() => {
        throw new Error("clock broke");
      }),
    );
    vi.spyOn(console, "error").mockImplementation(() => {});
    expect((await throwing.ask({ authorization: `Bearer ${bearer}` })).status).toBe(503);
    expect(state.handled + throwing.state.handled).toBe(0);
  });

  it("uses the real clock in the exported requireEntitlement", async () => {
    const { bearer, userId } = await signInAs("001111.aaaa.0001");
    await db().insert(entitlements).values(row({ userId, expiresAt: Date.now() + HOUR }));
    const live = paidRoute(requireEntitlement);
    expect((await live.ask({ authorization: `Bearer ${bearer}` })).status).toBe(200);
    await db().update(entitlements).set({ expiresAt: Date.now() - 1000 });
    expect((await live.ask({ authorization: `Bearer ${bearer}` })).status).toBe(403);
  });
});
