// The main process needs the same URL-test result the shared Dashboard UI renders, without
// importing the React tray. This is the small dependency-free derivation used by the native tray.
//
// Keep this in step with `urlTestResult` in the dashboard submodule's `src/api/format.ts`: a
// positive delay is a success, a zero delay with a completion time is a timeout, and 0/0 is
// untested. `time` is the generated int64 (`bigint`), so it must be compared with `0n`.
export type UrlTestTone = "neutral" | "good" | "medium" | "bad";

export interface UrlTestResult {
  /** A result exists; false only for the never-tested 0/0 state. */
  tested: boolean;
  /** A genuine probe failure: zero delay with a completion time, not a 0 ms success. */
  timeout: boolean;
  /** `123ms` for a success, or the caller's localized timeout label for a failure. */
  text: string;
  tone: UrlTestTone;
}

function positiveDelayTone(delay: number): UrlTestTone {
  if (delay < 800) {
    return "good";
  }
  if (delay < 1500) {
    return "medium";
  }
  return "bad";
}

/**
 * `urlTestTime` is the generated int64 (`bigint`). A plain `number` can still arrive from a fixture
 * or a hand-written payload, and mixing the two throws a `TypeError` that would take down the tray
 * rebuild. Normalise once, here, exactly like the Dashboard's `urlTestResult`.
 */
function completionTimeOf(time: bigint | number): bigint {
  if (typeof time === "bigint") {
    return time;
  }
  return Number.isFinite(time) ? BigInt(Math.trunc(time)) : 0n;
}

export function urlTestResult(
  delay: number,
  time: bigint | number,
  timeoutText = "Timeout",
): UrlTestResult {
  if (delay > 0) {
    return { tested: true, timeout: false, text: `${delay}ms`, tone: positiveDelayTone(delay) };
  }
  if (delay === 0 && completionTimeOf(time) > 0n) {
    return { tested: true, timeout: true, text: timeoutText, tone: "bad" };
  }
  return { tested: false, timeout: false, text: "", tone: "neutral" };
}
