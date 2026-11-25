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
//   the response body is the bare session token and is refused as a bearer. Routes read it through requireSession
//   (src/lib/session.ts).
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
 * The stand-in email for an Apple account whose very first identity token had
 * no email claim (Apple sends one when the app asks for the email scope). The
 * reserved `.invalid` domain can never receive mail. A returning user's stored
 * email is never replaced by it: later sign-ins do not override the user.
 */
export const placeholderEmail = (sub: string) => `${sub}@apple.placeholder.invalid`;

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
        mapProfileToUser: (profile) => (profile.email ? {} : { email: placeholderEmail(profile.sub), emailVerified: false }),
      },
    },
    // Only the signed token (set-auth-token) is accepted as a bearer: the bare
    // session token, as it sits in D1, is not enough without the secret.
    plugins: [bearer({ requireSignature: true })],
    account: {
      // The account row is written once, at first sign-in, without tokens (below).
      updateAccountOnSignIn: false,
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
    // request here; a Workers Rate Limiting binding for /api/auth/* is the
    // real answer (follow-up, not in task 13).
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
