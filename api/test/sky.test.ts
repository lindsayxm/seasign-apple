import { env, exports } from "cloudflare:workers";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { forecastCacheKey, geocodeCacheKey } from "../src/routes/sky.ts";
// Recorded from Open-Meteo on 2026-11-15 with the exact URLs the Worker builds.
import forecast10001 from "./fixtures/forecast-10001.json";
import geocode10001 from "./fixtures/geocode-10001.json";
import geocodeUnknown from "./fixtures/geocode-unknown.json";

const GEOCODING_HOST = "geocoding-api.open-meteo.com";
const FORECAST_HOST = "api.open-meteo.com";

type Reply = () => Response | Promise<Response>;

/**
 * Replaces outbound fetch. Each host answers with its reply; any other
 * request fails the test, so nothing reaches the network.
 */
function mockOpenMeteo(replies: { geocoding?: Reply; forecast?: Reply }) {
  return vi.spyOn(globalThis, "fetch").mockImplementation(async (input, init) => {
    const url = new URL(new Request(input, init).url);
    if (url.hostname === GEOCODING_HOST && replies.geocoding) return replies.geocoding();
    if (url.hostname === FORECAST_HOST && replies.forecast) return replies.forecast();
    throw new Error(`Unexpected outbound request: ${url}`);
  });
}

const recorded = {
  geocoding: () => Response.json(geocode10001),
  forecast: () => Response.json(forecast10001),
};

const requestedURLs = (spy: ReturnType<typeof mockOpenMeteo>) =>
  spy.mock.calls.map(([input, init]) => new URL(new Request(input, init).url));

const getSky = (query: string) => exports.default.fetch(`https://example.com/v1/sky${query}`);

const ZIPS = ["10001", "00000", "10002"];

beforeEach(async () => {
  // KV is shared by the tests in this file.
  for (const zip of ZIPS) {
    await env.CACHE.delete(geocodeCacheKey(zip));
    await env.CACHE.delete(forecastCacheKey(zip));
  }
});

afterEach(() => {
  vi.restoreAllMocks();
});

describe("GET /v1/sky", () => {
  it("returns place, weather, and two days of sun and moon times", async () => {
    mockOpenMeteo(recorded);

    const response = await getSky("?zip=10001");

    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({
      zip: "10001",
      place: { name: "New York", region: "New York", latitude: 40.71427, longitude: -74.00597 },
      timezone: "America/New_York",
      utcOffsetSeconds: -18000,
      current: {
        observedAt: "2026-11-15T23:00:00Z",
        temperatureF: 43.4,
        weatherCode: 0,
        cloudCoverPercent: 4,
        windSpeedMph: 9.3,
        windGustsMph: 25.1,
        isDay: false,
      },
      days: [
        {
          date: "2026-11-15",
          sunrise: "2026-11-15T11:42:55Z",
          sunset: "2026-11-15T21:37:53Z",
          moonrise: "2026-11-15T17:01:14Z",
          moonset: "2026-11-16T02:49:21Z",
          moonPhase: 0.196,
        },
        {
          date: "2026-11-16",
          sunrise: "2026-11-16T11:44:04Z",
          sunset: "2026-11-16T21:37:05Z",
          moonrise: "2026-11-16T17:28:05Z",
          moonset: "2026-11-17T03:52:11Z",
          moonPhase: 0.226,
        },
      ],
    });
  });

  it("asks Open-Meteo for the zip, then for the place's coordinates", async () => {
    const spy = mockOpenMeteo(recorded);

    await getSky("?zip=10001");

    const [geocoding, forecast] = requestedURLs(spy);
    expect(geocoding?.hostname).toBe(GEOCODING_HOST);
    expect(Object.fromEntries(geocoding!.searchParams)).toEqual({
      name: "10001",
      count: "1",
      countryCode: "US",
      format: "json",
    });
    expect(forecast?.hostname).toBe(FORECAST_HOST);
    expect(Object.fromEntries(forecast!.searchParams)).toEqual({
      latitude: "40.71427",
      longitude: "-74.00597",
      current: "temperature_2m,weather_code,cloud_cover,wind_speed_10m,wind_gusts_10m,is_day",
      daily: "sunrise,sunset,moonrise,moonset,moon_phase",
      timezone: "auto",
      temperature_unit: "fahrenheit",
      wind_speed_unit: "mph",
      timeformat: "unixtime",
      forecast_days: "2",
    });
  });

  it("fetches both on a cache miss and neither on a cache hit", async () => {
    const spy = mockOpenMeteo(recorded);

    const first = await getSky("?zip=10001");
    expect(first.status).toBe(200);
    expect(spy).toHaveBeenCalledTimes(2);

    const second = await getSky("?zip=10001");
    expect(second.status).toBe(200);
    expect(spy).toHaveBeenCalledTimes(2);
    expect(await second.json()).toEqual(await first.json());
  });

  it("keeps the geocode when only the forecast has expired", async () => {
    const spy = mockOpenMeteo(recorded);
    await getSky("?zip=10001");
    await env.CACHE.delete(forecastCacheKey("10001"));

    const response = await getSky("?zip=10001");

    expect(response.status).toBe(200);
    expect(spy).toHaveBeenCalledTimes(3);
    expect(requestedURLs(spy)[2]?.hostname).toBe(FORECAST_HOST);
  });

  it.each(["", "?zip=", "?zip=1000", "?zip=100011", "?zip=1000a", "?zip=10001-1234"])(
    "rejects an invalid zip (%s) with 400 and no outbound request",
    async (query) => {
      const spy = mockOpenMeteo({});

      const response = await getSky(query);

      expect(response.status).toBe(400);
      expect(await response.json()).toEqual({
        error: "invalid_zip",
        message: "zip must be a 5-digit US zip code",
      });
      expect(spy).not.toHaveBeenCalled();
    },
  );

  it("returns 404 for a zip Open-Meteo does not know", async () => {
    const spy = mockOpenMeteo({ geocoding: () => Response.json(geocodeUnknown) });

    const response = await getSky("?zip=00000");

    expect(response.status).toBe(404);
    expect(await response.json()).toMatchObject({ error: "unknown_zip" });
    expect(spy).toHaveBeenCalledTimes(1);
  });

  it("returns 404 when the geocoder's match does not list the zip", async () => {
    // Synthetic: the recorded result with the requested zip removed, standing
    // in for a loose match on some other place.
    const loose = structuredClone(geocode10001);
    loose.results[0]!.postcodes = loose.results[0]!.postcodes.filter((code) => code !== "10002");
    const spy = mockOpenMeteo({ geocoding: () => Response.json(loose) });

    const response = await getSky("?zip=10002");

    expect(response.status).toBe(404);
    expect(spy).toHaveBeenCalledTimes(1);
    expect(await env.CACHE.get(geocodeCacheKey("10002"))).toBeNull();
  });

  it("returns null for a moonset that does not happen that day", async () => {
    // Synthetic: the recorded forecast with the first moonset removed, which
    // is how Open-Meteo reports a day without one.
    const noMoonset = structuredClone(forecast10001);
    const moonset: (number | null)[] = noMoonset.daily.moonset;
    moonset[0] = null;
    mockOpenMeteo({ ...recorded, forecast: () => Response.json(noMoonset) });

    const response = await getSky("?zip=10001");

    expect(response.status).toBe(200);
    const body = (await response.json()) as { days: { moonset: string | null }[] };
    expect(body.days.map((day) => day.moonset)).toEqual([null, "2026-11-17T03:52:11Z"]);
  });

  it("returns null sun times when the sun neither rises nor sets", async () => {
    // Synthetic: in polar night Open-Meteo repeats the day's start for both
    // (seen live for Utqiagvik, Alaska).
    const polar = structuredClone(forecast10001);
    polar.daily.sunrise[0] = polar.daily.time[0]!;
    polar.daily.sunset[0] = polar.daily.time[0]!;
    mockOpenMeteo({ ...recorded, forecast: () => Response.json(polar) });

    const response = await getSky("?zip=10001");

    const body = (await response.json()) as { days: { sunrise: string | null; sunset: string | null }[] };
    expect(body.days[0]).toMatchObject({ sunrise: null, sunset: null });
    expect(body.days[1]).toMatchObject({ sunrise: "2026-11-16T11:44:04Z", sunset: "2026-11-16T21:37:05Z" });
  });

  it("returns null sun times under the midnight sun", async () => {
    // Synthetic: in polar day Open-Meteo sends the day's start as sunrise and
    // the next day's start as sunset.
    const polar = structuredClone(forecast10001);
    polar.daily.sunrise[0] = polar.daily.time[0]!;
    polar.daily.sunset[0] = polar.daily.time[0]! + 86400;
    mockOpenMeteo({ ...recorded, forecast: () => Response.json(polar) });

    const response = await getSky("?zip=10001");

    const body = (await response.json()) as { days: { sunrise: string | null; sunset: string | null }[] };
    expect(body.days[0]).toMatchObject({ sunrise: null, sunset: null });
  });

  it("dates each day correctly across a daylight-saving change", async () => {
    // Synthetic: Open-Meteo's day starts are 86400 s apart at today's offset.
    // Asked on 2026-11-01 before the clocks go back (UTC-4), the second day
    // starts at 04:00 UTC on 2 November, which is 23:00 on 1 November locally.
    const fallBack = structuredClone(forecast10001);
    fallBack.utc_offset_seconds = -14400;
    fallBack.daily.time = [Date.UTC(2026, 10, 1, 4) / 1000, Date.UTC(2026, 10, 2, 4) / 1000];
    mockOpenMeteo({ ...recorded, forecast: () => Response.json(fallBack) });

    const response = await getSky("?zip=10001");

    const body = (await response.json()) as { days: { date: string }[] };
    expect(body.days.map((day) => day.date)).toEqual(["2026-11-01", "2026-11-02"]);
  });

  describe("when Open-Meteo fails", () => {
    const failures: [string, Reply][] = [
      ["answers 500", () => new Response("oops", { status: 500 })],
      ["is unreachable", () => Promise.reject(new TypeError("network down"))],
      ["answers with something that is not JSON", () => new Response("<html>", { status: 200 })],
      ["answers with an unexpected shape", () => Response.json({ error: true, reason: "bad" })],
    ];

    it.each(failures)("returns 502 and caches nothing when the forecast %s", async (_name, reply) => {
      mockOpenMeteo({ ...recorded, forecast: reply });

      const failed = await getSky("?zip=10001");

      expect(failed.status).toBe(502);
      expect(await failed.json()).toEqual({
        error: "upstream_error",
        message: "The weather provider is unavailable",
      });
      expect(await env.CACHE.get(forecastCacheKey("10001"))).toBeNull();

      // The next request asks Open-Meteo again and succeeds.
      vi.restoreAllMocks();
      const spy = mockOpenMeteo(recorded);
      const retried = await getSky("?zip=10001");
      expect(retried.status).toBe(200);
      expect(requestedURLs(spy).map((url) => url.hostname)).toEqual([FORECAST_HOST]);
    });

    it.each(failures.slice(0, 3))("returns 502 and caches nothing when the geocoder %s", async (_name, reply) => {
      mockOpenMeteo({ geocoding: reply });

      const failed = await getSky("?zip=10001");

      expect(failed.status).toBe(502);
      expect(await env.CACHE.get(geocodeCacheKey("10001"))).toBeNull();

      vi.restoreAllMocks();
      const spy = mockOpenMeteo(recorded);
      const retried = await getSky("?zip=10001");
      expect(retried.status).toBe(200);
      expect(spy).toHaveBeenCalledTimes(2);
    });
  });
});
