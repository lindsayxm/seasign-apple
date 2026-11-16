---
id: 20
title: API: discover follow-ups from review, and real-key smoke tests
status: backlog
owner: 
depends_on: []
created: 2026-11-16T13:14:12Z
updated: 2026-11-16T13:14:12Z
---

## Goal

From the task 11 review. (L1) api/src/routes/discover.ts:183-185 drops an item only when it holds the full key; also drop items containing any 8+ character run of the key, and fix the leak test so its tail check is not vacuous (api/test/discover.test.ts:196). (L2) api/src/llm/results.ts:54-61 reads only the first code fence; try every fence and then the unfenced text. (L3) accept only IANA zone names for timezone (reject offsets like +05:00). (L4) map provider spend-limit and quota errors correctly: OpenAI organization_spend_limit_exceeded, project_spend_limit_exceeded, organization_usage_limit_exceeded -> quota_exceeded; Anthropic spend-limit 400 and tier spend-cap 429 -> quota_exceeded; Gemini's daily quota -> rate_limited (it resets). (L5) api/src/llm/results.ts:240: Anthropic page_age is last-updated, not published; prefer the model's stated date and fall back to page_age. (L6) add a test reaching the 500 internal_error body. (M1, needs a real key from the user) Gemini may return no items because the Interactions API may give no result URLs for a JSON-only answer; smoke-test each provider with a real key the user supplies in the Simulator or by curl, Gemini first, and fix what the real responses show (for Gemini, match items to url_citation annotations by span if needed). Never commit or log a real key.

## Acceptance criteria

- [ ] L1-L6 fixed with tests; npm test and npx tsc --noEmit pass
- [ ] Each provider smoke-tested with a real key by or with the user, results recorded in the task log without the key

## Relevant files

- api/src/llm/
- api/src/routes/discover.ts
- api/test/

## What's been tried


## Log

- 2026-11-16T13:14:12Z [li] created (backlog)
