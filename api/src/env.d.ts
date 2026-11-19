// Secrets the Worker reads, declared for the type checker only. No value is in
// the repository: the user sets each one at deploy with `wrangler secret put`
// (task 156; plan plans/2026-11-19-google-calendar-push.md, task D).
//
// They are optional on purpose. Without them the APNs sender reports "not
// configured" and the webhook still answers 200, so `wrangler dev` and the
// tests run without any secret. They are declared here rather than under
// `secrets.required` in wrangler.jsonc because that setting also changes what
// `wrangler dev` loads and makes `wrangler deploy` fail while one is missing;
// whether to adopt it is a deploy-time choice (task D).
interface CloudflareBindings {
  /** The APNs auth key: the PKCS#8 PEM text Apple gives as a download, BEGIN and END lines included. */
  APNS_KEY?: string;
  /** The key's 10-character Key ID from the Apple developer account. */
  APNS_KEY_ID?: string;
  /** The 10-character Apple Team ID that owns the key and the app. */
  APNS_TEAM_ID?: string;
}
