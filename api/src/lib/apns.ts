// Background pushes to the app through Apple Push Notification service, for
// the Google Calendar webhook (task 156). Plain fetch; the provider token is
// signed with WebCrypto. No package.
//
// Apple docs read on 2026-11-19:
// - Sending notification requests to APNs:
//   https://developer.apple.com/documentation/usernotifications/sending-notification-requests-to-apns
//   POST /3/device/<hex token> on api.sandbox.push.apple.com or
//   api.push.apple.com over HTTP/2; headers authorization (bearer <JWT>),
//   apns-topic (the bundle ID), apns-push-type, apns-priority, apns-expiration.
// - Establishing a token-based connection to APNs:
//   https://developer.apple.com/documentation/usernotifications/establishing-a-token-based-connection-to-apns
//   ES256 JWT, header {alg: ES256, kid: <Key ID>}, claims {iss: <Team ID>,
//   iat: <seconds>}. Refresh no more than once every 20 minutes and no less
//   than once every 60; an iat over an hour old is refused (403
//   ExpiredProviderToken). A key may be limited to sandbox or production.
// - Pushing background updates to your app:
//   https://developer.apple.com/documentation/usernotifications/pushing-background-updates-to-your-app
//   payload {"aps": {"content-available": 1}} plus custom keys; apns-push-type
//   background and apns-priority 5; "don't try to send more than two or three
//   per hour" (the system throttles).
// - Handling notification responses from APNs:
//   https://developer.apple.com/documentation/usernotifications/handling-notification-responses-from-apns
//   200 success; 410 Unregistered / ExpiredToken; 400 BadDeviceToken (token
//   invalid or for the other environment), DeviceTokenNotForTopic; do not retry
//   those. Errors carry {"reason": "..."}.
//
// The secrets (APNS_KEY, APNS_KEY_ID, APNS_TEAM_ID) never appear in a log line,
// an error or a return value; neither does the device token.

export const APNS_HOSTS = {
  sandbox: "https://api.sandbox.push.apple.com",
  production: "https://api.push.apple.com",
} as const;

export type ApnsEnvironment = keyof typeof APNS_HOSTS;

/** Time allowed for one push, connection included. The webhook waits for it. */
export const APNS_TIMEOUT_MS = 3000;
/** The deadline in use. Only the tests change it. */
export const apnsDeadline = { ms: APNS_TIMEOUT_MS };
/** A provider token is reused for this long: inside Apple's 20 to 60 minute window. */
export const PROVIDER_TOKEN_TTL_MS = 40 * 60 * 1000;
/** The largest APNs error body read; it only carries a reason string. */
const ERROR_MAX_BYTES = 4096;

/** The fixed payload: wake the app, say why, nothing about the user or the calendar. */
export const PUSH_PAYLOAD = JSON.stringify({ aps: { "content-available": 1 }, type: "calendar-changed" });

export type PushOutcome =
  /** APNs accepted the push. */
  | "sent"
  /** The secrets or the bundle ID are missing. */
  | "not_configured"
  /** APNS_KEY is present but is not a P-256 PKCS#8 key. */
  | "bad_key"
  /** The device token is no longer valid for this app (410, BadDeviceToken, DeviceTokenNotForTopic): forget it. */
  | "unregistered"
  /** APNs refused our provider token (403): a key, key ID or team problem, or a key for the other environment. */
  | "auth_failed"
  /** Too many pushes to this device (429). */
  | "throttled"
  /** Unreachable, timed out, 5xx or any other answer. */
  | "failed";

export type ApnsConfig = {
  key: string;
  keyId: string;
  teamId: string;
  topic: string;
};

/** The APNs settings from the environment, or null when any is missing or empty. */
export function apnsConfig(env: Partial<CloudflareBindings> | undefined): ApnsConfig | null {
  const key = env?.APNS_KEY;
  const keyId = env?.APNS_KEY_ID;
  const teamId = env?.APNS_TEAM_ID;
  const topic = env?.APPLE_APP_BUNDLE_ID;
  if (typeof key !== "string" || typeof keyId !== "string" || typeof teamId !== "string" || typeof topic !== "string") return null;
  if (!key.trim() || !keyId.trim() || !teamId.trim() || !topic.trim()) return null;
  return { key, keyId: keyId.trim(), teamId: teamId.trim(), topic: topic.trim() };
}

// ───────────────────────── provider token ─────────────────────────

const base64url = (bytes: Uint8Array) => {
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
};
const base64urlText = (text: string) => base64url(new TextEncoder().encode(text));

/**
 * The DER bytes of a PKCS#8 PEM. Accepts the text as Apple ships it, with
 * Windows line ends, with literal "\n" sequences (a key pasted through a shell
 * on one line) or with the armour left out. Null when it is not base64.
 */
export function pemBytes(pem: string): Uint8Array | null {
  const body = pem
    .replace(/\\n/g, "\n")
    .replace(/-----BEGIN [A-Z ]+-----/g, "")
    .replace(/-----END [A-Z ]+-----/g, "")
    .replace(/\s+/g, "");
  if (!body || !/^[A-Za-z0-9+/]+={0,2}$/.test(body)) return null;
  try {
    const binary = atob(body);
    const bytes = new Uint8Array(binary.length);
    for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
    return bytes;
  } catch {
    return null;
  }
}

type CachedToken = { cacheKey: string; token: string; madeAt: number };
let cachedToken: CachedToken | null = null;
let cachedKey: { source: string; key: CryptoKey } | null = null;

/** For the tests: forget the cached provider token and key. */
export function resetApnsCache(): void {
  cachedToken = null;
  cachedKey = null;
}

/** Thrown inside this module only; turned into a PushOutcome. */
class BadKey extends Error {}

async function signingKey(pem: string): Promise<CryptoKey> {
  if (cachedKey && cachedKey.source === pem) return cachedKey.key;
  const der = pemBytes(pem);
  if (!der) throw new BadKey();
  let key: CryptoKey;
  try {
    key = await crypto.subtle.importKey("pkcs8", der, { name: "ECDSA", namedCurve: "P-256" }, false, ["sign"]);
  } catch {
    throw new BadKey();
  }
  cachedKey = { source: pem, key };
  return key;
}

/**
 * The ES256 provider token, made at most once per PROVIDER_TOKEN_TTL_MS for
 * the same key, key ID and team. WebCrypto's ECDSA signature is already the
 * 64-byte r||s form a JWS needs.
 */
export async function providerToken(config: ApnsConfig, now = Date.now()): Promise<string> {
  const cacheKey = `${config.keyId}\u0000${config.teamId}\u0000${config.key}`;
  if (cachedToken && cachedToken.cacheKey === cacheKey && now - cachedToken.madeAt < PROVIDER_TOKEN_TTL_MS && now >= cachedToken.madeAt) {
    return cachedToken.token;
  }
  const key = await signingKey(config.key);
  const header = base64urlText(JSON.stringify({ alg: "ES256", kid: config.keyId }));
  const claims = base64urlText(JSON.stringify({ iss: config.teamId, iat: Math.floor(now / 1000) }));
  const input = `${header}.${claims}`;
  let signature: ArrayBuffer;
  try {
    signature = await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, key, new TextEncoder().encode(input));
  } catch {
    throw new BadKey();
  }
  const token = `${input}.${base64url(new Uint8Array(signature))}`;
  cachedToken = { cacheKey, token, madeAt: now };
  return token;
}

// ───────────────────────── sending ─────────────────────────

const UNREGISTERED_REASONS = new Set(["BadDeviceToken", "DeviceTokenNotForTopic", "Unregistered", "ExpiredToken"]);

async function readReason(response: Response): Promise<string | null> {
  try {
    const declared = Number(response.headers.get("content-length"));
    if (Number.isFinite(declared) && declared > ERROR_MAX_BYTES) {
      void response.body?.cancel().catch(() => {});
      return null;
    }
    const text = await response.text();
    if (text.length > ERROR_MAX_BYTES) return null;
    const body: unknown = JSON.parse(text);
    if (typeof body === "object" && body !== null && typeof (body as { reason?: unknown }).reason === "string") return (body as { reason: string }).reason;
  } catch {
    // Unreadable: classed by status alone.
  }
  return null;
}

/**
 * Sends one background push to `deviceToken` (lowercase hex) on the given
 * environment's host. Never throws; never logs.
 */
export async function sendBackgroundPush(
  env: Partial<CloudflareBindings> | undefined,
  deviceToken: string,
  environment: ApnsEnvironment,
): Promise<PushOutcome> {
  const config = apnsConfig(env);
  if (!config) return "not_configured";
  if (!/^[0-9a-f]+$/.test(deviceToken)) return "unregistered";

  // One deadline for the push and its one resend, so the webhook still answers within it.
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), apnsDeadline.ms);
  try {
    let token: string;
    try {
      token = await providerToken(config);
    } catch {
      return "bad_key";
    }
    let answer = await attempt(config, token, deviceToken, environment, controller.signal);
    if (answer.status === 403 && answer.reason === "ExpiredProviderToken") {
      // A stale token (an isolate clock or cache gone wrong): drop it and send
      // this push once more with a fresh one. Only once: a fresh token refused
      // as expired again is reported, not retried. Any other 403 (a wrong key
      // or team) keeps the token and is not resent, since remaking it on every
      // push would earn 429 TooManyProviderTokenUpdates on top.
      cachedToken = null;
      try {
        token = await providerToken(config);
      } catch {
        return "bad_key";
      }
      answer = await attempt(config, token, deviceToken, environment, controller.signal);
    }
    return outcomeOf(answer);
  } catch {
    return "failed";
  } finally {
    clearTimeout(timer);
  }
}

type ApnsAnswer = { status: number; reason: string | null };

/** One POST to APNs. Throws when it is unreachable or the deadline passes. */
async function attempt(config: ApnsConfig, token: string, deviceToken: string, environment: ApnsEnvironment, signal: AbortSignal): Promise<ApnsAnswer> {
  const response = await fetch(`${APNS_HOSTS[environment]}/3/device/${deviceToken}`, {
    method: "POST",
    headers: {
      authorization: `bearer ${token}`,
      "apns-topic": config.topic,
      "apns-push-type": "background",
      "apns-priority": "5",
      // Stored by APNs for up to an hour if the phone is offline; a later
      // change sends a fresh push anyway.
      "apns-expiration": String(Math.floor(Date.now() / 1000) + 3600),
      "content-type": "application/json",
    },
    body: PUSH_PAYLOAD,
    redirect: "manual",
    signal,
  });
  if (response.status === 200) {
    void response.body?.cancel().catch(() => {});
    return { status: 200, reason: null };
  }
  return { status: response.status, reason: await readReason(response) };
}

function outcomeOf({ status, reason }: ApnsAnswer): PushOutcome {
  if (status === 200) return "sent";
  if (status === 410) return "unregistered";
  if (status === 400 && reason !== null && UNREGISTERED_REASONS.has(reason)) return "unregistered";
  if (status === 403) return "auth_failed";
  if (status === 429) return "throttled";
  return "failed";
}
