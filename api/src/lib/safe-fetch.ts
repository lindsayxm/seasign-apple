// Fetching a URL that a user typed in. The Worker must not become a way to
// reach hosts the user could not reach themselves, to hold a connection open
// for ever, or to pull an unbounded body into memory. Every route that fetches
// a user-supplied URL (calendar links, followed sites, AI-found pages) goes
// through `safeFetch`.
//
// Error messages never contain the URL: a calendar link is a credential.
// Nothing here imports `cloudflare:*`, so the spec writer can load it in Node.

export const SAFE_FETCH_TIMEOUT_MS = 8000;
export const SAFE_FETCH_MAX_BYTES = 2 * 1024 * 1024;
export const SAFE_FETCH_MAX_REDIRECTS = 3;
export const SAFE_FETCH_USER_AGENT = "SeasignBot/1.0";

export type SafeFetchErrorCode =
  /** Not a URL, not https, carries credentials, or uses a port other than 443. */
  | "invalid_url"
  /** A private, loopback, link-local or otherwise internal host. */
  | "blocked_host"
  /** More than the allowed number of redirects, or a redirect without a usable Location. */
  | "bad_redirect"
  /** The deadline passed before the whole body had arrived. */
  | "timeout"
  /** The body is larger than the cap. */
  | "too_large"
  /** The host could not be reached. */
  | "network"
  /** The final answer was not 2xx. `status` holds it. */
  | "http_status";

const MESSAGES: Record<SafeFetchErrorCode, string> = {
  invalid_url: "The address is not a plain https URL",
  blocked_host: "The address points to a private or local host",
  bad_redirect: "The address redirects too many times or to nowhere",
  timeout: "The host took too long to answer",
  too_large: "The response is too large",
  network: "The host could not be reached",
  http_status: "The host answered with an error status",
};

/** Why a fetch was refused or failed. The message is fixed text per code and never holds the URL. */
export class SafeFetchError extends Error {
  readonly code: SafeFetchErrorCode;
  /** The HTTP status, for `http_status`. */
  readonly status?: number;

  constructor(code: SafeFetchErrorCode, status?: number) {
    super(MESSAGES[code]);
    this.name = "SafeFetchError";
    this.code = code;
    this.status = status;
  }
}

export type SafeFetchOptions = {
  /** Deadline for the whole exchange: every redirect hop plus reading the body. */
  timeoutMs?: number;
  /** Largest body accepted, in bytes, counted while reading. */
  maxBytes?: number;
  /** Redirects followed before giving up. */
  maxRedirects?: number;
  /** Value of the Accept header. */
  accept?: string;
};

export type SafeFetchResult = {
  /** The URL that answered, after redirects. Treat it like the input: do not log it. */
  url: URL;
  status: number;
  headers: Headers;
  body: Uint8Array;
};

/**
 * Parses a user-supplied address and checks it. `webcal://` and `webcals://`
 * (calendar subscription links) are read as `https://`. The fragment is
 * dropped, since it is never sent. Throws `SafeFetchError`.
 */
export function parseSafeUrl(input: string): URL {
  const rewritten = input.trim().replace(/^webcals?:\/\//i, "https://");
  let url: URL;
  try {
    url = new URL(rewritten);
  } catch {
    throw new SafeFetchError("invalid_url");
  }
  url.hash = "";
  assertSafeUrl(url);
  return url;
}

/**
 * Throws `SafeFetchError` unless the URL is https on port 443, without
 * credentials, and its host is neither a private or local IP literal nor a
 * local-only name. Used for the first URL and again for every redirect hop.
 *
 * A public name that resolves to a private address is not caught here: a
 * Worker cannot resolve DNS before fetching. Cloudflare's network does not
 * route Worker subrequests to private address space.
 */
export function assertSafeUrl(url: URL): void {
  if (url.protocol !== "https:") throw new SafeFetchError("invalid_url");
  if (url.username !== "" || url.password !== "") throw new SafeFetchError("invalid_url");
  // The URL parser drops a default port, so any port left is not 443.
  if (url.port !== "") throw new SafeFetchError("invalid_url");

  const host = url.hostname.toLowerCase().replace(/\.+$/, "");
  if (host === "") throw new SafeFetchError("invalid_url");

  if (host.startsWith("[")) {
    const groups = parseIPv6(host.slice(1, -1));
    if (!groups || isBlockedIPv6(groups)) throw new SafeFetchError("blocked_host");
    return;
  }

  const v4 = parseIPv4(host);
  if (v4) {
    if (isBlockedIPv4(v4)) throw new SafeFetchError("blocked_host");
    return;
  }
  // The URL parser turns every numeric form of an IPv4 address (decimal, hex,
  // octal, short) into dotted decimal. A host that still ends in a number is
  // not something to trust.
  if (/(^|\.)(\d+|0x[0-9a-f]*)$/.test(host)) throw new SafeFetchError("blocked_host");

  if (isLocalName(host)) throw new SafeFetchError("blocked_host");
}

const LOCAL_SUFFIXES = [".localhost", ".local", ".internal", ".lan", ".localdomain", ".home.arpa", ".intranet", ".corp", ".home"];

function isLocalName(host: string): boolean {
  // A single label ("localhost", "router", "metadata") only resolves inside a network.
  if (!host.includes(".")) return true;
  return LOCAL_SUFFIXES.some((suffix) => host.endsWith(suffix));
}

function parseIPv4(host: string): [number, number, number, number] | null {
  const match = /^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$/.exec(host);
  if (!match) return null;
  const parts = match.slice(1).map(Number);
  if (parts.some((part) => part > 255)) return null;
  return parts as [number, number, number, number];
}

function isBlockedIPv4([a, b, c]: [number, number, number, number]): boolean {
  return (
    a === 0 || // "this" network
    a === 10 || // private
    (a === 100 && b >= 64 && b <= 127) || // carrier-grade NAT
    a === 127 || // loopback
    (a === 169 && b === 254) || // link-local, cloud metadata
    (a === 172 && b >= 16 && b <= 31) || // private
    (a === 192 && b === 0 && c === 0) || // IETF protocol assignments
    (a === 192 && b === 0 && c === 2) || // documentation
    (a === 192 && b === 168) || // private
    (a === 198 && (b === 18 || b === 19)) || // benchmarking
    (a === 198 && b === 51 && c === 100) || // documentation
    (a === 203 && b === 0 && c === 113) || // documentation
    a >= 224 // multicast, reserved, broadcast
  );
}

/** An IPv6 address as eight 16-bit groups, or null when it is not one. */
function parseIPv6(text: string): number[] | null {
  let address = text;
  // A zone ID ("%eth0") never belongs in a URL we fetch.
  if (address.includes("%")) return null;

  // A dotted IPv4 tail ("::ffff:127.0.0.1") becomes two groups.
  const lastColon = address.lastIndexOf(":");
  const tail = address.slice(lastColon + 1);
  if (tail.includes(".")) {
    const v4 = parseIPv4(tail);
    if (!v4) return null;
    const high = ((v4[0] << 8) | v4[1]).toString(16);
    const low = ((v4[2] << 8) | v4[3]).toString(16);
    address = `${address.slice(0, lastColon + 1)}${high}:${low}`;
  }

  const halves = address.split("::");
  if (halves.length > 2) return null;
  const parse = (part: string) => (part === "" ? [] : part.split(":"));
  const head = parse(halves[0] as string);
  const rest = halves.length === 2 ? parse(halves[1] as string) : [];
  const missing = 8 - head.length - rest.length;
  if (halves.length === 2 ? missing < 1 : missing !== 0) return null;

  const words = [...head, ...Array<string>(halves.length === 2 ? missing : 0).fill("0"), ...rest];
  const groups = words.map((word) => (/^[0-9a-f]{1,4}$/i.test(word) ? parseInt(word, 16) : NaN));
  return groups.some(Number.isNaN) ? null : groups;
}

function isBlockedIPv6(groups: number[]): boolean {
  const [g0, g1, g2, g3, g4, g5, g6, g7] = groups as [number, number, number, number, number, number, number, number];
  const embedded = (high: number, low: number) =>
    isBlockedIPv4([high >> 8, high & 0xff, low >> 8, low & 0xff]);

  const firstSixZero = g0 === 0 && g1 === 0 && g2 === 0 && g3 === 0 && g4 === 0;
  if (firstSixZero && g5 === 0) {
    // "::" (unspecified), "::1" (loopback) and the old IPv4-compatible form.
    return g6 === 0 && g7 <= 1 ? true : embedded(g6, g7);
  }
  if (firstSixZero && g5 === 0xffff) return embedded(g6, g7); // IPv4-mapped
  if (g0 === 0 && g1 === 0 && g2 === 0 && g3 === 0 && g4 === 0xffff && g5 === 0) return embedded(g6, g7); // IPv4-translated
  if (g0 === 0x64 && g1 === 0xff9b) return true; // NAT64: reaches IPv4 through a translator
  if (g0 === 0x2002) return embedded(g1, g2); // 6to4 carries an IPv4 address
  if (g0 === 0x2001 && g1 === 0) return true; // Teredo
  if (g0 === 0x2001 && g1 === 0xdb8) return true; // documentation
  if ((g0 & 0xfe00) === 0xfc00) return true; // unique local fc00::/7
  if ((g0 & 0xffc0) === 0xfe80) return true; // link-local fe80::/10
  if ((g0 & 0xffc0) === 0xfec0) return true; // site-local (deprecated)
  if ((g0 & 0xff00) === 0xff00) return true; // multicast
  return false;
}

const REDIRECT_STATUSES = new Set([301, 302, 303, 307, 308]);

/**
 * GETs a user-supplied https URL and returns the whole body.
 *
 * - `webcal://` is read as `https://`; anything else that is not https is refused.
 * - Credentials in the URL, ports other than 443, private, loopback and
 *   link-local IP literals, and local-only names are refused.
 * - Redirects are followed by hand, at most `maxRedirects`, and each hop is
 *   checked the same way (without the webcal rewrite).
 * - One deadline covers all hops and the body.
 * - The body is counted while it is read and dropped once it passes `maxBytes`,
 *   whatever Content-Length says.
 * - A non-2xx final answer is an error.
 *
 * Throws `SafeFetchError`, whose message never holds the URL.
 */
export async function safeFetch(input: string | URL, options: SafeFetchOptions = {}): Promise<SafeFetchResult> {
  const timeoutMs = options.timeoutMs ?? SAFE_FETCH_TIMEOUT_MS;
  const maxBytes = options.maxBytes ?? SAFE_FETCH_MAX_BYTES;
  const maxRedirects = options.maxRedirects ?? SAFE_FETCH_MAX_REDIRECTS;

  let url = parseSafeUrl(typeof input === "string" ? input : input.href);

  const controller = new AbortController();
  let timer: ReturnType<typeof setTimeout> | undefined;
  const deadline = new Promise<never>((_resolve, reject) => {
    timer = setTimeout(() => {
      reject(new SafeFetchError("timeout"));
      controller.abort();
    }, timeoutMs);
  });
  // The race below handles the rejection; this stops an unhandled-rejection
  // report when the fetch settles first.
  deadline.catch(() => {});

  /** Settles with the work, or rejects with `timeout` once the deadline passes. */
  const beforeDeadline = async <T>(work: Promise<T>): Promise<T> => {
    try {
      return await Promise.race([work, deadline]);
    } catch (error) {
      if (error instanceof SafeFetchError) throw error;
      throw new SafeFetchError(controller.signal.aborted ? "timeout" : "network");
    }
  };

  try {
    for (let redirects = 0; ; redirects++) {
      const response = await beforeDeadline(
        fetch(url.href, {
          method: "GET",
          redirect: "manual",
          headers: {
            "user-agent": SAFE_FETCH_USER_AGENT,
            accept: options.accept ?? "*/*",
          },
          signal: controller.signal,
        }),
      );

      if (REDIRECT_STATUSES.has(response.status)) {
        void response.body?.cancel().catch(() => {});
        if (redirects >= maxRedirects) throw new SafeFetchError("bad_redirect");
        const location = response.headers.get("location");
        if (!location) throw new SafeFetchError("bad_redirect");
        let next: URL;
        try {
          next = new URL(location, url);
        } catch {
          throw new SafeFetchError("bad_redirect");
        }
        next.hash = "";
        assertSafeUrl(next);
        url = next;
        continue;
      }

      if (!response.ok) {
        void response.body?.cancel().catch(() => {});
        throw new SafeFetchError("http_status", response.status);
      }

      const declared = Number(response.headers.get("content-length"));
      if (Number.isFinite(declared) && declared > maxBytes) {
        void response.body?.cancel().catch(() => {});
        throw new SafeFetchError("too_large");
      }

      const body = await readCapped(response, maxBytes, beforeDeadline);
      return { url, status: response.status, headers: response.headers, body };
    }
  } finally {
    clearTimeout(timer);
  }
}

async function readCapped(
  response: Response,
  maxBytes: number,
  beforeDeadline: <T>(work: Promise<T>) => Promise<T>,
): Promise<Uint8Array> {
  if (!response.body) return new Uint8Array(0);
  const reader = response.body.getReader();
  const chunks: Uint8Array[] = [];
  let total = 0;
  try {
    for (;;) {
      const { done, value } = await beforeDeadline(reader.read());
      if (done) break;
      total += value.byteLength;
      if (total > maxBytes) throw new SafeFetchError("too_large");
      chunks.push(value);
    }
  } catch (error) {
    void reader.cancel().catch(() => {});
    throw error;
  }
  const body = new Uint8Array(total);
  let offset = 0;
  for (const chunk of chunks) {
    body.set(chunk, offset);
    offset += chunk.byteLength;
  }
  return body;
}
