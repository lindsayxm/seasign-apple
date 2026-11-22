# BUILD

## What we are building

Seasign: an iPhone App - daily information, calendar, and to do / to get lists. 

TODAY SCREEN (main screen): today's date, temperature and next three calendar events over a Lake Michigan horizon that follows the real sun, moon and weather; below the waterline, what the sites you follow published since yesterday; and buttons for settings, do/get list, saved publications. Review changes in the Xcode iOS Simulator. 

LOCATION: The Today horizon follows the real sun, moon and weather over the user's own zip code - allow the user to set their own zip code in the settings panel - don't build it in or ask for their permission to view their location - that feels intrusive. Let the user specify the location. Derive the time of day from the zip code the user enters. 

DEFAULT ZIP: a fresh install starts with zip code 60611 (Chicago), so Today shows a real sky before any setup. The user can change or remove it in Settings.

LIST STORAGE: tables in D1 synced through the API (works for a later Android client. STACK: SwiftData-then-sync model) 

SIGN-IN: The app works without signing in. Until the user signs in with Apple, their data (lists, sites, calendar links, saved items, settings) lives on the device. Signing in uploads it to D1 and turns on sync.

CALENDARS: Events come from calendar links the user pastes in Settings - Google's "Secret address in iCal format", an Apple published calendar link, or an Outlook published calendar link. The API fetches and reads the links. The app does not ask for permission to read the phone's calendars. Since 2026-11-19 the user can also connect Google Calendar by signing in (events appear without refreshing), and since 2026-11-22 new events can be added to Google calendars the user owns; pasted links are read-only.

SITES: In Settings the user enters the URL of a page to follow (for example https://www.wired.com/category/science/) and a category they name themselves (for example "Sci"). The category is never taken from the URL.

AI SEARCH: In Settings the user can enter an API key for an LLM (Anthropic, OpenAI, Google Gemini or Perplexity), a comma-separated list of interests, and a maximum number of searches per day to cap API spend. A pill-shaped toggle reads "Use My List" on the left and "Let AI Search" on the right. When AI search is on, publications the LLM finds across the web on those interests are blended into the feed alongside the user's own sites, and each one is labelled as AI-found. The key is kept in the phone's Keychain.

BUTTONS ON TODAY (see ref-img/00-button-meanings.png): settings; do/get; saved (the asterisk); and >> which opens the last 7 days of everything that has been in the feed, so an article that was not saved can still be found after the feed refreshes. History and Saved can be searched by keyword and filtered by category. Saved items can carry notes.

TODAY FEED: shows only the newest headlines that fit below the waterline; it does not scroll. Tapping a headline opens a reading view with the site's own excerpt and a link to read on the original site.

DO/GET: one screen, DO on top and GET on the bottom, each with its own add field (ref-img/00-do-get-list.png).

ADDING EVENTS (added 2026-11-22, plan `plans/2026-11-22-day-calendar-and-voice.md`): Tapping the events area on Today opens a full-screen view of all of today's events. A mic button and a + button add an event by speaking or by typing one line ("meeting sunday at 3pm with Rahaf"). A popup shows the event (and reads it aloud after the mic); it is written to the user's Google Calendar only after the user says "Confirm" or taps Confirm. The voice that reads aloud is chosen in Settings. The app asks for the microphone and speech recognition the first time the mic is tapped; speech is recognised on the phone.

NOT IN V1: a "Hey Seasign" wake phrase, Siri/Shortcuts, home-screen widget, notifications, AI summaries. (Voice input was on this list until 2026-11-22.)

REFERENCE IMAGES: mockups and colour references are in ref-img/.

## External data sources 
The app uses Open-Meteo, a free weather API that needs no key. It supplies:

temperature
weather code (which drives rain and snow)
cloud cover
wind and gusts
sunrise and sunset
moonrise and moonset
moon phase 


## Who it is for

Primarily focusing on millennials and gen z users who love new technology.


## What it must do

The goal of the app is to aggregate information for the user that pertains to their day - all in one place. It helps remove distractions by surfacing the information and doesn't use adds or have other distracting elements. Additionally, it helps the user discover and keep a list of new information like new publications on topics they are interested in (based on values they set). We are creating a custom feed, which the *user* defines, so they get to be in charge of what information they consume. The user is never manipulated by an algorithm they have no control over or cannot see. 


