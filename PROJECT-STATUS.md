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
