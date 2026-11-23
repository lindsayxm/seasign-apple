# Decisions of 2026-11-20 to 2026-11-22: refresh cadence, stars, deploy on hold, phone checks later

Made by the user in the lead session. Voice, the day calendar and Google write access are in `2026-11-22-day-calendar-voice-and-google-write.md`.

## Pasted calendar links are checked every 5 minutes

- **Decision:** the app checks pasted iCal links every 5 minutes and the API caches each link for 5 minutes (task 160; was 1 minute). A pull down on Today still forces a check.
- **Reason:** a pasted link cannot be listened to; every check is a full download by the Worker. The user judged frequent checking expensive for little gain. Google Calendar through sign-in is the path for events that appear at once.
- **Rejected:** reading the phone's calendars with EventKit (the user does not want a dependency on how Apple Calendar is set up, and wants the user to decide in the app what is shared); a conditional "has it changed?" request (ETag / If-Modified-Since), judged not a well-known enough flow to be worth building.

## Stars on Today

- **Decision:** no stars while the sun is up; they fade in through sunset and out through sunrise (task 161). The star field is spread evenly, with no clumps (task 163). The field stays invented.
- **Rejected:** a real star catalogue. Open-Meteo has no star data; a bundled catalogue would be needed.

## Horizon times

- The rise and set times on the horizon use the same size as the event times (`TodayOverlayLayout.Fonts.timeSize`, task 165).

## Deploy is on hold

- **Decision:** nothing is deployed until more features are built (task 157 stays in `todo`). The user has Cloudflare Free, not Workers Paid.
- **Known limits to plan around when it resumes:** on Free, `/v1/feed` and large calendars are likely to pass the 10 ms CPU limit, and KV allows 1,000 writes a day. Whether to pay or to trim is the user's call then.

## Checks on the user's iPhone come later

- **Decision:** voice is checked on the user's own iPhone only after more features exist (task 180). The Simulator cannot recognise speech on the device (error 1101 on every attempt), so no live voice check has been done by anyone.
- **Needs first:** the user's go-ahead for a device install (signing) and an API the phone can reach (the Debug build points at `localhost:8787`).

## Day screen is a timeline

- **Decision:** the day screen shows the whole day on one screen, without scrolling, with each event as a box from its start to its end (task 181).
- **Open:** the mic and + sit in the header row beside the close mark; the user first asked for the mic at the top right with + below it, has been told, and may ask for that back.
