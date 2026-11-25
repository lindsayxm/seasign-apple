// Better Auth for the phone's account (task 13; plan
// plans/2026-11-24-account-and-subscription.md, phase B1).
//
// - One instance per request, made from that request's bindings: Workers allow
//   no I/O across requests, and the secret and D1 binding live in `env`.
// - Sign in with Apple by the native identity token only. The phone sends the
//   token Apple gave it to POST /api/auth/sign-in/social
//   ({ provider: "apple", idToken: { token, nonce? } }); Better Auth checks it
//   against Apple's published keys and answers with a session. There is no web
//   redirect flow: no Services ID and no client secret are configured, so a
//   sign-in without an ID token is refused.
// - The bearer plugin hands the signed session token back in the
//   `set-auth-token` response header; the phone keeps that value in the
//   Keychain and sends it as `Authorization: Bearer <value>`. The `token` in
//   the response body is the bare session token and is refused as a bearer.
//   Routes read it through requireSession (src/lib/session.ts).
// - Only three Better Auth endpoints are reachable, and only through
//   src/routes/auth.ts: sign-in/social (with an ID token, Apple only),
//   get-session and sign-out. That file also strips Cookie and Set-Cookie.
// - An account is Apple's `sub` and nothing else (task 13 rework, after the
//   security review). Better Auth matches a new sign-in to an existing user
//   by email and can link accounts by it, so its `email` column never holds a
//   real address: it is accountEmail(sub), unique per sub. Two Apple accounts
//   that share an address are two users, and neither can reach the other's
//   account. The address Apple sent is kept in our own `user.apple_email`
//   column by recordAppleEmail. Account linking is also off.
//
// What Better Auth checks on the identity token itself (Apple provider in
// @better-auth/core 1.7.28, verify-id-token.mjs, through jose's jwtVerify):
// the RS256 signature against the key in https://appleid.apple.com/auth/keys
// with the token's `kid`; `iss` is https://appleid.apple.com; `aud` is the
// app's bundle ID (appBundleIdentifier); `exp` not passed and `iat` at most an
// hour old, each with 30 s of clock skew; iss, sub, aud, exp and iat present;
// and the nonce, when the phone sends one. Nothing here adds to those checks.
//
// Nothing here may log an email or a token. Better Auth's own log lines go
// through `logger.log` below, which prints the message and drops the extra
// arguments (objects that could carry user data).
//
// This file imports nothing from `cloudflare:*`, so app.ts stays loadable in
// Node for the spec writer.
import { betterAuth } from "better-auth/minimal";
import { drizzleAdapter } from "better-auth/adapters/drizzle";
import { bearer } from "better-auth/plugins";
import { drizzle } from "drizzle-orm/d1";
import { account, session, user, verification } from "./db/schema.ts";

/** The bindings the auth instance reads. */
export type AuthBindings = Pick<CloudflareBindings, "DB" | "APPLE_APP_BUNDLE_ID" | "BETTER_AUTH_URL" | "BETTER_AUTH_SECRET">;

/** Better Auth warns below this; a shorter secret is treated as missing. */
export const MIN_SECRET_LENGTH = 32;

/**
 * The value in Better Auth's `user.email` for the Apple account `sub`: made
 * from the sub alone, so it is unique per Apple account and can never match
 * another account's. Better Auth lower-cases emails, so each capital letter
 * (and `_`, the escape) is written as `_` plus its lower-case form first:
 * two subs that differ only in letter case still get two values. Apple's subs
 * are digits, lower-case hex and dots, so in practice this is the sub as it
 * is. The reserved `.invalid` domain can never receive mail. Not an address
 * to show anyone or to look a user up by.
 */
export const accountEmail = (sub: string) => `${sub.replace(/[A-Z_]/g, (char) => `_${char.toLowerCase()}`)}@apple.seasign.invalid`;

/**
 * Removes the user row a first sign-in left behind if it stopped between
 * Better Auth's two inserts (user, then account; the Drizzle adapter runs them
 * without a transaction, and D1 has none to offer). Such a row holds
 * accountEmail(sub), so Better Auth would match every later sign-in of that
 * Apple ID to it and refuse to link: a lockout for good. Called only for a
 * verified token, just before Better Auth looks the user up.
 *
 * Why it is safe, all in one statement (D1 runs each statement atomically
 * and one at a time):
 * - Only the row with this sub's own account email can match, and
 *   accountEmail is one-to-one, so no other sub's user is ever touched.
 * - A user with an account row is never deleted: NOT EXISTS is checked in the
 *   same statement as the delete.
 * - A concurrent first sign-in of the same sub that has inserted its user but
 *   not yet its account can lose that user here. Its account insert then
 *   fails on the foreign key to user (D1 enforces it; a test checks), so that
 *   request fails once and leaves nothing behind, while this one goes on to
 *   create the user. Every other interleaving ends with at most a one-time
 *   401 or 500 for one request; any later sign-in finds either a whole
 *   account or nothing in its way. Sessions belong to accounts' users only,
 *   so none is lost.
 *
 * Never throws: on a D1 error the sign-in goes on (and may meet the lockout
 * once more, until a later sign-in gets through).
 */
export async function removeHalfMadeUser(db: D1Database, sub: string): Promise<void> {
  try {
    await db
      .prepare("DELETE FROM user WHERE email = ?1 AND NOT EXISTS (SELECT 1 FROM account WHERE account.user_id = user.id)")
      .bind(accountEmail(sub))
      .run();
  } catch {
    console.error("auth: could not check for a half-made user; sign-in continues");
  }
}

/** The longest address kept in `apple_email` (RFC 5321's path limit). */
const MAX_EMAIL_LENGTH = 254;

/**
 * Keeps the email of an Apple identity token in `user.apple_email` if that
 * user has none yet. Call it only after Better Auth answered 200 to a sign-in
 * with this very token: the token was verified in that request, so its claims
 * are Apple's. The user is found through the account row by `sub`, never by
 * email. A first address is never replaced. Never throws: a failed write is
 * logged with a fixed line (no address) and the sign-in still succeeds.
 */
export async function recordAppleEmail(db: D1Database, token: string): Promise<void> {
  const claims = verifiedTokenClaims(token);
  if (!claims) return;
  const { sub, email } = claims;
  if (typeof sub !== "string" || !sub || typeof email !== "string") return;
  const address = email.trim().toLowerCase();
  if (!address.includes("@") || address.length > MAX_EMAIL_LENGTH) return;
  try {
    await db
      .prepare(
        "UPDATE user SET apple_email = ?1 WHERE apple_email IS NULL AND id = (SELECT user_id FROM account WHERE provider_id = 'apple' AND account_id = ?2)",
      )
      .bind(address, sub)
      .run();
  } catch {
    // The sign-in itself has succeeded and its session exists; the address
    // is tried again on the next sign-in whose token carries one.
    console.error("auth: could not record the Apple email; sign-in served");
  }
}

/** The payload of a JWT that has already been verified elsewhere, or null if it does not parse. */
function verifiedTokenClaims(token: string): Record<string, unknown> | null {
  const part = token.split(".")[1];
  if (!part) return null;
  try {
    const binary = atob(part.replace(/-/g, "+").replace(/_/g, "/"));
    const json = new TextDecoder().decode(Uint8Array.from(binary, (char) => char.charCodeAt(0)));
    const value: unknown = JSON.parse(json);
    return value && typeof value === "object" && !Array.isArray(value) ? (value as Record<string, unknown>) : null;
  } catch {
    return null;
  }
}

function buildAuth(env: AuthBindings, secret: string) {
  return betterAuth({
    secret,
    baseURL: env.BETTER_AUTH_URL,
    database: drizzleAdapter(drizzle(env.DB), {
      provider: "sqlite",
      schema: { user, session, account, verification },
    }),
    socialProviders: {
      apple: {
        // The ID token's audience on iOS is the app's bundle ID, which also
        // stands as the client ID: there is no Services ID (no web flow).
        clientId: env.APPLE_APP_BUNDLE_ID,
        appBundleIdentifier: env.APPLE_APP_BUNDLE_ID,
        // Empty on purpose: the authorization-code flow needs one and must not run.
        clientSecret: "",
        // Every user's Better Auth email is made from the sub, whatever the
        // token says (see accountEmail); the real one goes to apple_email.
        // Better Auth calls this from the sign-in only after the identity
        // token has passed verification (sign-in.mjs: verifyProviderIdToken,
        // then getUserInfo, which calls this), so the sub here is Apple's and
        // a forged token never reaches the cleanup.
        mapProfileToUser: async (profile) => {
          await removeHalfMadeUser(env.DB, profile.sub);
          return { email: accountEmail(profile.sub), emailVerified: false };
        },
      },
    },
    // Only the signed token (set-auth-token) is accepted as a bearer: the bare
    // session token, as it sits in D1, is not enough without the secret.
    plugins: [bearer({ requireSignature: true })],
    account: {
      // The account row is written once, at first sign-in, without tokens (below).
      updateAccountOnSignIn: false,
      // Never attach an Apple account to an existing user. With emails made
      // from the sub nothing could match anyway; this is the second lock.
      accountLinking: { enabled: false },
    },
    databaseHooks: {
      account: {
        // The identity token has done its job once checked; it carries the
        // email and is not needed again, so no token column is filled.
        create: { before: async (row) => ({ data: { ...row, idToken: null, accessToken: null, refreshToken: null } }) },
        update: {
          before: async (row) => {
            const { idToken: _id, accessToken: _access, refreshToken: _refresh, ...rest } = row;
            return { data: rest };
          },
        },
      },
    },
    advanced: {
      // No client address is stored with a session.
      ipAddress: { disableIpTracking: true },
    },
    // Better Auth's limiter keeps its counts in memory, which lasts one
    // request here; /api/auth/* is limited per client address by the
    // RATE_LIMIT_AUTH binding instead (src/lib/rate-limit.ts).
    rateLimit: { enabled: false },
    telemetry: { enabled: false },
    logger: {
      level: "warn",
      log: (level, message) => {
        const line = `[auth] ${message}`;
        if (level === "error") console.error(line);
        else if (level === "warn") console.warn(line);
        else console.log(line);
      },
    },
  });
}

export type Auth = ReturnType<typeof buildAuth>;

/**
 * The auth instance for one request, or null when the secret is missing or
 * too short: Better Auth would otherwise fall back to its public default
 * secret outside production, and anyone could sign session tokens with it.
 */
export function createAuth(env: AuthBindings): Auth | null {
  const secret = env.BETTER_AUTH_SECRET;
  if (typeof secret !== "string" || secret.length < MIN_SECRET_LENGTH) return null;
  return buildAuth(env, secret);
}
