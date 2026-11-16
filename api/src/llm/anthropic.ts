// Anthropic Messages API with the server-side web search tool.
// Docs (read 2026-11-15): https://platform.claude.com/docs/en/agents-and-tools/tool-use/web-search-tool
// and .../tool-use/tool-reference, .../tool-use/server-tools.
import { DiscoverFailure, type Adapter, type Citation, type DiscoverErrorCode } from "./types.ts";
import { asArray, asString, errorField, isRecord } from "./http.ts";
import { INSTRUCTIONS, MAX_OUTPUT_TOKENS, MAX_SEARCHES, buildInput } from "./prompt.ts";

/** Claude Haiku 5.5: the fast, low-cost model ($0.10 / $0.50 per million tokens); listed for web search. */
export const ANTHROPIC_MODEL = "claude-haiku-5-5";
export const ANTHROPIC_HOST = "api.anthropic.com";
const API_VERSION = "2026-10-21";
/**
 * The basic web search tool: Claude calls it directly. The later versions
 * (`_20260209`, `_20260318`) filter results by running code first, which
 * adds code-execution blocks and makes the cost less predictable.
 */
const WEB_SEARCH_TOOL = "web_search_20250305";

export const anthropic: Adapter = {
  id: "anthropic",
  host: ANTHROPIC_HOST,
  model: ANTHROPIC_MODEL,

  buildRequest(key, query) {
    return {
      url: `https://${ANTHROPIC_HOST}/v1/messages`,
      headers: { "content-type": "application/json", "x-api-key": key, "anthropic-version": API_VERSION },
      body: {
        model: ANTHROPIC_MODEL,
        max_tokens: MAX_OUTPUT_TOKENS,
        // Thinking stays adaptive (the model's default); low effort keeps it short.
        output_config: { effort: "low" },
        system: INSTRUCTIONS,
        messages: [{ role: "user", content: buildInput(query) }],
        tools: [
          {
            type: WEB_SEARCH_TOOL,
            name: "web_search",
            max_uses: MAX_SEARCHES,
            ...(query.timezone ? { user_location: { type: "approximate", timezone: query.timezone } } : {}),
          },
        ],
      },
    };
  },

  readResponse(body) {
    if (!isRecord(body) || !Array.isArray(body.content)) throw new DiscoverFailure("provider_error");
    // `pause_turn`, `max_tokens` and `refusal` are read as they are: whatever
    // complete items the text holds are used, and no second request is made.
    const texts: string[] = [];
    const citations: Citation[] = [];
    for (const block of body.content) {
      if (!isRecord(block)) continue;
      if (block.type === "text") {
        // Citations split one answer into several text blocks: join them all.
        texts.push(asString(block.text) ?? "");
        for (const citation of asArray(block.citations)) {
          if (isRecord(citation) && citation.type === "web_search_result_location" && typeof citation.url === "string") {
            citations.push({ url: citation.url, title: asString(citation.title) });
          }
        }
      } else if (block.type === "web_search_tool_result") {
        // On a failed search `content` is one error object, not a list.
        for (const result of asArray(block.content)) {
          if (isRecord(result) && result.type === "web_search_result" && typeof result.url === "string") {
            citations.push({ url: result.url, title: asString(result.title), date: asString(result.page_age) });
          }
        }
      }
    }
    return { text: texts.join(""), citations };
  },

  classifyError(status, body): DiscoverErrorCode {
    if (status === 401) return "invalid_key";
    if (status === 402) return "quota_exceeded";
    if (status === 429) return "rate_limited";
    // An account without credit has been answered with a 400 saying so; the
    // message is only tested, never copied.
    if (status === 400 && /credit balance/i.test(errorField(body, "message") ?? "")) return "quota_exceeded";
    return "provider_error";
  },
};
