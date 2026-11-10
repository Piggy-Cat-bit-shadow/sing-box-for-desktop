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
}

export interface OwnershipProbe {
  /** The id the UI currently selects, or null. */
  selectedProfileId: () => string | null;
  /** Whether the daemon reports a running service. */
  running: () => boolean;
  /** The daemon's per-Box start timestamp, as a decimal string, or null. */
  startedAt: () => Promise<string | null>;
  /** The body currently stored for this profile. */
  storedContent: () => Promise<string>;
}

function owns(profileId: string, probe: OwnershipProbe): boolean {
  return probe.selectedProfileId() === profileId && probe.running();
}

function moved(before: string | null, after: string | null): boolean {
  return after !== null && after !== "0" && (before === null || BigInt(after) > BigInt(before));
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
  start: (stillOwner: () => boolean) => Promise<boolean>,
  describe: (error: unknown) => string = defaultDescribe,
): Promise<ApplyResult> {
  const before = await probe.startedAt();
  if (!owns(profileId, probe)) {
    return { status: "superseded", detail: "selection changed before the start" };
  }
  let started: boolean;
  try {
    started = await start(() => owns(profileId, probe));
  } catch (error) {
    if (!owns(profileId, probe)) {
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
  const after = await probe.startedAt();
  if (!owns(profileId, probe)) {
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
  if (disk !== content) {
    return {
      status: "superseded",
      detail: "a newer write replaced this body",
      previousStartedAt: before ?? undefined,
      startedAt: after ?? undefined,
    };
  }
  return {
    status: moved(before, after) ? "applied" : "apply-unconfirmed",
    previousStartedAt: before ?? undefined,
    startedAt: after ?? undefined,
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
): boolean {
  return (
    selectedProfileId === profileId &&
    running &&
    currentStartedAt !== null &&
    (startedAtAtStart === null || currentStartedAt === startedAtAtStart)
  );
}

function defaultDescribe(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}
