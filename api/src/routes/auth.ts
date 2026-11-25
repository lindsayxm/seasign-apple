// The only way into Better Auth (task 13 rework, after the security review).
// Better Auth serves dozens of endpoints under /api/auth; the phone needs
// three, so only these reach it and everything else under /api/auth is a 404:
//
//   POST /api/auth/sign-in/social   { provider: "apple", idToken: { token, nonce? } }
//   GET  /api/auth/get-session      Authorization: Bearer <set-auth-token>
//   POST /api/auth/sign-out         Authorization: Bearer <set-auth-token>
//
// A sign-in without an ID token never reaches Better Auth, whose redirect flow
// would write a state row before failing. The body Better Auth sees is rebuilt
// from the provider, the token and the nonce alone, so nothing else the client
// sends (callbackURL, additionalData, tokens, a user name) gets in.
//
// Only Authorization, Content-Type and User-Agent are passed in, so a cookie
// never authenticates and never brings in Better Auth's origin check, and
// Set-Cookie is taken off every answer: the bearer token in `set-auth-token`
// is the one credential. The rate limit (RATE_LIMIT_AUTH) and the 64 KB body
// cap run before this, in src/app.ts.
//
// Not in the OpenAPI spec: these are Better Auth's own endpoints.
import { Hono, type Context } from "hono";
import { z } from "zod";
import { createAuth, recordAppleEmail } from "../auth.ts";
import { AUTH_UNAVAILABLE } from "../lib/session.ts";

type Env = { Bindings: CloudflareBindings };

/** The fixed answer for anything under /api/auth that is not one of the three calls. */
export const AUTH_NOT_FOUND = { error: "not_found" as const, message: "Not found" };

/** The fixed answer for a sign-in that is not an Apple ID token sent as JSON. */
export const AUTH_INVALID_REQUEST = {
  error: "invalid_request" as const,
  message: "Send a JSON body with provider \"apple\" and idToken.token, the identity token from Sign in with Apple",
};

/** Apple's identity tokens are about 1 KB; the cap only bounds what is parsed. */
const MAX_TOKEN_LENGTH = 8192;
const MAX_NONCE_LENGTH = 512;

const SignIn = z.object({
  provider: z.literal("apple"),
  idToken: z.object({
    token: z.string().min(1).max(MAX_TOKEN_LENGTH),
    nonce: z.string().min(1).max(MAX_NONCE_LENGTH).optional(),
  }),
});

const SIGN_IN = "/api/auth/sign-in/social";
const GET_SESSION = "/api/auth/get-session";
const SIGN_OUT = "/api/auth/sign-out";
type AllowedPath = typeof SIGN_IN | typeof GET_SESSION | typeof SIGN_OUT;

/** The request headers Better Auth may see. */
const PASSED_HEADERS = ["authorization", "content-type", "user-agent"] as const;

function headersFor(from: Request): Headers {
  const headers = new Headers();
  for (const name of PASSED_HEADERS) {
    const value = from.headers.get(name);
    if (value !== null) headers.set(name, value);
  }
  return headers;
}

/** Hands a rebuilt request to Better Auth and takes Set-Cookie off its answer. */
async function toBetterAuth(c: Context<Env>, init: { path: AllowedPath; method: "GET" | "POST"; body?: string }): Promise<Response> {
  const auth = createAuth(c.env);
  if (!auth) return c.json(AUTH_UNAVAILABLE, 503);
  const headers = headersFor(c.req.raw);
  if (init.body === undefined) headers.delete("content-type");
  else headers.set("content-type", "application/json");
  // The address Better Auth routes on is this origin plus a fixed path: the
  // caller's own spelling of the path and any query string never reach it.
  const url = new URL(init.path, c.req.url).toString();
  const answer = await auth.handler(new Request(url, { method: init.method, headers, body: init.body }));
  const response = new Response(answer.body, answer);
  response.headers.delete("set-cookie");
  return response;
}

export const authRoutes = new Hono<Env>();

authRoutes.post(SIGN_IN, async (c) => {
  const invalid = () => c.json(AUTH_INVALID_REQUEST, 400);
  if (!/^application\/json\b/i.test(c.req.header("content-type") ?? "")) return invalid();
  let parsed: z.infer<typeof SignIn>;
  try {
    const result = SignIn.safeParse(JSON.parse(await c.req.text()));
    if (!result.success) return invalid();
    parsed = result.data;
  } catch {
    return invalid();
  }
  const { token, nonce } = parsed.idToken;
  const body = JSON.stringify({ provider: "apple", idToken: nonce === undefined ? { token } : { token, nonce } });
  const response = await toBetterAuth(c, { path: SIGN_IN, method: "POST", body });
  // A 200 means Better Auth verified this token in this request.
  if (response.status === 200) await recordAppleEmail(c.env.DB, token);
  return response;
});

authRoutes.get(GET_SESSION, (c) => toBetterAuth(c, { path: GET_SESSION, method: "GET" }));

authRoutes.post(SIGN_OUT, (c) => toBetterAuth(c, { path: SIGN_OUT, method: "POST", body: "{}" }));

authRoutes.all("/api/auth", (c) => c.json(AUTH_NOT_FOUND, 404));
authRoutes.all("/api/auth/*", (c) => c.json(AUTH_NOT_FOUND, 404));
