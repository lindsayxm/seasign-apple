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
- **Starting list items:** "Go outside" on the Do list, "Concert tickets" on the Get list.
- **Terms and privacy policy:** one page at `https://artisan.technology/seasign-terms`.
