# v10 — Simplify

Look-only mockup; nothing here is part of the app. A clean slate, not built on earlier versions. The user asked for "a very simplified japanese art inspired version" from the sheet in `ref-img/`: flat red-orange suns on cream paper, seas drawn as flowing lines (one solid navy with cream lines), a column of upright text, a small red seal, worn print texture, a great deal of empty paper.

Open `index.html`. Address switches: `?state=<id>` (the same twelve ids as the other versions), `&bare`, `&still`, `&t=<seconds>`, `&nobtn`.

## What is on the screen

- **Paper** fills the top half: cream by day, warmer at sunrise and sunset, greyer in cloud, rain and snow, deep indigo at night. Paper grain and a few fibres lie over the whole print.
- **One disc.** The sun is a flat red-orange disc, worn with specks and fine scratches where the paper shows through. The moon is the same disc in cream; its dark part is barely there. The disc travels a tall arc and sinks behind the sea at rise and set, a little larger there.
- **The sea** fills the bottom half: solid indigo with pale wave lines. The lines are drawn far to near and each hides what is behind it, so swells overlap; they drift slowly and fade toward the bottom, where the words are.
- **Weather** in the sky only: mist as flat bands with round ends that pass in front of the sun, rain as long fine slanting lines, snow as pale dots. A few stars at night.
- **Words**, as few as will do:
  - top left, the next three events, small, with the time in red;
  - top right, the day and date as one upright column read from the top down, and under it a small red seal with the temperature;
  - on the sea, six article titles in the serif, cream, with no numbers;
  - at the bottom, four small pale marks for settings, list, saved and all publications.
- **Colours:** paper, indigo, ink, and one red.

## Left out on purpose (it is the simplified version)

Wind, cloud cover, rise and set times, the moon's lit share as a number, the place name, button names, title numbers, any frame, rule or meter. The sky itself says whether it is clear, cloudy, raining or snowing.

## Decided without being asked

- "Monday" is spelled out in the upright column; the seal shows only `55°`.
- The sea is the solid-navy kind from the first reference, so that cream titles read on it; the line-only seas in the other references would put titles on top of dark lines.
- The sun does not change size much (54 points high, 68 on the horizon); it is always the largest thing on the page.

Stills `01-sunrise.png` … `12-moon-set.png` are rendered at 3× with headless Chrome, as for the other versions.
