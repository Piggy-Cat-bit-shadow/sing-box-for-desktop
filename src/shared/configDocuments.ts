/**
 * The daemon's configuration documents, as the shell receives them.
 *
 * The kernel reports what applying a profile would do (`PreviewServiceChange`), what the last
 * attempt did (`GetLastServiceChange`) and whether the instance in front of the user was reached
 * by recovering from a failed start (`GetLastConfigRecovery`). All three arrive as a JSON string
 * inside `JSONDocument`, and the three outcomes a caller must keep apart are:
 *
 *   - a document, because the daemon answered;
 *   - the JSON literal `null`, because the daemon has no record yet (a fresh instance);
 *   - an empty string or an `Unimplemented` status, because the daemon predates the RPC.
 *
 * Collapsing the last two is the failure this module exists to prevent. "This kernel cannot tell
 * you" and "nothing has happened yet" lead to different UI: the first must not be shown as a
 * clean state, and the second must not be shown as an unsupported feature.
 *
 * The libbox bridge in the core encodes the same distinction (`wrapString("")` for
 * `codes.Unimplemented`, the marshalled document otherwise), so the Windows shell and the Apple
 * client read one contract rather than two.
 */

import { Code, ConnectError } from "@connectrpc/connect";

/** One value a plan would change. Mirrors `daemon.DomainChange`. */
export interface DomainChange {
  kind: string;
  from?: string;
  to?: string;
  detail?: string;
}

/** What one live-owned domain would do. Mirrors `daemon.DomainPlan`. */
export interface DomainPlan {
  domain: string;
  supported: boolean;
  unsupportedReason?: string;
  restartRequired: boolean;
  changes?: DomainChange[];
  currentRevision?: string;
  targetRevision?: string;
}

/** The provider domain's plan. Mirrors `daemon.ProviderDomainPlan`. */
export interface ProviderDomainPlan {
  domain: string;
  supported: boolean;
  unsupportedReason?: string;
  tags?: string[];
  liveRefresh?: boolean;
  liveRefreshReason?: string;
  currentRevision?: string;
  targetRevision?: string;
}

/** Mirrors `daemon.ServiceChangePlan`. */
export interface ServiceChangePlan {
  started: boolean;
  currentRevision?: string;
  targetRevision?: string;
  unchanged: boolean;
  liveOnly: boolean;
  restartRequired: boolean;
  changedDocument: boolean;
  stale?: boolean;
  changedSections?: string[];
  mode?: DomainPlan;
  dns?: DomainPlan;
  rule?: DomainPlan;
  provider?: ProviderDomainPlan;
}

/** One provider's refresh result. Mirrors `daemon.ProviderRefreshResult`. */
export interface ProviderRefreshResult {
  tag: string;
  status: string;
  requestedRevision?: number;
  appliedRevision?: number;
  pendingTags?: string[];
  restartRequired?: boolean;
  reason?: string;
}

/** Mirrors `daemon.ProviderDomainReport`. */
export interface ProviderDomainReport {
  domain: string;
  status: string;
  results?: ProviderRefreshResult[];
  restartRequired: boolean;
  reason?: string;
  revision?: string;
}

/** Mirrors `daemon.ServiceChangeReport`. */
export interface ServiceChangeReport {
  plan: ServiceChangePlan;
  status: string;
  restartRequired: boolean;
  retained: boolean;
  activeRevision?: string;
  persistence?: string;
  persistenceWarning?: string;
  reason?: string;
  time: string;
  applied?: DomainChange[];
  provider?: ProviderDomainReport;
}

/** Mirrors `daemon.ConfigRecoveryInfo`. */
export interface ConfigRecoveryInfo {
  time: string;
  failedRevision: string;
  activeRevision: string;
  error: string;
}

/**
 * One configuration document, or the reason there is none.
 *
 * `absent` and `unsupported` are deliberately different values rather than two flavours of
 * `null`: only one of them is a statement about the daemon's version.
 */
export type ConfigurationDocument<T> =
  | { readonly kind: "document"; readonly document: T }
  | { readonly kind: "absent" }
  | { readonly kind: "unsupported" };

/**
 * Classifies the JSON payload of a `JSONDocument` response.
 *
 * Unknown fields are kept, not stripped: the kernel may add one before this client knows it, and
 * a strict decoder would turn a compatible daemon into a broken one. An array or a bare string is
 * NOT one of those additions - it is a document this contract cannot read - so it throws instead
 * of being shown as a document with missing fields.
 */
export function classifyConfigurationDocument<T extends object>(
  json: string,
): ConfigurationDocument<T> {
  if (json.length === 0) {
    return { kind: "unsupported" };
  }
  const value: unknown = JSON.parse(json);
  if (value === null) {
    return { kind: "absent" };
  }
  if (typeof value !== "object" || Array.isArray(value)) {
    throw new Error("configuration document is not an object");
  }
  return { kind: "document", document: value as T };
}

/**
 * Runs one configuration call and classifies its answer.
 *
 * `Unimplemented` is the daemon saying "this RPC does not exist", which is the same statement as
 * the empty string the libbox bridge produces for an older kernel. Every other failure is
 * rethrown: a transport error, a deadline or an internal error is NOT evidence of an old daemon,
 * and reporting it as one would hide a broken connection behind a compatibility message.
 */
export async function readConfigurationDocument<T extends object>(
  call: () => Promise<string>,
): Promise<ConfigurationDocument<T>> {
  try {
    return classifyConfigurationDocument<T>(await call());
  } catch (error) {
    if (error instanceof ConnectError && error.code === Code.Unimplemented) {
      return { kind: "unsupported" };
    }
    throw error;
  }
}
