// Gemini Interactions API with Grounding with Google Search. The docs now make
// the Interactions API the default; generateContent is called legacy.
// Docs (read 2026-11-15): https://aistudio.google.com/docs/google-search,
// /api-reference/interactions-api/create-interaction, /docs/api-errors,
// /docs/models/gemini-3.5-flash-lite, /docs/pricing, /docs/deprecations.
import { DiscoverFailure, type Adapter, type Citation, type DiscoverErrorCode } from "./types.ts";
import { asArray, asString, errorField, isRecord } from "./http.ts";
import { INSTRUCTIONS, MAX_OUTPUT_TOKENS, buildInput } from "./prompt.ts";

/** Gemini 3.5 Flash-Lite: the fastest, lowest-cost 3.5 model ($0.30 / $2.50 per million tokens); stable, supports search grounding. */
export const GEMINI_MODEL = "gemini-3.5-flash-lite";
export const GEMINI_HOST = "generativelanguage.googleapis.com";
const API_REVISION = "2026-05-20";

export const gemini: Adapter = {
  id: "gemini",
  host: GEMINI_HOST,
  model: GEMINI_MODEL,

  buildRequest(key, query) {
    return {
      url: `https://${GEMINI_HOST}/v1beta/interactions`,
      // The key goes in the header, never in a `?key=` query string.
      headers: { "content-type": "application/json", "x-goog-api-key": key, "api-revision": API_REVISION },
      body: {
        model: GEMINI_MODEL,
        system_instruction: INSTRUCTIONS,
        input: buildInput(query),
        tools: [{ type: "google_search" }],
        // The API has no cap on searches per call; the instructions ask for at most three.
        generation_config: { max_output_tokens: MAX_OUTPUT_TOKENS, thinking_level: "low" },
        store: false,
      },
    };
  },

  readResponse(body) {
    if (!isRecord(body) || !Array.isArray(body.steps)) throw new DiscoverFailure("provider_error");
    if (body.status === "failed" || body.status === "cancelled") throw new DiscoverFailure("provider_error");
    // `incomplete` and `requires_continuation` are read as they are.
    const texts: string[] = [];
    const citations: Citation[] = [];
    for (const step of body.steps) {
      if (!isRecord(step)) continue;
      if (step.type === "model_output") {
        for (const part of asArray(step.content)) {
          if (!isRecord(part) || part.type !== "text") continue;
          texts.push(asString(part.text) ?? "");
          for (const annotation of asArray(part.annotations)) {
            if (isRecord(annotation) && annotation.type === "url_citation" && typeof annotation.url === "string") {
              citations.push({ url: annotation.url, title: asString(annotation.title) });
            }
          }
        }
      } else if (step.type === "google_search_result" && step.is_error !== true) {
        // The reference shows results with url and title; the guide's example
        // has only `search_suggestions` (HTML for a widget, which is not read).
        for (const result of asArray(step.result)) {
          if (isRecord(result) && typeof result.url === "string") citations.push({ url: result.url, title: asString(result.title) });
        }
      }
    }
    return { text: texts.join("\n"), citations };
  },

  classifyError(status, body): DiscoverErrorCode {
    switch (errorField(body, "code")) {
      case "authentication":
        return "invalid_key";
      case "payment_required":
      case "quota_exceeded":
        return "quota_exceeded";
      case "rate_limit_exceeded":
      case "too_many_requests":
        return "rate_limited";
    }
    if (status === 401) return "invalid_key";
    if (status === 402) return "quota_exceeded";
    if (status === 429) return "rate_limited";
    return "provider_error";
  },
};
