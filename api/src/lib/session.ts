// The one way a route learns who is signed in (task 13). Later routes that
// read or write user data (sync, entitlements, account deletion: tasks 221 to
// 225) put `requireSession` in front and scope every D1 query by
// `c.get("userId")`, never by anything the client sends.
//
// Only `Authorization: Bearer <token>` counts, the token being the
// `set-auth-token` value from sign-in. Cookies are ignored: the phone never
// sends one, and refusing them keeps the /v1 routes free of cross-site
// request forgery.
import { createMiddleware } from "hono/factory";
import { createAuth } from "../auth.ts";

/** What requireSession puts on the context. */
export type SessionVariables = { userId: string };

/** The fixed answer without a valid session. Routes behind requireSession declare it as their 401. */
export const UNAUTHORIZED = { error: "unauthorized" as const, message: "Sign in again" };

/** The fixed answer while the server has no auth secret. */
export const AUTH_UNAVAILABLE = { error: "auth_unavailable" as const, message: "Accounts are not set up on this server" };

export const requireSession = createMiddleware<{ Bindings: CloudflareBindings; Variables: SessionVariables }>(async (c, next) => {
  const auth = createAuth(c.env);
  if (!auth) return c.json(AUTH_UNAVAILABLE, 503);
  const authorization = c.req.header("authorization");
  if (!authorization) return c.json(UNAUTHORIZED, 401);
  // Only the Authorization header is handed on, so no cookie can stand in for it.
  const found = await auth.api.getSession({ headers: new Headers({ authorization }) });
  if (!found) return c.json(UNAUTHORIZED, 401);
  c.set("userId", found.user.id);
  await next();
});
