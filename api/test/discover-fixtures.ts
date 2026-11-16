// Provider responses for the /v1/discover tests, written by hand in the shape
// each provider documents (read 2026-11-15): Anthropic's web search tool page,
// OpenAI's web search guide and Responses reference, Gemini's Grounding with
// Google Search page and Interactions reference, Perplexity's Agent API
// quickstart and web search page. No provider was called and no key is real.
import type { ProviderId } from "../src/llm/types.ts";

/** An obviously fake key. Its tail is checked too, since some providers quote the end of a key. */
export const FAKE_KEY = "fake-llm-key-NOT-REAL-0000-tail9k7q";
export const KEY_TAIL = "tail9k7q";
export const KEY_PREFIX = "fake-llm";

/** Monday 16 November 2026, 15:00 UTC. */
export const NOW = new Date("2026-11-16T15:00:00Z");

export const HOSTS: Record<ProviderId, string> = {
  anthropic: "https://api.anthropic.com/v1/messages",
  openai: "https://api.openai.com/v1/responses",
  gemini: "https://generativelanguage.googleapis.com/v1beta/interactions",
  perplexity: "https://api.perplexity.ai/v1/agent",
};

export type Cite = { url: string; title: string; date?: string };

/** What the providers' searches found, as their metadata gives it. */
export const CITES: Cite[] = [
  { url: "https://news.example.com/science/tide-pools-warming", title: "Tide pools are warming faster than expected - Example News", date: "2026-11-14" },
  { url: "https://observatory.example.org/news/first-light/", title: "First light for the new telescope", date: "2026-11-15" },
  { url: "https://10.0.0.5/internal/report", title: "Internal" },
  { url: "http://plain.example.net/story-about-tides", title: "A story about tides" },
  { url: "https://news.example.com/science/old-story", title: "Old", date: "2026-10-01" },
  { url: "https://journal.example.com/future-paper", title: "Future" },
];

/** The model's JSON items: two good, and one of each kind that must be dropped or corrected. */
export const MODEL_ITEMS = [
  {
    title: "Tide pools are warming faster than expected",
    url: "https://news.example.com/science/tide-pools-warming",
    source: "Example News",
    published: "2026-11-14",
    description: "A survey of 40 tide pools found summer temperatures rising twice as fast as the open sea.",
    interest: 0,
  },
  {
    // Written by the model with www, a tracking parameter and no trailing slash: matched, and the provider's spelling returned.
    title: "New telescope sees first light &amp; it's sharp",
    url: "https://www.observatory.example.org/news/first-light?utm_source=ai",
    source: "Observatory News",
    published: "Nov 15, 2026",
    description: "The observatory released its <b>first images</b>.",
    interest: "new telescopes",
  },
  // Not among the citations: invented.
  { title: "An invented story", url: "https://made-up.example.net/story", source: "Nowhere", published: null, description: "x", interest: 0 },
  // Cited, but a private address.
  { title: "Internal report", url: "https://10.0.0.5/internal/report", source: "Intranet", published: null, description: "x", interest: 0 },
  // No link.
  { title: "No link at all", source: "Nowhere", published: null, description: "x", interest: 0 },
  // Not a web link.
  { title: "Not https", url: "javascript:alert(1)", source: "Nowhere", published: null, description: "x", interest: 0 },
  // Cited over http: returned as https.
  { title: "A story about tides", url: "http://plain.example.net/story-about-tides", source: "", published: "2 days ago", description: "", interest: 7 },
  // Older than the window.
  { title: "An old story", url: "https://news.example.com/science/old-story", source: "Example News", published: "2026-10-01", description: "x", interest: 0 },
  // Dated in the future: the date is dropped.
  { title: "A paper from the future", url: "https://journal.example.com/future-paper", source: "Journal", published: "2027-03-01", description: "x", interest: 1 },
  // The same page again.
  { title: "Duplicate", url: "https://news.example.com/science/tide-pools-warming/", source: "Example News", published: null, description: "x", interest: 0 },
];

/** What the route returns for MODEL_ITEMS with CITES and interests ["tide pools", "new telescopes"]. */
export const EXPECTED_ITEMS = [
  {
    title: "Tide pools are warming faster than expected",
    link: "https://news.example.com/science/tide-pools-warming",
    source: "Example News",
    published: "2026-11-14T00:00:00Z",
    excerpt: "A survey of 40 tide pools found summer temperatures rising twice as fast as the open sea.",
    interest: "tide pools",
  },
  {
    title: "New telescope sees first light & it's sharp",
    link: "https://observatory.example.org/news/first-light/",
    source: "Observatory News",
    published: "2026-11-15T00:00:00Z",
    excerpt: "The observatory released its <b>first images</b>.",
    interest: "new telescopes",
  },
  {
    title: "A story about tides",
    link: "https://plain.example.net/story-about-tides",
    source: "plain.example.net",
    published: null,
    excerpt: null,
    interest: null,
  },
  {
    title: "A paper from the future",
    link: "https://journal.example.com/future-paper",
    source: "Journal",
    published: null,
    excerpt: "x",
    interest: "new telescopes",
  },
];

export const modelJson = (items: unknown[] = MODEL_ITEMS) => JSON.stringify({ items });

// ---------------------------------------------------------------------------
// Success bodies, one builder per provider

export function anthropicBody(text: string, cites: Cite[] = CITES): unknown {
  // Citations split the answer into several text blocks; the JSON is split across two here.
  const cut = Math.floor(text.length / 2);
  return {
    id: "msg_01XFDUDYJgAACzvnptvVoYEL",
    type: "message",
    role: "assistant",
    model: "claude-haiku-5-5",
    content: [
      { type: "text", text: "I'll search for recent news on these interests." },
      { type: "server_tool_use", id: "srvtoolu_01WYG3ziw53XMcoyKL4XcZmE", name: "web_search", input: { query: "tide pools news" } },
      {
        type: "web_search_tool_result",
        tool_use_id: "srvtoolu_01WYG3ziw53XMcoyKL4XcZmE",
        content: cites.map((cite) => ({
          type: "web_search_result",
          url: cite.url,
          title: cite.title,
          encrypted_content: "EqgfCioIARgBIiQ3YTAwMjY1Mi1mZjM5LTQ1NGUtODgxNC1kNjNjNTk1ZWI3Y...",
          page_age: cite.date ?? null,
        })),
      },
      { type: "server_tool_use", id: "srvtoolu_02", name: "web_search", input: { query: "telescope first light" } },
      { type: "web_search_tool_result", tool_use_id: "srvtoolu_02", content: { type: "web_search_tool_result_error", error_code: "max_uses_exceeded" } },
      { type: "text", text: text.slice(0, cut) },
      {
        type: "text",
        text: text.slice(cut),
        citations: [
          {
            type: "web_search_result_location",
            url: cites[0]?.url ?? "https://news.example.com/",
            title: cites[0]?.title ?? "",
            encrypted_index: "Eo8BCioIAhgBIiQyYjQ0OWJmZi1lNm..",
            cited_text: "A survey of 40 tide pools found summer temperatures rising...",
          },
        ],
      },
    ],
    stop_reason: "end_turn",
    usage: { input_tokens: 6039, output_tokens: 931, server_tool_use: { web_search_requests: 1 } },
  };
}

export function openaiBody(text: string, cites: Cite[] = CITES): unknown {
  return {
    id: "resp_67ccd2bed1ec8190b14f964abc0542670bb6a6b452d3795b",
    object: "response",
    created_at: 1771891641,
    status: "completed",
    error: null,
    incomplete_details: null,
    model: "gpt-6-luna",
    output: [
      {
        type: "web_search_call",
        id: "ws_67c9fa0502748190b7dd390736892e100be649c1a5ff9609",
        status: "completed",
        action: { type: "search", query: "tide pools news this week", sources: cites.map((cite) => ({ type: "url", url: cite.url })) },
      },
      {
        id: "msg_67c9fa077e288190af08fdffda2e34f20be649c1a5ff9609",
        type: "message",
        status: "completed",
        role: "assistant",
        content: [
          {
            type: "output_text",
            text,
            annotations: cites.slice(0, 1).map((cite) => ({ type: "url_citation", start_index: 0, end_index: 10, url: cite.url, title: cite.title })),
          },
        ],
      },
    ],
    store: false,
    usage: { input_tokens: 9000, output_tokens: 1200, total_tokens: 10200 },
  };
}

export function geminiBody(text: string, cites: Cite[] = CITES, withResults = true): unknown {
  return {
    created: "2026-11-16T15:00:00Z",
    id: "v1_ChdPU0F4YWFtNkFwS2kxZThQZ05lbXdROBIXT1NBeGFhbTZBcEtpMWU4UGdOZW13UTg",
    model: "gemini-3.5-flash-lite",
    object: "interaction",
    status: "completed",
    steps: [
      { type: "thought", summary: [{ type: "text", text: "I need to search for recent news." }], signature: "CoMDAXLI2nynRYojJIy6B1Jh9os2crpWLfB0..." },
      { type: "google_search_call", id: "search_call_19201", arguments: { queries: ["tide pools news this week"] } },
      withResults
        ? { type: "google_search_result", call_id: "search_call_19201", result: cites.map((cite) => ({ title: cite.title, url: cite.url, snippet: "…" })) }
        : { type: "google_search_result", call_id: "search_call_19201", result: [{ search_suggestions: "<!-- HTML and CSS for the search widget -->" }] },
      {
        type: "model_output",
        content: [
          {
            type: "text",
            text,
            annotations: cites.map((cite) => ({ type: "url_citation", url: cite.url, title: new URL(cite.url).hostname, start_index: 0, end_index: 10 })),
          },
        ],
      },
    ],
    updated: "2026-11-16T15:00:00Z",
    usage: { total_input_tokens: 7000, total_output_tokens: 900 },
  };
}

export function perplexityBody(text: string, cites: Cite[] = CITES): unknown {
  return {
    background: false,
    completed_at: 1771891641,
    created_at: 1771891641,
    error: null,
    id: "resp_aca2bace-3782-4d81-be45-a82c24cfff9d",
    incomplete_details: null,
    max_output_tokens: 4096,
    model: "openai/gpt-6-luna",
    object: "response",
    output: [
      {
        queries: ["tide pools news", "telescope first light"],
        results: cites.map((cite, index) => ({
          date: cite.date ?? null,
          id: index + 1,
          last_updated: "2026-11-16T12:12:34",
          snippet: "",
          source: "web",
          title: cite.title,
          url: cite.url,
        })),
        type: "search_results",
      },
      {
        content: [{ annotations: [], logprobs: [], text, type: "output_text" }],
        id: "msg_1140f2e2-5bdb-4be8-a4c8-9d56bf61f35f",
        role: "assistant",
        status: "completed",
        type: "message",
      },
    ],
    status: "completed",
    store: false,
    usage: { input_tokens: 12088, output_tokens: 2743, tool_calls_details: { search_web: { invocation: 1 } }, total_tokens: 14831 },
  };
}

export const SUCCESS: Record<ProviderId, (text: string, cites?: Cite[]) => unknown> = {
  anthropic: anthropicBody,
  openai: openaiBody,
  gemini: geminiBody,
  perplexity: perplexityBody,
};

// ---------------------------------------------------------------------------
// Error bodies, as each provider documents them (read again 2026-11-16 for
// task 20; the URLs are in each adapter's classifyError), some quoting part of
// the key. Where a page gives the code but no body, the body is the provider's
// usual envelope with that code.

type ErrorCase = { status: number; body: unknown };

const openaiError = (code: string, type: string | null, message: string) => ({ error: { message, type, param: null, code } });

export const ERRORS: Record<ProviderId, { invalidKey: ErrorCase; rateLimited: ErrorCase[]; quota: ErrorCase[]; server: ErrorCase }> = {
  anthropic: {
    invalidKey: { status: 401, body: { type: "error", error: { type: "authentication_error", message: `invalid x-api-key ${FAKE_KEY}` } } },
    rateLimited: [
      { status: 429, body: { type: "error", error: { type: "rate_limit_error", message: "Number of request tokens has exceeded your per-minute rate limit" } } },
      // A ramp limit (the docs give the code and the gist of the message, not its words).
      {
        status: 429,
        body: {
          type: "error",
          error: { type: "rate_limit_error", message: "Ramp limit exceeded: your current ramp limit is 50,000 input tokens per minute.", details: { error_code: "ramp_limit_exceeded" } },
          request_id: "req_018EeWyXxfu5pfWkrYcMdjWG",
        },
      },
    ],
    quota: [
      { status: 402, body: { type: "error", error: { type: "billing_error", message: "Billing problem" } } },
      { status: 400, body: { type: "error", error: { type: "invalid_request_error", message: "Your credit balance is too low to access the Anthropic API." } } },
      // The tier's monthly spend cap: a 429 rate_limit_error told apart by details.error_code.
      {
        status: 429,
        body: {
          type: "error",
          error: {
            type: "rate_limit_error",
            message:
              "You have reached your API usage limits: your organization has crossed its monthly API usage threshold, set based on your organization's API tier. You will regain access on 2026-12-01 at 00:00 UTC.",
            details: { error_code: "enforced_spend_limit_reached" },
          },
          request_id: "req_018EeWyXxfu5pfWkrYcMdjWG",
        },
      },
      // A spend limit the user set, on the organization and on a workspace.
      {
        status: 400,
        body: {
          type: "error",
          error: { type: "invalid_request_error", message: "You have reached your specified API usage limits. You will regain access on 2026-12-01 at 00:00 UTC." },
        },
      },
      {
        status: 400,
        body: {
          type: "error",
          error: { type: "invalid_request_error", message: "You have reached your specified workspace API usage limits. You will regain access on 2026-12-01 at 00:00 UTC." },
        },
      },
    ],
    server: { status: 529, body: { type: "error", error: { type: "overloaded_error", message: "Overloaded" } } },
  },
  openai: {
    invalidKey: {
      status: 401,
      body: { error: { message: `Incorrect API key provided: fake-llm**********${KEY_TAIL}.`, type: "invalid_request_error", param: null, code: "invalid_api_key" } },
    },
    rateLimited: [
      { status: 429, body: openaiError("rate_limit_exceeded", "requests", "Rate limit reached for requests") },
      { status: 429, body: openaiError("slow_down", "rate_limit_error", "Your request rate increased too quickly.") },
    ],
    quota: [
      { status: 429, body: openaiError("credit_balance_exhausted", "insufficient_quota", "Your organization has no prepaid credits remaining.") },
      { status: 429, body: openaiError("organization_spend_limit_exceeded", null, "Your organization reached its enforced spend limit.") },
      { status: 429, body: openaiError("project_spend_limit_exceeded", null, "Your project reached its enforced spend limit.") },
      { status: 429, body: openaiError("organization_usage_limit_exceeded", null, "Your organization reached its OpenAI-assigned usage limit.") },
      { status: 429, body: openaiError("insufficient_quota", "insufficient_quota", "You exceeded your current quota.") },
    ],
    server: { status: 500, body: { error: { message: "The server had an error while processing your request.", type: "server_error", param: null, code: null } } },
  },
  gemini: {
    invalidKey: { status: 401, body: { error: { code: "authentication", message: `API key not valid: ${FAKE_KEY}` } } },
    rateLimited: [
      { status: 429, body: { error: { code: "rate_limit_exceeded", message: "You have exceeded the per-minute or per-second request or token limit." } } },
      { status: 429, body: { error: { code: "too_many_requests", message: "Too many requests in a short period." } } },
      // The daily quota resets: try later, not top up.
      { status: 429, body: { error: { code: "quota_exceeded", message: "You have exceeded your daily quota." } } },
      // The legacy generateContent shape, in case it is ever answered.
      { status: 429, body: { error: { code: 429, message: "Resource has been exhausted (e.g. check quota).", status: "RESOURCE_EXHAUSTED" } } },
    ],
    quota: [{ status: 402, body: { error: { code: "payment_required", message: "Your Prepay credit balance is depleted." } } }],
    server: { status: 503, body: { error: { code: "service_unavailable", message: "The model is overloaded." } } },
  },
  perplexity: {
    invalidKey: { status: 401, body: { error: { message: `Invalid API key ...${KEY_TAIL}`, type: "invalid_api_key", code: 401 } } },
    rateLimited: [
      {
        status: 429,
        body: { error: { message: "Token rate limit exceeded (TPM). Retry after the Retry-After interval.", type: "token_rate_limit_exceeded", code: 429 } },
      },
      { status: 429, body: { error: { message: "Request rate limit exceeded, please try again later.", type: "request_rate_limit_exceeded", code: 429 } } },
    ],
    quota: [{ status: 402, body: { error: { message: "Insufficient credits", type: "insufficient_credits", code: 402 } } }],
    server: { status: 500, body: { error: { message: "Internal server error", type: "server_error", code: 500 } } },
  },
};
