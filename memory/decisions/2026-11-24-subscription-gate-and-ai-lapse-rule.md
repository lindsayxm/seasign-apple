# 2026-11-24: Settings behind an account plus subscription; no AI on a lapsed subscription

The user's decisions of 2026-11-24. The plan is `plans/2026-11-24-account-and-subscription.md` (draft until the user approves it).

- **HARD RULE: no AI features on a lapsed subscription, ever.** The user's words: "no AI features allowed on lapsed subscriptions ever - make this a hard rule you keep track of". When a subscription lapses the feed flips to list-only refreshes. This holds whether AI runs on the user's own provider key (as built) or on Seasign's keys (the user may change to that later). How to apply: every task that touches AI search, the Use My List / Let AI Search toggle, the display of AI-found items, `POST /v1/discover`, or the subscription state must keep this rule and have a test for it; a reviewer checks it. A subscription state that cannot be determined counts as not subscribed for AI.
- **Settings needs an account and a paid subscription, taken together.** Free download; prepopulated sites; the events box says "Add your calendar... ↑"; tapping settings shows "You need an account to update settings." with UPGRADE NOW. Account creation and subscribing happen in one flow, never one without the other.
- **The zip code is free.** A user without a subscription can change the zip code and nothing else in Settings.
- **Real emails are not required.** Collecting them could be useful; the lead's recommendation after research is Sign in with Apple only (the app always gets a real or relay address), with an optional opt-in email field possibly later.
- Tasks 13 and 14 keep their numbers but their "optional sign-in, app works signed out" design is replaced by the plan once approved.

Added later on 2026-11-24, the user's answers to the plan's first draft:

- **Prepopulated sites:** Hacker News `https://news.ycombinator.com/`, Wired Science `https://www.wired.com/category/science/`, Ars Technica Space `https://arstechnica.com/space/`.
- **Order of the upgrade:** whatever App Store reviewers like most. The plan uses purchase first, then Sign in with Apple. Confirmed by the user the same day: a person who pays and closes the sign-in keeps Settings on that phone.
- **Free zip code change:** a "Change zip code" row on the upgrade popup.
- **Price:** 2.99 a month, no free trial for now.
- **On lapse:** sync and the Google Calendar push pause, as well as AI being off.
- **The AI key in Settings:** further work on hold until the user decides how AI keys will be handled.
- **Real email collection:** skipped for now.
- **A new subscriber** starts with the same three sites and can remove them.
- **Starting list items:** "Go outside" on the Do list, "Concert tickets" on the Get list. On every fresh install, no subscription needed: they show what the lists are for.
- **Terms and privacy policy:** one page at `https://artisan.technology/seasign-terms`.

The user's answers of 2026-11-24 (evening), before phase A starts:

- **Saved articles that AI found stay visible on a lapsed subscription.** The user's reason: they have already been fetched, so keeping them visible costs nothing. Only Saved was asked about: AI-found items in the feed (Today, History) stop showing on lapse, as the plan says (the lead's reading; the user was told).
- **AI stops as soon as a renewal fails.** No grace period for AI: Apple's `inGracePeriod` and `inBillingRetryPeriod` both count as Lapsed. The user's reason: the subscription's price is there to cover API fees. Billing Grace Period stays off in App Store Connect.
- **Product ID:** `technology.artisan.seasign.monthly`.
- **What the hard rule is for (the user, 2026-11-24):** "the thing that matters is that we are not incurring any additional charges after a subscription has lapsed." Whether already-fetched AI headlines stay visible does not matter to the user; do what is easier. Chosen: the app's existing behaviour, which already hides AI-found feed items whenever AI search is not active (`FeedModel.showsAI`, set from `AISearchModel.isActive`), so a lapse hides them with no new code, and they come back on renewal while still cached. The test of the rule is that no request that costs money is sent for a lapsed subscription.
- **The stored list/AI choice is not rewritten by the subscription (lead, task 216, after review; the user was told).** AI is in effect only while the choice is Let AI Search and a fresh read says Subscribed; otherwise the feed is list-only and the toggle shows Use My List, locked. AI comes back by itself when the state is Subscribed again. Wording beside the toggle: "AI search needs a subscription." (free), "AI search is off because your subscription isn't active." (lapsed, including billing retry), "AI search waits until your subscription can be checked." (unknown).

Phase A as built (tasks 217 and 218, 2026-11-24). The lead's choices are marked; the user has been told and has not yet answered:

- **Read-only Settings for a lapsed subscriber (lead):** usable are the zip code, removing a followed site, removing a calendar link, Disconnect Google, Refresh headlines now, Restore and Manage subscription. Everything else is locked, including the HUD color (the user's rule: only the zip code changes without a subscription) and the whole AI section, Remove key included (the AI key section is on hold).
- **Free and Unknown get the popup only (lead):** no VIEW SETTINGS; the Unknown popup never offers UPGRADE NOW, so a paying customer is not pushed to buy twice. The price is always the product's own; with no product the popup says the App Store can't be reached.
- **Popup and read-only wording:** drafts in `UpgradeWords` (`ios/Seasign/Subscription/SettingsGate.swift`); only "You need an account to update settings." is the user's. Waiting for the user's approval.
- **Debug subscription state:** `-debugSubscription` and the Debug chips set the gate and Settings only, never AI search, a purchase or a restore. Until the product exists in App Store Connect the real read is Unknown, so AI search is off on the user's own Debug builds.
- **Starter content:** seeded once, when the user store file is first created; an existing install is never seeded; a reinstall is a fresh install. Titles are the user's names ("Hacker News", "Wired Science", "Ars Technica Space"); categories Tech, Science, Space (the implementer's choice, not confirmed by the user). Wired is stored in feed mode with `https://www.wired.com/feed/category/science/latest/rss`.
- **"Add your calendar... ↑":** shown when a zip is set and there is no calendar link, Google was never connected and there are no events; the zip prompt wins when there is no zip.
