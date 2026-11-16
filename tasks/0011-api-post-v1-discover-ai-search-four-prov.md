---
id: 11
title: API: POST /v1/discover (AI search, four providers)
status: done
owner: implementer-1
depends_on: [7]
created: 2026-11-15T22:33:55Z
updated: 2026-11-16T13:14:12Z
---

## Goal

Read plans/2026-11-15-v1-build.md first; it holds the decisions and design. Add POST /v1/discover. Header X-LLM-Key carries the user's key; body has provider (anthropic, openai, gemini, perplexity) and interests (list of strings). One adapter per provider calls its API with plain fetch using its web search feature and returns recent publications on the interests as items (title, link, source, published date if known, excerpt, origin ai). Look up current model IDs and request shapes in each provider's documentation; do not rely on memory. Never store or log the key; strip it from errors. Rate-limit per client IP. Regenerate spec and client.

## Acceptance criteria

- [x] Each adapter has tests against mocked provider responses, including an auth failure
- [x] A test proves the key never appears in logs, KV or error bodies
- [x] Items without a source link are dropped
- [x] npm test and npx tsc --noEmit pass; openapi/openapi.json regenerated and the iOS app still builds

## Relevant files

- api/src/routes/discover.ts
- api/src/llm/
- api/test/
- openapi/openapi.json

## What's been tried

- Route-level timeout with vi.useFakeTimers(setTimeout): fails - workerd reports the request as hung, and advancing the fake clock aborts the Worker's AbortController from the test's context (cross-context I/O error). Replaced by a providerDeadline knob in http.ts that the test shortens to 100 ms; adapter-level tests use callProvider({timeoutMs: 50}).

## Log

- 2026-11-15T22:33:55Z [li] created (todo)
- 2026-11-16T04:38:40Z [implementer-1] status: todo → in-progress — claimed by implementer-1
- 2026-11-16T04:48:36Z [implementer-1] Provider docs read 2026-11-15. Anthropic: platform.claude.com/docs/en/agents-and-tools/tool-use/web-search-tool.md (+ tool-reference.md, server-tools.md, claude-api skill cached 2026-11-03). Model claude-haiku-5-5 ($0.10/$0.50 per MTok, listed in web search supportedModels), tool web_search_20250305 (basic, direct caller; avoids dynamic filtering's code execution), max_uses 3, effort low, anthropic-version 2026-10-21, $10/1k searches. Citations: web_search_tool_result.content[] urls + text citations web_search_result_location.url.
- 2026-11-16T04:48:36Z [implementer-1] OpenAI: developers.openai.com/api/docs/guides/tools-web-search.md, /api/docs/models (gpt-6-luna page), /api/reference/resources/responses/methods/create.md, /api/docs/pricing.md, /api/docs/guides/error-codes. Model gpt-6-luna (cheapest text model, $0.10/$0.50, web_search supported), POST api.openai.com/v1/responses, tool web_search search_context_size low, include web_search_call.action.sources, max_tool_calls 3, reasoning low, store false. $10/1k search calls. Citations: url_citation annotations + action.sources. Quota: 429 credit_balance_exhausted / type insufficient_quota.
- 2026-11-16T04:48:36Z [implementer-1] Gemini: aistudio.google.com/docs/google-search.md, api-reference/interactions-api/create-interaction.md, docs/api-errors.md, docs/models/gemini-3.5-flash-lite.md, docs/pricing.md, docs/deprecations.md. Docs now make the Interactions API the default (generateContent is legacy), so POST generativelanguage.googleapis.com/v1beta/interactions with x-goog-api-key and Api-Revision 2026-05-20, tools [{type: google_search}]. Model gemini-3.5-flash-lite (stable, no shutdown announced; $0.30/$2.50, search $14/1k after 5,000 free/month). thinking_level low, store false. Citations: model_output text annotations url_citation + google_search_result result[].url when present. Errors: error.code authentication 401, payment_required 402, quota_exceeded/rate_limit_exceeded 429.
- 2026-11-16T04:48:36Z [implementer-1] Perplexity: docs.perplexity.ai/docs/agent-api/tools/web-search.md, agent-api/quickstart.md, agent-api/models.md, agent-api/effort.md, agent-api/migrate-from-sonar/{overview,how-to}.md, api-reference/agent-post.md, resources/faq.md. Sonar Chat Completions support ended 2026-09-27, so the Agent API: POST api.perplexity.ai/v1/agent, Bearer. Model openai/gpt-6-luna with max_steps 1 = the documented fast effort configuration (Perplexity maps sonar to fast); web_search search_type fast ($1/1k), max_results 20, filters.search_recency_filter week; store false. Citations: output search_results.results[].url. 401 auth, 402 out of credits, 429 rate.
- 2026-11-16T04:59:26Z [implementer-1] Built POST /v1/discover (commit 90ea55d): adapters in api/src/llm/, route api/src/routes/discover.ts, spec regenerated. quota_exceeded is 402 (not 429) so the app can tell top-up from retry; 403 maps to provider_error. No structured-output params (prompt JSON only); no KV. Results: only links in the provider's own citation/source metadata (matched ignoring scheme/www/fragment/trailing slash/utm), provider spelling returned; items dated >8 days ago dropped; future dates nulled; item containing the key dropped.
- 2026-11-16T04:59:26Z [implementer-1] Deliberately deferred per the lead's brief (so the reviewer does not fail them): per-IP rate limiting is task 19 (64 KB body cap applies, X-LLM-Key capped at 512); the iOS build was NOT run (another agent is in ios/; the lead reruns it); the task goal's origin: ai field is not in the response - every /v1/discover item is AI-found by definition, so the app labels them (task 12).
- 2026-11-16T04:59:26Z [implementer-1] tried: Route-level timeout with vi.useFakeTimers(setTimeout): fails - workerd reports the request as hung, and advancing the fake clock aborts the Worker's AbortController from the test's context (cross-context I/O error). Replaced by a providerDeadline knob in http.ts that the test shortens to 100 ms; adapter-level tests use callProvider({timeoutMs: 50}).
- 2026-11-16T05:04:26Z [implementer-1] Second commit: in-200 search failures mapped (Anthropic too_many_requests -> rate_limited, else provider_error; Gemini is_error -> provider_error), text parts joined with no separator, optional model fields .catch(null), trailing-slash loop, timeout added to the leak test. Verified: npm test 14 files / 1483 tests pass; npx tsc --noEmit clean; npm run openapi regenerated (Discover, DiscoverItem, DiscoverRequest, DiscoverError; x-llm-key header required; 200/400/401/402/429/500/502/504). iOS build not run (lead reruns).
- 2026-11-16T05:04:26Z [implementer-1] status: in-progress → review
- 2026-11-16T05:15:24Z [implementer-1] criterion 1 met: Each adapter has tests against mocked provider responses, including an auth failure
- 2026-11-16T05:15:24Z [implementer-1] criterion 2 met: A test proves the key never appears in logs, KV or error bodies
- 2026-11-16T05:15:24Z [implementer-1] criterion 3 met: Items without a source link are dropped
- 2026-11-16T05:15:24Z [implementer-1] review: PASS (API half). Verified myself: npm test 14 files/1483 pass, tsc clean, npm run openapi no diff, no new deps, nothing changed outside api/ openapi/ memory/architecture.md. C1 ticked: each adapter has mocked tests incl. 401 invalid_key. C2 ticked: leak test is not vacuous - temporary mutations (key in request body, key in error message, key tail in console.warn, a KV put, an adapter echoing the key tail) each made it fail; files restored, git diff clean. Gaps (low): it does not catch a key prefix (a mutation echoing key.slice(0,30) in the 200 body passed), and the success-path KEY_TAIL check is vacuous because the planted item also holds the full key; the route filter (discover.ts:183-185) checks only the full key, so an item holding just the tail or a 20-char prefix is returned. C3 ticked: linkless, uncited, unsafe and private-address items dropped (tests + my probes). C4 left unticked: API half holds (tests, tsc, spec); iOS build is for the lead. wrangler dev probes (dup header, 513 chars, non-ASCII, Bearer prefix, no key, provider __proto__) all fixed 400, no provider call, key absent from logs. Docs re-read 2026-11-15: Anthropic high confidence, OpenAI high, Perplexity medium-high (max_steps 1 + web_search is the documented fast config), Gemini medium: the guide shows real page URLs only in url_citation annotations; google_search_result carries only search_suggestions. If the JSON-only answer gets no annotations, or the model never sees the real URLs, Gemini always returns []. Needs a real-key check. Other lows: unfenced() reads only the first fence (prose fence then JSON outside = 0 items); isTimeZone accepts '+05:00' and it is forwarded as user_location.timezone (docs want IANA); quota mapping misses OpenAI *_spend_limit_exceeded/usage_limit codes unless type=insufficient_quota, the Anthropic spend-limit 400, and Gemini daily quota_exceeded maps to a 'top up' 402; Anthropic page_age (last-updated) is preferred over the model's published date.
- 2026-11-16T05:17:34Z [implementer-1] review addendum: the Swift client is generated at build time from ../openapi/openapi.json (ios/project.yml lines 40-44), so there is no committed copy to go stale. The 500 internal_error path and the 'unexpected failure' log line (discover.ts:151-155, 196-197) are checked by reading only; no test reaches them (low coverage gap). Gemini, more precisely: the guide's example and the reference's property list show google_search_result with only search_suggestions, while the reference's example shows title/url/snippet; the guide's url_citation annotations carry real page URLs, not vertexaisearch redirects. Perplexity reasoning.effort 'low' is in the ReasoningConfig enum; Sonar end confirmed in migrate-from-sonar/overview.
- 2026-11-16T13:14:12Z [implementer-1] criterion 4 met: npm test and npx tsc --noEmit pass; openapi/openapi.json regenerated and the iOS app still builds
- 2026-11-16T13:14:12Z [implementer-1] lead: reviewer passed the API half (key handling, parser, provider docs). iOS half of criterion 4: 242 tests passed on iPhone 16 (iOS 18.3.1) against the new spec. Low findings L1-L5 and the Gemini doubt M1 moved to task 20. Nothing has been called with a real key.
- 2026-11-16T13:14:12Z [implementer-1] status: review → done
