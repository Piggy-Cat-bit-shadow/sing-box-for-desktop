/**
 * The two halves of a remote-profile update, as one structured result.
 *
 * A remote update is not one boolean. The subscription body can download, validate, stay
 * unchanged or be replaced by a new Box, and the remote provider refresh is a second, independent
 * operation that has its own statuses (published / unchanged / partial / busy / cancelled). The
 * renderer used to receive `Promise<void>` and therefore could not show either half; a provider
 * that refused a group or an old daemon without the RPC was indistinguishable from success.
 *
 * This module is deliberately pure: no Electron, no daemon client, no files. The main process maps
 * the daemon's protobuf response into [ProviderRefreshLike] and asks [describeProviderRefresh] what
 * to report; the renderer maps the same result type into text.
 */

/** One provider entry as the daemon reports it. Field names are the protobuf (camelCase) names. */
export interface ProviderRefreshLike {
  tag: string;
  status: string;
  pendingTags: string[];
  restartRequired: boolean;
  reason: string;
}

/** The daemon's `RemoteProviderRefreshResponse`, structurally. */
export interface ProviderRefreshSummaryLike {
  results: ProviderRefreshLike[];
  cancelled: boolean;
  boxChanged: boolean;
}

export type ConfigUpdateStatus =
  /** The downloaded body is byte-identical to the stored one; nothing was reloaded. */
  | "unchanged"
  /** The body changed and the daemon confirmed a new startedAt on the selected profile. */
  | "applied"
  /** The body changed but this profile is not the running one (or the daemon is stopped). */
  | "saved"
  /** The body changed and the reload RPC failed; the old document is still on disk. */
  | "apply-failed"
  /** The reload returned but the daemon's startedAt did not move: no observable new instance. */
  | "apply-unconfirmed"
  /** The body downloaded but did not pass static validation; the stored body was kept. */
  | "invalid-config"
  | "download-failed"
  /** The profile was switched away while the update was in flight; nothing was applied. */
  | "superseded";

export type ProviderUpdateStatus =
  /** The provider refresh succeeded on the live Box. */
  | "published"
  | "unchanged"
  /** The core accepted the document but the live graph refused some members. */
  | "partial"
  | "failed"
  | "busy"
  | "cancelled"
  /** The Box changed during the refresh; the report is about more than one instance. */
  | "box-changed"
  /** The running config has no remote providers. */
  | "none"
  /** The updated profile is not the selected/running one, so no instance belongs to it. */
  | "not-active"
  /** The selected profile is not running; a refresh would have no Box to reach. */
  | "not-running"
  /** Another operation replaced the body/instance while this update was in flight. */
  | "superseded"
  /** The daemon predates RefreshRemoteProviders. */
  | "unsupported"
  /** The RPC failed for another reason. */
  | "unavailable";

export interface ProviderUpdateCounts {
  published: number;
  unchanged: number;
  failed: number;
  skipped: number;
  busy: number;
  pending: number;
  restartRequired: number;
  total: number;
}

export interface RemoteProfileConfigUpdate {
  status: ConfigUpdateStatus;
  /** Human-readable detail (validation message, RPC error), absent for clean outcomes. */
  detail?: string;
  /** The daemon instance timestamp before the reload, as a decimal string. */
  previousStartedAt?: string;
  /** The daemon instance timestamp after the reload, as a decimal string. */
  startedAt?: string;
}

export interface RemoteProfileProviderUpdate {
  status: ProviderUpdateStatus;
  counts?: ProviderUpdateCounts;
  detail?: string;
}

export interface RemoteProfileUpdate {
  profileId: string;
  /** Whether the stored body changed. Independent of whether it was applied. */
  changed: boolean;
  config: RemoteProfileConfigUpdate;
  providers: RemoteProfileProviderUpdate;
}

/**
 * Maps the daemon response (or the reason there is none) into the provider half.
 *
 * Order matters. A partial document comes back as `published` plus pending tags, so counting
 * statuses first would report it as a clean success; `box_changed` means the report spans two
 * instances and cannot be shown as one instance's result. Unknown statuses count toward `total` and
 * make the result `failed` rather than silently claiming success.
 */
export function describeProviderRefresh(
  summary: ProviderRefreshSummaryLike | null,
  unavailable: Extract<ProviderUpdateStatus, "not-active" | "not-running" | "unsupported" | "unavailable"> | null = null,
): RemoteProfileProviderUpdate {
  if (summary === null) {
    return { status: unavailable ?? "unavailable" };
  }
  if (summary.boxChanged) {
    return { status: "box-changed" };
  }
  if (summary.cancelled) {
    return { status: "cancelled" };
  }
  const counts: ProviderUpdateCounts = {
    published: 0,
    unchanged: 0,
    failed: 0,
    skipped: 0,
    busy: 0,
    pending: 0,
    restartRequired: 0,
    total: summary.results.length,
  };
  let unknown = 0;
  for (const result of summary.results) {
    counts.pending += result.pendingTags.length;
    if (result.restartRequired) {
      counts.restartRequired += 1;
    }
    switch (result.status) {
      case "published":
        counts.published += 1;
        break;
      case "unchanged":
        counts.unchanged += 1;
        break;
      case "failed":
        counts.failed += 1;
        break;
      case "skipped":
        counts.skipped += 1;
        break;
      case "busy":
        counts.busy += 1;
        break;
      default:
        unknown += 1;
        break;
    }
  }
  // An unknown status is not a pending one: if it is reported alongside pending tags, calling the
  // whole report `partial` would present a result this client cannot interpret as a warning about
  // the parts it can. Ask for the failure first; the counts still carry the pending/restart facts.
  if (unknown > 0) {
    return { status: "failed", counts, detail: `${unknown} unknown provider status` };
  }
  if (counts.pending > 0 || counts.restartRequired > 0) {
    return { status: "partial", counts };
  }
  if (counts.total === 0) {
    return { status: "none", counts };
  }
  if (counts.failed > 0) {
    return { status: "failed", counts };
  }
  if (counts.busy > 0) {
    return { status: "busy", counts };
  }
  if (counts.published > 0) {
    return { status: "published", counts };
  }
  return { status: "unchanged", counts };
}
