import { applyD1Migrations } from "cloudflare:test";
import { env } from "cloudflare:workers";
import { drizzle } from "drizzle-orm/d1";
import { eq } from "drizzle-orm";
import { Hono } from "hono";
import { afterEach, beforeAll, beforeEach, describe, expect, it, vi } from "vitest";
import { app } from "../src/app.ts";
import { account, session, user, verification } from "../src/db/schema.ts";
import { AUTH_INVALID_REQUEST, AUTH_NOT_FOUND } from "../src/routes/auth.ts";
import { accountEmail } from "../src/auth.ts";
import { AUTH_UNAVAILABLE, UNAUTHORIZED, requireSession, type SessionVariables } from "../src/lib/session.ts";
import { startWorker } from "./start-worker.ts";

startWorker();

// Sign in with Apple by native ID token, bearer sessions and the session
// helper (task 13). Apple is never reached: its key list
// (https://appleid.apple.com/auth/keys) is answered by a stubbed fetch with
// the public half of an RSA key made here, and the identity tokens are signed
// here with its private half, shaped like Apple's (RS256, kid in the header,
// iss/aud/sub/iat/exp, email claims as strings).

const APPLE_KEYS = "https://appleid.apple.com/auth/keys";
const ISSUER = "https://appleid.apple.com";
const BUNDLE_ID = "technology.artisan.seasign";
const KID = "TESTKID001";
const SUB = "001234.0a1b2c3d4e5f60718293a4b5c6d7e8f9.0420";
const EMAIL = "x7k2m9q4pz@privaterelay.appleid.com";
const BASE = "https://api.seasign.app";
const CLIENT_IP = "203.0.113.7";

let signingKey: CryptoKey;
let otherKey: CryptoKey;
let publicJwk: Record<string, unknown>;

const bytesToBase64url = (bytes: ArrayBuffer | Uint8Array) =>
  btoa(String.fromCharCode(...new Uint8Array(bytes)))
    .replace(/\+/g, "-")
    .replace(/\//g, "_")
    .replace(/=+$/, "");
const jsonToBase64url = (value: unknown) => bytesToBase64url(new TextEncoder().encode(JSON.stringify(value)));

const RSA = { name: "RSASSA-PKCS1-v1_5", modulusLength: 2048, publicExponent: new Uint8Array([1, 0, 1]), hash: "SHA-256" };

beforeAll(async () => {
  await applyD1Migrations(env.DB, env.TEST_MIGRATIONS);
  const pair = (await crypto.subtle.generateKey(RSA, true, ["sign", "verify"])) as CryptoKeyPair;
  const other = (await crypto.subtle.generateKey(RSA, true, ["sign", "verify"])) as CryptoKeyPair;
  signingKey = pair.privateKey;
  otherKey = other.privateKey;
  const jwk = (await crypto.subtle.exportKey("jwk", pair.publicKey)) as JsonWebKey;
  // The shape of an entry in Apple's key list.
  publicJwk = { kty: "RSA", kid: KID, use: "sig", alg: "RS256", n: jwk.n, e: jwk.e };
});

const nowSeconds = () => Math.floor(Date.now() / 1000);

/** The claims of a good identity token for the app, first sign-in (email present). */
function claims(extra: Record<string, unknown> = {}): Record<string, unknown> {
  const now = nowSeconds();
  return {
    iss: ISSUER,
    aud: BUNDLE_ID,
    sub: SUB,
    iat: now,
    exp: now + 600,
    auth_time: now,
    email: EMAIL,
    email_verified: "true",
    is_private_email: "true",
    nonce_supported: true,
    ...extra,
  };
}

/** Signs like Apple: RS256 over header.payload, kid in the header. */
async function idToken(payload: Record<string, unknown> = claims(), key: CryptoKey = signingKey, header: Record<string, unknown> = { alg: "RS256", kid: KID }) {
  const input = `${jsonToBase64url(header)}.${jsonToBase64url(payload)}`;
  const signature = await crypto.subtle.sign("RSASSA-PKCS1-v1_5", key, new TextEncoder().encode(input));
  return `${input}.${bytesToBase64url(signature)}`;
}

// ───────────────────────── outbound mock ─────────────────────────

function mockApple() {
  const calls: string[] = [];
  const spy = vi.spyOn(globalThis, "fetch").mockImplementation(async (input, init) => {
    const request = new Request(input, init);
    calls.push(request.url);
    if (request.url === APPLE_KEYS) return new Response(JSON.stringify({ keys: [publicJwk] }), { status: 200, headers: { "content-type": "application/json" } });
    return new Response("unexpected", { status: 500 });
  });
  return { calls, spy, keyFetches: () => calls.filter((url) => url === APPLE_KEYS).length };
}

/** Every console line, flattened to text, so a test can say what was never printed. */
function captureConsole() {
  const lines: string[] = [];
  for (const level of ["log", "info", "warn", "error", "debug", "trace"] as const) {
    vi.spyOn(console, level).mockImplementation((...args: unknown[]) => {
      lines.push(args.map((arg) => (arg instanceof Error ? `${arg.message} ${arg.stack ?? ""}` : typeof arg === "string" ? arg : JSON.stringify(arg))).join(" "));
    });
  }
  return lines;
}

// ───────────────────────── helpers ─────────────────────────

const TEST_SECRET = env.BETTER_AUTH_SECRET;

function testEnv(extra: Record<string, unknown> = {}): CloudflareBindings {
  return { ...env, ...extra } as unknown as CloudflareBindings;
}

const db = () => drizzle(env.DB);

/** Rows in every table of the database (D1's and Cloudflare's own left out), so a test can say nothing was written. */
async function rowCounts(): Promise<Record<string, number>> {
  const tables = await env.DB.prepare("SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE '\\_cf\\_%' ESCAPE '\\' AND name NOT LIKE 'sqlite\\_%' ESCAPE '\\' AND name != 'd1_migrations'").all<{ name: string }>();
  const counts: Record<string, number> = {};
  for (const { name } of tables.results) {
    const row = await env.DB.prepare(`SELECT count(*) AS n FROM "${name}"`).first<{ n: number }>();
    counts[name] = row!.n;
  }
  return counts;
}

const post = (path: string, body: unknown, headers: Record<string, string> = {}) =>
  app.request(`${BASE}${path}`, { method: "POST", headers: { "content-type": "application/json", ...headers }, body: typeof body === "string" ? body : JSON.stringify(body) }, testEnv());

function signIn(token: string, bindings: CloudflareBindings = testEnv(), { nonce, base = BASE }: { nonce?: string; base?: string } = {}) {
  return app.request(
    `${base}/api/auth/sign-in/social`,
    {
      method: "POST",
      // A client address as Cloudflare and proxies give it, to show it is not kept.
      // (CF-Connecting-IP is left out: it would bring in the real rate limiter,
      // which test/rate-limit.test.ts covers.)
      headers: { "content-type": "application/json", "user-agent": "Seasign/1 CFNetwork", "x-forwarded-for": CLIENT_IP, "x-real-ip": CLIENT_IP },
      body: JSON.stringify({ provider: "apple", idToken: nonce === undefined ? { token } : { token, nonce } }),
    },
    bindings,
  );
}

/** A route behind the session helper, as the later /v1 routes will use it. */
const probe = new Hono<{ Bindings: CloudflareBindings; Variables: SessionVariables }>();
probe.get("/v1/probe", requireSession, (c) => c.json({ userId: c.get("userId") }));

const askProbe = (headers: Record<string, string> = {}, bindings: CloudflareBindings = testEnv()) => probe.request(`${BASE}/v1/probe`, { headers }, bindings);

beforeEach(async () => {
  await db().delete(verification);
  await db().delete(session);
  await db().delete(account);
  await db().delete(user);
});

afterEach(() => {
  vi.restoreAllMocks();
});

// ───────────────────────── tests ─────────────────────────

describe("the test setup", () => {
  it("gives the Worker a test-only auth secret through the Vitest config", () => {
    expect(typeof TEST_SECRET).toBe("string");
    expect(TEST_SECRET!.length).toBeGreaterThanOrEqual(32);
  });
});

describe("POST /api/auth/sign-in/social with an Apple ID token", () => {
  it("creates the user keyed by Apple's sub, keeps the token's email in apple_email, and returns a bearer session", async () => {
    const apple = mockApple();
    const response = await signIn(await idToken());
    expect(response.status).toBe(200);
    const body = (await response.json()) as { token: string; user: { id: string; email: string } };
    // Better Auth's own email column holds a value made from the sub, never a real address.
    expect(body.user.email).toBe(accountEmail(SUB));
    expect(JSON.stringify(body)).not.toContain(EMAIL);
    const bearer = response.headers.get("set-auth-token");
    expect(bearer).toBeTruthy();
    expect(apple.keyFetches()).toBe(1);

    const users = await db().select().from(user).all();
    expect(users).toHaveLength(1);
    expect(users[0]!.email).toBe(accountEmail(SUB));
    expect(users[0]!.appleEmail).toBe(EMAIL);
    expect(users[0]!.emailVerified).toBe(false);
    expect(users[0]!.id).toBe(body.user.id);

    const accounts = await db().select().from(account).all();
    expect(accounts).toHaveLength(1);
    expect(accounts[0]!.providerId).toBe("apple");
    expect(accounts[0]!.accountId).toBe(SUB);
    expect(accounts[0]!.userId).toBe(body.user.id);
    // The identity token is not kept once it has been checked.
    expect(accounts[0]!.idToken).toBeNull();
    expect(accounts[0]!.accessToken).toBeNull();
    expect(accounts[0]!.refreshToken).toBeNull();

    const sessions = await db().select().from(session).all();
    expect(sessions).toHaveLength(1);
    expect(sessions[0]!.userId).toBe(body.user.id);
    // No client address is stored with the session.
    expect(sessions[0]!.ipAddress || null).toBeNull();
    expect(JSON.stringify(sessions[0])).not.toContain(CLIENT_IP);
  });

  it("signs a returning user in without an email claim and keeps the stored Apple email", async () => {
    mockApple();
    const first = await signIn(await idToken());
    expect(first.status).toBe(200);
    const firstUser = ((await first.json()) as { user: { id: string } }).user.id;

    const { email: _email, email_verified: _verified, is_private_email: _private, ...withoutEmail } = claims();
    const second = await signIn(await idToken(withoutEmail));
    expect(second.status).toBe(200);
    const secondBody = (await second.json()) as { user: { id: string; email: string } };
    expect(secondBody.user.id).toBe(firstUser);
    expect(secondBody.user.email).toBe(accountEmail(SUB));

    const users = await db().select().from(user).all();
    expect(users).toHaveLength(1);
    expect(users[0]!.appleEmail).toBe(EMAIL);
    expect(await db().select().from(account).all()).toHaveLength(1);
    expect(await db().select().from(session).all()).toHaveLength(2);
  });

  it("a returning user whose token carries a changed email keeps the first one", async () => {
    mockApple();
    expect((await signIn(await idToken())).status).toBe(200);
    const second = await signIn(await idToken(claims({ email: "someone.else@example.com" })));
    expect(second.status).toBe(200);
    const users = await db().select().from(user).all();
    expect(users).toHaveLength(1);
    expect(users[0]!.appleEmail).toBe(EMAIL);
  });

  it("a user whose first token had no email gets the email from the first later token that has one", async () => {
    mockApple();
    const { email: _email, email_verified: _verified, is_private_email: _private, ...withoutEmail } = claims();
    const first = await signIn(await idToken(withoutEmail));
    expect(first.status).toBe(200);
    expect((await db().select().from(user).all())[0]!.appleEmail).toBeNull();
    expect((await signIn(await idToken(claims({ email: "First.Seen@Example.com" })))).status).toBe(200);
    expect((await signIn(await idToken(claims({ email: "later@example.com" })))).status).toBe(200);
    const users = await db().select().from(user).all();
    expect(users).toHaveLength(1);
    expect(users[0]!.email).toBe(accountEmail(SUB));
    expect(users[0]!.appleEmail).toBe("first.seen@example.com");
  });

  it("a refused token leaves a stored Apple email alone", async () => {
    mockApple();
    const { email: _email, email_verified: _verified, is_private_email: _private, ...withoutEmail } = claims();
    expect((await signIn(await idToken(withoutEmail))).status).toBe(200);
    expect((await signIn(await idToken(claims({ email: "forged@example.com" }), otherKey))).status).toBe(401);
    expect((await db().select().from(user).all())[0]!.appleEmail).toBeNull();
  });

  // Each refused token is the good one with exactly one thing changed, and
  // each test checks that the key list was fetched, so a refusal cannot come
  // from a broken fixture before verification ran.
  const refused: [string, () => Promise<string>][] = [
    ["a wrong audience", () => idToken(claims({ aud: "technology.artisan.other" }))],
    ["the Services ID style audience of another app", () => idToken(claims({ aud: `${BUNDLE_ID}.web` }))],
    ["a wrong issuer", () => idToken(claims({ iss: "https://appleid.example.com" }))],
    ["a signature by another key under Apple's kid", () => idToken(claims(), otherKey)],
    ["an expired token", () => idToken(claims({ iat: nowSeconds() - 900, exp: nowSeconds() - 120 }))],
    ["a token issued more than an hour ago", () => idToken(claims({ iat: nowSeconds() - 3700, exp: nowSeconds() + 600 }))],
  ];

  for (const [name, make] of refused) {
    it(`refuses ${name} with 401 and creates nothing`, async () => {
      const apple = mockApple();
      const before = await rowCounts();
      const response = await signIn(await make());
      expect(response.status).toBe(401);
      expect(response.headers.get("set-auth-token")).toBeNull();
      expect(apple.keyFetches()).toBe(1);
      expect(await db().select().from(user).all()).toHaveLength(0);
      // Nothing in any table, verification included.
      expect(await rowCounts()).toEqual(before);
    });
  }

  it("refuses a token signed with HS256 and the key list's key id", async () => {
    mockApple();
    const header = jsonToBase64url({ alg: "HS256", kid: KID });
    const payload = jsonToBase64url(claims());
    const response = await signIn(`${header}.${payload}.${bytesToBase64url(new Uint8Array(32))}`);
    expect(response.status).toBe(401);
    expect(await db().select().from(user).all()).toHaveLength(0);
  });

  it("checks the nonce when the phone sends one: the same nonce or its SHA-256 hex in the token passes, another is refused", async () => {
    mockApple();
    const raw = "n-0S6_WzA2Mj";
    const hashed = [...new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(raw)))].map((byte) => byte.toString(16).padStart(2, "0")).join("");
    // Apple puts the SHA-256 of the app's nonce in the token when the app hashed it for the request.
    expect((await signIn(await idToken(claims({ nonce: raw })), testEnv(), { nonce: raw })).status).toBe(200);
    expect((await signIn(await idToken(claims({ nonce: hashed })), testEnv(), { nonce: raw })).status).toBe(200);
    expect((await signIn(await idToken(claims({ nonce: raw })), testEnv(), { nonce: "a-different-nonce" })).status).toBe(401);
    expect((await signIn(await idToken(), testEnv(), { nonce: raw })).status).toBe(401);
  });

  it("does not check a nonce the phone does not send", async () => {
    mockApple();
    expect((await signIn(await idToken(claims({ nonce: "n-0S6_WzA2Mj" })))).status).toBe(200);
  });

  it("works the same on the local dev origin the Debug app calls (http://localhost:8787)", async () => {
    mockApple();
    const response = await signIn(await idToken(), testEnv(), { base: "http://localhost:8787" });
    expect(response.status).toBe(200);
    const bearer = response.headers.get("set-auth-token")!;
    expect(bearer).toBeTruthy();
    const asked = await probe.request("http://localhost:8787/v1/probe", { headers: { authorization: `Bearer ${bearer}` } }, testEnv());
    expect(asked.status).toBe(200);
  });

  it("offers no web redirect flow: without an ID token there is no authorize URL", async () => {
    const apple = mockApple();
    const response = await app.request(
      `${BASE}/api/auth/sign-in/social`,
      { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ provider: "apple" }) },
      testEnv(),
    );
    expect(response.status).toBe(400);
    const text = await response.text();
    expect(JSON.parse(text)).toEqual(AUTH_INVALID_REQUEST);
    expect(text).not.toContain("appleid.apple.com/auth/authorize");
    expect(response.headers.get("location")).toBeNull();
    expect(apple.calls).toHaveLength(0);
    // Better Auth's redirect flow would have written a state row first.
    expect(await db().select().from(verification).all()).toHaveLength(0);
  });

  it("answers 503 and creates nothing when the auth secret is not set", async () => {
    const apple = mockApple();
    const response = await signIn(await idToken(), testEnv({ BETTER_AUTH_SECRET: undefined }));
    expect(response.status).toBe(503);
    expect(await response.json()).toEqual(AUTH_UNAVAILABLE);
    expect(apple.calls).toHaveLength(0);
    expect(await db().select().from(user).all()).toHaveLength(0);
  });

  it("answers 503 when the auth secret is too short to be a real one", async () => {
    mockApple();
    const response = await signIn(await idToken(), testEnv({ BETTER_AUTH_SECRET: "short" }));
    expect(response.status).toBe(503);
    expect(await response.json()).toEqual(AUTH_UNAVAILABLE);
  });

  it("never prints the email, the identity token or the session token", async () => {
    mockApple();
    const lines = captureConsole();
    const good = await idToken();
    const response = await signIn(good);
    const bearer = response.headers.get("set-auth-token")!;
    const body = (await response.json()) as { token: string };
    await signIn(await idToken(claims({ aud: "technology.artisan.other" })));
    await signIn(await idToken(claims(), otherKey));
    await signIn(await idToken(claims({ iat: nowSeconds() - 900, exp: nowSeconds() - 120 })));
    await askProbe({ authorization: `Bearer ${bearer}` });
    await askProbe({ authorization: "Bearer not-a-session" });
    const printed = lines.join("\n");
    for (const secret of [EMAIL, good, good.split(".")[2]!, bearer, body.token, TEST_SECRET!]) {
      expect(printed).not.toContain(secret);
    }
  });
});

describe("an account is Apple's sub, never the email", () => {
  const OTHER_SUB = "009876.ffeeddccbbaa99887766554433221100.0311";

  for (const [name, email] of [
    ["the same email", EMAIL],
    ["the same email in another letter case", EMAIL.toUpperCase()],
  ] as const) {
    it(`a different Apple account with ${name} gets its own user and never the first user's session`, async () => {
      mockApple();
      const first = await signIn(await idToken());
      expect(first.status).toBe(200);
      const firstUser = ((await first.json()) as { user: { id: string } }).user.id;

      const second = await signIn(await idToken(claims({ sub: OTHER_SUB, email })));
      expect(second.status).toBe(200);
      const secondBody = (await second.json()) as { user: { id: string } };
      expect(secondBody.user.id).not.toBe(firstUser);

      // The second person's bearer token reaches requireSession as the second user.
      const bearer = second.headers.get("set-auth-token")!;
      const asked = await askProbe({ authorization: `Bearer ${bearer}` });
      expect(await asked.json()).toEqual({ userId: secondBody.user.id });

      const users = await db().select().from(user).all();
      expect(users).toHaveLength(2);
      const accounts = await db().select().from(account).all();
      expect(accounts).toHaveLength(2);
      expect(accounts.find((row) => row.accountId === SUB)!.userId).toBe(firstUser);
      expect(accounts.find((row) => row.accountId === OTHER_SUB)!.userId).toBe(secondBody.user.id);
      // No session of the first user was made by the second sign-in.
      const sessions = await db().select().from(session).all();
      expect(sessions.filter((row) => row.userId === firstUser)).toHaveLength(1);
    });
  }

  it("two subs that differ only in letter case are two users", async () => {
    mockApple();
    const lower = "001234.abcdef0123456789abcdef0123456789.0420";
    const upper = "001234.ABCDEF0123456789abcdef0123456789.0420";
    expect(accountEmail(lower)).not.toBe(accountEmail(upper));
    const first = await signIn(await idToken(claims({ sub: lower })));
    const second = await signIn(await idToken(claims({ sub: upper })));
    expect(first.status).toBe(200);
    expect(second.status).toBe(200);
    const firstId = ((await first.json()) as { user: { id: string } }).user.id;
    const secondId = ((await second.json()) as { user: { id: string } }).user.id;
    expect(secondId).not.toBe(firstId);
    expect(await db().select().from(user).all()).toHaveLength(2);
  });

  it("the stored Apple email is never sent back: not on a later sign-in, not by get-session", async () => {
    mockApple();
    expect((await signIn(await idToken())).status).toBe(200);
    expect((await db().select().from(user).all())[0]!.appleEmail).toBe(EMAIL);
    const { email: _email, email_verified: _verified, is_private_email: _private, ...withoutEmail } = claims();
    const again = await signIn(await idToken(withoutEmail));
    const bearer = again.headers.get("set-auth-token")!;
    expect(await again.text()).not.toContain(EMAIL);
    const read = await app.request(`${BASE}/api/auth/get-session`, { headers: { authorization: `Bearer ${bearer}` } }, testEnv());
    expect(read.status).toBe(200);
    expect(await read.text()).not.toContain(EMAIL);
  });

  it("a failed write of the Apple email still serves the sign-in, logging a fixed line without the address", async () => {
    mockApple();
    const lines = captureConsole();
    const real = env.DB;
    const failing = new Proxy(real, {
      get(target, prop) {
        if (prop === "prepare")
          return (sql: string) => {
            if (sql.includes("SET apple_email")) throw new Error("D1 is down");
            return target.prepare(sql);
          };
        const value = Reflect.get(target, prop);
        return typeof value === "function" ? value.bind(target) : value;
      },
    });
    const response = await signIn(await idToken(), testEnv({ DB: failing }));
    expect(response.status).toBe(200);
    expect(response.headers.get("set-auth-token")).toBeTruthy();
    expect((await db().select().from(user).all())[0]!.appleEmail).toBeNull();
    expect(lines).toContain("auth: could not record the Apple email; sign-in served");
    expect(lines.join("\n")).not.toContain(EMAIL);
    // The next sign-in with an email fills it in.
    expect((await signIn(await idToken())).status).toBe(200);
    expect((await db().select().from(user).all())[0]!.appleEmail).toBe(EMAIL);
  });
});

describe("Apple's key list and token header", () => {
  it("refuses with 401 when Apple's key list answers an error", async () => {
    vi.spyOn(globalThis, "fetch").mockImplementation(async () => new Response("down", { status: 503 }));
    expect((await signIn(await idToken())).status).toBe(401);
    expect(await db().select().from(user).all()).toHaveLength(0);
  });

  it("refuses with 401 when Apple's key list cannot be reached", async () => {
    vi.spyOn(globalThis, "fetch").mockImplementation(async () => {
      throw new TypeError("network down");
    });
    expect((await signIn(await idToken())).status).toBe(401);
    expect(await db().select().from(user).all()).toHaveLength(0);
  });

  it("refuses an unsigned token (alg none)", async () => {
    mockApple();
    const token = `${jsonToBase64url({ alg: "none", kid: KID })}.${jsonToBase64url(claims())}.`;
    expect((await signIn(token)).status).toBe(401);
    expect(await db().select().from(user).all()).toHaveLength(0);
  });

  it("refuses a token whose kid is not in Apple's key list", async () => {
    const apple = mockApple();
    const response = await signIn(await idToken(claims(), signingKey, { alg: "RS256", kid: "NOT-IN-LIST" }));
    expect(response.status).toBe(401);
    expect(apple.keyFetches()).toBe(1);
    expect(await db().select().from(user).all()).toHaveLength(0);
  });
});

describe("/api/auth/* lets through only the phone's three calls", () => {
  it("refuses sign-in without an ID token before Better Auth runs, writing nothing anywhere", async () => {
    const apple = mockApple();
    const before = await rowCounts();
    for (const body of [
      { provider: "apple" },
      { provider: "apple", idToken: {} },
      { provider: "apple", idToken: { token: "" } },
      { provider: "apple", idToken: { token: 42 } },
      { provider: "apple", additionalData: { junk: "x".repeat(10_000) } },
      { provider: "google", idToken: { token: "a.b.c" } },
      { idToken: { token: "a.b.c" } },
      [],
      "null",
      "not json",
    ]) {
      const response = await post("/api/auth/sign-in/social", body);
      expect(response.status, JSON.stringify(body).slice(0, 60)).toBe(400);
      expect(await response.json()).toEqual(AUTH_INVALID_REQUEST);
    }
    const notJson = await app.request(`${BASE}/api/auth/sign-in/social`, { method: "POST", headers: { "content-type": "text/plain" }, body: JSON.stringify({ provider: "apple", idToken: { token: "a.b.c" } }) }, testEnv());
    expect(notJson.status).toBe(400);
    expect(await rowCounts()).toEqual(before);
    expect(apple.calls).toHaveLength(0);
  });

  it("passes on only the provider and the ID token: extra fields write nothing more", async () => {
    mockApple();
    const response = await post("/api/auth/sign-in/social", {
      provider: "apple",
      idToken: { token: await idToken(), accessToken: "junk-access", refreshToken: "junk-refresh" },
      callbackURL: "https://evil.example/",
      additionalData: { junk: "x".repeat(10_000) },
      requestSignUp: true,
    });
    expect(response.status).toBe(200);
    expect(response.headers.get("location")).toBeNull();
    expect(await db().select().from(verification).all()).toHaveLength(0);
    const rows = await db().select().from(account).all();
    expect(rows[0]!.accessToken).toBeNull();
    expect(rows[0]!.refreshToken).toBeNull();
  });

  it("answers 404 for every other Better Auth endpoint, signed in or not, writing nothing", async () => {
    mockApple();
    const signedIn = await signIn(await idToken());
    const bearer = signedIn.headers.get("set-auth-token")!;
    const before = await rowCounts();
    const calls: [string, string, unknown?][] = [
      ["GET", "/api/auth/ok"],
      ["GET", "/api/auth/sign-in/social"],
      ["GET", "/api/auth/callback/apple?code=x&state=y"],
      ["POST", "/api/auth/callback/apple", "code=x&state=y"],
      ["POST", "/api/auth/link-social", { provider: "apple", idToken: { token: "a.b.c" } }],
      ["POST", "/api/auth/link-social", { provider: "apple" }],
      ["POST", "/api/auth/update-user", { name: "x".repeat(1000), image: "https://evil.example/x.png" }],
      ["POST", "/api/auth/sign-up/email", { email: "a@example.com", password: "password1234", name: "A" }],
      ["POST", "/api/auth/sign-in/email", { email: "a@example.com", password: "password1234" }],
      ["GET", "/api/auth/list-sessions"],
      ["POST", "/api/auth/revoke-sessions", {}],
      ["POST", "/api/auth/delete-user", {}],
      ["GET", "/api/auth/list-accounts"],
      ["POST", "/api/auth/unlink-account", { providerId: "apple" }],
      ["GET", "/api/auth/get-session/extra"],
      ["GET", "/api/auth/"],
      ["GET", "/api/auth"],
    ];
    for (const [method, path, body] of calls) {
      for (const headers of [{}, { authorization: `Bearer ${bearer}` }] as Record<string, string>[]) {
        const init: RequestInit = { method, headers: { ...headers, ...(body === undefined ? {} : { "content-type": typeof body === "string" ? "application/x-www-form-urlencoded" : "application/json" }) } };
        if (body !== undefined) init.body = typeof body === "string" ? body : JSON.stringify(body);
        const response = await app.request(`${BASE}${path}`, init, testEnv());
        expect(response.status, `${method} ${path}`).toBe(404);
        expect(await response.json()).toEqual(AUTH_NOT_FOUND);
      }
    }
    expect(await rowCounts()).toEqual(before);
  });

  it("routes on the exact path: other spellings are 404, and Better Auth only ever sees the fixed path", async () => {
    mockApple();
    const token = await idToken();
    const body = { provider: "apple", idToken: { token } };
    const before = await rowCounts();
    for (const path of ["/api/auth/sign-in/social/", "/api/auth//sign-in/social", "/api/auth/sign-in%2Fsocial", "/api/auth/sign-in/social;x"]) {
      const response = await post(path, body);
      expect(response.status, path).toBe(404);
      expect(await response.json()).toEqual(AUTH_NOT_FOUND);
    }
    expect(await rowCounts()).toEqual(before);
    // `%2D` is `-` by URL rules (an encoded unreserved character), so Hono
    // routes it to the sign-in handler, which forwards the fixed path: the plain sign-in.
    expect((await post("/api/auth/sign%2Din/social", body)).status).toBe(200);
    // A query string is dropped on the way to Better Auth: the plain sign-in happens.
    const withQuery = await post("/api/auth/sign-in/social?callbackURL=https://evil.example/&disableRedirect=false", body);
    expect(withQuery.status).toBe(200);
    expect(withQuery.headers.get("location")).toBeNull();
    const bearer = withQuery.headers.get("set-auth-token")!;
    const read = await app.request(`${BASE}/api/auth/get-session?disableCookieCache=true&disableRefresh=true`, { headers: { authorization: `Bearer ${bearer}` } }, testEnv());
    expect(read.status).toBe(200);
    expect(await read.json()).not.toBeNull();
  });

  it("refuses a body over 64 KB with the fixed 400 before it reaches Better Auth", async () => {
    const apple = mockApple();
    const before = await rowCounts();
    const response = await post("/api/auth/sign-in/social", { provider: "apple", idToken: { token: "x".repeat(70 * 1024) } });
    expect(response.status).toBe(400);
    expect(await response.json()).toEqual({ error: "invalid_request", message: "The request body is too large" });
    expect(apple.calls).toHaveLength(0);
    expect(await rowCounts()).toEqual(before);
  });

  it("sets no cookie: the sign-in answer carries set-auth-token and no Set-Cookie", async () => {
    mockApple();
    const response = await signIn(await idToken());
    expect(response.status).toBe(200);
    expect(response.headers.get("set-auth-token")).toBeTruthy();
    expect(response.headers.get("set-cookie")).toBeNull();
  });

  it("reads the session from the bearer token only: get-session ignores a cookie", async () => {
    mockApple();
    const signedIn = await signIn(await idToken());
    const bearer = signedIn.headers.get("set-auth-token")!;
    const userId = ((await signedIn.json()) as { user: { id: string } }).user.id;
    const withBearer = await app.request(`${BASE}/api/auth/get-session`, { headers: { authorization: `Bearer ${bearer}` } }, testEnv());
    expect(withBearer.status).toBe(200);
    expect(((await withBearer.json()) as { user: { id: string } }).user.id).toBe(userId);
    expect(withBearer.headers.get("set-cookie")).toBeNull();
    for (const name of ["better-auth.session_token", "__Secure-better-auth.session_token"]) {
      const withCookie = await app.request(`${BASE}/api/auth/get-session`, { headers: { cookie: `${name}=${encodeURIComponent(bearer)}` } }, testEnv());
      expect(await withCookie.json(), name).toBeNull();
    }
  });

  it("signs out with the bearer token even when the phone also sends a cookie and no Origin", async () => {
    mockApple();
    const signedIn = await signIn(await idToken());
    const bearer = signedIn.headers.get("set-auth-token")!;
    const out = await app.request(
      `${BASE}/api/auth/sign-out`,
      { method: "POST", headers: { authorization: `Bearer ${bearer}`, cookie: `__Secure-better-auth.session_token=${encodeURIComponent(bearer)}` } },
      testEnv(),
    );
    expect(out.status).toBe(200);
    expect(out.headers.get("set-cookie")).toBeNull();
    expect(await db().select().from(session).all()).toHaveLength(0);
  });
});

/** env.DB, except that a statement whose SQL matches `fail` throws, `times` times. */
function dbFailing(fail: RegExp, times = 1) {
  let left = times;
  const real = env.DB;
  return new Proxy(real, {
    get(target, prop) {
      if (prop === "prepare")
        return (sql: string) => {
          if (left > 0 && fail.test(sql)) {
            left--;
            throw new Error("D1 failed (test)");
          }
          return target.prepare(sql);
        };
      const value = Reflect.get(target, prop);
      return typeof value === "function" ? value.bind(target) : value;
    },
  });
}

const ACCOUNT_INSERT = /insert into "account"/i;

describe("a first sign-in cut off between the user and the account row", () => {
  it("D1 enforces the account's foreign key to user (the cleanup's safety rests on it)", async () => {
    await expect(
      env.DB.prepare("INSERT INTO account (id, account_id, provider_id, user_id, updated_at) VALUES ('a1', 'x', 'apple', 'no-such-user', 0)").run(),
    ).rejects.toThrow(/FOREIGN KEY/i);
  });

  it("does not lock the Apple ID out: the next valid sign-in succeeds", async () => {
    mockApple();
    const cut = await signIn(await idToken(), testEnv({ DB: dbFailing(ACCOUNT_INSERT) }));
    expect(cut.status).toBeGreaterThanOrEqual(400);
    // The half-made state: a user with this sub's account email and no account.
    expect(await db().select().from(user).all()).toHaveLength(1);
    expect(await db().select().from(account).all()).toHaveLength(0);

    const next = await signIn(await idToken());
    expect(next.status).toBe(200);
    const body = (await next.json()) as { user: { id: string } };
    const users = await db().select().from(user).all();
    expect(users).toHaveLength(1);
    expect(users[0]!.id).toBe(body.user.id);
    expect(users[0]!.email).toBe(accountEmail(SUB));
    expect(users[0]!.appleEmail).toBe(EMAIL);
    const accounts = await db().select().from(account).all();
    expect(accounts).toHaveLength(1);
    expect(accounts[0]!.userId).toBe(body.user.id);
  });

  it("a forged or refused token for that sub deletes nothing", async () => {
    mockApple();
    await signIn(await idToken(), testEnv({ DB: dbFailing(ACCOUNT_INSERT) }));
    const orphan = (await db().select().from(user).all())[0]!;
    for (const token of [
      await idToken(claims(), otherKey),
      await idToken(claims({ aud: "technology.artisan.other" })),
      await idToken(claims({ iat: nowSeconds() - 900, exp: nowSeconds() - 120 })),
      `${jsonToBase64url({ alg: "none", kid: KID })}.${jsonToBase64url(claims())}.`,
    ]) {
      expect((await signIn(token)).status).toBe(401);
      expect(await db().select().from(user).all()).toEqual([orphan]);
    }
  });

  it("never touches another sub's user, half-made or whole", async () => {
    mockApple();
    const OTHER = "005555.0123456789abcdef0123456789abcdef.0101";
    await signIn(await idToken(claims({ sub: OTHER })), testEnv({ DB: dbFailing(ACCOUNT_INSERT) }));
    const whole = await signIn(await idToken(claims({ sub: "007777.fedcba9876543210fedcba9876543210.0202" })));
    expect(whole.status).toBe(200);
    const wholeId = ((await whole.json()) as { user: { id: string } }).user.id;
    expect((await signIn(await idToken())).status).toBe(200);
    const emails = (await db().select().from(user).all()).map((row) => row.email).sort();
    expect(emails).toEqual([accountEmail(OTHER), accountEmail("007777.fedcba9876543210fedcba9876543210.0202"), accountEmail(SUB)].sort());
    expect((await db().select().from(user).where(eq(user.id, wholeId)).all())).toHaveLength(1);
  });

  it("never deletes a user that has an account row, so a returning user keeps the same id", async () => {
    mockApple();
    const first = await signIn(await idToken());
    const id = ((await first.json()) as { user: { id: string } }).user.id;
    for (let i = 0; i < 3; i++) {
      const again = await signIn(await idToken());
      expect(((await again.json()) as { user: { id: string } }).user.id).toBe(id);
    }
    expect(await db().select().from(user).all()).toHaveLength(1);
  });

  it("concurrent first sign-ins of one sub end with one user and one account, and the next sign-in works", async () => {
    mockApple();
    const answers = await Promise.all([1, 2, 3].map(async () => signIn(await idToken())));
    expect(answers.some((answer) => answer.status === 200)).toBe(true);
    const next = await signIn(await idToken());
    expect(next.status).toBe(200);
    const id = ((await next.json()) as { user: { id: string } }).user.id;
    const users = await db().select().from(user).all();
    expect(users.map((row) => row.id)).toEqual([id]);
    const accounts = await db().select().from(account).all();
    expect(accounts.map((row) => row.userId)).toEqual([id]);
  });
});

describe("limits and answers on /api/auth/*", () => {
  it("every answer says Cache-Control: no-store", async () => {
    mockApple();
    const signedIn = await signIn(await idToken());
    const bearer = signedIn.headers.get("set-auth-token")!;
    const answers = [
      signedIn,
      await signIn(await idToken(claims(), otherKey)),
      await post("/api/auth/sign-in/social", { provider: "apple" }),
      await app.request(`${BASE}/api/auth/get-session`, { headers: { authorization: `Bearer ${bearer}` } }, testEnv()),
      await app.request(`${BASE}/api/auth/ok`, {}, testEnv()),
      await app.request(`${BASE}/api/auth/sign-out`, { method: "POST", headers: { authorization: `Bearer ${bearer}` } }, testEnv()),
      await signIn(await idToken(), testEnv({ BETTER_AUTH_SECRET: undefined })),
    ];
    for (const answer of answers) expect(answer.headers.get("cache-control"), String(answer.status)).toBe("no-store");
  });

  it("refuses a token over 8192 characters and a nonce over 512 before Better Auth runs", async () => {
    const apple = mockApple();
    const before = await rowCounts();
    const good = await idToken();
    expect((await post("/api/auth/sign-in/social", { provider: "apple", idToken: { token: `${good}${"A".repeat(8193 - good.length)}` } })).status).toBe(400);
    expect((await post("/api/auth/sign-in/social", { provider: "apple", idToken: { token: good, nonce: "n".repeat(513) } })).status).toBe(400);
    expect((await post("/api/auth/sign-in/social", { provider: "apple", idToken: { token: good, nonce: "" } })).status).toBe(400);
    expect(apple.calls).toHaveLength(0);
    expect(await rowCounts()).toEqual(before);
    // At the limits it is accepted.
    const longNonce = "n".repeat(512);
    expect((await post("/api/auth/sign-in/social", { provider: "apple", idToken: { token: await idToken(claims({ nonce: longNonce })), nonce: longNonce } })).status).toBe(200);
  });

  it("drops idToken.user and every other extra field: the name and email Apple did not sign are not stored", async () => {
    mockApple();
    const response = await post("/api/auth/sign-in/social", {
      provider: "apple",
      idToken: { token: await idToken(), user: { name: { firstName: "Mallory", lastName: "Spoof" }, email: "mallory@example.com" }, expiresAt: 1 },
      name: "Mallory",
      email: "mallory@example.com",
      image: "https://evil.example/x.png",
    });
    expect(response.status).toBe(200);
    const users = await db().select().from(user).all();
    expect(users[0]!.name).toBe("");
    expect(users[0]!.image).toBeNull();
    expect(users[0]!.appleEmail).toBe(EMAIL);
    expect(JSON.stringify(users)).not.toContain("Mallory");
    expect(JSON.stringify(users)).not.toContain("mallory@");
  });

  it("stores at most 256 characters of the User-Agent", async () => {
    mockApple();
    const response = await app.request(
      `${BASE}/api/auth/sign-in/social`,
      { method: "POST", headers: { "content-type": "application/json", "user-agent": `Seasign/1 ${"x".repeat(60_000)}` }, body: JSON.stringify({ provider: "apple", idToken: { token: await idToken() } }) },
      testEnv(),
    );
    expect(response.status).toBe(200);
    const stored = (await db().select().from(session).all())[0]!.userAgent!;
    expect(stored.length).toBeLessThanOrEqual(256);
    expect(stored.startsWith("Seasign/1 ")).toBe(true);
  });
});

describe("requireSession", () => {
  async function signedIn() {
    mockApple();
    const response = await signIn(await idToken());
    expect(response.status).toBe(200);
    const body = (await response.json()) as { token: string; user: { id: string } };
    return { bearer: response.headers.get("set-auth-token")!, rawToken: body.token, userId: body.user.id };
  }

  it("passes the user ID of the bearer token's session to the route", async () => {
    const { bearer, userId } = await signedIn();
    const response = await askProbe({ authorization: `Bearer ${bearer}` });
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ userId });
  });

  it("refuses the bare session token from the sign-in body: only the signed set-auth-token value counts", async () => {
    const { rawToken, bearer } = await signedIn();
    expect(bearer.startsWith(`${rawToken}.`)).toBe(true);
    const response = await askProbe({ authorization: `Bearer ${rawToken}` });
    expect(response.status).toBe(401);
    expect(await response.json()).toEqual(UNAUTHORIZED);
  });

  it("answers 401 without an Authorization header", async () => {
    const response = await askProbe();
    expect(response.status).toBe(401);
    expect(await response.json()).toEqual(UNAUTHORIZED);
  });

  it("answers 401 for a token that is not a session", async () => {
    await signedIn();
    for (const value of ["Bearer not-a-session", "Bearer ", "Basic dXNlcjpwYXNz", "Bearer a.b", "bearer x.y.z"]) {
      const response = await askProbe({ authorization: value });
      expect(response.status, value).toBe(401);
      expect(await response.json()).toEqual(UNAUTHORIZED);
    }
  });

  it("answers 401 for a session token with a forged signature", async () => {
    const { bearer } = await signedIn();
    const [token] = bearer.split(".");
    const response = await askProbe({ authorization: `Bearer ${token}.${"A".repeat(43)}` });
    expect(response.status).toBe(401);
  });

  it("answers 401 for a session that has expired", async () => {
    const { bearer, userId } = await signedIn();
    await db().update(session).set({ expiresAt: new Date(Date.now() - 60_000) }).where(eq(session.userId, userId));
    const response = await askProbe({ authorization: `Bearer ${bearer}` });
    expect(response.status).toBe(401);
  });

  it("answers 401 for a session that was deleted on the server", async () => {
    const { bearer, userId } = await signedIn();
    await db().delete(session).where(eq(session.userId, userId));
    const response = await askProbe({ authorization: `Bearer ${bearer}` });
    expect(response.status).toBe(401);
  });

  it("answers 401 after the phone signs out with its bearer token", async () => {
    const { bearer } = await signedIn();
    const out = await app.request(`${BASE}/api/auth/sign-out`, { method: "POST", headers: { authorization: `Bearer ${bearer}` } }, testEnv());
    expect(out.status).toBe(200);
    expect(await db().select().from(session).all()).toHaveLength(0);
    const response = await askProbe({ authorization: `Bearer ${bearer}` });
    expect(response.status).toBe(401);
  });

  it("does not accept the session as a cookie: only the Authorization header counts", async () => {
    const { bearer } = await signedIn();
    for (const name of ["better-auth.session_token", "__Secure-better-auth.session_token"]) {
      const response = await askProbe({ cookie: `${name}=${encodeURIComponent(bearer)}` });
      expect(response.status, name).toBe(401);
    }
  });

  it("answers 503 when the auth secret is not set", async () => {
    const { bearer } = await signedIn();
    const response = await askProbe({ authorization: `Bearer ${bearer}` }, testEnv({ BETTER_AUTH_SECRET: undefined }));
    expect(response.status).toBe(503);
    expect(await response.json()).toEqual(AUTH_UNAVAILABLE);
  });
});
