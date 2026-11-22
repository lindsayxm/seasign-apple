# Google Calendar through sign-in and push; refresh rules on Today

Date: 2026-11-19. Plan: `plans/2026-11-19-google-calendar-push.md`. Tasks: #150–#156.

## Decisions (the user's)

1. **Google calendars come through the Google Calendar API with sign-in, and changes arrive by push.** "we need to switch to using the google calendar api. i want the user to see the calendar event automatically inside the app as soon as it is added on the google side - they shouldnt have to refresh anything." This reverses the v1 rule "no sign-in, paste a link" for Google. Pasted links stay for Apple and Outlook calendars ("Keep both").
2. **The API is to be deployed** on the user's domain `seasign.app` (lead's proposal: `api.seasign.app`), with remote D1 and KV, and the app gets the real identity (`technology.artisan.seasign`, team `Q79NR2FCR9`) and the Push Notifications capability. Approved: "Ok i approve all of the above." Each deploy, remote-resource and secret step is still announced before it is run; the user types the APNs key into Cloudflare themselves.
3. **Refresh on Today:** calendar and headline refresh are separate. Pull down above the horizon: events and the sky. Pull down on the sea or the titles: headlines only. Each has a spinner at the upper right of its area, on one vertical line. Temperature and conditions refresh silently every 10 minutes. No pull ever starts an AI search.

## Choices made by the lead (open to the user)

- Until push is live, the app polls Google events every 5 seconds while Today is open.
- Only ordinary events and ones Google makes from mail are read; working location, focus time, out of office and birthdays are left out.
- Cache times: calendar links 1 minute (KV's shortest), sky 5 minutes, sites 30 minutes (unchanged; a headline pull can still return a copy up to 30 minutes old).
- The server keeps no Google token: the app sends it with each call, and a notification channel row holds only the channel, a hash of its token and the phone's push token (`memory/decisions/2026-11-19-google-push-channels.md`).
- "Calendar area" was read as everything above the horizon.

## Rejected

- Reading the phone's own calendars (EventKit): instant, but needs the calendar permission the user ruled out for v1.
- Waiting for push before building anything: the sign-in and reading parts work locally first.
- The system pull-to-refresh (`.refreshable`): it never fired on the fixed Today layout; a drag gesture is used.

## Later changes

- 2026-11-21 (user decision, task #160): pasted calendar links are the slow fallback; Connect Google is the fast path. The app checks pasted links every 5 minutes instead of every 60 seconds (`EventsModel.refreshInterval`; Today's minute loop still runs for the sky but sends a calendar request only when the last answer is 5 minutes old), and the API caches a link's events for 5 minutes instead of 1 (`CALENDAR_TTL` 300 s). Why: fewer Worker requests and about a fifth of the KV writes. An event added to a pasted calendar now shows within about 5 minutes, up to about 10 when another phone keeps the same link's cache entry warm. A pull above the horizon, adding a link, and a return to the foreground with events 5 minutes old or more send `fresh: true` on `POST /v1/calendar/events`, which skips the cache read (the fetch keeps every safe-fetch cap, the result is cached as usual, and the 20-a-minute calendar rate limit still applies); scheduled checks never send it. Considered and dropped: a conditional "has it changed?" check, not worth its cost for the fallback path. This replaces the "calendar links 1 minute" cache time above.
