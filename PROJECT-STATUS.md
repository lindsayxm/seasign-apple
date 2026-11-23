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

## 2026-11-17 — `design-ideas/v7-firmament/` built and refined over many rounds; landing page of all versions added

- Done:
  - #45–#97: `design-ideas/v7-firmament/`, made from v6 without the portal ring and beams, then refined step by step with the user. Open sky of slow stars, horizon at y 376, sun and moon on a low path and far larger at rise and set, day, sunrise and sunset sky gradients, reworked header (left-aligned with the clock, temperature only, 12-hour event times), serif article titles without numbers, flat buttons on a see-through panel, `∀` button for all publications, gulls once a minute. Twelve stills re-rendered at each step.
  - #98: `design-ideas/v0-version-landing-page/`: one page with a thumbnail per version (v1–v7) that opens it.
  - `design-ideas/README.md` lists v7 and the landing page. No file under `ios/` or `api/` changed. Working tree clean at the wrap-up commit.
- In flight:
  - #20 (in `todo`, 1 of 2 criteria): real-key provider smoke tests, still on hold until the user has provider keys.
  - v7 has no open task; the user is expected to bring more changes.
- Next:
  1. Continue v7 when the user returns. Read the 2026-11-17 section of `memory/notes/2026-11-16-design-ideas.md` and `design-ideas/v7-firmament/README.md` first: they list what is settled and what the user tried and rejected.
  2. When the user picks a design, create tasks to build it in `ios/`; nothing from `design-ideas/` is in the app yet.
  3. #20 when the user has provider keys; #13 and #14 when the Apple Developer account is approved.
- Notes:
  - The agent cannot watch the animations. Motion (stars, gulls, the sun's rippling line) was checked only by comparing frames at different times.
  - In v7 the drawn line of the sun and moon's path is switched off by the user's request to see the look without it (`?arc` shows it). The user has not said whether it stays off.
  - Open questions for the user: keep the path line off or bring it back; whether the fainter second ripple line round the sun stays; the 150 points now free below the last title (more titles or more spacing); the older ones (v6 beam colours, real symbols in v2–v4, calendar links to the Keychain, hiding private event titles).
  - The landing page's thumbnails are copies of each version's mid-day and mid-night stills and must be remade when a version's stills change.
  - The user added `left-justification.png` and `reading.png` to `design-ideas/v7-firmament/`; both were committed with the stills. `reading.png` has not been opened or used.
  - The headless-Chrome helper scripts are in the session scratchpad and will not survive; the notes file says how to rewrite them.
  - Tasks #45–#98 were closed by the lead without a separate reviewer (look-only mockups).
  - Still to correct: the `npx -y npm@11 install` row in the `AGENTS.md` CLI table overstates the problem.

## 2026-11-19 — Today design v11 built in the app; refresh rules; Google Calendar through sign-in started (API routes, app sign-in, notification API), nothing deployed

- Done:
  - #99–#144 (2026-11-18): look-only rounds `design-ideas/v8-lemuria/`, `v9-pangea/`, `v10-simplify/`, `v11-artemis/` and v7 tweaks. The user chose v11 for Today.
  - #145–#147: v11 built in `ios/` (scene, overlay, follow-ups). Spec: `plans/2026-11-18-today-v11.md`.
  - #148, #149: the rise/set tag removed, wind line always shown, no AI mark on Today titles; v11 mockup, four stills and the plan updated to match (`memory/decisions/2026-11-19-today-no-tag-no-ai-mark.md`).
  - #150–#152: calendar links cached 1 minute (was 15) and refreshed by the app every minute (was 10); sky cached 5 minutes (was 15); pull down above the horizon refreshes events and sky, pull down on the sea or titles refreshes headlines, each with its own spinner.
  - #153, #155: `GET /v1/google/calendars` and `POST /v1/google/events` (header `X-Google-Token`, never stored or logged), reviewed and passed, with the reviewer's follow-ups applied.
  - The plan `plans/2026-11-19-google-calendar-push.md` (approved by the user) and `memory/decisions/2026-11-19-google-calendar-api-and-refresh.md`.
  - The project now uses the real identity: bundle ID `technology.artisan.seasign`, team `Q79NR2FCR9` (`app-identity.xcconfig`, `api/wrangler.jsonc`).
- In flight:
  - #154 (`todo`, 5 of 7 criteria, code committed): Google sign-in in the app, calendar choice in Settings, Google events on Today, 5-second polling. A reviewer asked for changes; the seven fixes are listed in the task's last lead note (the main one: a cancelled request is treated as a Google failure). The user has not yet tried the real sign-in.
  - #156 (`review`, code committed, not yet reviewed): `POST /v1/google/watch`, `/unwatch`, the webhook `/v1/google/notify`, the D1 table `calendar_channels` (local migration applied) and the APNs sender. Tested with mocks only.
  - #20: still waiting for provider keys.
- Next:
  1. Ask the user how the Google sign-in went on the iPhone 16 Pro Max simulator (Settings → Connect Google Calendar); fix what it shows.
  2. Give #154 to an implementer for the review fixes, then re-review and close.
  3. Give #156 to a reviewer.
  4. Plan task D, the deploy to `api.seasign.app`: remote D1 and KV, the migration, the custom domain, the three APNs secrets typed by the user (`APNS_KEY`, `APNS_KEY_ID`, `APNS_TEAM_ID`), the app's base URL per build configuration. Ask before each step. First check after deploy: a tokenless POST from the Worker to APNs must answer 403 `MissingProviderToken`; if a Worker cannot reach APNs (HTTP/2), a relay is needed and that is a new service to ask about.
  5. Plan task E: Push Notifications capability, device-token registration, background push handling, channel upkeep; then task F, the end-to-end check with the user.
- Notes:
  - Nothing is deployed and no secret is set. Nothing has run against live Google or APNs. The user holds the APNs key file; the agent must never see it. The key ID and Google iOS client ID are in the plan (not secrets).
  - A `wrangler dev` started this session on port 8787 may still be running; the app in the Simulator needs it. The XcodeBuildMCP defaults point at the iPhone 16 Pro Max with the new bundle ID.
  - The new bundle ID installed as a new app; the old `com.example.seasign` app (with the user's pasted calendar link) is still on the Pro Max and the iPhone 16 simulators.
  - The iPhone 16 simulator holds the user's real zip and a personal calendar link: do not screenshot or log its calendar contents or change its settings.
  - Closed by the lead without a separate reviewer: #145–#152 except where a reviewer is named in the task log (#146 had one). #151 is done with one criterion unticked: no headline pull has been seen fetching real headlines, because the Pro Max follows no sites.
  - Not verified by anyone: VoiceOver on Today (description, the two refresh actions); pulls and taps on iOS 27.2; the Settings button after the pull gesture was added; real weather on screen for all twelve v11 states.
  - Open for the user: spinner colour (system grey) and its overlap with a full-width first event or headline; whether a headline pull should bypass the 30-minute site cache; whether working-location, focus-time, out-of-office and birthday entries should show; removing the AI mark from History, Saved and Reading too; duplicate events when one Google calendar is both connected and pasted; day-name size cap, daytime stars in bad weather, lighter mono type, and unused code from the old Today design.
  - Google test mode: at most 100 users, an "unverified app" warning, sign-in expires every 7 days; verification is needed before the App Store.
  - Background pushes are low priority and throttled by iOS; the app must keep fetching on return to the foreground. Coalescing pushes per device may be needed.
  - Still to correct: the `npx -y npm@11 install` row in the `AGENTS.md` CLI table.

## 2026-11-22 — Google sign-in, push and write access finished in code; day timeline; adding events by typing and by voice; nothing deployed

- Done:
  - #154, #156, #158, #159: Google sign-in review fixes, watch channels and APNs sender, and the app's push handling (`GoogleWatchKeeper.swift`, `RemotePush.swift`). The user tried the real Google sign-in on the iPhone 16 Pro Max simulator and it works. Push has never run for real (it needs the deploy).
  - #160, #162: pasted calendar links are checked every 5 minutes (was 1).
  - #161, #163, #165: no stars while the sun is up, stars spread evenly, horizon times the size of the event times.
  - #166–#172, #176: plan `plans/2026-11-22-day-calendar-and-voice.md`. API: a `day` parameter on both event routes, `accessRole` on the calendar list, `POST /v1/google/events/create`. App: the write scope `calendar.events.owned` and "Connect again to add events"; the day screen opened by tapping the events box on Today; adding an event by typing one line (`EventPhraseParser.swift`, `AddEventModel.swift`); adding by voice (`ios/Seasign/Voice/`) with read-aloud, a spoken Confirm or Cancel, and a Voice section in Settings.
  - #175: Connect again as a different Google account is a Disconnect then a fresh Connect; the same account's token is never revoked; connection and scopes in one save.
  - #177: the speech-recognition prompt wording the user chose. #179: a recognizer failure no longer says "Nothing was heard".
  - #181: the day screen is a full-day timeline, no scrolling (`DayTimeline.swift`, `DayTimelineView.swift`).
  - The user typed an event with + on the Pro Max simulator and it was created in their Google Calendar: the first real create.
  - Last verified by the lead at `2fe6ea3`: iOS suite 755 tests passed on iPhone 16 / iOS 18.3.1 and iPhone 17 / iOS 27.2. API last run at `d31f8dc`: `npm test` 1,978 passed, `tsc` clean; no API change since.
- In flight: nothing is in progress. The board has no claimed task.
- Next:
  1. Ask the user which features come next; they said more features come before the deploy and before checks on their phone.
  2. Ask whether the mic and + should go back to the top right with + under the mic (they are in the day screen's header row now; the user's first wording was stacked).
  3. Ask the user to tap the mic once on the Pro Max simulator and say which message shows: "Speech can't be recognised on this iPhone right now…" means #179 works there; "Nothing was heard" means the path where the error comes more than 2 s after the audio ends needs a task.
  4. Backlog in rough order of value: #178 (Google account-switch edge cases; a renamed Google email is taken for another account and ends the new sign-in), #164, #174, #173 (Pocket-TTS voice clone trial; the user allowed the install on this Mac, the cloning waits; read the licence first), #180 (voice checks on the user's iPhone).
- Notes:
  - Decisions: `memory/decisions/2026-11-22-day-calendar-voice-and-google-write.md` (voice in the product, the first permission prompts, Google write access, the scope is marked sensitive by Google) and `memory/decisions/2026-11-22-refresh-stars-deploy-and-checks.md`. Architecture notes for the day screen, voice and Connect again are in `memory/architecture.md`.
  - Nothing is deployed and no secret is set. #157 (deploy) is on hold by the user's choice; they have Cloudflare Free. #20 still waits for provider keys.
  - Not verified by anyone: live speech recognition, the read-aloud voice by ear, a spoken confirm, the two permission prompts on a phone (the Simulator cannot recognise speech on the device: error 1101 every time, the Mac's microphone does reach it); the three-scope consent screen was passed by the user but not described; VoiceOver on the day timeline and the events button; a real push; live polling.
  - Closed by the lead without a separate reviewer: #161, #163, #165, #166, #177, #179, #181, and the last parser pass and retry fix of #172 (`267626c`, `65c241c`). The voice code of #172 had two reviews.
  - Accepted by the user as built: "at ten to seven" is 6:50 PM; "next friday" is the first Friday after today; "12am"/"12:30am" with a day is the start of that day, "midnight" and "12 tonight" the end.
  - Simulators: the old `com.example.seasign` app was removed from every simulator at the user's request (with it the pasted calendar link on the Pro Max). The iPhone 16 Pro Max holds the user's real Google connection and has the build of `2fe6ea3`; do not screenshot or log it. Speech recognition is denied for the app on the iPhone 17 simulator (`simctl privacy reset` was refused), so the real listener cannot be driven there.
  - iOS test runs: one `xcodebuild` at a time, own `-derivedDataPath`, wait on `pgrep -x xcodebuild` (`pgrep -f` matches the waiting shell itself). A result counts only with `Test run with N tests ... passed` and `** TEST SUCCEEDED **`. The lead re-runs the suite before closing; an implementer's first report this session gave false pass counts. A lead run started while an implementer has uncommitted files compiles those files.
  - A `wrangler dev` started this session on port 8787 may still be running; the app in the Simulator needs it.
  - The app built for the iPhone 17 destination crashed at launch on the iPhone SE simulator (dyld, library not read); the iPhone 16 build ran there. Not looked into.
  - Still to correct: the `npx -y npm@11 install` row in the `AGENTS.md` CLI table.
