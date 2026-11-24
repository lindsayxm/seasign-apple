# Account and subscription: the gate on Settings

Date: 2026-11-24. Owner: lead session. Status: third draft, with all of the user's answers of 2026-11-24 worked in. No implementation until the user says to start. Replaces the design of tasks 13 and 14 (optional free sign-in and sync) in `plans/2026-11-15-v1-build.md`; nothing is built yet.

## What the user asked for (2026-11-24)

- The app is free to download and ships with some prepopulated sites in the publication feed.
- With no calendar, the calendar box says "Add your calendar... ↑", the arrow pointing at the settings button.
- Tapping settings shows a popup: "You need an account to update settings." and under it an UPGRADE NOW button.
- Upgrading creates the account and starts a subscription in one flow. Never one without the other.
- The zip code can be changed without a subscription. Nothing else in Settings can.
- **Hard rule: no AI features on a lapsed subscription, ever.** When a subscription lapses the feed flips to list-only refreshes. The user may later run AI search on their own provider keys, so the user's key in Settings may go away; the rule holds either way.
- Real email addresses are not needed, but collecting them could be useful.

## The user's answers to the first draft (2026-11-24)

| question | answer |
|---|---|
| The three states | Correct as written |
| Prepopulated sites | Hacker News `https://news.ycombinator.com/`, Wired Science `https://www.wired.com/category/science/`, Ars Technica Space `https://arstechnica.com/space/` |
| Order of sign-in and purchase | Whatever App Store reviewers like most; purchase first, then sign-in, is fine |
| Free zip code change | A "Change zip code" row on the popup |
| Price | 2.99 a month. No free trial now; one may be added later |
| On lapse | Sync and the Google Calendar push pause (AI off was already the hard rule) |
| The AI key in Settings | Hold further work on it until the user decides how AI keys will be handled |
| Collecting real emails | Skipped for now |
| Paid but not signed in | Confirmed: the purchase-first flow as written, Settings stays open on that phone |
| A new subscriber's sites | The same three, removable |
| Starting list items | "Go outside" on the Do list and "Concert tickets" on the Get list |
| Terms and privacy policy | One page: `https://artisan.technology/seasign-terms` |

## What the research found

Sources: Apple's App Review Guidelines (page dated 2026-10-16; sections 3.1 onward were read through a summarising fetch, so the wording below must be checked on the live page before it is quoted to Apple), Apple's Sign in with Apple documentation (read in full), and Apple's support page on managing Sign in with Apple.

### Email through Sign in with Apple

- The app can ask for the email. The person chooses between sharing their real address and hiding it. If they hide it, the app gets a private relay address instead.
- Mail sent to a relay address is forwarded to one of the person's verified addresses, so it still reaches them. To send it we must register our sending domain with Apple and pass SPF. Each relay address takes at most 100 emails a day.
- The person can turn forwarding off at any time; after that Apple rejects our mail to that address. The setting covers every app from our team.
- The email is in the identity token on every sign-in, so the server can always read it. The name comes only the first time.
- Not confirmed from Apple's pages: whether a person can decline to give any address at all. As far as the lead knows the choice is only share or hide, so some address always arrives.
- The guidelines allow asking for contact details as an extra, but only if it is optional: "features and services are not conditional on providing the information" (5.1.1(x), from the summary). Using an address for marketing needs the person's permission (5.1.2(i)).

Decided: Sign in with Apple is the only sign-in. Every account then has a working address (real or relay) with no password system and no verification mail to build. Real email collection is skipped for now; an optional "email for news from Seasign" field with a clear opt-in could be added later without changing the account design. No separate email-and-password system: it would add an email-sending service, and offering any other sign-in beside it would bring guideline 4.8 into play.

### Review risk

| point | what the guidelines say | where this design stands |
|---|---|---|
| Paying | Unlocking features in the app must use in-app purchase (3.1.1) | The subscription is an in-app purchase. No other way to pay |
| Value | A subscription must give ongoing value; describe what the person gets before asking (3.1.2) | Ongoing: own sites, calendars, AI search, sync across devices. The upgrade popup lists these with the price, 2.99 a month |
| Restore | A restore mechanism is expected for restorable purchases (3.1.1) | Restore Purchases on the popup and in Settings |
| Login | "If your app doesn't include significant account-based features, let people use it without a login" (5.1.1(v)) | The free app needs no login. The account carries sync and the subscription across devices, which is account-based |
| Deleting | An app with account creation must offer account deletion in the app (5.1.1(v)) | In Settings. It must say that deleting the account does not cancel the subscription, and link to Apple's subscription page |
| Login services | 4.8 applies when a third-party login is used | Not triggered with Sign in with Apple alone |

The one real risk: reviewers have rejected apps that make people register with personal details before they can buy something that does not need an account. This comes from the lead's knowledge of review practice; the summary found no sentence in the guidelines that forbids it. The user chose the order reviewers are least likely to object to, so the plan now uses it from the start: **purchase first, then sign-in** (see "The upgrade flow"). Nobody has to hand over personal details before paying, and the account is asked for where it is needed: sync and the server's subscription check. With that order the risk is low.

Also to settle before submission, not now: App Store privacy labels for the email and the account, and the wording of the subscription terms on the popup (price, period, renewal, links to terms and privacy policy).

## The three states

| state | how the app knows | Settings | feed | sync |
|---|---|---|---|---|
| Free | no subscription ever | popup; zip code only | the three prepopulated sites, list refresh only | none |
| Subscribed | active subscription | everything | own sites; AI search allowed once signed in | on once signed in |
| Lapsed | had a subscription, now expired, refunded or revoked | read-only view of what they set up; zip code editable; popup to renew | their own sites, list refresh only; **AI off** | paused; the Google Calendar push pauses too |

Subscribed has one sub-state, "account not finished": the person paid and closed the sign-in sheet. Settings is open on that phone; sync, the Google Calendar push and AI search wait for the sign-in, because the server cannot check a subscription without an account. Settings shows a "Finish setting up your account" row at the top until they sign in.

On lapse the Google events still show: the app goes on checking Google itself while it is open; only the server's push is paused.

## The upgrade flow

1. Settings is tapped by a Free or Lapsed user. The popup shows "You need an account to update settings.", what the subscription includes, "2.99 a month" with the renewal terms and links to the terms and the privacy policy, UPGRADE NOW, Restore Purchases, and a "Change zip code" row.
2. UPGRADE NOW opens Apple's purchase sheet. If it is cancelled or fails, nothing changes.
3. When the purchase succeeds, Settings unlocks and the Sign in with Apple sheet opens straight away, with one line saying the account keeps their settings on all their devices.
4. Signing in creates the account on the server, ties the purchase to it, uploads the phone's data and starts sync.
5. Closing the sign-in sheet leaves the "account not finished" state above.

The user's first wording was that account and subscription cannot be had one without the other. This flow keeps half of that strictly: there is never an account without a subscription. The other half is softened for review's sake: a person who pays and refuses to sign in keeps what they paid for on that phone. Confirmed by the user on 2026-11-24.

The popup's terms and privacy links both go to `https://artisan.technology/seasign-terms`. The page must exist and cover both before submission; App Store Connect also asks for a privacy policy address.

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
3. The settings popup as in "The upgrade flow": UPGRADE NOW, 2.99 a month and what is included, Restore Purchases, and the "Change zip code" row.
4. The three prepopulated sites on a fresh install, each first checked through the API's site resolver (feed found, headlines come back); a Free user's feed refreshes from them like anyone's, and the API already caches each site for everyone. "Add your calendar... ↑" in the events box. A new subscriber keeps the same three and can remove them.
5. Starting list items on a fresh install: "Go outside" on the Do list and "Concert tickets" on the Get list. The lists are not behind the gate, so the lead reads this as every fresh install, Free included, and the items can be ticked and cleared like any other (to confirm). Seeded once, when the store is first created, like the default zip; never put back after the user removes them.
6. Settings read-only when Lapsed.
7. The AI rule's gate is built. Nothing else about the AI key or its Settings section changes: that work is on hold by the user's decision.

In this phase UPGRADE NOW runs the purchase only; the Apple sign-in joins it in phase C. Nothing ships between the phases.

### Phase B: accounts in the API

1. Better Auth with Sign in with Apple, as the stack already names. The email from the identity token is stored at first sign-in.
2. An entitlement record per account, fed by Apple's App Store Server Notifications and checked against Apple's signed transaction data. The purchase carries the account's ID, so the server can tie them together.
3. The sync tables and routes from the v1 plan (settings, calendar links, sites, saved items, list items), each query scoped by the session's user ID, and refused without an active entitlement.
4. `DELETE /v1/account`.
5. `POST /v1/discover` requires an active entitlement.
6. The Cron morning refresh from the v1 plan, for subscribed accounts only.

### Phase C: the joined flow in the app

1. The Sign in with Apple sheet straight after a successful purchase, the "account not finished" state and its row in Settings.
2. First upload of the phone's data, then sync both ways. Sync and the Google Calendar push pause on lapse and resume on renewal.
3. Account deletion in Settings, with the note about the subscription.
4. A second device: sign in, restore, data arrives.

### Phase D: only the user can do these

- App Store Connect: the Paid Apps agreement, banking and tax, the subscription group and a monthly product at 2.99 with no introductory offer.
- Approve adding the Sign in with Apple and In-App Purchase capabilities to the app (a signing change, asked for when phase C starts).
- Register the sending domain with Apple if mail to relay addresses is wanted.
- Publish the terms and privacy policy at `https://artisan.technology/seasign-terms`.

### Phase E: needs the deploy

Real purchases in the sandbox, Apple's notifications reaching the API, sign-in against the deployed API, sync between two devices. Until the deploy, phases B and C are proven with tests and local runs only.

## Still open for the user

1. **Starting list items for Free users.** The plan seeds "Go outside" and "Concert tickets" on every fresh install, since the lists are free to use. Say if they should appear only after subscribing.
2. **The AI key** (on hold): how AI keys will be handled. Until then the plan only adds the gate.
3. **A free trial** later: adding one is an App Store Connect change plus one line on the popup.

## Not in this plan

The deploy itself (task 157), Android, family sharing, promotional offers, and any web sign-up.
