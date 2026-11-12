import assert from "node:assert/strict";
import { describe, it } from "node:test";

import { SelectionLedger } from "./selectionIdentity";

function readBack(requestId: bigint, outboundTag = "member-b", appliedRevision = 7n, stale = false) {
  return { requestId, appliedOutboundTag: outboundTag, appliedRevision, stale };
}

describe("SelectionLedger", () => {
  it("applies the member the group holds, not the member that was requested", () => {
    const ledger = new SelectionLedger();
    const snapshot = ledger.begin("group-a", "member-b");
    const settlement = ledger.settle(snapshot, readBack(snapshot.requestId, "member-c", 7n));
    assert.deepEqual(settlement, { kind: "applied", outboundTag: "member-c", revision: 7n, stale: false });
    assert.equal(ledger.pendingSelection("group-a"), null);
    assert.equal(ledger.appliedRevision("group-a"), 7n);
  });

  it("carries the last applied revision as the next attempt's expectation", () => {
    const ledger = new SelectionLedger();
    const first = ledger.begin("group-a", "member-b");
    ledger.settle(first, readBack(first.requestId, "member-b", 9n));
    const second = ledger.begin("group-a", "member-c");
    assert.equal(second.expectedRevision, 9n);
    assert.notEqual(second.requestId, first.requestId);
  });

  it("ignores the answer of a replaced attempt", () => {
    const ledger = new SelectionLedger();
    const first = ledger.begin("group-a", "member-b");
    const second = ledger.begin("group-a", "member-c");
    const late = ledger.settle(first, readBack(first.requestId, "member-b"));
    assert.deepEqual(late, { kind: "ignored-older-request", latestRequestId: second.requestId });
    assert.equal(ledger.pendingSelection("group-a")?.outboundTag, "member-c");
  });

  it("ignores an answer whose revision is older than one already applied", () => {
    const ledger = new SelectionLedger();
    const first = ledger.begin("group-a", "member-b");
    ledger.settle(first, readBack(first.requestId, "member-b", 9n));
    const second = ledger.begin("group-a", "member-c");
    const late = ledger.settle(second, readBack(second.requestId, "member-c", 8n));
    assert.deepEqual(late, { kind: "ignored-older-revision", latestRevision: 9n });
    assert.equal(ledger.appliedRevision("group-a"), 9n);
  });

  it("treats an answer without identity as unconfirmed, never as success", () => {
    const ledger = new SelectionLedger();
    const snapshot = ledger.begin("group-a", "member-b");
    // An old daemon ignores the fields it does not know and answers id 0.
    const settlement = ledger.settle(snapshot, readBack(0n, "", 0n));
    assert.equal(settlement.kind, "unconfirmed");
    assert.equal(ledger.pendingSelection("group-a"), null);
    assert.equal(ledger.appliedRevision("group-a"), 0n);
  });

  it("does not let a failure for a replaced attempt clear the newer one", () => {
    const ledger = new SelectionLedger();
    const first = ledger.begin("group-a", "member-b");
    const second = ledger.begin("group-a", "member-c");
    assert.deepEqual(ledger.fail(first, "connection reset"), { kind: "ignored-older-request", latestRequestId: second.requestId });
    assert.equal(ledger.pendingSelection("group-a")?.requestId, second.requestId);
  });

  it("clears the pending overlay when the latest attempt fails", () => {
    const ledger = new SelectionLedger();
    const snapshot = ledger.begin("group-a", "member-b");
    assert.deepEqual(ledger.fail(snapshot, "timeout"), { kind: "failed", reason: "timeout" });
    assert.equal(ledger.pendingSelection("group-a"), null);
  });
});
