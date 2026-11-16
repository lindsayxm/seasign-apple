---
id: 20
title: API: discover follow-ups from review, and real-key smoke tests
status: todo
owner: 
depends_on: []
created: 2026-11-16T13:14:12Z
updated: 2026-11-16T21:11:11Z
---

## Goal

From the task 11 review. (L1) api/src/routes/discover.ts:183-185 drops an item only when it holds the full key; also drop items containing any 8+ character run of the key, and fix the leak test so its tail check is not vacuous (api/test/discover.test.ts:196). (L2) api/src/llm/results.ts:54-61 reads only the first code fence; try every fence and then the unfenced text. (L3) accept only IANA zone names for timezone (reject offsets like +05:00). (L4) map provider spend-limit and quota errors correctly: OpenAI organization_spend_limit_exceeded, project_spend_limit_exceeded, organization_usage_limit_exceeded -> quota_exceeded; Anthropic spend-limit 400 and tier spend-cap 429 -> quota_exceeded; Gemini's daily quota -> rate_limited (it resets). (L5) api/src/llm/results.ts:240: Anthropic page_age is last-updated, not published; prefer the model's stated date and fall back to page_age. (L6) add a test reaching the 500 internal_error body. (M1, needs a real key from the user) Gemini may return no items because the Interactions API may give no result URLs for a JSON-only answer; smoke-test each provider with a real key the user supplies in the Simulator or by curl, Gemini first, and fix what the real responses show (for Gemini, match items to url_citation annotations by span if needed). Never commit or log a real key.

## Acceptance criteria

- [x] L1-L6 fixed with tests; npm test and npx tsc --noEmit pass
- [ ] Each provider smoke-tested with a real key by or with the user, results recorded in the task log without the key

## Relevant files

- api/src/llm/
- api/src/routes/discover.ts
- api/test/

## What's been tried


## Log

- 2026-11-16T13:14:12Z [li] created (backlog)
- 2026-11-16T14:25:47Z [li] status: backlog → todo
- 2026-11-16T14:25:47Z [implementer-2] status: todo → in-progress — claimed by implementer-2
- 2026-11-16T14:38:28Z [implementer-2] L4 docs read 2026-11-16: OpenAI https://developers.openai.com/api/docs/guides/error-codes and /api/docs/guides/rate-limits (429 codes credit_balance_exhausted, organization_spend_limit_exceeded, project_spend_limit_exceeded, organization_usage_limit_exceeded; type can still be insufficient_quota; slow_down is a rate_limit_error; no JSON body shown on either page). Anthropic https://platform.claude.com/docs/en/api/errors and /api/rate-limits (spend cap: 429 rate_limit_error with error.details.error_code enforced_spend_limit_reached, no retry-after; own spend limit: 400 invalid_request_error, message starts 'You have reached your specified (workspace) API usage limits'; ramp_limit_exceeded is a rate limit). Gemini https://aistudio.google.com/docs/api-errors and /docs/troubleshooting (Interactions error {error:{code,message}}; 402 payment_required = Prepay credits depleted; 429 quota_exceeded = daily quota, resets; 400 failed_precondition 'such as disabled billing'). Perplexity https://docs.perplexity.ai/docs/resources/faq (402 when out of credits) and /docs/admin/rate-limits-usage-tiers (429 types request_rate_limit_exceeded, token_rate_limit_exceeded; overloaded is not a rate limit, status not given; no spend-limit error documented).
- 2026-11-16T14:38:28Z [implementer-2] L5 docs read 2026-11-16: Anthropic web-search-tool page: page_age = 'When the site was last updated'. Perplexity /docs/agent-api/tools/web-search: date = 'Date the page was originally published', last_updated = 'Date the page was last updated'. OpenAI tools-web-search and Gemini aistudio.google.com/docs/google-search: no date field on citations, sources or results. Citation now has published (Perplexity date) and updated (Anthropic page_age); order is provider published, then the model's date if it parses and is at most a day ahead, then provider updated. Perplexity last_updated is deliberately not read.
- 2026-11-16T14:38:28Z [implementer-2] L1: route drops an item if any string holds any 8 consecutive chars of the key (keyRuns Set of windows + holdsKeyRun, linear). Leak test plants 5 items on cited undated pages (whole key, tail only, prefix only, run in source, run in link) plus a control run under another key that returns all 5; reverting to the old whole-key filter makes the test fail (checked). L2: modelItems tries each fence (max 20, open last fence runs to end) then the outside text, first with a valid item wins; candidate cap 100 shared across fences. Hostile shapes all <= 2 ms in Node; local workerd clock does advance (probe 25 ms), so the in-test 250 ms bounds are real. L3: isIanaZone in discover.ts = UTC or Area/Loc(/Place) in the ten geographic areas, later parts capitalised, then isTimeZone; every Intl.supportedValuesOf name passes (tested). Spec diff: only the timezone and 400 descriptions. L6: behaviour change - a non-DiscoverFailure thrown inside the provider call now answers the fixed 500 internal_error (was 502 provider_error) with only 'discover: <p> unexpected failure' logged; tests cover that and the onError 500 (Intl.DateTimeFormat throwing).
- 2026-11-16T14:38:28Z [implementer-2] Gemini 400 failed_precondition and 403 permission_denied left as provider_error (not only billing). Perplexity error.type overloaded -> provider_error. Not done: iOS AIRules.swift comment and the app-side architecture paragraph still describe the API check as Intl + 64 chars; iOS build not rerun after the description-only spec change (spec is consumed by the build plugin, no checked-in generated code).
- 2026-11-16T14:38:39Z [implementer-2] L1-L6 done in 57491fa (npm test 1538 passed, tsc clean, npm run openapi: description-only diff). Remaining: M1 (Gemini items when Interactions gives no result URLs) and the real-key smoke tests for all four providers, which need the user. Task left in-progress.
- 2026-11-16T14:42:32Z [implementer-2] criterion 1 met: L1-L6 fixed with tests; npm test and npx tsc --noEmit pass
- 2026-11-16T14:42:32Z [implementer-2] review (lead): L1-L6 committed as 57491fa; I ran npm test (1,538 passed) and tsc (clean) in api/, and the iOS suite on iPhone 17 (iOS 27.2) against the changed spec descriptions (341 passed). Criterion 1 ticked. Accepted: MAX_FENCES = 20; the stricter timezone rule (GMT, Etc/GMT+5 and US/Eastern refused; every Foundation and Intl zone name except GMT passes, and the app sends UTC for GMT); an unexpected exception inside a provider call now answers 500 internal_error instead of 502. Task stays in-progress for M1 and the real-key smoke tests, which need the user. Owner released to the lead.
- 2026-11-16T21:11:11Z [lead] Session end 2026-11-16: criterion 1 (L1-L6) is done and committed (57491fa). Criterion 2 is not started: it needs the user's own provider keys. Next: run npx wrangler dev in api/, the user enters a key in the Simulator (never given to the agent, never logged), test Gemini first (M1: the Interactions API may return no result URLs for a JSON-only answer), then Anthropic, OpenAI, Perplexity; record results here without the key. Released to todo until the user is ready.
- 2026-11-16T21:11:11Z [lead] status: in-progress → todo
