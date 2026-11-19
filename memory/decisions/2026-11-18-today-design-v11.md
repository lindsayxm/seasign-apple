# Today screen design: v11 "Artemis"

Date: 2026-11-18

## Decision

The Today screen is built to `design-ideas/v11-artemis/` (v8's full-screen sky and sea with v7's header). The user: "ok v11 is the one - please implement v11 in the app". The flat spec, with the mockup's sample-state rules rewritten for real data, is `plans/2026-11-18-today-v11.md`.

## What it replaces

The Today screen drawn from the `ref-img/` mockups (flat charcoal sky, pale blue water, coral sun, PT Sans Narrow day name, `»` button, wind dashes). The `ref-img/` screen mockups are no longer the reference for Today; they still describe the other screens (Settings, Do/Get, Saved, History, Reading), which were not redesigned.

## Rejected

v1–v6 and v9–v10 in `design-ideas/` (kept for the record; see `memory/notes/2026-11-16-design-ideas.md`). v7 and v8 are the two parents of v11.

## Consequences

- New type on Today: Avenir Next Condensed (day name), Iowan Old Style (article titles) and the system mono face; all ship with iOS, so no font files are added. Jost stays for caps text. PT Sans Narrow stays bundled only if another screen still uses it.
- Wind is shown as a number; the wind marks on the water are gone.
- The scene rules on real data that the mockup did not settle (when the sunrise and sunset looks start, stars by day in bad weather) are in the plan and were decided by the lead; the star rule is flagged to the user.
