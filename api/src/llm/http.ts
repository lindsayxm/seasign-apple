import { DiscoverFailure, type Adapter, type ProviderOutput, type SearchQuery } from "./types.ts";

/** Time for one provider call, from sending the request to the end of the body. */
export const PROVIDER_TIMEOUT_MS = 25_000;
/** The largest successful provider body read. A search answer is a few tens of KB. */
export const PROVIDER_MAX_BYTES = 1024 * 1024;
/** The largest error body read. It is only parsed to compare its code with known values. */
export const ERROR_MAX_BYTES = 64 * 1024;

export type CallOptions = { timeoutMs?: number; maxBytes?: number };

/** The deadline the route uses. Only the tests change it, to see the route's timeout without waiting 25 s. */
export const providerDeadline = { ms: PROVIDER_TIMEOUT_MS };

/**
 * Sends one request to the adapter's provider and reads what it says.
 *
 * - The URL is the adapter's own constant; it is checked to be on the
 *   adapter's host before anything is sent.
 * - Redirects are not followed (a redirect would carry the key's header to
 *   wherever it points); any 3xx is `provider_error`.
 * - One deadline covers the request and the whole body; when it passes the
 *   call is aborted and the result is `timeout`.
 * - The body is counted while it is read and dropped past the cap.
 * - Every failure is a DiscoverFailure with a fixed code. Nothing the
 *   provider sent (status text, error message, headers) and nothing of the
 *   key is ever put into an error, a log line or a return value, except the
 *   parsed 2xx body handed to the adapter.
 */
export async function callProvider(adapter: Adapter, key: string, query: SearchQuery, options: CallOptions = {}): Promise<ProviderOutput> {
  const timeoutMs = options.timeoutMs ?? providerDeadline.ms;
  const maxBytes = options.maxBytes ?? PROVIDER_MAX_BYTES;
  const request = adapter.buildRequest(key, query);
  if (new URL(request.url).host !== adapter.host) throw new DiscoverFailure("provider_error");

  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  try {
    let response: Response;
    try {
      response = await fetch(request.url, {
        method: "POST",
        headers: request.headers,
        body: JSON.stringify(request.body),
        redirect: "manual",
        signal: controller.signal,
      });
    } catch {
      throw new DiscoverFailure(controller.signal.aborted ? "timeout" : "provider_error");
    }

    if (response.status < 200 || response.status >= 300) {
      if (response.status >= 300 && response.status < 400) {
        void response.body?.cancel().catch(() => {});
        throw new DiscoverFailure("provider_error");
      }
      // The body is read only to tell quota from rate limit and the like.
      let parsed: unknown = null;
      try {
        parsed = JSON.parse(new TextDecoder().decode(await readCapped(response, ERROR_MAX_BYTES, controller.signal)));
      } catch (error) {
        if (controller.signal.aborted) throw new DiscoverFailure("timeout");
        if (!(error instanceof SyntaxError) && !(error instanceof DiscoverFailure)) throw new DiscoverFailure("provider_error");
        // Unreadable or too large: classify by the status alone.
      }
      throw new DiscoverFailure(adapter.classifyError(response.status, parsed));
    }

    let text: string;
    try {
      text = new TextDecoder().decode(await readCapped(response, maxBytes, controller.signal));
    } catch (error) {
      if (controller.signal.aborted) throw new DiscoverFailure("timeout");
      if (error instanceof DiscoverFailure) throw error;
      throw new DiscoverFailure("provider_error");
    }
    let body: unknown;
    try {
      body = JSON.parse(text);
    } catch {
      throw new DiscoverFailure("provider_error");
    }
    return adapter.readResponse(body);
  } finally {
    clearTimeout(timer);
  }
}

/** The body, counted as it is read; past `maxBytes` it is cancelled and `provider_error` is thrown. */
async function readCapped(response: Response, maxBytes: number, signal: AbortSignal): Promise<Uint8Array> {
  const declared = Number(response.headers.get("content-length"));
  if (Number.isFinite(declared) && declared > maxBytes) {
    void response.body?.cancel().catch(() => {});
    throw new DiscoverFailure("provider_error");
  }
  if (!response.body) return new Uint8Array(0);
  const reader = response.body.getReader();
  // A body stalled after the headers is ended by the deadline too.
  const onAbort = () => void reader.cancel().catch(() => {});
  signal.addEventListener("abort", onAbort);
  const chunks: Uint8Array[] = [];
  let total = 0;
  try {
    for (;;) {
      const { done, value } = await reader.read();
      if (signal.aborted) throw new DiscoverFailure("timeout");
      if (done) break;
      total += value.byteLength;
      if (total > maxBytes) {
        void reader.cancel().catch(() => {});
        throw new DiscoverFailure("provider_error");
      }
      chunks.push(value);
    }
  } finally {
    signal.removeEventListener("abort", onAbort);
  }
  const body = new Uint8Array(total);
  let offset = 0;
  for (const chunk of chunks) {
    body.set(chunk, offset);
    offset += chunk.byteLength;
  }
  return body;
}

// Small readers for provider JSON, which is untrusted in shape.

export const isRecord = (value: unknown): value is Record<string, unknown> =>
  typeof value === "object" && value !== null && !Array.isArray(value);

export const asArray = (value: unknown): unknown[] => (Array.isArray(value) ? value : []);

export const asString = (value: unknown): string | undefined => (typeof value === "string" ? value : undefined);

/** `body.error.<field>` as a string, for comparing with known codes. */
export function errorField(body: unknown, field: string): string | undefined {
  if (!isRecord(body) || !isRecord(body.error)) return undefined;
  return asString(body.error[field]);
}
