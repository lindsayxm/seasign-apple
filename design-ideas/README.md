# design-ideas

A place to explore how Seasign looks. Nothing here is part of the app.

- Only the look: layouts, colours, type, scene states, icons. No app code and no API code.
- Nothing in `ios/` or `api/` reads from this folder, and work here does not change them.
- An idea becomes part of the app only when the user picks it; then it gets its own task and is built in `ios/`.
- The current design references are in `ref-img/`. Ideas here may depart from them.
- One subfolder per version, numbered and named: `v1-original/` (the app as built), `v2-halo/`, `v3-cyclo/`, `v4-cartography/`, `v5-hud/`, `v6-hud2/`, `v7-firmament/`, `v8-lemuria/` (its own `ref-img/` holds the user's HUD references).
- `v0-version-landing-page/` is an index: a page with a thumbnail of each version that opens it.
- Reference images for a version go in `ref-img/` under the same name, for example `ref-img/v3-cyclo/`.
