# Account and subscription: the gate on Settings

Date: 2026-11-24. Owner: lead session. Status: draft for the user's approval. Replaces the design of tasks 13 and 14 (optional free sign-in and sync) in `plans/2026-11-15-v1-build.md`; nothing is built yet.

## What the user asked for (2026-11-24)

- The app is free to download and ships with some prepopulated sites in the publication feed.
- With no calendar, the calendar box says "Add your calendar... ↑", the arrow pointing at the settings button.
- Tapping settings shows a popup: "You need an account to update settings." and under it an UPGRADE NOW button.
- Upgrading creates the account and starts a subscription in one flow. Never one without the other.
- The zip code can be changed without a subscription. Nothing else in Settings can.
- **Hard rule: no AI features on a lapsed subscription, ever.** When a subscription lapses the feed flips to list-only refreshes. The user may later run AI search on their own provider keys, so the user's key in Settings may go away; the rule holds either way.
- Real email addresses are not needed, but collecting them could be useful.

## What the research found

Sources: Apple's App Review Guidelines (page dated 2026-10-16; sections 3.1 onward were read through a summarising fetch, so the wording below must be checked on the live page before it is quoted to Apple), Apple's Sign in with Apple documentation (read in full), and Apple's support page on managing Sign in with Apple.

### Email through Sign in with Apple

- The app can ask for the email. The person chooses between sharing their real address and hiding it. If they hide it, the app gets a private relay address instead.
- Mail sent to a relay address is forwarded to one of the person's verified addresses, so it still reaches them. To send it we must register our sending domain with Apple and pass SPF. Each relay address takes at most 100 emails a day.
- The person can turn forwarding off at any time; after that Apple rejects our mail to that address. The setting covers every app from our team.
- The email is in the identity token on every sign-in, so the server can always read it. The name comes only the first time.
- Not confirmed from Apple's pages: whether a person can decline to give any address at all. As far as the lead knows the choice is only share or hide, so some address always arrives.
- The guidelines allow asking for contact details as an extra, but only if it is optional: "features and services are not conditional on providing the information" (5.1.1(x), from the summary). Using an address for marketing needs the person's permission (5.1.2(i)).

Recommendation: Sign in with Apple is the only sign-in. Every account then has a working address (real or relay) with no password system and no verification mail to build. If real addresses matter later, add an optional "email for news from Seasign" field with a clear opt-in after the upgrade. Do not build a separate email-and-password system: it adds an email-sending service, and offering any other sign-in beside it would bring guideline 4.8 into play.

### Review risk

| point | what the guidelines say | where this design stands |
|---|---|---|
| Paying | Unlocking features in the app must use in-app purchase (3.1.1) | The subscription is an in-app purchase. No other way to pay |
| Value | A subscription must give ongoing value; describe what the person gets before asking (3.1.2) | Ongoing: own sites, calendars, AI search, sync across devices. The upgrade popup has to list these with the price |
| Restore | A restore mechanism is expected for restorable purchases (3.1.1) | Restore Purchases on the popup and in Settings |
| Login | "If your app doesn't include significant account-based features, let people use it without a login" (5.1.1(v)) | The free app needs no login. The account carries sync and the subscription across devices, which is account-based |
| Deleting | An app with account creation must offer account deletion in the app (5.1.1(v)) | In Settings. It must say that deleting the account does not cancel the subscription, and link to Apple's subscription page |
| Login services | 4.8 applies when a third-party login is used | Not triggered with Sign in with Apple alone |

The one real risk: reviewers have rejected apps that make people register with personal details before they can buy something that does not need an account. This comes from the lead's knowledge of review practice; the summary found no sentence in the guidelines that forbids it. This design is on the safer side because the subscription is account-based (sync, and later server-side AI) and Sign in with Apple lets the person hide their email. Risk: moderate, not high. If a reviewer objects, the fallback is small: let the purchase go through first and make the Apple sign-in the next, skippable step, with sync starting when they sign in. The build below keeps purchase and account as separate parts so that fallback is a change of order, not a rebuild.

Also to settle before submission, not now: App Store privacy labels for the email and the account, and the wording of the subscription terms on the popup (price, period, renewal, links to terms and privacy policy).

## The three states

| state | how the app knows | Settings | feed | sync |
|---|---|---|---|---|
| Free | no subscription ever | popup; zip code only | prepopulated sites, list refresh only | none |
| Subscribed | active subscription and signed in | everything | own sites; AI search allowed | on |
| Lapsed | had a subscription, now expired, refunded or revoked | read-only view of what they set up; zip code editable; popup to renew | their own sites, list refresh only; **AI off** | paused (open decision 4) |

### The hard rule in code

- One pure function decides whether AI may run. It takes the subscription state and answers no for anything but Subscribed. Every AI path goes through it: the automatic search, the manual search, the toggle in Settings, and the display of AI-found items already cached.
- On lapse the mode is set to Use My List and the toggle cannot move. Cached AI-found items stop showing.
- A state the app cannot determine (no network, StoreKit not answering) counts as not subscribed for AI. AI comes back when the state is known to be Subscribed.
- The API enforces it too once accounts exist: `POST /v1/discover` refuses a request without an active entitlement. This becomes essential the day AI runs on Seasign's own keys.
- Tests pin each of these, and a reviewer checks the rule on every later task that touches AI or the subscription state.

## What gets built

### Phase A: the gate, on the phone only (no server, no deploy)

1. Subscription state on the phone with StoreKit, tested with Xcode's local StoreKit test file: Free, Subscribed, Lapsed; purchase, restore, expiry, refund.
2. The AI rule above, with its tests.
3. The settings popup with UPGRADE NOW, the price and what is included, Restore Purchases, and the free zip code change (open decision 1).
4. Prepopulated sites for a fresh install (open decision 2), and "Add your calendar... ↑" in the events box.
5. Settings read-only when Lapsed.

In this phase UPGRADE NOW runs the purchase only; the Apple sign-in joins it in phase C. Nothing ships between the phases.

### Phase B: accounts in the API

1. Better Auth with Sign in with Apple, as the stack already names. The email from the identity token is stored at first sign-in.
2. An entitlement record per account, fed by Apple's App Store Server Notifications and checked against Apple's signed transaction data. The purchase carries the account's ID, so the server can tie them together.
3. The sync tables and routes from the v1 plan (settings, calendar links, sites, saved items, list items), each query scoped by the session's user ID, and refused without an active entitlement.
4. `DELETE /v1/account`.
5. `POST /v1/discover` requires an active entitlement.
6. The Cron morning refresh from the v1 plan, for subscribed accounts only.

### Phase C: the joined flow in the app

1. UPGRADE NOW: Sign in with Apple, then the purchase sheet, as one flow. If the purchase is cancelled or fails, no account is kept on the server and the app stays Free.
2. First upload of the phone's data, then sync both ways.
3. Account deletion in Settings, with the note about the subscription.
4. A second device: sign in, restore, data arrives.

### Phase D: only the user can do these

- App Store Connect: the Paid Apps agreement, banking and tax, the subscription group and product, price and period, any free trial.
- Approve adding the Sign in with Apple and In-App Purchase capabilities to the app (a signing change, asked for when phase C starts).
- Register the sending domain with Apple if mail to relay addresses is wanted.
- Privacy policy and terms pages the popup can link to.

### Phase E: needs the deploy

Real purchases in the sandbox, Apple's notifications reaching the API, sign-in against the deployed API, sync between two devices. Until the deploy, phases B and C are proven with tests and local runs only.

## Open decisions for the user

1. **Where the free zip code change lives.** The popup appears when settings is tapped, so the zip field needs a home. Recommended: a "Change zip code" row on the popup itself, under UPGRADE NOW.
2. **Which sites ship prepopulated**, and whether a free user's feed refreshes from them like anyone's (recommended: yes; the API already caches each site for everyone).
3. **Price, period and trial.** Needed for the popup's text and the App Store Connect product.
4. **What else stops on lapse.** Settled: AI stops. Recommended for the rest: their sites and calendars keep showing, read-only; sync and the Google Calendar push pause, since both cost server work.
5. **The user's own AI key in Settings.** Keep it for now and gate it by the subscription, or wait for the decision on Seasign's own keys before building any more around it.
6. **Collecting a real email.** Recommended: not at launch; the optional opt-in field can be added later without changing the account design.

## Not in this plan

The deploy itself (task 157), Android, family sharing, promotional offers, and any web sign-up.
