# BUILD

## What we are building

Seasign: an iPhone App - daily information, calendar, and to do / to get lists. 

TODAY SCREEN (main screen): today's date, temperature and next three calendar events over a Lake Michigan horizon that follows the real sun, moon and weather; below the waterline, what the sites you follow published since yesterday; and buttons for settings, do/get list, saved publications. Review changes in the Xcode iOS Simulator. 

LOCATION: The Today horizon follows the real sun, moon and weather over the user's own zip code - allow the user to set their own zip code in the settings panel - don't build it in or ask for their permission to view their location - that feels intrusive. Let the user specify the location. Derive the time of day from the zip code the user enters. 

LIST STORAGE: tables in D1 synced through the API (works for a later Android client. STACK: SwiftData-then-sync model) 

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


