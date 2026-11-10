/**
 * Ownership of one remote-config application, as a pure sequence.
 *
 * `updateRemoteProfile` used to read the selected profile once, then spend an unbounded amount of
 * time in `getStartedAt()` and `serviceStartOptions()` before handing A's content to the daemon.
 * A profile switch inside that window still applied A's body and then attributed the next Box to A.
 *
 * This module makes the boundary explicit and injectable: every await that can lose ownership is
 * performed by a probe the test can park, and the decision is a value. The production caller
 * supplies the real daemon; the tests park `startedAt` or the start-options step and switch the
 * selected profile in between.
 */

export type ApplyStatus = "applied" | "apply-unconfirmed" | "superseded" | "apply-failed";

export interface ApplyResult {
  status: ApplyStatus;
  previousStartedAt?: string;
  startedAt?: string;
  detail?: string;
  /** The daemon's revision for the bytes this operation confirmed, when it answered. */
  confirmedRevision?: string;
  /** Selection epoch that was current when the revision was confirmed. */
  confirmedEpoch?: number;
}

export interface OwnershipProbe {
  /** The id the UI currently selects, or null. */
  selectedProfileId: () => string | null;
  /** Whether the daemon reports a running service. */
  running: () => boolean;
  /**
   * Monotonic selection epoch. It moves on every selected-profile write, including A -> B -> A,
   * where the id alone would compare equal at both ends.
   */
  selectionEpoch: () => number;
  /** The daemon's per-Box start timestamp, as a decimal string, or null. */
  startedAt: () => Promise<string | null>;
  /** The body currently stored for this profile. */
  storedContent: () => Promise<string>;
  /** The daemon's target revision for [content], or null when it cannot answer. */
  targetRevision?: (content: string) => Promise<string | null>;
  /** Polls the daemon's active revision and returns the one it reports for [expected]. */
  appliedRevision?: (expected: string) => Promise<string | null>;
}

function owns(profileId: string, probe: OwnershipProbe): boolean {
  return probe.selectedProfileId() === profileId && probe.running();
}

/**
 * Applies [content] to [profileId], refusing at every re-check once the selection or the instance
 * has moved.
 *
 * `start` receives a `stillOwner` guard: the production implementation must call it after resolving
 * start options and before its daemon call. Returning false means the start was skipped; true means
 * the daemon accepted the start call.
 *
 * Timestamps prove only that a Box instance changed; content equality proves the stored document is
 * still this operation's. Neither proves the daemon consumed these exact bytes (the pinned daemon
 * has no applied-revision receipt), which is why the caller must report `apply-unconfirmed` when the
 * timestamp did not move.
 */
export async function applyOwnedConfig(
  profileId: string,
  content: string,
  probe: OwnershipProbe,
  start: (stillOwner: () => Promise<boolean>) => Promise<boolean>,
  describe: (error: unknown) => string = defaultDescribe,
): Promise<ApplyResult> {
  const epochBefore = probe.selectionEpoch();
  const stillOwner = () => owns(profileId, probe) && probe.selectionEpoch() === epochBefore;
  let before: string | null;
  try {
    before = await probe.startedAt();
  } catch (error) {
    return { status: "apply-unconfirmed", detail: `instance identity unavailable: ${describe(error)}` };
  }
  if (!stillOwner()) {
    return { status: "superseded", detail: "selection changed before the start" };
  }
  if (probe.running() && before === null) {
    // A running Box we cannot identify is not a baseline: accepting a later timestamp would let
    // another operation's instance confirm this one.
    return { status: "apply-unconfirmed", detail: "running instance identity unavailable" };
  }
  let expectedRevision: string | null = null;
  if (probe.targetRevision !== undefined) {
    try {
      expectedRevision = await probe.targetRevision(content);
    } catch {
      expectedRevision = null;
    }
    if (!stillOwner()) {
      return { status: "superseded", detail: "selection changed while reading the target revision" };
    }
  }
  let started: boolean;
  try {
    started = await start(async () => {
      if (!stillOwner()) return false;
      if (before === null) return true;
      // The start options / target-revision read can outlive the Box that was current when this
      // operation began. A same-profile restart is a different instance even though the id and
      // epoch are unchanged.
      try {
        return (await probe.startedAt()) === before;
      } catch {
        return false;
      }
    });
  } catch (error) {
    if (!stillOwner()) {
      return { status: "superseded", detail: describe(error) };
    }
    return { status: "apply-failed", detail: describe(error), previousStartedAt: before ?? undefined };
  }
  if (!started) {
    return {
      status: "superseded",
      detail: "selection changed before the daemon start",
      previousStartedAt: before ?? undefined,
    };
  }
  let after: string | null;
  try {
    after = await probe.startedAt();
  } catch (error) {
    return {
      status: "apply-unconfirmed",
      detail: `instance identity unavailable after the start: ${describe(error)}`,
      previousStartedAt: before ?? undefined,
    };
  }
  if (!stillOwner()) {
    return {
      status: "superseded",
      detail: "selection changed during the daemon start",
      previousStartedAt: before ?? undefined,
      startedAt: after ?? undefined,
    };
  }
  let disk: string;
  try {
    disk = await probe.storedContent();
  } catch (error) {
    return { status: "apply-failed", detail: describe(error), previousStartedAt: before ?? undefined };
  }
  // The last read is itself an await: A -> B -> A by id looks unchanged, and another start/reload
  // can move the timestamp. Re-read both after the body and compare with what was confirmed.
  let final: string | null;
  try {
    final = await probe.startedAt();
  } catch (error) {
    return {
      status: "apply-unconfirmed",
      detail: `instance identity unavailable while confirming: ${describe(error)}`,
      previousStartedAt: before ?? undefined,
      startedAt: after ?? undefined,
    };
  }
  if (!stillOwner()) {
    return {
      status: "superseded",
      detail: "selection changed during the final read",
      previousStartedAt: before ?? undefined,
      startedAt: after ?? undefined,
    };
  }
  if (disk !== content) {
    return {
      status: "superseded",
      detail: "a newer write replaced this body",
      previousStartedAt: before ?? undefined,
      startedAt: after ?? undefined,
    };
  }
  if (final === null || final !== after) {
    return {
      status: "superseded",
      detail: "the instance changed while confirming this update",
      previousStartedAt: before ?? undefined,
      startedAt: final ?? after ?? undefined,
    };
  }
  let appliedRevision: string | null = null;
  if (probe.appliedRevision !== undefined && expectedRevision !== null) {
    try {
      appliedRevision = await probe.appliedRevision(expectedRevision);
    } catch {
      appliedRevision = null;
    }
    if (!stillOwner()) {
      return {
        status: "superseded",
        detail: "selection changed while reading the applied revision",
        previousStartedAt: before ?? undefined,
        startedAt: final,
      };
    }
  }
  if (expectedRevision !== null) {
    if (appliedRevision === expectedRevision) {
      return {
        status: "applied",
        confirmedRevision: expectedRevision,
        confirmedEpoch: epochBefore,
        previousStartedAt: before ?? undefined,
        startedAt: final,
      };
    }
    return {
      status: "apply-unconfirmed",
      detail:
        appliedRevision === null
          ? "the daemon has no applied-revision receipt"
          : "the daemon is serving a different revision",
      previousStartedAt: before ?? undefined,
      startedAt: final,
    };
  }
  // No revision contract on this daemon. A moved timestamp still proves a new Box existed, but
  // never which document it consumed, so the most this operation may report is unconfirmed.
  return {
    status: "apply-unconfirmed",
    detail: "the daemon predates the applied-revision receipt",
    previousStartedAt: before ?? undefined,
    startedAt: final,
  };
}

/**
 * Whether a provider refresh still targets the instance the operation started against.
 *
 * A timestamp that moved means another start/reload happened, so the old operation's provider
 * result would describe a different Box. A selection change is checked by the caller as well; this
 * is the instance half.
 */
export function instanceStillOurs(
  profileId: string,
  selectedProfileId: string | null,
  running: boolean,
  startedAtAtStart: string | null,
  currentStartedAt: string | null,
  selectionEpochAtStart?: number,
  currentSelectionEpoch?: number,
): boolean {
  return (
    selectedProfileId === profileId &&
    running &&
    startedAtAtStart !== null &&
    currentStartedAt !== null &&
    currentStartedAt === startedAtAtStart &&
    (selectionEpochAtStart === undefined ||
      currentSelectionEpoch === undefined ||
      currentSelectionEpoch === selectionEpochAtStart)
  );
}

/** The live facts the provider half must match before it may send an RPC. */
export interface LiveInstance {
  selectedProfileId: string | null;
  running: boolean;
  startedAt: string | null;
  selectionEpoch: number;
  revision: string | null;
}

export type ProviderBinding = "ok" | "not-active" | "not-running" | "superseded";

/** The independent reads a provider refresh needs, injectable so a barrier can move them. */
export interface ProviderReads {
  selectedProfileId: () => string | null;
  running: () => boolean;
  selectionEpoch: () => number;
  startedAt: () => Promise<string | null>;
  revision: () => Promise<string | null>;
}

/**
 * Reads one coherent provider-binding snapshot, with the revision query as the last slow read.
 *
 * Every field that a selection/Box change can move is read again after `revision()`; if any moved
 * during the read, the result is null. Returning a snapshot is never proof that no change follows
 * it, only that the values in it were observed in the same stable window.
 */
export async function stableLiveInstance(
  reads: ProviderReads,
  expectedRevision: string | null,
): Promise<LiveInstance | null> {
  const selectedBefore = reads.selectedProfileId();
  const runningBefore = reads.running();
  const epochBefore = reads.selectionEpoch();
  let revision = expectedRevision;
  if (expectedRevision !== null) {
    revision = await reads.revision();
  }
  const selected = reads.selectedProfileId();
  const running = reads.running();
  const epoch = reads.selectionEpoch();
  const started = await reads.startedAt();
  const revisionAfter = expectedRevision === null ? null : await reads.revision();
  const selectedAfter = reads.selectedProfileId();
  const runningAfter = reads.running();
  const epochAfter = reads.selectionEpoch();
  if (
    selectedBefore !== selectedAfter ||
    runningBefore !== runningAfter ||
    epochBefore !== epochAfter ||
    selectedAfter !== selected ||
    runningAfter !== running ||
    epochAfter !== epoch ||
    revisionAfter !== revision
  ) {
    return null;
  }
  return {
    selectedProfileId: selectedAfter,
    running: runningAfter,
    startedAt: started,
    selectionEpoch: epochAfter,
    revision: revisionAfter,
  };
}

export type ProviderRefreshOutcome<T> =
  | { kind: "ok"; value: T }
  | { kind: "not-active" | "not-running" | "superseded"; detail?: string };

/**
 * Runs the provider RPC only while the confirmed instance/epoch/revision are still bound.
 *
 * The callback is the actual transport call in production and a spy in tests. A moved selection
 * during the revision query, a different live instance, or a revision mismatch returns before the
 * callback, so the test can assert zero calls to the wrong target. A change during the callback is
 * caught afterwards and its value is dropped (the RPC cannot be un-sent).
 */
export async function refreshProvidersIfStillBound<T>(
  profileId: string,
  expectedStartedAt: string,
  expectedEpoch: number,
  expectedRevision: string | null,
  reads: ProviderReads,
  refresh: () => Promise<T>,
): Promise<ProviderRefreshOutcome<T>> {
  const before = await stableLiveInstance(reads, expectedRevision);
  if (before === null) {
    return { kind: "superseded", detail: "the selection or revision changed while reading the instance" };
  }
  const binding = classifyProviderBinding(
    profileId,
    expectedStartedAt,
    expectedEpoch,
    expectedRevision,
    before,
  );
  if (binding !== "ok") {
    return { kind: binding };
  }
  const value = await refresh();
  const after = await stableLiveInstance(reads, expectedRevision);
  if (
    after === null ||
    classifyProviderBinding(profileId, expectedStartedAt, expectedEpoch, expectedRevision, after) !== "ok"
  ) {
    return { kind: "superseded", detail: "the instance changed during the provider refresh" };
  }
  return { kind: "ok", value };
}

/**
 * Classifies whether the provider RPC may still be attributed to the confirmed instance.
 *
 * Unlike [instanceStillOurs], an unknown expected start timestamp is never "ok": a provider call
 * has no way to say which Box it wants, so "I could not identify the instance" must produce an
 * explicit non-ok result instead of refreshing whatever is current. The same rule applies to the
 * applied revision: `null` expected revision means this daemon has no receipt, and the caller must
 * not claim the refresh belongs to this update.
 */
export function classifyProviderBinding(
  profileId: string,
  expectedStartedAt: string,
  expectedEpoch: number,
  expectedRevision: string | null,
  live: LiveInstance,
): ProviderBinding {
  if (live.selectedProfileId !== profileId) return "not-active";
  if (!live.running) return "not-running";
  if (
    expectedStartedAt === "" ||
    live.startedAt === null ||
    live.startedAt !== expectedStartedAt ||
    live.selectionEpoch !== expectedEpoch
  ) {
    return "superseded";
  }
  if (expectedRevision !== null && live.revision !== expectedRevision) return "superseded";
  return "ok";
}

function defaultDescribe(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}
