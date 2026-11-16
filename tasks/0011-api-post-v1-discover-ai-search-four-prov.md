---
id: 11
title: API: POST /v1/discover (AI search, four providers)
status: in-progress
owner: implementer-1
depends_on: [7]
created: 2026-11-15T22:33:55Z
updated: 2026-11-16T04:38:40Z
---

## Goal

Read plans/2026-11-15-v1-build.md first; it holds the decisions and design. Add POST /v1/discover. Header X-LLM-Key carries the user's key; body has provider (anthropic, openai, gemini, perplexity) and interests (list of strings). One adapter per provider calls its API with plain fetch using its web search feature and returns recent publications on the interests as items (title, link, source, published date if known, excerpt, origin ai). Look up current model IDs and request shapes in each provider's documentation; do not rely on memory. Never store or log the key; strip it from errors. Rate-limit per client IP. Regenerate spec and client.

## Acceptance criteria

- [ ] Each adapter has tests against mocked provider responses, including an auth failure
- [ ] A test proves the key never appears in logs, KV or error bodies
- [ ] Items without a source link are dropped
- [ ] npm test and npx tsc --noEmit pass; openapi/openapi.json regenerated and the iOS app still builds

## Relevant files

- api/src/routes/discover.ts
- api/src/llm/
- api/test/
- openapi/openapi.json

## What's been tried


## Log

- 2026-11-15T22:33:55Z [li] created (todo)
- 2026-11-16T04:38:40Z [implementer-1] status: todo → in-progress — claimed by implementer-1
