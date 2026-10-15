/**
 * The remote-profile request: the body, and the quota header that may come with it.
 *
 * Separate from `profiles.ts` so it can be tested. This is where the one rule that must not
 * break lives - the profile content is the FIRST response's body, always - and it was
 * previously reachable only through Electron's main process, which is why it had no test.
 * Nothing here touches Electron, Node files or the database: it takes a `fetch`, returns two
 * values, and the caller decides what to persist.
 */

import {
  SUBSCRIPTION_QUOTA_COMPATIBILITY_USER_AGENTS,
  SUBSCRIPTION_USER_INFO_HEADER,
  type SubscriptionQuotaUpdate,
  parseSubscriptionUserInfo,
} from "./subscription";

export const REMOTE_REQUEST_TIMEOUT_MILLISECONDS = 30_000;
export const MAXIMUM_REMOTE_PROFILE_BYTES = 16 * 1024 * 1024;
export const MAXIMUM_REMOTE_ERROR_BYTES = 64 * 1024;

/** Just enough of `fetch` to be replaceable in a test. */
export type FetchLike = (input: URL, init: RequestInit) => Promise<Response>;

export interface RemoteProfileFetch {
  content: string;
  quota: SubscriptionQuotaUpdate;
}

export interface FetchRemoteProfileOptions {
  /** The User-Agent the first request carries, and the profile's own client identity. */
  userAgent: string;
  /** Injected for tests; defaults to the global. */
  fetchImplementation?: FetchLike;
  /** Milliseconds before a request is aborted. */
  timeoutMilliseconds?: number;
  maximumProfileBytes?: number;
  maximumErrorBytes?: number;
}

function describeStatus(response: Response): string {
  return response.statusText === ""
    ? String(response.status)
    : `${response.status} ${response.statusText}`;
}

function concatenate(chunks: Uint8Array[], totalLength: number): Uint8Array {
  const joined = new Uint8Array(totalLength);
  let offset = 0;
  for (const chunk of chunks) {
    joined.set(chunk, offset);
    offset += chunk.byteLength;
  }
  return joined;
}

/**
 * Reads a response body, refusing anything over the limit.
 *
 * `TextDecoder` and `Uint8Array` rather than `Buffer`: this module is exercised directly by
 * `node --test`, and keeping it on platform-neutral APIs means the test needs no type
 * configuration of its own to see it - the failure that arrangement prevents is a test file
 * that type-checks in one project and not the other.
 */
async function readLimitedResponse(response: Response, maximumBytes: number): Promise<string> {
  const declaredLength = Number(response.headers.get("content-length"));
  if (Number.isFinite(declaredLength) && declaredLength > maximumBytes) {
    throw new Error(`response exceeds ${maximumBytes} bytes`);
  }
  if (response.body === null) {
    return "";
  }
  const reader = response.body.getReader();
  const chunks: Uint8Array[] = [];
  let totalLength = 0;
  for (;;) {
    const result = await reader.read();
    if (result.done) {
      break;
    }
    totalLength += result.value.byteLength;
    if (totalLength > maximumBytes) {
      await reader.cancel();
      throw new Error(`response exceeds ${maximumBytes} bytes`);
    }
    chunks.push(result.value);
  }
  return new TextDecoder().decode(concatenate(chunks, totalLength));
}

/**
 * One request, with the URL auth the existing client already had.
 *
 * Mirrors libbox's HTTPClient (experimental/libbox/http.go): URL userinfo becomes a basic
 * Authorization header, and the credentials are removed from the URL before it is sent.
 *
 * Base64 by `btoa` over the encoded bytes rather than `Buffer.from(...).toString("base64")`:
 * identical output, no Node-only global.
 */
async function requestRemote(
  requestUrl: URL,
  userAgent: string,
  timeoutMilliseconds: number,
  fetchImplementation: FetchLike,
): Promise<Response> {
  const url = new URL(requestUrl);
  const headers = new Headers({ "User-Agent": userAgent });
  if (url.username !== "" || url.password !== "") {
    const credentials = `${decodeURIComponent(url.username)}:${decodeURIComponent(url.password)}`;
    headers.set("Authorization", `Basic ${base64(credentials)}`);
    url.username = "";
    url.password = "";
  }
  return await fetchImplementation(url, {
    headers,
    signal: AbortSignal.timeout(timeoutMilliseconds),
  });
}

function base64(value: string): string {
  const bytes = new TextEncoder().encode(value);
  let binary = "";
  for (const byte of bytes) {
    binary += String.fromCharCode(byte);
  }
  return btoa(binary);
}

function quotaUpdateFromHeaders(headers: Headers): SubscriptionQuotaUpdate {
  const quota = parseSubscriptionUserInfo(headers.get(SUBSCRIPTION_USER_INFO_HEADER));
  if (quota === undefined) {
    return undefined;
  }
  // Stamped where the header is read, not where it is written, so a slow body download
  // cannot make the quota look older than it is - and so the value means "when this header
  // arrived" rather than "when the database was next touched".
  return { quota: { ...quota, updatedAt: Date.now() } };
}

/**
 * Asks for the quota header under a compatibility User-Agent, without taking the body.
 *
 * Every failure returns `undefined` - a non-200, a transport error, a timeout, and a success
 * with no usable header all mean the same thing to the caller: keep the last known snapshot.
 * The body is CANCELLED rather than buffered, which is what makes "a retry cannot replace the
 * profile content" a property of the code rather than a convention: there is no retry body in
 * scope that could be mistaken for content.
 */
async function querySubscriptionQuota(
  requestUrl: URL,
  fetchImplementation: FetchLike,
  timeoutMilliseconds: number,
): Promise<SubscriptionQuotaUpdate> {
  for (const compatibilityUserAgent of SUBSCRIPTION_QUOTA_COMPATIBILITY_USER_AGENTS) {
    let response: Response;
    try {
      response = await requestRemote(
        requestUrl,
        compatibilityUserAgent,
        timeoutMilliseconds,
        fetchImplementation,
      );
    } catch {
      continue;
    }
    try {
      if (response.status !== 200) {
        continue;
      }
      const update = quotaUpdateFromHeaders(response.headers);
      if (update !== undefined) {
        return update;
      }
    } finally {
      // Never read, only released. Cancelling also releases the connection, so the retry
      // cannot leave a half-consumed download behind it.
      await response.body?.cancel().catch(() => {});
    }
  }
  return undefined;
}

/**
 * Fetches a remote profile: the body, and whatever quota header came with it.
 *
 * # The one rule that matters here
 *
 * The body from the FIRST request is the profile content, always. Some providers answer a
 * Clash User-Agent with a different subscription - a different node set, sometimes a
 * different format entirely - so a compatibility retry must never be allowed to replace it.
 *
 * # Why the retry is worth its cost
 *
 * Providers that gate the header behind a recognised client are common enough that without
 * this the quota would simply never appear for them. Providers that send it to everyone pay
 * nothing: the retry is skipped when the header parsed, and a failed update is not retried
 * either (the request has already failed, with its own error).
 *
 * A failed retry is not a failed update. The quota was optional before this feature existed
 * and it stays optional.
 */
export async function fetchRemoteProfile(
  remoteUrl: string,
  options: FetchRemoteProfileOptions,
): Promise<RemoteProfileFetch> {
  const {
    userAgent,
    fetchImplementation = globalThis.fetch as unknown as FetchLike,
    timeoutMilliseconds = REMOTE_REQUEST_TIMEOUT_MILLISECONDS,
    maximumProfileBytes = MAXIMUM_REMOTE_PROFILE_BYTES,
    maximumErrorBytes = MAXIMUM_REMOTE_ERROR_BYTES,
  } = options;
  const requestUrl = new URL(remoteUrl);
  const response = await requestRemote(
    requestUrl,
    userAgent,
    timeoutMilliseconds,
    fetchImplementation,
  );
  if (response.status !== 200) {
    const status = describeStatus(response);
    let body: string;
    try {
      body = await readLimitedResponse(response, maximumErrorBytes);
    } catch (error) {
      throw new Error(
        `HTTP ${status}: ${error instanceof Error ? error.message : String(error)}`,
      );
    }
    throw new Error(`HTTP ${status}: ${body}`);
  }
  const quota = quotaUpdateFromHeaders(response.headers);
  const content = await readLimitedResponse(response, maximumProfileBytes);
  if (quota !== undefined) {
    return { content, quota };
  }
  return { content, quota: await querySubscriptionQuota(requestUrl, fetchImplementation, timeoutMilliseconds) };
}
