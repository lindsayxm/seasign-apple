// Open-Meteo calls for /v1/sky: zip to place (geocoding API) and place to
// current weather plus sun and moon times (forecast API). No API key is needed.
// Nothing here imports `cloudflare:*`, so the spec writer can load it in Node.
import { z } from "@hono/zod-openapi";

const GEOCODING_URL = "https://geocoding-api.open-meteo.com/v1/search";
const FORECAST_URL = "https://api.open-meteo.com/v1/forecast";
const UPSTREAM_TIMEOUT_MS = 8000;

/** Open-Meteo could not be reached or answered with something unusable. */
export class UpstreamError extends Error {}

export type Place = {
  name: string;
  region: string | null;
  latitude: number;
  longitude: number;
};

export type Forecast = {
  timezone: string;
  utcOffsetSeconds: number;
  current: {
    observedAt: string;
    temperatureF: number;
    weatherCode: number;
    cloudCoverPercent: number;
    windSpeedMph: number;
    windGustsMph: number;
    isDay: boolean;
  };
  days: {
    date: string;
    sunrise: string | null;
    sunset: string | null;
    moonrise: string | null;
    moonset: string | null;
    moonPhase: number;
  }[];
};

const GeocodingResponse = z.object({
  results: z
    .array(
      z.object({
        name: z.string(),
        admin1: z.string().optional(),
        latitude: z.number(),
        longitude: z.number(),
        postcodes: z.array(z.string()).optional(),
      }),
    )
    .optional(),
});

const unixOrNull = z.number().int().nullable();

const ForecastResponse = z.object({
  timezone: z.string(),
  utc_offset_seconds: z.number().int(),
  current: z.object({
    time: z.number().int(),
    temperature_2m: z.number(),
    weather_code: z.number().int(),
    cloud_cover: z.number(),
    wind_speed_10m: z.number(),
    wind_gusts_10m: z.number(),
    is_day: z.number().int(),
  }),
  daily: z.object({
    time: z.array(z.number().int()).min(1),
    sunrise: z.array(unixOrNull),
    sunset: z.array(unixOrNull),
    moonrise: z.array(unixOrNull),
    moonset: z.array(unixOrNull),
    moon_phase: z.array(z.number()),
  }),
});

async function getJSON(url: URL): Promise<unknown> {
  let response: Response;
  try {
    response = await fetch(url.toString(), {
      headers: { accept: "application/json" },
      signal: AbortSignal.timeout(UPSTREAM_TIMEOUT_MS),
    });
  } catch {
    throw new UpstreamError(`${url.hostname} could not be reached`);
  }
  if (!response.ok) {
    throw new UpstreamError(`${url.hostname} answered ${response.status}`);
  }
  try {
    return await response.json();
  } catch {
    throw new UpstreamError(`${url.hostname} did not answer with JSON`);
  }
}

/**
 * Looks a 5-digit US zip up. Returns null when Open-Meteo does not know it.
 * The geocoder matches loosely, so a result counts only when its own
 * `postcodes` list holds the zip that was asked for.
 */
export async function geocodeZip(zip: string): Promise<Place | null> {
  const url = new URL(GEOCODING_URL);
  url.searchParams.set("name", zip);
  url.searchParams.set("count", "1");
  url.searchParams.set("countryCode", "US");
  url.searchParams.set("format", "json");

  const parsed = GeocodingResponse.safeParse(await getJSON(url));
  if (!parsed.success) {
    throw new UpstreamError("unexpected geocoding response");
  }
  const result = parsed.data.results?.[0];
  if (!result || !result.postcodes?.includes(zip)) {
    return null;
  }
  return {
    name: result.name,
    region: result.admin1 ?? null,
    latitude: result.latitude,
    longitude: result.longitude,
  };
}

/** Unix seconds to a UTC ISO 8601 string without fractional seconds. */
function instant(unixSeconds: number): string {
  return new Date(unixSeconds * 1000).toISOString().replace(/\.\d{3}Z$/, "Z");
}

/** The calendar date (YYYY-MM-DD) of an instant in an IANA time zone. */
function localDate(unixSeconds: number, timeZone: string): string {
  const parts = new Intl.DateTimeFormat("en-US", {
    timeZone,
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
  }).formatToParts(new Date(unixSeconds * 1000));
  const part = (type: string) => parts.find((p) => p.type === type)?.value ?? "";
  return `${part("year")}-${part("month")}-${part("day")}`;
}

/**
 * Current weather plus two days of sun and moon times for a coordinate.
 *
 * Times are requested as Unix timestamps (`timeformat=unixtime`), not as local
 * strings: the local strings all share one `utc_offset_seconds`, which is wrong
 * for the far side of a daylight-saving change inside the two-day window.
 */
export async function fetchForecast(latitude: number, longitude: number): Promise<Forecast> {
  const url = new URL(FORECAST_URL);
  url.searchParams.set("latitude", String(latitude));
  url.searchParams.set("longitude", String(longitude));
  url.searchParams.set(
    "current",
    "temperature_2m,weather_code,cloud_cover,wind_speed_10m,wind_gusts_10m,is_day",
  );
  url.searchParams.set("daily", "sunrise,sunset,moonrise,moonset,moon_phase");
  url.searchParams.set("timezone", "auto");
  url.searchParams.set("temperature_unit", "fahrenheit");
  url.searchParams.set("wind_speed_unit", "mph");
  url.searchParams.set("timeformat", "unixtime");
  url.searchParams.set("forecast_days", "2");

  const parsed = ForecastResponse.safeParse(await getJSON(url));
  if (!parsed.success) {
    throw new UpstreamError("unexpected forecast response");
  }
  const { timezone, utc_offset_seconds, current, daily } = parsed.data;

  const columns = [daily.sunrise, daily.sunset, daily.moonrise, daily.moonset, daily.moon_phase];
  if (columns.some((column) => column.length !== daily.time.length)) {
    throw new UpstreamError("unexpected forecast response");
  }

  let days: Forecast["days"];
  try {
    days = daily.time.map((dayStart, i) => {
      const sunrise = daily.sunrise[i] ?? null;
      const sunset = daily.sunset[i] ?? null;
      // On a day without a sunrise or sunset (polar night, midnight sun)
      // Open-Meteo repeats the day's start for both instead of sending null.
      const noSunEvents = sunrise === null || sunset === null || sunrise === sunset;
      const moonrise = daily.moonrise[i] ?? null;
      const moonset = daily.moonset[i] ?? null;
      return {
        date: localDate(dayStart, timezone),
        sunrise: noSunEvents ? null : instant(sunrise),
        sunset: noSunEvents ? null : instant(sunset),
        moonrise: moonrise === null ? null : instant(moonrise),
        moonset: moonset === null ? null : instant(moonset),
        moonPhase: daily.moon_phase[i] as number,
      };
    });
  } catch {
    // An unknown time zone name or an out-of-range timestamp.
    throw new UpstreamError("unexpected forecast response");
  }

  return {
    timezone,
    utcOffsetSeconds: utc_offset_seconds,
    current: {
      observedAt: instant(current.time),
      temperatureF: current.temperature_2m,
      weatherCode: current.weather_code,
      cloudCoverPercent: current.cloud_cover,
      windSpeedMph: current.wind_speed_10m,
      windGustsMph: current.wind_gusts_10m,
      isDay: current.is_day === 1,
    },
    days,
  };
}
