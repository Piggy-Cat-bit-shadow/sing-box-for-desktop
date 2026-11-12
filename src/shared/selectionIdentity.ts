// Which selection attempt a confirmation belongs to.
//
// The tray used to settle a selection by its tags: `selectOutbound({ groupTag, outboundTag })`
// and then nothing - the radio state is rebuilt from the groups stream, and the call's answer was
// dropped. A group tag cannot name an attempt, so two clicks on one group were indistinguishable:
// a late answer for the first could be read after the second, and a failure left the menu showing
// the last stream snapshot with only a console line.
//
// The daemon's `SelectOutboundResponse` carries the caller's `requestId`, the member the group
// actually holds and the group revision after the selection. This ledger keeps the latest attempt
// per group and decides what an answer may change:
//
//   * an answer for a replaced attempt is ignored;
//   * an answer whose revision is older than one already applied is ignored;
//   * an answer without the identity fields (`requestId` 0) is unconfirmed, not a success: an old
//     daemon performed the selection but cannot say which attempt it was;
//   * only the latest attempt, at a revision not older than the last applied one, moves the row.
//
// It is a plain value/class pair with no Electron or protobuf dependency, so it is testable under
// `node --test` without a daemon.

export interface SelectionSnapshot {
  readonly groupTag: string;
  readonly outboundTag: string;
  readonly requestId: bigint;
  readonly expectedRevision: bigint;
}

export interface SelectionResponse {
  readonly requestId: bigint;
  readonly appliedOutboundTag: string;
  readonly appliedRevision: bigint;
  readonly stale: boolean;
}

export type SelectionSettlement =
  | { readonly kind: "applied"; readonly outboundTag: string; readonly revision: bigint; readonly stale: boolean }
  | { readonly kind: "unconfirmed"; readonly reason: string }
  | { readonly kind: "ignored-older-request"; readonly latestRequestId: bigint }
  | { readonly kind: "ignored-older-revision"; readonly latestRevision: bigint }
  | { readonly kind: "failed"; readonly reason: string };

export class SelectionLedger {
  private readonly pending = new Map<string, { requestId: bigint; outboundTag: string }>();
  private readonly appliedRevisions = new Map<string, bigint>();
  private nextRequestId = 0n;

  /** Starts a new attempt and makes it the latest for its group. */
  begin(groupTag: string, outboundTag: string): SelectionSnapshot {
    this.nextRequestId += 1n;
    const snapshot: SelectionSnapshot = {
      groupTag,
      outboundTag,
      requestId: this.nextRequestId,
      expectedRevision: this.appliedRevisions.get(groupTag) ?? 0n,
    };
    this.pending.set(groupTag, { requestId: snapshot.requestId, outboundTag });
    return snapshot;
  }

  /** The tag the menu should keep showing while an attempt is in flight. */
  pendingSelection(groupTag: string): { readonly requestId: bigint; readonly outboundTag: string } | null {
    return this.pending.get(groupTag) ?? null;
  }

  appliedRevision(groupTag: string): bigint {
    return this.appliedRevisions.get(groupTag) ?? 0n;
  }

  /** Applies the daemon's read-back, if it may still move the menu. */
  settle(snapshot: SelectionSnapshot, response: SelectionResponse): SelectionSettlement {
    const current = this.pending.get(snapshot.groupTag);
    if (current === undefined || current.requestId !== snapshot.requestId) {
      return { kind: "ignored-older-request", latestRequestId: current?.requestId ?? snapshot.requestId };
    }
    if (response.requestId !== snapshot.requestId) {
      return { kind: "unconfirmed", reason: `the daemon answered request ${response.requestId}, not ${snapshot.requestId}` };
    }
    if (!response.appliedOutboundTag) {
      this.pending.delete(snapshot.groupTag);
      return { kind: "unconfirmed", reason: "the daemon did not name the member the group holds" };
    }
    const latestRevision = this.appliedRevisions.get(snapshot.groupTag) ?? 0n;
    if (response.appliedRevision < latestRevision) {
      this.pending.delete(snapshot.groupTag);
      return { kind: "ignored-older-revision", latestRevision };
    }
    this.pending.delete(snapshot.groupTag);
    this.appliedRevisions.set(snapshot.groupTag, response.appliedRevision);
    return { kind: "applied", outboundTag: response.appliedOutboundTag, revision: response.appliedRevision, stale: response.stale };
  }

  /** Reports a failed attempt. A failure for a replaced attempt changes nothing. */
  fail(snapshot: SelectionSnapshot, reason: string): SelectionSettlement {
    const current = this.pending.get(snapshot.groupTag);
    if (current === undefined || current.requestId !== snapshot.requestId) {
      return { kind: "ignored-older-request", latestRequestId: current?.requestId ?? snapshot.requestId };
    }
    this.pending.delete(snapshot.groupTag);
    return { kind: "failed", reason };
  }
}
