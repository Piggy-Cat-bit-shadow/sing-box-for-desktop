import assert from "node:assert/strict";
import { describe, it } from "node:test";

import {
  applyOwnedConfig,
  instanceStillOurs,
  type OwnershipProbe,
} from "./remoteApply";

function deferred<T>() {
  let resolve!: (value: T) => void;
  let reject!: (reason?: unknown) => void;
  const promise = new Promise<T>((res, rej) => {
    resolve = res;
    reject = rej;
  });
  return { promise, resolve, reject };
}

function probe(overrides: Partial<OwnershipProbe> = {}): OwnershipProbe {
  return {
    selectedProfileId: () => "a",
    running: () => true,
    startedAt: async () => "100",
    storedContent: async () => "body-a",
    ...overrides,
  };
}

describe("applyOwnedConfig", () => {
  it("does not start when the selection moves while the start timestamp is read", async () => {
    const startedAt = deferred<string | null>();
    let selected = "a";
    let startCalls = 0;
    const pending = applyOwnedConfig(
      "a",
      "body-a",
      probe({
        selectedProfileId: () => selected,
        startedAt: () => startedAt.promise,
      }),
      async () => {
        startCalls += 1;
        return true;
      },
    );
    await Promise.resolve();
    selected = "b";
    startedAt.resolve("100");
    const result = await pending;
    assert.equal(result.status, "superseded");
    assert.equal(startCalls, 0);
  });

  it("skips the daemon call when the selection moves while start options resolve", async () => {
    const options = deferred<void>();
    let selected = "a";
    const pending = applyOwnedConfig(
      "a",
      "body-a",
      probe({ selectedProfileId: () => selected }),
      async (stillOwner) => {
        await options.promise;
        return stillOwner();
      },
    );
    await Promise.resolve();
    selected = "b";
    options.resolve();
    const switched = await pending;
    assert.equal(switched.status, "superseded");
    assert.match(switched.detail ?? "", /before the daemon start/);
  });

  it("is superseded when a newer body replaced this one before the check", async () => {
    const result = await applyOwnedConfig(
      "a",
      "body-a",
      probe({ storedContent: async () => "body-b" }),
      async () => true,
    );
    assert.equal(result.status, "superseded");
    assert.match(result.detail ?? "", /newer write/);
  });

  it("reports applied only when the timestamp moved and the stored body is still ours", async () => {
    let reads = 0;
    const result = await applyOwnedConfig(
      "a",
      "body-a",
      probe({
        startedAt: async () => (++reads === 1 ? "100" : "101"),
      }),
      async () => true,
    );
    assert.equal(result.status, "applied");
    assert.equal(result.previousStartedAt, "100");
    assert.equal(result.startedAt, "101");
  });

  it("reports apply-unconfirmed when the timestamp did not move", async () => {
    const result = await applyOwnedConfig(
      "a",
      "body-a",
      probe(),
      async () => true,
    );
    assert.equal(result.status, "apply-unconfirmed");
  });

  it("reports apply-failed only while the operation still owns the instance", async () => {
    const result = await applyOwnedConfig(
      "a",
      "body-a",
      probe(),
      async () => {
        throw new Error("daemon rejected");
      },
    );
    assert.equal(result.status, "apply-failed");
    assert.match(result.detail ?? "", /daemon rejected/);
  });

  it("a start guard can veto the daemon call after options resolve", async () => {
    // This is the production shape: startServiceWithContent awaits serviceStartOptions and then
    // calls stillOwner() immediately before desktopService.startService().
    let owner = true;
    const result = await applyOwnedConfig(
      "a",
      "body-a",
      probe(),
      async (stillOwner) => {
        owner = false;
        return owner && stillOwner();
      },
    );
    assert.equal(result.status, "superseded");
  });
});

describe("instanceStillOurs", () => {
  it("requires the same profile, a running daemon and the same start timestamp", () => {
    assert.equal(instanceStillOurs("a", "a", true, "100", "100"), true);
    assert.equal(instanceStillOurs("a", "b", true, "100", "100"), false);
    assert.equal(instanceStillOurs("a", "a", false, "100", "100"), false);
    assert.equal(instanceStillOurs("a", "a", true, "100", "101"), false);
    assert.equal(instanceStillOurs("a", "a", true, null, "101"), true);
    assert.equal(instanceStillOurs("a", "a", true, "100", null), false);
  });
});
