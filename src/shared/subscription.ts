/**
 * The `Subscription-Userinfo` response header: parsing, and the request policy that
 * obtains it.
 *
 * This lives in `shared/` because the dashboard's test runner is the repository's only test
 * harness, and this is the part of the feature that has to be tested rather than eyeballed -
 * it takes numbers from a remote server, and every one of them can be absent, malformed, out
 * of range or lying.
 *
 * It carries no Node or Electron API, so it is importable from either side.
 */

/**
 * A quota snapshot as it is STORED and carried on the profile: the raw facts a provider
 * reported, plus when they arrived.
 *
 * One type rather than a parsed shape plus a stored shape, because they are the same object
 * on the wire - `ProfileMetadata.subscription` is the row - and a second declaration would be
 * a second thing to keep in step. Only `updatedAt` is not the provider's: the parser cannot
 * know it, so the caller stamps it.
 *
 * These are the RAW facts. `used`, `remaining`, percentages and formatted text are all
 * derivable and are therefore not stored - a persisted derived value is a value that can be
 * left disagreeing with its inputs after a partial update.
 */
export interface SubscriptionQuota {
  /** Bytes uploaded, as the provider reported them. */
  upload?: number;
  /** Bytes downloaded, as the provider reported them. */
  download?: number;
  /** Quota total in bytes. Absent when the provider sells no fixed quota. */
  total?: number;
  /** Unix timestamp in SECONDS, exactly as the header carries it. */
  expire?: number;
  /**
   * When this snapshot arrived, in milliseconds.
   *
   * Separate from `ProfileMetadata.lastUpdated` on purpose. That one says when the profile
   * CONTENT was last refreshed; a provider can stop sending the header at any time, so the
   * content can be a minute old while the quota is a week old. Showing one as the other
   * would present stale traffic figures as current.
   */
  updatedAt: number;
}

/** What `parseSubscriptionUserInfo` produces: the provider's fields, with no timestamp yet. */
export type ParsedSubscriptionQuota = Omit<SubscriptionQuota, "updatedAt">;

/**
 * The quota change a fetch produced - the state machine, as one type.
 *
 * It is declared here, next to the snapshot it describes, and not in either of the two places
 * that consume it: `subscriptionFetch` produces one and `subscriptionStorage` applies one, and
 * `shared/` must not import from `main/` (the renderer bundles `shared/`, and `main/` pulls in
 * Node and Electron). So the type lives where both sides can name it, and the alternative -
 * two structurally identical declarations - would be two things to keep in step.
 *
 *   `undefined`            the provider sent no header. Keep the last known snapshot and
 *                          leave its `updatedAt` alone, so the UI can say how old it is
 *                          instead of showing an empty card.
 *   `{ quota: {...} }`     the provider sent a header. AUTHORITATIVE: fields it left out are
 *                          cleared rather than inherited from the previous snapshot, so an
 *                          old `expire` cannot attach itself to a new `total`, and
 *                          `updatedAt` moves to now.
 *   `{ quota: null }`      the snapshot is gone - the profile's URL changed, so the old
 *                          account's quota is not this subscription's.
 *
 * The distinction between the first and second is the one that is easiest to get subtly
 * wrong and hardest to notice: the wrong way round produces a card that is either permanently
 * stale or permanently empty, and both look like "the provider did something".
 */
export type SubscriptionQuotaUpdate = { quota: SubscriptionQuota | null } | undefined;

/**
 * Largest number accepted from the header.
 *
 * Not `Number.MAX_SAFE_INTEGER` by accident: above 2^53-1 a JavaScript number can no longer
 * represent every integer, so a byte count that large would be silently rounded to a nearby
 * value that is not what the server said. 1 PiB is ~2^50, so this is far past every real
 * quota while staying inside the exactly-representable range; SQLite's INTEGER is 64-bit and
 * could hold more, which is not a reason to persist a number the UI has already corrupted.
 */
export const MAXIMUM_SUBSCRIPTION_QUOTA_VALUE = 1_125_899_906_842_624;

/**
 * Reads a byte count or a unix-seconds timestamp out of one header segment.
 *
 * Rejects, rather than repairs: a non-numeric, negative, non-finite or out-of-range value
 * means the segment is dropped, so `upload=abc` cannot become 0 (which would understate
 * usage) and `total=-1` cannot become a quota.
 */
function parseQuotaValue(raw: string): number | undefined {
  const text = raw.trim();
  // Only an optional sign and digits. `Number()` would also accept "1e9", "0x10", " 1 " and
  // "" (as 0), none of which a provider is entitled to send here.
  if (!/^[+-]?\d+$/.test(text)) {
    return undefined;
  }
  const value = Number(text);
  if (!Number.isSafeInteger(value) || value < 0 || value > MAXIMUM_SUBSCRIPTION_QUOTA_VALUE) {
    return undefined;
  }
  return value;
}

/**
 * Parses a `Subscription-Userinfo` header value.
 *
 * Returns `undefined` when the header is absent, and an object when it is present - possibly
 * an empty one. The caller needs that distinction, because "the provider did not send the
 * header" and "the provider sent a header we could not use" mean different things for the
 * snapshot that is already stored. Collapsing both to `undefined` would make a provider that
 * stopped sending usable numbers indistinguishable from one that never sent the header, and
 * the stale snapshot would then be presented as current forever.
 *
 * Tolerated: key case, whitespace around keys, `=`, values and `;`, a missing trailing `;`,
 * duplicate keys (last wins, which is the order a browser would also produce), unknown keys,
 * and segments with no `=` at all. None of these are errors - the header is a semi-formal
 * convention shared by many panels, not a specification.
 */
export function parseSubscriptionUserInfo(
  header: string | null | undefined,
): ParsedSubscriptionQuota | undefined {
  if (header === null || header === undefined) {
    return undefined;
  }
  const quota: ParsedSubscriptionQuota = {};
  for (const segment of header.split(";")) {
    const separator = segment.indexOf("=");
    if (separator === -1) {
      continue;
    }
    const key = segment.slice(0, separator).trim().toLowerCase();
    const value = parseQuotaValue(segment.slice(separator + 1));
    if (value === undefined) {
      continue;
    }
    switch (key) {
      case "upload":
        quota.upload = value;
        break;
      case "download":
        quota.download = value;
        break;
      case "total":
        quota.total = value;
        break;
      case "expire":
        quota.expire = value;
        break;
      default:
        // An unknown key is ignored, never guessed at.
        break;
    }
  }
  return quota;
}

/** Whether a parsed snapshot carries at least one usable fact. */
export function hasSubscriptionQuota(quota: ParsedSubscriptionQuota | undefined): boolean {
  return (
    quota !== undefined &&
    (quota.upload !== undefined ||
      quota.download !== undefined ||
      quota.total !== undefined ||
      quota.expire !== undefined)
  );
}

/**
 * The header name, lower-cased for the Fetch API's case-insensitive lookup.
 *
 * Spelled once because it is looked up in two paths - the initial response and each
 * compatibility retry - and a typo in either would look exactly like a provider that does
 * not send the header.
 */
export const SUBSCRIPTION_USER_INFO_HEADER = "subscription-userinfo";

/**
 * The User-Agent every subscription body request carries on first import and every update.
 *
 * Fixed independently of the app's own identity: panels identify subscription clients by this
 * stable string, while GitHub updates, rule-set downloads and every other request keep the
 * app's own User-Agent.
 */
export const SUBSCRIPTION_USER_AGENT = "sing-box/1.15.0";

/**
 * The User-Agents tried, in order, ONLY to recover the quota header.
 *
 * Some providers send `subscription-userinfo` only to clients they recognise, and return the
 * same subscription body to everyone. The first request is always made with this client's own
 * User-Agent, and its body - not a retry's - is the profile content; a retry exists solely to
 * read this header.
 *
 * Deliberately two entries and not a matrix: each retry is a real request to the provider,
 * and a provider that recognises neither of these is not going to recognise a third guess.
 * The spellings are the ones the reference implementation settled on
 * (xinggaoya/sing-box-windows, `SUBSCRIPTION_USERINFO_COMPAT_UAS`).
 */
export const SUBSCRIPTION_QUOTA_COMPATIBILITY_USER_AGENTS = ["clash.meta", "clash-verge/1.7.7"] as const;

/**
 * Whether a retry for the quota header is warranted.
 *
 * There is nothing to recover when the header already parsed, and nothing to retry when the
 * response was not a success - a 404 or an error page will not start carrying the header for
 * a different User-Agent, and retrying it would triple the cost of every failed update.
 */
export function shouldRetryForSubscriptionQuota(
  responseOk: boolean,
  quota: ParsedSubscriptionQuota | undefined,
): boolean {
  return responseOk && quota === undefined;
}
