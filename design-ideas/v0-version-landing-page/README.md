# v0 — version landing page

One page that shows a thumbnail of every design version and opens the version when its thumbnail is selected. Look only; no app code.

- `index.html` is the page (`open design-ideas/v0-version-landing-page/index.html`). Each card links to `../<version>/index.html`, so it must stay beside the version folders.
- `thumbs/` holds two small pictures per version, made from that version's `02-mid-day.png` and `08-mid-night.png` (393 points wide, JPEG). The card shows mid-day and changes to mid-night under the pointer or keyboard focus.
- The thumbnails are copies: after a version's stills change, remake them, and add a card here when a new version is added.
- `fonts/` holds a copy of the app's Jost font so the page works offline.
