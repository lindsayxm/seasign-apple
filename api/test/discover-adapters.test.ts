import { exports } from "cloudflare:workers";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { ANTHROPIC_MODEL } from "../src/llm/anthropic.ts";
import { GEMINI_MODEL } from "../src/llm/gemini.ts";
import { PROVIDER_MAX_BYTES, callProvider } from "../src/llm/http.ts";
import { ADAPTERS } from "../src/llm/index.ts";
import { OPENAI_MODEL } from "../src/llm/openai.ts";
import { PERPLEXITY_MODEL } from "../src/llm/perplexity.ts";
import { PROVIDERS, type ProviderId } from "../src/llm/types.ts";
import { CITES, ERRORS, EXPECTED_ITEMS, FAKE_KEY, HOSTS, MODEL_ITEMS, NOW, SUCCESS, geminiBody, modelJson } from "./discover-fixtures.ts";

const INTERESTS = ["tide pools", "new telescopes"];

type Reply = (request: Request, signal: AbortSignal | undefined) => Response | Promise<Response>;

/** Replaces outbound fetch: the provider's endpoint answers with `reply`, anything else throws. */
function mockProvider(provider: ProviderId, reply: Reply) {
  return vi.spyOn(globalThis, "fetch").mockImplementation(async (input, init) => {
    const request = new Request(input, init);
    if (request.url !== HOSTS[provider]) throw new Error("Unexpected outbound request");
    return reply(request, init?.signal ?? undefined);
  });
}

const json = (body: unknown, status = 200, headers: Record<string, string> = {}) =>
  new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json", ...headers } });

const post = (body: unknown, key = FAKE_KEY) =>
  exports.default.fetch("https://example.com/v1/discover", {
    method: "POST",
    headers: { "content-type": "application/json", "x-llm-key": key },
    body: JSON.stringify(body),
  });

type Answer = { status: number; body: { items?: unknown[]; provider?: string; searchedAt?: string; error?: string; message?: string } };

async function discover(provider: ProviderId, extra: Record<string, unknown> = {}): Promise<Answer> {
  const response = await post({ provider, interests: INTERESTS, ...extra });
  return { status: response.status, body: (await response.json()) as Answer["body"] };
}

const MODELS: Record<ProviderId, string> = {
  anthropic: ANTHROPIC_MODEL,
  openai: OPENAI_MODEL,
  gemini: GEMINI_MODEL,
  perplexity: PERPLEXITY_MODEL,
};

beforeEach(() => {
  vi.useFakeTimers({ toFake: ["Date"], now: NOW });
  // Failures log one fixed line each; keep the output quiet.
  vi.spyOn(console, "warn").mockImplementation(() => {});
});

afterEach(() => {
  vi.useRealTimers();
  vi.restoreAllMocks();
});

describe.each(PROVIDERS)("%s adapter", (provider) => {
  const success = SUCCESS[provider];
  const errors = ERRORS[provider];

  it("sends one POST to the provider's fixed endpoint, with the key only in its auth header", async () => {
    // A request body can only be read inside the mock, in the Worker's own context.
    const seen: { request: Request; body: string }[] = [];
    const spy = mockProvider(provider, async (request) => {
      seen.push({ request, body: await request.text() });
      return json(success(modelJson()));
    });

    const { status } = await discover(provider, { timezone: "America/Chicago" });

    expect(status).toBe(200);
    expect(spy).toHaveBeenCalledTimes(1);
    const { request, body } = seen[0] as { request: Request; body: string };
    expect(request.method).toBe("POST");
    expect(request.url).toBe(HOSTS[provider]);
    expect(request.url).not.toContain(FAKE_KEY);
    expect(body).not.toContain(FAKE_KEY);
    const sent = JSON.parse(body) as Record<string, unknown>;
    expect(sent.model).toBe(MODELS[provider]);
    // No sampling parameters (rejected or ignored by current models).
    expect(sent).not.toHaveProperty("temperature");
    expect(sent).not.toHaveProperty("top_p");
    // The interests are in the prompt as a JSON array, and today's date is the user's.
    expect(body).toContain(JSON.stringify(JSON.stringify(INTERESTS)).slice(1, -1));
    expect(body).toContain("Today is 2026-11-16 (America/Chicago)");

    const headersWithKey = [...request.headers].filter(([, value]) => value.includes(FAKE_KEY)).map(([name, value]) => [name, value]);
    const expected = {
      anthropic: [["x-api-key", FAKE_KEY]],
      openai: [["authorization", `Bearer ${FAKE_KEY}`]],
      gemini: [["x-goog-api-key", FAKE_KEY]],
      perplexity: [["authorization", `Bearer ${FAKE_KEY}`]],
    }[provider];
    expect(headersWithKey).toEqual(expected);
  });

  it("asks for a small, bounded result", async () => {
    let sent: Record<string, unknown> = {};
    mockProvider(provider, async (request) => {
      sent = (await request.json()) as Record<string, unknown>;
      return json(success(modelJson()));
    });

    await discover(provider);

    switch (provider) {
      case "anthropic":
        expect(sent).toMatchObject({
          max_tokens: 4096,
          output_config: { effort: "low" },
          tools: [{ type: "web_search_20250305", name: "web_search", max_uses: 3 }],
        });
        expect(sent).not.toHaveProperty("thinking");
        break;
      case "openai":
        expect(sent).toMatchObject({
          max_output_tokens: 4096,
          max_tool_calls: 3,
          reasoning: { effort: "low" },
          store: false,
          include: ["web_search_call.action.sources"],
          tools: [{ type: "web_search", search_context_size: "low" }],
        });
        break;
      case "gemini":
        expect(sent).toMatchObject({
          generation_config: { max_output_tokens: 4096, thinking_level: "low" },
          store: false,
          tools: [{ type: "google_search" }],
        });
        break;
      case "perplexity":
        expect(sent).toMatchObject({
          max_steps: 1,
          max_output_tokens: 4096,
          store: false,
          tools: [{ type: "web_search", search_type: "fast", max_results: 20, filters: { search_recency_filter: "week" } }],
        });
        break;
    }
  });

  it("returns the cited items, cleaned, and drops invented, unsafe, linkless, old and repeated ones", async () => {
    mockProvider(provider, () => json(success(modelJson())));

    const { status, body } = await discover(provider);

    expect(status).toBe(200);
    expect(body.provider).toBe(provider);
    expect(body.searchedAt).toBe("2026-11-16T15:00:00Z");
    expect(body.items).toEqual(EXPECTED_ITEMS);
  });

  it("reads output wrapped in a code fence and prose", async () => {
    const text = `Here is what I found this week:\n\n\`\`\`json\n${JSON.stringify({ items: MODEL_ITEMS.slice(0, 2) }, null, 2)}\n\`\`\`\n\nLet me know if you want more.`;
    mockProvider(provider, () => json(success(text)));

    const { status, body } = await discover(provider);

    expect(status).toBe(200);
    expect(body.items).toEqual(EXPECTED_ITEMS.slice(0, 2));
  });

  it("keeps the whole items of an answer cut off mid-way, and answers 200 with no items for text that is not JSON", async () => {
    const full = modelJson(MODEL_ITEMS.slice(0, 2));
    // Cut inside the second item, as an answer that ran out of output tokens is.
    mockProvider(provider, () => json(success(full.slice(0, full.indexOf("Observatory News")))));
    expect((await discover(provider)).body.items).toEqual(EXPECTED_ITEMS.slice(0, 1));

    vi.restoreAllMocks();
    vi.spyOn(console, "warn").mockImplementation(() => {});
    mockProvider(provider, () => json(success('{"items": [ {"title": "x", "url": ')));
    expect(await discover(provider)).toEqual({ status: 200, body: { items: [], provider, searchedAt: "2026-11-16T15:00:00Z" } });

    vi.restoreAllMocks();
    vi.spyOn(console, "warn").mockImplementation(() => {});
    mockProvider(provider, () => json(success("I could not find anything recent on these topics.")));
    expect((await discover(provider)).body.items).toEqual([]);
  });

  it("drops malformed items and keeps the rest", async () => {
    const items = [
      { title: 42, url: CITES[0]?.url },
      { title: "Missing url" },
      { title: "Url is a number", url: 7 },
      "just a string",
      ["an", "array"],
      { title: "", url: "https://news.example.com/science/tide-pools-warming" },
      MODEL_ITEMS[1],
    ];
    mockProvider(provider, () => json(success(JSON.stringify({ items }))));

    const { body } = await discover(provider);

    // The empty title falls back to the provider's title for that page; the
    // date comes from the provider's metadata where it gives one.
    const dated = provider === "anthropic" || provider === "perplexity";
    expect(body.items).toEqual([
      {
        ...EXPECTED_ITEMS[0],
        title: "Tide pools are warming faster than expected - Example News",
        source: "news.example.com",
        published: dated ? "2026-11-14T00:00:00Z" : null,
        excerpt: null,
        interest: null,
      },
      EXPECTED_ITEMS[1],
    ]);
  });

  it("keeps an item whose optional fields have the wrong type, without those fields", async () => {
    const items = [{ ...MODEL_ITEMS[1], source: 5, published: { day: 15 }, description: ["a"], interest: [0, 1] }];
    mockProvider(provider, () => json(success(JSON.stringify({ items }))));

    const { body } = await discover(provider);

    const dated = provider === "anthropic" || provider === "perplexity";
    expect(body.items).toEqual([
      {
        ...EXPECTED_ITEMS[1],
        source: "observatory.example.org",
        published: dated ? "2026-11-15T00:00:00Z" : null,
        excerpt: null,
        interest: null,
      },
    ]);
  });

  it("returns only links that appear in the provider's citations", async () => {
    // The search found only the first page; the model names three.
    mockProvider(provider, () => json(success(modelJson(MODEL_ITEMS.slice(0, 3)), CITES.slice(0, 1))));

    const { body } = await discover(provider);

    expect(body.items).toEqual(EXPECTED_ITEMS.slice(0, 1));
  });

  it("returns no items when the provider gives no citations at all", async () => {
    mockProvider(provider, () => json(success(modelJson(), [])));

    const { status, body } = await discover(provider);

    expect(status).toBe(200);
    expect(body.items).toEqual([]);
  });

  it("returns at most 20 items, each link once", async () => {
    const cites = Array.from({ length: 30 }, (_, i) => ({ url: `https://news.example.com/story-${i}`, title: `Story ${i}`, date: "2026-11-15" }));
    const items = cites.flatMap((cite) => [
      { title: cite.title, url: cite.url, source: "Example", published: null, description: "d", interest: 0 },
      { title: cite.title, url: `${cite.url}/`, source: "Example", published: null, description: "d", interest: 0 },
    ]);
    mockProvider(provider, () => json(success(JSON.stringify({ items }), cites)));

    const { body } = await discover(provider);

    expect(body.items).toHaveLength(20);
    expect(new Set((body.items as { link: string }[]).map((item) => item.link)).size).toBe(20);
  });

  it("answers 401 invalid_key when the provider refuses the key", async () => {
    mockProvider(provider, () => json(errors.invalidKey.body, errors.invalidKey.status));
    expect(await discover(provider)).toEqual({ status: 401, body: { error: "invalid_key", message: "The provider did not accept the API key" } });
  });

  it("answers 429 rate_limited when the provider limits the key", async () => {
    mockProvider(provider, () => json(errors.rateLimited.body, errors.rateLimited.status, { "retry-after": "20" }));
    expect(await discover(provider)).toEqual({
      status: 429,
      body: { error: "rate_limited", message: "The provider is limiting requests for this key; try again later" },
    });
  });

  it("answers 402 quota_exceeded when the key's account has no credit or quota", async () => {
    for (const quota of errors.quota) {
      vi.restoreAllMocks();
      vi.spyOn(console, "warn").mockImplementation(() => {});
      mockProvider(provider, () => json(quota.body, quota.status));
      expect(await discover(provider)).toEqual({
        status: 402,
        body: { error: "quota_exceeded", message: "The provider says the key's account has no credit or quota left" },
      });
    }
  });

  it("answers 502 provider_error for a server error, a redirect, an error body that is not JSON, and an unexpected envelope", async () => {
    const replies: Reply[] = [
      () => json(errors.server.body, errors.server.status),
      () => new Response(null, { status: 302, headers: { location: "https://elsewhere.example.com/" } }),
      () => new Response("<html>Bad gateway</html>", { status: 502 }),
      () => new Response("not json at all", { status: 200 }),
      () => json({ unexpected: true }),
      () => json([1, 2, 3]),
      () => Promise.reject(new TypeError("network connection lost")),
    ];
    for (const reply of replies) {
      vi.restoreAllMocks();
      vi.spyOn(console, "warn").mockImplementation(() => {});
      mockProvider(provider, reply);
      expect(await discover(provider)).toEqual({ status: 502, body: { error: "provider_error", message: "The provider could not complete the search" } });
    }
  });

  it("refuses a response body over 1 MB, with or without a Content-Length, without reading all of it", async () => {
    const chunk = new Uint8Array(64 * 1024).fill(32);
    let pulled = 0;
    const endless = () =>
      new Response(
        new ReadableStream<Uint8Array>({
          pull(controller) {
            pulled += chunk.byteLength;
            controller.enqueue(chunk);
          },
        }),
        { status: 200 },
      );
    mockProvider(provider, endless);
    expect((await discover(provider)).body.error).toBe("provider_error");
    expect(pulled).toBeLessThanOrEqual(PROVIDER_MAX_BYTES + 3 * chunk.byteLength);

    vi.restoreAllMocks();
    vi.spyOn(console, "warn").mockImplementation(() => {});
    mockProvider(provider, () => new Response("{}", { status: 200, headers: { "content-length": String(PROVIDER_MAX_BYTES + 1) } }));
    expect((await discover(provider)).body.error).toBe("provider_error");

    // A body of exactly the cap is read.
    vi.restoreAllMocks();
    const text = modelJson(MODEL_ITEMS.slice(0, 1));
    const base = JSON.stringify(success(text));
    const padded = `${base.slice(0, -1)},"padding":"${" ".repeat(PROVIDER_MAX_BYTES - new TextEncoder().encode(base).length - 13)}"}`;
    expect(new TextEncoder().encode(padded).length).toBe(PROVIDER_MAX_BYTES);
    mockProvider(provider, () => new Response(padded, { status: 200 }));
    expect((await discover(provider)).body.items).toEqual(EXPECTED_ITEMS.slice(0, 1));
  });

  it("gives up with timeout when the provider does not answer in time, and aborts the request", async () => {
    let aborted = false;
    mockProvider(
      provider,
      (_request, signal) =>
        new Promise<Response>((_resolve, reject) => {
          signal?.addEventListener("abort", () => {
            aborted = true;
            reject(new DOMException("The operation was aborted", "AbortError"));
          });
        }),
    );

    await expect(callProvider(ADAPTERS[provider], FAKE_KEY, { interests: INTERESTS, today: "2026-11-16" }, { timeoutMs: 50 })).rejects.toMatchObject({
      code: "timeout",
    });
    expect(aborted).toBe(true);
  });

  it("gives up with timeout when the body stalls after the headers", async () => {
    mockProvider(provider, () => new Response(new ReadableStream<Uint8Array>({ start: (controller) => controller.enqueue(new Uint8Array([123])) }), { status: 200 }));

    await expect(callProvider(ADAPTERS[provider], FAKE_KEY, { interests: INTERESTS, today: "2026-11-16" }, { timeoutMs: 50 })).rejects.toMatchObject({
      code: "timeout",
    });
  });
});

describe("provider-specific shapes", () => {
  it("anthropic: reads citations from text blocks and results, and an error object inside a search result is not a list", async () => {
    mockProvider("anthropic", () => json(SUCCESS.anthropic(modelJson(MODEL_ITEMS.slice(0, 1)), CITES.slice(0, 1))));
    expect((await discover("anthropic")).body.items).toEqual(EXPECTED_ITEMS.slice(0, 1));
  });

  it("anthropic: when every search failed inside a 200, the answer is an error, not an empty list", async () => {
    const failedSearch = (code: string) => ({
      type: "message",
      role: "assistant",
      content: [
        { type: "server_tool_use", id: "srvtoolu_01", name: "web_search", input: { query: "tide pools" } },
        { type: "web_search_tool_result", tool_use_id: "srvtoolu_01", content: { type: "web_search_tool_result_error", error_code: code } },
        { type: "text", text: '{"items":[]}' },
      ],
      stop_reason: "end_turn",
    });
    mockProvider("anthropic", () => json(failedSearch("too_many_requests")));
    expect((await discover("anthropic")).body.error).toBe("rate_limited");
    vi.restoreAllMocks();
    vi.spyOn(console, "warn").mockImplementation(() => {});
    mockProvider("anthropic", () => json(failedSearch("unavailable")));
    expect((await discover("anthropic")).body.error).toBe("provider_error");
  });

  it("openai: a failed response is a provider error, or rate_limited when it says so", async () => {
    const failed = (code: string) => ({ ...(SUCCESS.openai("") as object), status: "failed", error: { code, message: `quoting ${FAKE_KEY}` } });
    mockProvider("openai", () => json(failed("server_error")));
    expect((await discover("openai")).status).toBe(502);
    vi.restoreAllMocks();
    vi.spyOn(console, "warn").mockImplementation(() => {});
    mockProvider("openai", () => json(failed("rate_limit_exceeded")));
    expect((await discover("openai")).status).toBe(429);
  });

  it("gemini: with only search suggestions, the annotations are the citations", async () => {
    mockProvider("gemini", () => json(geminiBody(modelJson(), CITES, false)));
    expect((await discover("gemini")).body.items).toEqual(EXPECTED_ITEMS);
  });

  it("gemini: a failed search inside a 200 with nothing cited is a provider error", async () => {
    const body = {
      status: "completed",
      steps: [
        { type: "google_search_call", id: "search_call_1", arguments: { queries: ["tide pools"] } },
        { type: "google_search_result", call_id: "search_call_1", is_error: true, result: [] },
        { type: "model_output", content: [{ type: "text", text: '{"items":[]}' }] },
      ],
    };
    mockProvider("gemini", () => json(body));
    expect((await discover("gemini")).body.error).toBe("provider_error");
  });

  it("gemini: grounding redirect links are not returned", async () => {
    const redirect = "https://vertexaisearch.cloud.google.com/grounding-api-redirect/AbF9wXE";
    const items = [{ title: "Redirected", url: redirect, source: "x", published: null, description: "x", interest: 0 }];
    mockProvider("gemini", () => json(geminiBody(JSON.stringify({ items }), [{ url: redirect, title: "example.com" }])));
    expect((await discover("gemini")).body.items).toEqual([]);
  });

  it("perplexity: the search result's own date is preferred to the model's", async () => {
    const items = [{ ...MODEL_ITEMS[0], published: "2026-11-01" }];
    mockProvider("perplexity", () => json(SUCCESS.perplexity(JSON.stringify({ items }), CITES.slice(0, 1))));
    expect((await discover("perplexity")).body.items).toEqual(EXPECTED_ITEMS.slice(0, 1));
  });
});
