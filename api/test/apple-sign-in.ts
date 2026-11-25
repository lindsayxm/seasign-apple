// A real bearer session for tests of routes behind requireSession (task 221),
// made the way the phone makes one: an Apple-shaped identity token posted to
// /api/auth/sign-in/social. Apple is never reached: the key list is answered
// by a stubbed fetch with the public half of an RSA key made here. The full
// sign-in tests live in test/auth.test.ts; this is only what other files need.
import { env } from "cloudflare:workers";
import { vi } from "vitest";
import { app } from "../src/app.ts";

const APPLE_KEYS = "https://appleid.apple.com/auth/keys";
const BUNDLE_ID = "technology.artisan.seasign";
const KID = "TESTKID221";
const BASE = "https://api.seasign.app";
const RSA = { name: "RSASSA-PKCS1-v1_5", modulusLength: 2048, publicExponent: new Uint8Array([1, 0, 1]), hash: "SHA-256" };

const bytesToBase64url = (bytes: ArrayBuffer | Uint8Array) =>
  btoa(String.fromCharCode(...new Uint8Array(bytes)))
    .replace(/\+/g, "-")
    .replace(/\//g, "_")
    .replace(/=+$/, "");
const jsonToBase64url = (value: unknown) => bytesToBase64url(new TextEncoder().encode(JSON.stringify(value)));

let keys: { privateKey: CryptoKey; publicJwk: Record<string, unknown> } | undefined;

async function signingKeys() {
  if (!keys) {
    const pair = (await crypto.subtle.generateKey(RSA, true, ["sign", "verify"])) as CryptoKeyPair;
    const jwk = (await crypto.subtle.exportKey("jwk", pair.publicKey)) as JsonWebKey;
    keys = { privateKey: pair.privateKey, publicJwk: { kty: "RSA", kid: KID, use: "sig", alg: "RS256", n: jwk.n, e: jwk.e } };
  }
  return keys;
}

/** Signs in as the Apple account `sub` and returns the bearer token and the user ID. Restores fetch afterwards. */
export async function signInAs(sub: string): Promise<{ bearer: string; userId: string }> {
  const { privateKey, publicJwk } = await signingKeys();
  const now = Math.floor(Date.now() / 1000);
  const input = `${jsonToBase64url({ alg: "RS256", kid: KID })}.${jsonToBase64url({ iss: "https://appleid.apple.com", aud: BUNDLE_ID, sub, iat: now, exp: now + 600 })}`;
  const signature = await crypto.subtle.sign("RSASSA-PKCS1-v1_5", privateKey, new TextEncoder().encode(input));
  const token = `${input}.${bytesToBase64url(signature)}`;
  const spy = vi.spyOn(globalThis, "fetch").mockImplementation(async (url, init) => {
    const request = new Request(url, init);
    if (request.url === APPLE_KEYS) return new Response(JSON.stringify({ keys: [publicJwk] }), { status: 200, headers: { "content-type": "application/json" } });
    return new Response("unexpected", { status: 500 });
  });
  try {
    const response = await app.request(
      `${BASE}/api/auth/sign-in/social`,
      { method: "POST", headers: { "content-type": "application/json", "user-agent": "Seasign/1 CFNetwork" }, body: JSON.stringify({ provider: "apple", idToken: { token } }) },
      env as unknown as CloudflareBindings,
    );
    if (response.status !== 200) throw new Error(`sign-in answered ${response.status}`);
    const body = (await response.json()) as { user: { id: string } };
    const bearer = response.headers.get("set-auth-token");
    if (!bearer) throw new Error("sign-in gave no set-auth-token");
    return { bearer, userId: body.user.id };
  } finally {
    spy.mockRestore();
  }
}
