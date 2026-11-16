// OpenAI Responses API with the hosted web_search tool.
// Docs (read 2026-11-15): https://developers.openai.com/api/docs/guides/tools-web-search,
// /api/docs/models/gpt-6-luna, /api/reference/resources/responses/methods/create,
// /api/docs/guides/error-codes, /api/docs/pricing.
import { DiscoverFailure, type Adapter, type Citation, type DiscoverErrorCode } from "./types.ts";
import { asArray, asString, errorField, isRecord } from "./http.ts";
import { INSTRUCTIONS, MAX_OUTPUT_TOKENS, MAX_SEARCHES, buildInput } from "./prompt.ts";

/** GPT-6 Luna: OpenAI's most efficient model ($0.10 / $0.50 per million tokens); supports web_search. */
export const OPENAI_MODEL = "gpt-6-luna";
export const OPENAI_HOST = "api.openai.com";

/** 429 codes that mean the account cannot spend more until someone changes its credit or limits. */
const QUOTA_CODES = new Set([
  "credit_balance_exhausted",
  "organization_spend_limit_exceeded",
  "project_spend_limit_exceeded",
  "organization_usage_limit_exceeded",
  "insufficient_quota",
]);

export const openai: Adapter = {
  id: "openai",
  host: OPENAI_HOST,
  model: OPENAI_MODEL,

  buildRequest(key, query) {
    return {
      url: `https://${OPENAI_HOST}/v1/responses`,
      headers: { "content-type": "application/json", authorization: `Bearer ${key}` },
      body: {
        model: OPENAI_MODEL,
        instructions: INSTRUCTIONS,
        input: buildInput(query),
        tools: [
          {
            type: "web_search",
            search_context_size: "low",
            ...(query.timezone ? { user_location: { type: "approximate", timezone: query.timezone } } : {}),
          },
        ],
        // The complete list of URLs the search returned, not only the ones cited inline.
        include: ["web_search_call.action.sources"],
        max_tool_calls: MAX_SEARCHES,
        max_output_tokens: MAX_OUTPUT_TOKENS,
        reasoning: { effort: "low" },
        store: false,
      },
    };
  },

  readResponse(body) {
    if (!isRecord(body) || !Array.isArray(body.output)) throw new DiscoverFailure("provider_error");
    if (body.status === "failed") {
      throw new DiscoverFailure(errorField(body, "code") === "rate_limit_exceeded" ? "rate_limited" : "provider_error");
    }
    // `incomplete` (out of output tokens) is read as it is: complete items in the text are kept.
    const texts: string[] = [];
    const citations: Citation[] = [];
    for (const item of body.output) {
      if (!isRecord(item)) continue;
      if (item.type === "message") {
        for (const part of asArray(item.content)) {
          if (!isRecord(part) || part.type !== "output_text") continue;
          texts.push(asString(part.text) ?? "");
          for (const annotation of asArray(part.annotations)) {
            if (isRecord(annotation) && annotation.type === "url_citation" && typeof annotation.url === "string") {
              citations.push({ url: annotation.url, title: asString(annotation.title) });
            }
          }
        }
      } else if (item.type === "web_search_call" && isRecord(item.action)) {
        for (const source of asArray(item.action.sources)) {
          if (isRecord(source) && source.type === "url" && typeof source.url === "string") citations.push({ url: source.url });
        }
        // A page the model opened is a page the provider fetched.
        if (item.action.type === "open_page" && typeof item.action.url === "string") citations.push({ url: item.action.url });
      }
    }
    return { text: texts.join(""), citations };
  },

  // Docs (read 2026-11-16): https://developers.openai.com/api/docs/guides/error-codes
  // and /api/docs/guides/rate-limits. Every billing, spend and usage-limit
  // error is a 429 that retrying does not cure; "the broader `error.type` can
  // still be `insufficient_quota`". Anything else on a 429 (`slow_down`, a
  // request or token rate limit) is a rate limit.
  classifyError(status, body): DiscoverErrorCode {
    if (status === 401) return "invalid_key";
    if (status === 402) return "quota_exceeded";
    if (status === 429) {
      const code = errorField(body, "code");
      if ((code !== undefined && QUOTA_CODES.has(code)) || errorField(body, "type") === "insufficient_quota") return "quota_exceeded";
      return "rate_limited";
    }
    return "provider_error";
  },
};
