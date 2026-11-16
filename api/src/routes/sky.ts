import { OpenAPIHono, createRoute, z } from "@hono/zod-openapi";
import {
  UpstreamError,
  fetchForecast,
  geocodeZip,
  type Forecast,
  type Place,
} from "../lib/open-meteo.ts";
import { retryAfterHeader } from "../lib/rate-limit.ts";

// KV lifetimes, in seconds. A zip's place does not move; the weather does.
const GEOCODE_TTL = 60 * 60 * 24 * 30;
const FORECAST_TTL = 60 * 15;

/** KV key of a zip's geocoded place. Exported for the tests. */
export const geocodeCacheKey = (zip: string) => `sky:geo:v1:${zip}`;
/** KV key of a zip's forecast. Exported for the tests. */
export const forecastCacheKey = (zip: string) => `sky:forecast:v1:${zip}`;

const instant = (description: string) =>
  z.string().openapi({ format: "date-time", description, example: "2026-11-15T11:42:55Z" });

const SkyQuerySchema = z.object({
  zip: z
    .string()
    .regex(/^\d{5}$/)
    .openapi({
      param: { name: "zip", in: "query" },
      description: "5-digit US zip code",
      example: "10001",
    }),
});

const SkyPlaceSchema = z
  .object({
    name: z.string().openapi({ description: "City or town the zip belongs to", example: "New York" }),
    region: z.string().nullable().openapi({ description: "State name", example: "New York" }),
    latitude: z.number().openapi({ description: "Degrees north", example: 40.71427 }),
    longitude: z.number().openapi({ description: "Degrees east", example: -74.00597 }),
  })
  .openapi("SkyPlace");

const SkyCurrentSchema = z
  .object({
    observedAt: instant("When these values were measured, as a UTC instant"),
    temperatureF: z.number().openapi({ description: "Air temperature in °F", example: 43.8 }),
    weatherCode: z
      .number()
      .int()
      .openapi({ description: "WMO weather interpretation code (0 clear … 99 thunderstorm with hail)", example: 0 }),
    cloudCoverPercent: z.number().openapi({ description: "Total cloud cover, 0–100 percent", example: 4 }),
    windSpeedMph: z.number().openapi({ description: "Wind speed at 10 m in mph", example: 9.3 }),
    windGustsMph: z.number().openapi({ description: "Wind gusts at 10 m in mph", example: 25.1 }),
    isDay: z.boolean().openapi({ description: "True between sunrise and sunset" }),
  })
  .openapi("SkyCurrent");

const SkyDaySchema = z
  .object({
    date: z
      .string()
      .openapi({ description: "Calendar date in the place's time zone, YYYY-MM-DD", example: "2026-11-15" }),
    sunrise: instant("Sunrise as a UTC instant; null when the sun does not rise or set that day").nullable(),
    sunset: instant("Sunset as a UTC instant; null when the sun does not rise or set that day").nullable(),
    moonrise: instant("Moonrise as a UTC instant; null when the moon does not rise that day").nullable(),
    moonset: instant("Moonset as a UTC instant; null when the moon does not set that day").nullable(),
    moonPhase: z.number().openapi({
      description: "Moon phase as a fraction of the cycle: 0 new, 0.25 first quarter, 0.5 full, 0.75 last quarter",
      example: 0.196,
    }),
  })
  .openapi("SkyDay");

const SkySchema = z
  .object({
    zip: z.string().openapi({ example: "10001" }),
    place: SkyPlaceSchema,
    timezone: z.string().openapi({ description: "IANA time zone of the place", example: "America/New_York" }),
    utcOffsetSeconds: z.number().int().openapi({
      description: "The time zone's offset from UTC right now, in seconds. Use `timezone` for other instants",
      example: -18000,
    }),
    current: SkyCurrentSchema,
    days: z.array(SkyDaySchema).openapi({ description: "Today and tomorrow in the place's time zone, in order" }),
  })
  .openapi("Sky");

const ErrorSchema = z
  .object({
    error: z.enum(["invalid_zip", "unknown_zip", "rate_limited", "upstream_error"]).openapi({ description: "Machine-readable reason" }),
    message: z.string().openapi({ description: "Human-readable explanation" }),
  })
  .openapi("SkyError");

const errorResponse = (description: string) => ({
  description,
  content: { "application/json": { schema: ErrorSchema } },
});

const getSky = createRoute({
  method: "get",
  path: "/v1/sky",
  operationId: "getSky",
  summary: "Current weather and sun and moon times for a US zip code",
  request: { query: SkyQuerySchema },
  responses: {
    200: {
      description: "Weather now, plus sun and moon times for today and tomorrow",
      content: { "application/json": { schema: SkySchema } },
    },
    400: errorResponse("The zip is missing or is not five digits"),
    404: errorResponse("No US place is known for this zip"),
    429: {
      ...errorResponse("rate_limited: too many requests from this network; wait Retry-After seconds"),
      headers: retryAfterHeader(true),
    },
    502: errorResponse("The weather provider failed; try again later"),
  },
});

export const sky = new OpenAPIHono<{ Bindings: CloudflareBindings }>({
  defaultHook: (result, c) => {
    if (!result.success) {
      return c.json({ error: "invalid_zip" as const, message: "zip must be a 5-digit US zip code" }, 400);
    }
  },
});

sky.openapi(getSky, async (c) => {
  const { zip } = c.req.valid("query");
  const cache = c.env.CACHE;

  try {
    let place = await cache.get<Place>(geocodeCacheKey(zip), "json");
    if (!place) {
      place = await geocodeZip(zip);
      if (!place) {
        return c.json({ error: "unknown_zip" as const, message: `No US place found for zip ${zip}` }, 404);
      }
      await cache.put(geocodeCacheKey(zip), JSON.stringify(place), { expirationTtl: GEOCODE_TTL });
    }

    let forecast = await cache.get<Forecast>(forecastCacheKey(zip), "json");
    if (!forecast) {
      forecast = await fetchForecast(place.latitude, place.longitude);
      await cache.put(forecastCacheKey(zip), JSON.stringify(forecast), { expirationTtl: FORECAST_TTL });
    }

    return c.json({ zip, place, ...forecast }, 200);
  } catch (error) {
    if (error instanceof UpstreamError) {
      console.warn(`sky: ${error.message}`);
      return c.json({ error: "upstream_error" as const, message: "The weather provider is unavailable" }, 502);
    }
    throw error;
  }
});
