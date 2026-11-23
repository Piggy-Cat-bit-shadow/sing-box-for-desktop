import assert from "node:assert/strict";
import { describe, it } from "node:test";

import { urlTestResult } from "./urlTest";

describe("urlTestResult", () => {
  it("shows the delay after a successful probe", () => {
    assert.deepEqual(urlTestResult(123, 1_700_000_000n, "Timeout"), {
      tested: true,
      timeout: false,
      text: "123ms",
      tone: "good",
    });
  });

  it("shows the localized timeout after a failed probe", () => {
    assert.deepEqual(urlTestResult(0, 1_700_000_000n, "超时"), {
      tested: true,
      timeout: true,
      text: "超时",
      tone: "bad",
    });
  });

  it("keeps the never-tested state for a zero delay and zero time", () => {
    assert.deepEqual(urlTestResult(0, 0n, "Timeout"), {
      tested: false,
      timeout: false,
      text: "",
      tone: "neutral",
    });
  });

  it("treats a positive delay as a success even without a completion time", () => {
    assert.equal(urlTestResult(42, 0n).tested, true);
    assert.equal(urlTestResult(42, 0n).timeout, false);
  });

  it("keeps the delay tone thresholds", () => {
    assert.equal(urlTestResult(799, 1n).tone, "good");
    assert.equal(urlTestResult(800, 1n).tone, "medium");
    assert.equal(urlTestResult(1499, 1n).tone, "medium");
    assert.equal(urlTestResult(1500, 1n).tone, "bad");
  });

  // The native tray rebuilds from a protobuf message, where urlTestTime is a bigint. A plain number
  // can still arrive from a fixture or a hand-written payload, and mixing the two throws - which
  // would abort the whole tray rebuild. It must normalise instead.
  it("a numeric completion time behaves like the bigint of the same value", () => {
    const numeric = urlTestResult(0, 1_700_000_000 as unknown as bigint, "Timeout");
    const big = urlTestResult(0, 1_700_000_000n, "Timeout");
    assert.deepEqual(numeric, big);
    assert.equal(numeric.timeout, true);
    assert.equal(urlTestResult(0, 0 as unknown as bigint).tested, false);
  });
});