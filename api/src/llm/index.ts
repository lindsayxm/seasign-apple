import { anthropic } from "./anthropic.ts";
import { gemini } from "./gemini.ts";
import { openai } from "./openai.ts";
import { perplexity } from "./perplexity.ts";
import type { Adapter, ProviderId } from "./types.ts";

export const ADAPTERS: Record<ProviderId, Adapter> = { anthropic, openai, gemini, perplexity };
