// Drizzle schema for D1. Generate migrations into ../migrations with
// `npx drizzle-kit generate`; apply them locally with
// `npx wrangler d1 migrations apply seasign --local`.
//
// Nothing here imports `cloudflare:*`, so the spec writer can load it in Node.
import { sql } from "drizzle-orm";
import { index, integer, sqliteTable, text } from "drizzle-orm/sqlite-core";

/**
 * One Google Calendar push channel (task 156, plan
 * plans/2026-11-19-google-calendar-push.md). Google calls the webhook with the
 * channel id and token; the row says which phone to wake. It holds no Google
 * token, no calendar id, no user id and no event data: a leaked row says only
 * "this phone watches some calendar until then".
 */
export const calendarChannels = sqliteTable(
  "calendar_channels",
  {
    /** Our random channel id, sent to Google as the channel's `id` and back to us in X-Goog-Channel-ID. */
    id: text("id").primaryKey(),
    /** Lowercase hex SHA-256 of the channel token (X-Goog-Channel-Token). The token itself is not kept. */
    tokenHash: text("token_hash").notNull(),
    /** Google's resourceId from the watch answer; channels.stop needs it. */
    resourceId: text("resource_id").notNull(),
    /** The APNs device token, lowercase hex. */
    deviceToken: text("device_token").notNull(),
    /** Which APNs host the device token belongs to. */
    environment: text("environment", { enum: ["sandbox", "production"] }).notNull(),
    /** When Google stops the channel, Unix milliseconds. */
    expiresAt: integer("expires_at").notNull(),
    /** When the row was written, Unix milliseconds. */
    createdAt: integer("created_at").notNull(),
  },
  (table) => [index("calendar_channels_device_token").on(table.deviceToken), index("calendar_channels_expires_at").on(table.expiresAt)],
);

export type CalendarChannel = typeof calendarChannels.$inferSelect;

// ───────────────────────── Better Auth (task 13) ─────────────────────────
//
// The four tables Better Auth's Drizzle adapter uses, as `npx auth@1.7.28
// generate --adapter drizzle --dialect sqlite` wrote them for the options in
// src/auth.ts (Apple provider and the bearer plugin add no columns). The
// generator's relations are left out: joins are not turned on. Regenerate
// when a Better Auth upgrade or a new plugin changes the schema, and keep the
// table and column names: the adapter maps by them. `user.apple_email` was
// added by hand after generation and is not part of Better Auth's schema.
//
// What is kept, and what is not (src/auth.ts makes it so):
// - user: an account is Apple's `sub` and nothing else. Better Auth's
//   `email` column (NOT NULL, UNIQUE, and what Better Auth would link
//   accounts by) holds `<sub>@apple.seasign.invalid`, made from the sub, never
//   a real address; `email_verified` is false. The real address Apple sent is
//   in our own `apple_email` column (task 13 rework, migration 0002). Name is
//   empty unless Apple sent one.
// - account: provider "apple" and Apple's stable `sub` as account_id. The
//   identity token, access and refresh token columns stay empty.
// - session: the session token, expiry and the client's user agent. No IP
//   address is recorded.
// - verification: unused by the ID-token sign-in; Better Auth requires it.

export const user = sqliteTable("user", {
  id: text("id").primaryKey(),
  name: text("name").notNull(),
  email: text("email").notNull().unique(),
  emailVerified: integer("email_verified", { mode: "boolean" })
    .default(false)
    .notNull(),
  image: text("image"),
  createdAt: integer("created_at", { mode: "timestamp_ms" })
    .default(sql`(cast(unixepoch('subsecond') * 1000 as integer))`)
    .notNull(),
  updatedAt: integer("updated_at", { mode: "timestamp_ms" })
    .default(sql`(cast(unixepoch('subsecond') * 1000 as integer))`)
    .$onUpdate(() => /* @__PURE__ */ new Date())
    .notNull(),
  /**
   * Ours, not Better Auth's (Better Auth does not know this column): the
   * email from the first verified Apple identity token that carried one,
   * lower-cased, a real or private relay address. Not unique: two Apple
   * accounts may share an address and are still two users. Written by
   * recordAppleEmail in src/auth.ts, never by anything the client sends.
   */
  appleEmail: text("apple_email"),
});

export const session = sqliteTable(
  "session",
  {
    id: text("id").primaryKey(),
    expiresAt: integer("expires_at", { mode: "timestamp_ms" }).notNull(),
    token: text("token").notNull().unique(),
    createdAt: integer("created_at", { mode: "timestamp_ms" })
      .default(sql`(cast(unixepoch('subsecond') * 1000 as integer))`)
      .notNull(),
    updatedAt: integer("updated_at", { mode: "timestamp_ms" })
      .$onUpdate(() => /* @__PURE__ */ new Date())
      .notNull(),
    ipAddress: text("ip_address"),
    userAgent: text("user_agent"),
    userId: text("user_id")
      .notNull()
      .references(() => user.id, { onDelete: "cascade" }),
  },
  (table) => [index("session_userId_idx").on(table.userId)],
);

export const account = sqliteTable(
  "account",
  {
    id: text("id").primaryKey(),
    accountId: text("account_id").notNull(),
    providerId: text("provider_id").notNull(),
    userId: text("user_id")
      .notNull()
      .references(() => user.id, { onDelete: "cascade" }),
    accessToken: text("access_token"),
    refreshToken: text("refresh_token"),
    idToken: text("id_token"),
    accessTokenExpiresAt: integer("access_token_expires_at", {
      mode: "timestamp_ms",
    }),
    refreshTokenExpiresAt: integer("refresh_token_expires_at", {
      mode: "timestamp_ms",
    }),
    scope: text("scope"),
    password: text("password"),
    createdAt: integer("created_at", { mode: "timestamp_ms" })
      .default(sql`(cast(unixepoch('subsecond') * 1000 as integer))`)
      .notNull(),
    updatedAt: integer("updated_at", { mode: "timestamp_ms" })
      .$onUpdate(() => /* @__PURE__ */ new Date())
      .notNull(),
  },
  (table) => [index("account_userId_idx").on(table.userId)],
);

export const verification = sqliteTable(
  "verification",
  {
    id: text("id").primaryKey(),
    identifier: text("identifier").notNull(),
    value: text("value").notNull(),
    expiresAt: integer("expires_at", { mode: "timestamp_ms" }).notNull(),
    createdAt: integer("created_at", { mode: "timestamp_ms" })
      .default(sql`(cast(unixepoch('subsecond') * 1000 as integer))`)
      .notNull(),
    updatedAt: integer("updated_at", { mode: "timestamp_ms" })
      .default(sql`(cast(unixepoch('subsecond') * 1000 as integer))`)
      .$onUpdate(() => /* @__PURE__ */ new Date())
      .notNull(),
  },
  (table) => [index("verification_identifier_idx").on(table.identifier)],
);

export type User = typeof user.$inferSelect;
export type Session = typeof session.$inferSelect;

// ───────────────────────── Entitlements (task 221) ─────────────────────────

/**
 * One row per Apple auto-renewable subscription tied to an account (plan
 * plans/2026-11-24-account-and-subscription.md, phase B2). Written only by
 * `recordVerifiedSubscription` in src/lib/entitlements.ts, from facts that
 * the (not yet built) Apple verification has already checked; never from
 * anything the phone sends directly. Read only by `activeEntitlement`,
 * scoped by the session's user ID.
 *
 * Only what the check and later notification handling need is kept: no
 * price, currency, storefront, offer, auto-renew or app account token.
 * Times are Unix milliseconds, as Apple gives them.
 */
export const entitlements = sqliteTable(
  "entitlements",
  {
    /**
     * Apple's `originalTransactionId`: the same for every renewal of one
     * subscription, and what App Store Server Notifications and the App Store
     * Server API name a subscription by. The primary key, so one Apple
     * subscription can belong to one account only.
     */
    originalTransactionId: text("original_transaction_id").primaryKey(),
    /** The account it belongs to. Deleting the user deletes its entitlements. Not unique: a user who rebuys under another Apple ID has a second row. */
    userId: text("user_id")
      .notNull()
      .references(() => user.id, { onDelete: "cascade" }),
    /** Apple's `productId` (today only technology.artisan.seasign.monthly), kept so a later second product or an upgrade can be told apart. */
    productId: text("product_id").notNull(),
    /**
     * Apple's `environment`, "Sandbox" or "Production", in Apple's casing.
     * The check ignores it (App Review buys in the sandbox against the
     * production server); notification handling needs it to call the right
     * App Store Server API host. Whether a sandbox row may count on the
     * production server is the user's call, not made yet.
     */
    environment: text("environment").notNull(),
    /**
     * Our own word for the subscription's state: "active", "expired",
     * "billing_retry", "grace_period" or "revoked" (Apple's status 1 to 5).
     * Plain text on purpose: only "active" counts, and any other value,
     * including one a later build writes and this one does not know, is not
     * active.
     */
    state: text("state").notNull(),
    /** Apple's `expiresDate`: when this period ends. Null when Apple gave none, which is never active. */
    expiresAt: integer("expires_at"),
    /** Apple's `revocationDate` (refund or revocation). Any value at all means not active. */
    revokedAt: integer("revoked_at"),
    /**
     * Apple's `signedDate` of the data last applied. Notifications are
     * retried and can arrive out of order; facts signed at or before this are
     * ignored, so a late "active" cannot undo a revocation.
     */
    signedAt: integer("signed_at").notNull(),
    /** When this server last wrote the row (the injected clock). */
    updatedAt: integer("updated_at").notNull(),
  },
  (table) => [index("entitlements_user_id").on(table.userId)],
);

export type Entitlement = typeof entitlements.$inferSelect;
