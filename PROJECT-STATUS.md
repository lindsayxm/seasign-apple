# PROJECT STATUS

Append-only. One dated entry per development session, added at the end by the `session-wrap-up` skill. The newest entry is last; the next session starts from it. Earlier entries are never edited.

Entry format:

    ## YYYY-MM-DD — one-line summary

    - Done: what was finished, with task IDs
    - In flight: what is partly done
    - Next: what the next session should pick up first
    - Notes: blockers, open questions, links to plans/ or memory/

---

## 2026-11-15 — v1 planned; scaffold, sky, Today scene, calendar API and Do/Get done; feed API and calendar screen in review

- Done:
  - Planning: v1 plan agreed and saved as `plans/2026-11-15-v1-build.md`; product decisions in `memory/decisions/2026-11-15-v1-product-decisions.md`; `BUILD.md`, `AGENTS.md`, `memory/architecture.md` and the skills updated (#1). Board holds tasks 1–19.
  - #2 scaffold of `api/`, `openapi/`, `ios/`; identity comes from `app-identity.xcconfig` (test values `com.example.seasign`, empty team). #15 scaffold follow-ups. #16 API tests moved to `@cloudflare/vitest-plugin`.
  - #3 `GET /v1/sky` (zip → weather, sun, moon via Open-Meteo).
  - #4 design system, Today screen and living scene, zip in Settings. #17 polish from its review (stale-cache rule, horizon crossing, two local stores, iPhone-only, VoiceOver labels).
  - #5 `POST /v1/calendar/events` with the shared `safeFetch` helper; three review rounds; ical.js now parses only.
  - #10 Do/Get list (device only).
  - Last verified state: API `npm test` 1,299 passed and `npx tsc --noEmit` clean (implementer, at `8b3b362`); iOS 149 tests passed on iPhone 16 / iOS 18.3.1 (lead, before the last spec change).
- In flight:
  - #7 `POST /v1/sites/resolve` and `POST /v1/feed`: in `review`. First review found unbounded parser memory and other issues; the rework is committed (`aa849b1`, `37cbee4`, `8b3b362`) but the second review has NOT been run, and the iOS build has not been rerun against the changed spec (`published` not nullable, `dateSource` two values, resolve returns `linkCount`).
  - #6 calendar links in Settings and next three events on Today: in `review`, criteria 2–4 ticked. Criterion 1 is open: the add-link path is proven only with stub responses; it needs a live check with a real calendar link pasted in the Simulator while `npx wrangler dev` runs in `api/`.
- Next:
  1. The user is changing the models used by the `implementer` and `reviewer` agents; confirm that is done before delegating.
  2. Second review of #7, then rerun `xcodebuild ... test` on both runtimes and close it.
  3. #8 (sites and categories in Settings, real headlines on Today, reading view), then #9; #11 (AI search API) can run alongside #8; then #12.
  4. #18 (calendar memory bound) and #19 (per-IP rate limiting) before any deploy.
- Notes:
  - The user is iterating on the design: keep visual polish and screenshot matching light on UI tasks; keep full review for logic, data safety and API security.
  - Open questions for the user: move calendar links from SwiftData to the Keychain (lead recommends yes); honour the phone's 24-hour setting for event times; keep or drop the carry-over of a calendar's events after a network failure; whether titles of private events should be hidden.
  - Nothing is deployed and no cloud resource exists. `/v1/feed` will need the Workers Paid plan. #13 and #14 wait on the Apple Developer account.
  - Build notes: `xcodebuild` needs `-skipPackagePluginValidation`, and `name=iPhone 16` needs `OS=18.3.1`; build per runtime. The `npx -y npm@11 install` row in the `AGENTS.md` CLI table overstates the problem: plain `npm install` worked for three package changes; correct that row with the next docs change.
  - The Mac's disk was nearly full during the session (about 30 GB free at last check). Session screenshots are under `/private/tmp` and will not survive a reboot.
  - Implementation decisions from this session: `memory/decisions/2026-11-15-build-decisions.md`.

## 2026-11-16 — every v1 screen and route built and reviewed; two live checks need the user; sign-in and sync wait on the Apple account

- Done:
  - #7 `POST /v1/sites/resolve` and `POST /v1/feed` closed after its final review round (bounded parser memory, text-run cap, 64 KB body cap).
  - #8 followed sites with categories in Settings, real headlines on Today, reading view. #9 7-day History (`>>`) and Saved (asterisk) with search, category filter and notes.
  - #11 `POST /v1/discover`: AI search through the user's own key, four provider adapters (Anthropic, OpenAI, Gemini, Perplexity). #12 AI settings, key in the Keychain, daily cap, blended and labelled feed. #21 hardening from the #12 review.
  - #18 and #22 calendar memory bounds (ical.js is handed only lines we have already counted; RDATE periods counted).
  - #19 per-client-IP rate limits on the open `/v1` routes with the Workers Rate Limiting binding (`ratelimits` in `api/wrangler.jsonc`). #24 the app handles the API's own 429 on discover, sky, calendar, sites and feed.
  - #23 event times follow the phone's 24-hour setting; AI headlines alternate with the user's own on Today ("every other").
  - #25 a fresh install starts with zip 60611 (Chicago); `SkyStore.defaultZip`, written only when the settings row is first created.
  - #20 criterion 1: discover review fixes L1–L6.
  - Config: lead session on Fable 5.2, `implementer` and `reviewer` on Opus 5.5 (`c628e56`).
  - Last verified state: API `npm test` 1,613 passed and `npx tsc --noEmit` clean; iOS 380 tests passed on iPhone 16 / iOS 18.3.1 and iPhone 17 / iOS 27.2 at `f922c70`. Working tree clean.
- In flight:
  - #6 (in `review`, 3 of 4 criteria): needs a live check with a real calendar link pasted by the user in the Simulator while `npx wrangler dev` runs in `api/`.
  - #20 (released to `todo`, 1 of 2 criteria): real-key smoke tests of the four providers. The user enters their own key in the Simulator; it is never given to the agent, logged or committed. Test Gemini first: its Interactions API may return no result URLs for a JSON-only answer (M1 in the task), in which case items must be matched to `url_citation` annotations.
- Next:
  1. With the user present: the #6 live calendar check, then the #20 smoke tests. Close both.
  2. Ask the user the two open questions under Notes, and create tasks from the answers.
  3. The user's design iteration on the Today scene and screens, when they bring changes.
  4. #13 and #14 (auth, D1 tables, sync, account deletion, Cron refresh) once the Apple Developer account is approved; then put the real bundle ID and team in `app-identity.xcconfig`.
- Notes:
  - Not verified anywhere: nothing is deployed and no cloud resource exists (D1 and KV IDs in `api/wrangler.jsonc` are placeholders). No AI search has run against a real provider. The rate limiter keys on `CF-Connecting-IP`, so it is unproven until deployed. The 24-hour switch was tested in unit tests, not on a device. The Chicago default was not seen on screen, because both simulators already hold a saved zip; delete the app from a simulator to see it.
  - Before any deploy (ask the user first): Workers Paid plan (needed by `/v1/feed`), pricing of the rate-limit binding, a burst test after deploy, and a check that logs never record `X-LLM-Key` or calendar links. See `memory/decisions/2026-11-16-rate-limits-and-deploy-limits.md`.
  - Open questions for the user: move calendar links from SwiftData to the Keychain (lead recommends yes, a link is a credential); whether titles of private events should be hidden. The `/statusline` setup from the first session was never chosen.
  - The user is still iterating on the design: keep visual polish and screenshot matching light on UI tasks; keep full review for logic, data safety and API security.
  - #25 was implemented and closed by the lead without a separate reviewer (one line of behaviour plus three tests).
  - Still to correct: the `npx -y npm@11 install` row in the `AGENTS.md` CLI table overstates the problem; plain `npm install` has worked.
  - Test output: filter `xcodebuild` output with `^✘ Test |^\*\* TEST|^✔ Test run`; the `LocalStore` tests print CoreData "error" lines that are not failures.
  - The Mac's disk is nearly full; builds use the default DerivedData.
  - User decisions from this session: `memory/decisions/2026-11-16-user-decisions.md`.

## 2026-11-16 (later) — calendar live check passed; six look-only design versions in `design-ideas/`, v6 being refined

- Done:
  - #6 closed: the user pasted a real Google secret iCal link in the Simulator against local `wrangler dev`; events loaded, and the link did not appear in the server log.
  - #26–#33: `design-ideas/` created (rules in `design-ideas/README.md`, row added to `AGENTS.md`), with `v1-original/` (12 Simulator screenshots and a web page of the current look), `v2-halo/`, `v3-cyclo/`, `v4-cartography/`, `v5-hud/`. Each has an animated `index.html`, twelve stills and a README. The user's references are in `design-ideas/ref-img/<same name>/`.
  - #34–#44: `v6-hud2/`, the version the user is refining: rotating portal ring, beams, swirling star dust, sun and moon on a low arc inside the ring, weather inside it, warm accents by day and cool at night, buttons in a column at the right.
  - No file under `ios/` or `api/` changed. Working tree clean at the wrap-up commit.
- In flight:
  - #20 (in `todo`, 1 of 2 criteria): real-key provider smoke tests, on hold because the user has no Gemini key yet.
  - v6 has no open task; the user is expected to bring more changes.
- Next:
  1. Continue v6 when the user returns. Read `memory/notes/2026-11-16-design-ideas.md` first: it lists what is settled, how stills are rendered, and the random-number pitfall.
  2. When the user picks a design, create tasks to build it in `ios/`; nothing from `design-ideas/` is in the app yet.
  3. #20 when the user has provider keys; #13 and #14 when the Apple Developer account is approved.
- Notes:
  - The agent cannot watch the mockup animations. Every motion change was checked by comparing still frames a few seconds apart, and speeds were set by number.
  - v6's soft-light pass uses the canvas `filter` property; browsers without it show a sharper picture.
  - Open questions for the user: should v6's beams follow the warm-by-day, cool-at-night rule; should v2–v4 get the app's real settings, list and saved symbols; move calendar links to the Keychain (lead recommends yes); hide titles of private events.
  - Tasks #34 and later were closed by the lead without a separate reviewer (look-only mockups). #34's acceptance line was not saved as a checkbox, so it shows done with none ticked.
  - The local API server started for the #6 check was stopped at wrap-up. The iPhone 17 simulator was last launched with a forced moonset scene; a normal relaunch restores the real sky.
  - Still to correct: the `npx -y npm@11 install` row in the `AGENTS.md` CLI table overstates the problem.
