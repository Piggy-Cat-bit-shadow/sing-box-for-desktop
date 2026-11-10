import assert from "node:assert/strict";
import { describe, it } from "node:test";

import {
  applyOwnedConfig,
  classifyProviderBinding,
  instanceStillOurs,
  refreshProvidersIfStillBound,
  stableLiveInstance,
  type LiveInstance,
  type OwnershipProbe,
  type ProviderReads,
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
    selectionEpoch: () => 0,
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
        return await stillOwner();
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

  it("reports applied only when the daemon confirms this exact revision", async () => {
    let reads = 0;
    const result = await applyOwnedConfig(
      "a",
      "body-a",
      probe({
        startedAt: async () => {
          reads += 1;
          return reads === 1 ? "100" : "101";
        },
        targetRevision: async () => "rev-1",
        appliedRevision: async () => "rev-1",
      }),
      async () => true,
    );
    assert.equal(result.status, "applied");
    assert.equal(result.previousStartedAt, "100");
    assert.equal(result.startedAt, "101");
    assert.equal(result.confirmedRevision, "rev-1");
  });

  it("does not claim applied when the daemon reports a different revision", async () => {
    let reads = 0;
    const result = await applyOwnedConfig(
      "a",
      "body-a",
      probe({
        startedAt: async () => {
          reads += 1;
          return reads === 1 ? "100" : "101";
        },
        targetRevision: async () => "rev-1",
        appliedRevision: async () => "rev-2",
      }),
      async () => true,
    );
    assert.equal(result.status, "apply-unconfirmed");
    assert.match(result.detail ?? "", /different revision/);
  });

  it("does not start a running instance whose initial identity is unknown", async () => {
    let startCalls = 0;
    const result = await applyOwnedConfig(
      "a",
      "body-a",
      probe({ startedAt: async () => null }),
      async () => {
        startCalls += 1;
        return true;
      },
    );
    assert.equal(result.status, "apply-unconfirmed");
    assert.equal(startCalls, 0);
  });

  it("rejects A -> B -> A while the final stored-body read is pending", async () => {
    const stored = deferred<string>();
    const storedStarted = deferred<void>();
    let epoch = 0;
    const pending = applyOwnedConfig(
      "a",
      "body-a",
      probe({
        selectionEpoch: () => epoch,
        storedContent: () => {
          storedStarted.resolve();
          return stored.promise;
        },
        targetRevision: async () => "rev-1",
        appliedRevision: async () => "rev-1",
      }),
      async () => true,
    );
    await storedStarted.promise;
    epoch = 2; // A -> B -> A: the id is "a" again, the epoch is not
    stored.resolve("body-a");
    const result = await pending;
    assert.equal(result.status, "superseded");
    assert.match(result.detail ?? "", /final read|selection changed/);
  });

  it("rejects a same-profile restart while the final read is pending", async () => {
    const finalStartedAt = deferred<string | null>();
    const finalReached = deferred<void>();
    let reads = 0;
    const pending = applyOwnedConfig(
      "a",
      "body-a",
      probe({
        startedAt: () => {
          reads += 1;
          if (reads === 1) return Promise.resolve("100");
          if (reads === 2) return Promise.resolve("101");
          finalReached.resolve();
          return finalStartedAt.promise;
        },
        targetRevision: async () => "rev-1",
        appliedRevision: async () => "rev-1",
      }),
      async () => true,
    );
    await finalReached.promise;
    assert.equal(reads, 3);
    finalStartedAt.resolve("102");
    const result = await pending;
    assert.equal(result.status, "superseded");
    assert.match(result.detail ?? "", /instance changed while confirming/);
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

  it("vetoes the start when the same profile got a new Box while options resolve", async () => {
    const options = deferred<void>();
    let startedAt = "100";
    let startCalls = 0;
    const pending = applyOwnedConfig(
      "a",
      "body-a",
      probe({
        startedAt: async () => startedAt,
        targetRevision: async () => "rev-1",
        appliedRevision: async () => "rev-1",
      }),
      async (stillOwner) => {
        await options.promise;
        const ok = await stillOwner();
        if (ok) startCalls += 1;
        return ok;
      },
    );
    await Promise.resolve();
    startedAt = "101";
    options.resolve();
    const result = await pending;
    assert.equal(result.status, "superseded");
    assert.equal(startCalls, 0);
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
        return (await stillOwner()) && owner;
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
    assert.equal(instanceStillOurs("a", "a", true, null, "101"), false);
    assert.equal(instanceStillOurs("a", "a", true, "100", null), false);
    assert.equal(instanceStillOurs("a", "a", true, "100", "100", 1, 2), false);
    assert.equal(instanceStillOurs("a", "a", true, "100", "100", 2, 2), true);
  });
});

describe("stableLiveInstance", () => {
  function reads(overrides: Partial<ProviderReads> = {}): ProviderReads {
    return {
      selectedProfileId: () => "a",
      running: () => true,
      selectionEpoch: () => 2,
      startedAt: async () => "100",
      revision: async () => "rev-a",
      ...overrides,
    };
  }

  it("discards a snapshot when the selection moves inside the final revision read", async () => {
    const revision = deferred<string | null>();
    let selected = "a";
    const pending = stableLiveInstance(
      reads({
        selectedProfileId: () => selected,
        revision: () => revision.promise,
      }),
      "rev-a",
    );
    await Promise.resolve();
    selected = "b";
    revision.resolve("rev-a");
    assert.equal(await pending, null);
  });

  it("discards A -> B -> A even though the final id is a again", async () => {
    const revision = deferred<string | null>();
    let epoch = 2;
    const pending = stableLiveInstance(
      reads({
        selectionEpoch: () => epoch,
        revision: () => revision.promise,
      }),
      "rev-a",
    );
    await Promise.resolve();
    epoch = 4;
    revision.resolve("rev-a");
    assert.equal(await pending, null);
  });

  it("returns the stable fields when nothing moved", async () => {
    assert.deepEqual(await stableLiveInstance(reads(), "rev-a"), {
      selectedProfileId: "a",
      running: true,
      startedAt: "100",
      selectionEpoch: 2,
      revision: "rev-a",
    });
  });
});

describe("refreshProvidersIfStillBound", () => {
  function reads(overrides: Partial<ProviderReads> = {}): ProviderReads {
    return {
      selectedProfileId: () => "a",
      running: () => true,
      selectionEpoch: () => 2,
      startedAt: async () => "100",
      revision: async () => "rev-a",
      ...overrides,
    };
  }

  it("does not send the provider RPC when the selection moves in the revision read", async () => {
    const revision = deferred<string | null>();
    let selected = "a";
    let calls = 0;
    const pending = refreshProvidersIfStillBound(
      "a",
      "100",
      2,
      "rev-a",
      reads({
        selectedProfileId: () => selected,
        revision: () => revision.promise,
      }),
      async () => {
        calls += 1;
        return "provider-result";
      },
    );
    await Promise.resolve();
    selected = "b";
    revision.resolve("rev-a");
    const result = await pending;
    assert.equal(result.kind, "superseded");
    assert.equal(calls, 0);
  });

  it("sends once and returns the value while the instance stays bound", async () => {
    let calls = 0;
    const result = await refreshProvidersIfStillBound(
      "a",
      "100",
      2,
      "rev-a",
      reads(),
      async () => {
        calls += 1;
        return "provider-result";
      },
    );
    assert.deepEqual(result, { kind: "ok", value: "provider-result" });
    assert.equal(calls, 1);
  });

  it("drops a result if the instance changed while the RPC ran", async () => {
    let calls = 0;
    let startedAt = "100";
    const result = await refreshProvidersIfStillBound(
      "a",
      "100",
      2,
      "rev-a",
      reads({
        startedAt: async () => startedAt,
      }),
      async () => {
        calls += 1;
        startedAt = "200";
        return "provider-result";
      },
    );
    assert.equal(result.kind, "superseded");
    assert.equal(calls, 1);
  });
});

describe("classifyProviderBinding", () => {
  const live = (overrides: Partial<LiveInstance> = {}): LiveInstance => ({
    selectedProfileId: "a",
    running: true,
    startedAt: "100",
    selectionEpoch: 2,
    revision: "rev-1",
    ...overrides,
  });

  it("binds a provider call to the exact instance, epoch and revision", () => {
    assert.equal(classifyProviderBinding("a", "100", 2, "rev-1", live()), "ok");
  });

  it("never accepts an unknown baseline as an instance", () => {
    assert.equal(classifyProviderBinding("a", "", 2, "rev-1", live()), "superseded");
    assert.equal(classifyProviderBinding("a", "100", 2, "rev-1", live({ startedAt: null })), "superseded");
  });

  it("rejects A -> B -> A by epoch even though the id is the same", () => {
    assert.equal(classifyProviderBinding("a", "100", 2, "rev-1", live({ selectionEpoch: 4 })), "superseded");
  });

  it("rejects a same-profile restart or a different applied revision", () => {
    assert.equal(classifyProviderBinding("a", "100", 2, "rev-1", live({ startedAt: "101" })), "superseded");
    assert.equal(classifyProviderBinding("a", "100", 2, "rev-1", live({ revision: "rev-2" })), "superseded");
  });

  it("distinguishes not-active and not-running from superseded", () => {
    assert.equal(classifyProviderBinding("a", "100", 2, "rev-1", live({ selectedProfileId: "b" })), "not-active");
    assert.equal(classifyProviderBinding("a", "100", 2, "rev-1", live({ running: false })), "not-running");
  });
});
