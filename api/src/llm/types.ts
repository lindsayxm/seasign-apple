// Shared types for the AI search adapters (`POST /v1/discover`).
//
// The user's own LLM key passes through here. It is a credential that costs
// the user money: it is put only in the chosen provider's auth header, and is
// never logged, stored, cached, echoed or put in an error message. Errors in
// this folder carry a fixed code and fixed text, never anything a provider
// said, because some providers quote part of the key back in their errors.

export const PROVIDERS = ["anthropic", "openai", "gemini", "perplexity"] as const;
export type ProviderId = (typeof PROVIDERS)[number];

export const DISCOVER_ERRORS = ["invalid_key", "rate_limited", "quota_exceeded", "provider_error", "timeout"] as const;
export type DiscoverErrorCode = (typeof DISCOVER_ERRORS)[number];

/** A provider call failed. The message is the code: nothing from the provider and nothing of the key. */
export class DiscoverFailure extends Error {
  readonly code: DiscoverErrorCode;
  constructor(code: DiscoverErrorCode) {
    super(code);
    this.name = "DiscoverFailure";
    this.code = code;
  }
}

/** What an adapter is asked for. The interests are user text and go into the prompt only as data. */
export type SearchQuery = {
  interests: string[];
  /** Today's date in the user's time zone, YYYY-MM-DD. */
  today: string;
  /** IANA time zone, when the app sent one. */
  timezone?: string;
};

/** A page the provider's search returned or cited: provider metadata, not model text. */
export type Citation = {
  url: string;
  title?: string;
  /** When the provider says the page was first published, as it gave it (Perplexity `date`). */
  published?: string;
  /** When the provider says the page was last updated, as it gave it (Anthropic `page_age`). */
  updated?: string;
};

/** What an adapter reads out of a successful provider response. */
export type ProviderOutput = {
  /** The model's answer text, all of it, in order. */
  text: string;
  /** Every URL the provider's own metadata says was found or cited. */
  citations: Citation[];
};

export type ProviderRequest = { url: string; headers: Record<string, string>; body: unknown };

export type Adapter = {
  id: ProviderId;
  /** The one host this adapter ever calls. */
  host: string;
  /** The model asked for. One constant per adapter. */
  model: string;
  /** The request to send. `key` goes into a header here and nowhere else. */
  buildRequest(key: string, query: SearchQuery): ProviderRequest;
  /** Reads a 2xx body. Throws DiscoverFailure("provider_error") when the envelope is not what the provider documents. */
  readResponse(body: unknown): ProviderOutput;
  /**
   * Maps a non-2xx answer to our code. `body` is the parsed error body (or
   * null); it is only compared against known codes, never copied anywhere.
   */
  classifyError(status: number, body: unknown): DiscoverErrorCode;
};
