// The entitlement record and the one check every paid route uses (task 221,
// plan plans/2026-11-24-account-and-subscription.md phase B2).
//
// THE PROJECT'S HARD RULE (memory/decisions/2026-11-24-subscription-gate-and-
// ai-lapse-rule.md): no AI feature and no request that costs money for a
// subscription that is not active, ever. A state that cannot be determined is
// not active. A failed renewal (Apple's billing grace period and billing
// retry) is not active: there is no grace period.
//
// So every path here fails closed. `isActive` says yes for exactly one shape
// of row; `activeEntitlement` never throws and turns a read error into
// "unreadable"; `requireEntitlement` lets a request through only on "active".
//
// How Apple's signed data is verified (X.509 chain of the JWS, or the App
// Store Server API with a key the user sets) is not decided. The Apple work
// will call `recordVerifiedSubscription` with facts it has already verified;
// nothing in production calls it yet.
import { and, eq, sql } from "drizzle-orm";
import { drizzle, type DrizzleD1Database } from "drizzle-orm/d1";
import { createMiddleware } from "hono/factory";
import { entitlements, type Entitlement } from "../db/schema.ts";
import { UNAUTHORIZED, type SessionVariables } from "./session.ts";

/** The one subscription product (App Store Connect, not created yet). */
export const SUBSCRIPTION_PRODUCT_ID = "technology.artisan.seasign.monthly";

/**
 * Our words for a subscription's state, from Apple's status values 1 to 5
 * (App Store Server API `status`): active, expired, billing retry, billing
 * grace period, revoked. Only `active` grants anything.
 */
export const ENTITLEMENT_STATES = ["active", "expired", "billing_retry", "grace_period", "revoked"] as const;
export type EntitlementState = (typeof ENTITLEMENT_STATES)[number];

/** The only state that grants access. */
const SUBSCRIBED: EntitlementState = "active";

/** Apple's `environment` values, in Apple's casing. */
export const APPLE_ENVIRONMENTS = ["Sandbox", "Production"] as const;
export type AppleEnvironment = (typeof APPLE_ENVIRONMENTS)[number];

/** What a paid route answers (403) when the user's subscription is not active. Fixed: it never says why or whose. */
export const SUBSCRIPTION_REQUIRED = { error: "subscription_required" as const, message: "This needs an active subscription" };

/**
 * What a paid route answers (503) when the subscription could not be read.
 * Not 403: the phone treats this as "cannot be checked" (its Unknown state,
 * AI off, no push to buy again) rather than as a lapse. Not a bare 500: the
 * answer is fixed and the route never ran. Either way nothing is allowed.
 */
export const ENTITLEMENT_UNAVAILABLE = { error: "entitlement_unavailable" as const, message: "The subscription could not be checked. Try again" };

/** The columns the check reads. */
export type EntitlementCheckFields = Pick<Entitlement, "state" | "expiresAt" | "revokedAt">;

const isTime = (value: unknown): value is number => typeof value === "number" && Number.isFinite(value);

/**
 * True only when the state is exactly "active", the expiry is a real time
 * later than `now`, and there is no revocation. No row, any other state
 * (including one this build does not know), a missing or odd expiry, any
 * revocation value, or an unusable clock is false.
 */
export function isActive(row: EntitlementCheckFields | undefined, now: number): boolean {
  if (!row) return false;
  if (!isTime(now)) return false;
  if (row.state !== SUBSCRIBED) return false;
  if (row.revokedAt !== null) return false;
  if (!isTime(row.expiresAt)) return false;
  return row.expiresAt > now;
}

/** The loader's answer: active (with the row that makes it so), inactive, or unreadable (a read error). */
export type EntitlementCheck = { status: "active"; entitlement: Entitlement } | { status: "inactive" } | { status: "unreadable" };

/**
 * Whether `userId` (the session's user ID, never client input) has an
 * active subscription at `now`. Active when any of the user's rows passes
 * `isActive` (a user who rebought under another Apple ID has two). Never
 * throws: a D1 error is "unreadable", logged as a fixed line with no user ID
 * and no error text.
 */
export async function activeEntitlement(db: DrizzleD1Database, userId: string, now: number): Promise<EntitlementCheck> {
  let rows: Entitlement[];
  try {
    rows = await db.select().from(entitlements).where(eq(entitlements.userId, userId));
  } catch {
    console.error("entitlements: read failed");
    return { status: "unreadable" };
  }
  // The query is already scoped; the second look keeps a wrong row from ever counting.
  const found = rows.find((row) => row.userId === userId && isActive(row, now));
  return found ? { status: "active", entitlement: found } : { status: "inactive" };
}

/**
 * Facts about one subscription that the Apple work has ALREADY verified
 * (signature, bundle ID, environment). From Apple's decoded transaction and
 * renewal info, or the App Store Server API's status: originalTransactionId,
 * productId, environment, expiresDate, revocationDate, signedDate, and the
 * status mapped to our word. Times are Unix milliseconds.
 */
export type VerifiedSubscriptionFacts = {
  originalTransactionId: string;
  productId: string;
  environment: AppleEnvironment;
  state: EntitlementState;
  expiresAt: number | null;
  revokedAt: number | null;
  signedAt: number;
};

/**
 * stored: written. stale: facts signed at or before what is stored, ignored.
 * other_account: this Apple subscription belongs to another account, nothing
 * changed. invalid: the facts are not well formed, nothing written.
 */
export type RecordOutcome = { outcome: "stored" | "stale" | "other_account" | "invalid" };

const isOptionalTime = (value: unknown): value is number | null => value === null || isTime(value);

function wellFormed(facts: VerifiedSubscriptionFacts): boolean {
  return (
    typeof facts.originalTransactionId === "string" &&
    facts.originalTransactionId.length > 0 &&
    facts.originalTransactionId.length <= 64 &&
    facts.productId === SUBSCRIPTION_PRODUCT_ID &&
    (APPLE_ENVIRONMENTS as readonly unknown[]).includes(facts.environment) &&
    (ENTITLEMENT_STATES as readonly unknown[]).includes(facts.state) &&
    isOptionalTime(facts.expiresAt) &&
    isOptionalTime(facts.revokedAt) &&
    isTime(facts.signedAt)
  );
}

/**
 * THE INTERFACE FOR THE LATER APPLE WORK: record a subscription for
 * `userId` from facts that have already been verified against Apple. Not
 * called anywhere in production yet. One statement, so two accounts racing
 * for one original transaction ID cannot both win:
 *
 * - a new original transaction ID is inserted for `userId`;
 * - an existing one is updated only when it already belongs to `userId` and
 *   the facts are signed later than what is stored; `user_id` is never
 *   changed, so a subscription never moves to another account.
 *
 * A D1 error (including a `userId` with no user row) is thrown to the caller,
 * which should answer Apple with an error so Apple retries. The caller must
 * pass the session's user ID, or for a notification the owner found by the
 * original transaction ID; never an ID from the request body.
 */
export async function recordVerifiedSubscription(db: DrizzleD1Database, userId: string, facts: VerifiedSubscriptionFacts, now: number): Promise<RecordOutcome> {
  if (!wellFormed(facts) || !isTime(now)) return { outcome: "invalid" };
  const values = {
    originalTransactionId: facts.originalTransactionId,
    userId,
    productId: facts.productId,
    environment: facts.environment,
    state: facts.state,
    expiresAt: facts.expiresAt,
    revokedAt: facts.revokedAt,
    signedAt: facts.signedAt,
    updatedAt: now,
  };
  const written = await db
    .insert(entitlements)
    .values(values)
    .onConflictDoUpdate({
      target: entitlements.originalTransactionId,
      set: {
        productId: values.productId,
        environment: values.environment,
        state: values.state,
        expiresAt: values.expiresAt,
        revokedAt: values.revokedAt,
        signedAt: values.signedAt,
        updatedAt: values.updatedAt,
      },
      setWhere: and(eq(entitlements.userId, userId), sql`${entitlements.signedAt} < ${facts.signedAt}`),
    })
    .returning({ userId: entitlements.userId });
  if (written.length > 0) return { outcome: "stored" };
  // Nothing written: the row exists and either is another account's or is newer.
  const [existing] = await db
    .select({ userId: entitlements.userId })
    .from(entitlements)
    .where(eq(entitlements.originalTransactionId, facts.originalTransactionId));
  return { outcome: existing && existing.userId === userId ? "stale" : "other_account" };
}

/**
 * The middleware with an injected clock (Unix milliseconds). Mount it after
 * `requireSession`. Answers:
 * - 401 `unauthorized` when no session user is on the context (mounted
 *   without requireSession): refuse rather than guess;
 * - 403 `subscription_required` when the user's subscription is not active;
 * - 503 `entitlement_unavailable` when it could not be read (D1 error or a
 *   clock that throws).
 * The route runs only on "active". Every answer is fixed and `no-store`, and
 * the check reads only the session user's rows.
 */
export function entitlementGate(clock: () => number) {
  return createMiddleware<{ Bindings: CloudflareBindings; Variables: SessionVariables }>(async (c, next) => {
    const userId = c.get("userId");
    if (typeof userId !== "string" || userId.length === 0) {
      c.header("Cache-Control", "no-store");
      return c.json(UNAUTHORIZED, 401);
    }
    let check: EntitlementCheck;
    try {
      check = await activeEntitlement(drizzle(c.env.DB), userId, clock());
    } catch {
      console.error("entitlements: check failed");
      check = { status: "unreadable" };
    }
    if (check.status === "active") {
      await next();
      return;
    }
    c.header("Cache-Control", "no-store");
    if (check.status === "unreadable") return c.json(ENTITLEMENT_UNAVAILABLE, 503);
    return c.json(SUBSCRIPTION_REQUIRED, 403);
  });
}

/** The gate later paid routes use: `route.post(path, requireSession, requireEntitlement, handler)`. */
export const requireEntitlement = entitlementGate(() => Date.now());
