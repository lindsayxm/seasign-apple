# Today: no rise/set tag, wind always shown, no AI mark on Today titles

Date: 2026-11-19. Tasks: #148 (app), #149 (mockup and records).

## Decision

1. The text call-out ("tag") and its leader beside the sun or moon at rise and set are removed. Nothing is written beside the body in any state.
2. The wind line (`WIND 8 MPH`) under the temperature shows whenever fresh current weather exists, in every state.
3. AI-found article titles on Today carry no visible AI mark.

## Reason

The user, after seeing v11 in the app: "let's remove the text call out / label on the sun/moon at rise and set - just always show the windspeed in the upper left under the tempurature - it's ok that we cant see the time directly under the sun/moon - we can still see it in the upper corner of the phone ... please also remove the AI lables you added."

## Scope and readings (the lead's, not the user's words)

- The time mark under the end tick at a rising or setting body stays hidden, as it was while the tag showed; the user said losing that time is fine. The mark at the other end still shows.
- The AI mark was removed from Today only. History, Saved, Reading and the filter bar still show it, and VoiceOver still says "AI" on Today rows. This partly reverses the v1 decision that AI-found items are "visibly labelled" (`plans/2026-11-15-v1-build.md`); whether the mark goes from the other screens too is an open question for the user.

## Rejected

- Showing the rise or set time under the body once the tag is gone: new text the user did not ask for.
