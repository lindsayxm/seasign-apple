// Perplexity Agent API with its web_search tool. Sonar Chat Completions
// support ended on 2026-09-27; the Agent API is its replacement.
// Docs (read 2026-11-15): https://docs.perplexity.ai/docs/agent-api/tools/web-search,
// /docs/agent-api/effort, /docs/agent-api/models, /docs/agent-api/migrate-from-sonar/how-to,
// /api-reference/agent-post, /docs/resources/faq.
import { DiscoverFailure, type Adapter, type Citation, type DiscoverErrorCode } from "./types.ts";
import { asArray, asString, isRecord } from "./http.ts";
import { INSTRUCTIONS, MAX_ITEMS, MAX_OUTPUT_TOKENS, buildInput } from "./prompt.ts";

/**
 * The model of Perplexity's `fast` effort level (the one it maps `sonar` to),
 * $0.10 / $0.50 per million tokens. `perplexity/sonar` is the alternative.
 */
export const PERPLEXITY_MODEL = "openai/gpt-6-luna";
export const PERPLEXITY_HOST = "api.perplexity.ai";

export const perplexity: Adapter = {
  id: "perplexity",
  host: PERPLEXITY_HOST,
  model: PERPLEXITY_MODEL,

  buildRequest(key, query) {
    return {
      url: `https://${PERPLEXITY_HOST}/v1/agent`,
      headers: { "content-type": "application/json", authorization: `Bearer ${key}` },
      body: {
        model: PERPLEXITY_MODEL,
        instructions: INSTRUCTIONS,
        input: buildInput(query),
        tools: [
          {
            type: "web_search",
            // Fast Search: $1 per 1,000 calls instead of $2.50.
            search_type: "fast",
            max_results: MAX_ITEMS,
            filters: { search_recency_filter: "week" },
          },
        ],
        // One research step, as the `fast` effort level runs.
        max_steps: 1,
        max_output_tokens: MAX_OUTPUT_TOKENS,
        reasoning: { effort: "low" },
        store: false,
      },
    };
  },

  readResponse(body) {
    if (!isRecord(body) || !Array.isArray(body.output)) throw new DiscoverFailure("provider_error");
    if (body.status === "failed") throw new DiscoverFailure("provider_error");
    const texts: string[] = [];
    const citations: Citation[] = [];
    for (const item of body.output) {
      if (!isRecord(item)) continue;
      if (item.type === "message") {
        for (const part of asArray(item.content)) {
          if (isRecord(part) && part.type === "output_text") texts.push(asString(part.text) ?? "");
        }
      } else if (item.type === "search_results") {
        for (const result of asArray(item.results)) {
          if (isRecord(result) && typeof result.url === "string") {
            citations.push({ url: result.url, title: asString(result.title), date: asString(result.date) });
          }
        }
      }
    }
    return { text: texts.join(""), citations };
  },

  classifyError(status): DiscoverErrorCode {
    if (status === 401) return "invalid_key";
    // An account out of credits is answered with 402 Payment Required.
    if (status === 402) return "quota_exceeded";
    if (status === 429) return "rate_limited";
    return "provider_error";
  },
};
