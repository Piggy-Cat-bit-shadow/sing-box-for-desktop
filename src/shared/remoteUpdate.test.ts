import assert from "node:assert/strict";
import { describe, it } from "node:test";

import { describeProviderRefresh } from "./remoteUpdate";

describe("describeProviderRefresh", () => {
  it("reports a clean publish", () => {
    const result = describeProviderRefresh({
      results: [{ tag: "pp", status: "published", pendingTags: [], restartRequired: false, reason: "" }],
      cancelled: false,
      boxChanged: false,
    });
    assert.equal(result.status, "published");
    assert.equal(result.counts?.published, 1);
  });

  it("reports pending tags as partial, not as a clean publish", () => {
    const result = describeProviderRefresh({
      results: [{
        tag: "pp",
        status: "published",
        pendingTags: ["node-a", "node-b"],
        restartRequired: true,
        reason: "group rejected",
      }],
      cancelled: false,
      boxChanged: false,
    });
    assert.equal(result.status, "partial");
    assert.equal(result.counts?.pending, 2);
    assert.equal(result.counts?.restartRequired, 1);
  });

  it("keeps box replacement and cancellation distinct from a status count", () => {
    assert.equal(
      describeProviderRefresh({ results: [], cancelled: false, boxChanged: true }).status,
      "box-changed",
    );
    assert.equal(
      describeProviderRefresh({ results: [], cancelled: true, boxChanged: false }).status,
      "cancelled",
    );
  });

  it("does not claim success for an unknown status", () => {
    const result = describeProviderRefresh({
      results: [{ tag: "pp", status: "future-status", pendingTags: [], restartRequired: false, reason: "" }],
      cancelled: false,
      boxChanged: false,
    });
    assert.equal(result.status, "failed");
    assert.equal(result.counts?.total, 1);
  });

  it("does not hide an unknown status behind pending tags", () => {
    const result = describeProviderRefresh({
      results: [{
        tag: "pp",
        status: "future-status",
        pendingTags: ["node-a"],
        restartRequired: true,
        reason: "",
      }],
      cancelled: false,
      boxChanged: false,
    });
    assert.equal(result.status, "failed");
    assert.match(result.detail ?? "", /unknown provider status/);
    assert.equal(result.counts?.pending, 1);
  });

  it("names the reason when there is no report at all", () => {
    assert.equal(describeProviderRefresh(null, "unsupported").status, "unsupported");
    assert.equal(describeProviderRefresh(null).status, "unavailable");
  });
});
