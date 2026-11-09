import assert from "node:assert/strict";
import { describe, it } from "node:test";

import { Code, ConnectError } from "@connectrpc/connect";

import {
  classifyConfigurationDocument,
  readConfigurationDocument,
} from "./configDocuments";

describe("classifyConfigurationDocument", () => {
  it("keeps a document and the fields this client does not know", () => {
    const result = classifyConfigurationDocument<{ status: string; futureDomain?: unknown }>(
      JSON.stringify({ status: "restarted", futureDomain: { status: "published" } }),
    );
    assert.equal(result.kind, "document");
    if (result.kind !== "document") {
      return;
    }
    assert.equal(result.document.status, "restarted");
    assert.deepEqual(result.document.futureDomain, { status: "published" });
  });

  it("keeps 'no record yet' separate from 'this kernel cannot say'", () => {
    assert.deepEqual(classifyConfigurationDocument("null"), { kind: "absent" });
    // The libbox bridge answers an older kernel with the empty string, so the shell must read it
    // as the same statement as codes.Unimplemented - not as a malformed document.
    assert.deepEqual(classifyConfigurationDocument(""), { kind: "unsupported" });
  });

  it("rejects a document that is not an object instead of showing an empty one", () => {
    assert.throws(() => classifyConfigurationDocument("[]"), /not an object/);
    assert.throws(() => classifyConfigurationDocument('"text"'), /not an object/);
  });
});

describe("readConfigurationDocument", () => {
  it("classifies an Unimplemented call as an older kernel", async () => {
    const result = await readConfigurationDocument(async () => {
      throw new ConnectError("unknown method", Code.Unimplemented);
    });
    assert.deepEqual(result, { kind: "unsupported" });
  });

  it("rethrows a real transport failure instead of calling it an old kernel", async () => {
    await assert.rejects(
      readConfigurationDocument(async () => {
        throw new ConnectError("connection refused", Code.Unavailable);
      }),
      /connection refused/,
    );
    await assert.rejects(
      readConfigurationDocument(async () => {
        throw new Error("boom");
      }),
      /boom/,
    );
  });

  it("returns the classified document from a successful call", async () => {
    const result = await readConfigurationDocument<{ failedRevision: string }>(
      async () => JSON.stringify({ failedRevision: "abc" }),
    );
    assert.equal(result.kind, "document");
    if (result.kind === "document") {
      assert.equal(result.document.failedRevision, "abc");
    }
  });
});
