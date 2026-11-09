/**
 * The configuration documents over a REAL gRPC transport.
 *
 * The unit tests prove the classifier. This one proves the wire: a real HTTP/2 server with the
 * kernel's service definition, a real connect-node client, and the three outcomes the shell must
 * keep apart arriving as they actually arrive -
 *
 *   - a document, because the method is implemented;
 *   - the JSON literal `null`, because the daemon has no record;
 *   - `Unimplemented`, because the method is not registered at all - which is what a daemon older
 *     than the RPC answers, and is produced here by the SERVER rather than by a thrown fake;
 *   - a real transport failure, which must NOT be mistaken for an older daemon.
 *
 * The last two are the ones a mock cannot honestly cover: whether the wire code is
 * `Unimplemented` or `Unavailable` is decided by the protocol, not by the caller.
 *
 * The generated service module contains TypeScript enums, and a Node runtime that only strips
 * types cannot load it. That is a property of the runtime, not of this check, so the suite is
 * skipped there instead of failing; run it with `--experimental-transform-types` to execute it:
 *
 *   node --experimental-transform-types --import ./scripts/test-loader.mjs \
 *     --test "src/shared/configDocuments.transport.test.ts"
 */

import assert from "node:assert/strict";
import { createServer } from "node:http2";
import type { Http2Server } from "node:http2";
import { after, before, describe, it } from "node:test";

import { Code, ConnectError, createClient } from "@connectrpc/connect";
import { connectNodeAdapter, createGrpcTransport } from "@connectrpc/connect-node";

import { readConfigurationDocument, type ServiceChangePlan } from "./configDocuments";

async function loadGeneratedService() {
  try {
    return await import("./gen/daemon/started_service_pb");
  } catch (error) {
    if (error instanceof SyntaxError || (error as { code?: string }).code === "ERR_UNSUPPORTED_TYPESCRIPT_SYNTAX") {
      return null;
    }
    throw error;
  }
}

const generated = await loadGeneratedService();
const suite = generated === null ? describe.skip : describe;

let server: Http2Server;
let baseUrl: string;

before(async () => {
  if (generated === null) {
    return;
  }
  server = createServer(
    connectNodeAdapter({
      routes: (router) => {
        router.service(generated.StartedService, {
          previewServiceChange(request) {
            if (request.configContent === "reject-me") {
              throw new ConnectError("duplicate inbound tag", Code.InvalidArgument);
            }
            return {
              json: JSON.stringify({
                started: false,
                unchanged: false,
                liveOnly: true,
                restartRequired: false,
                changedDocument: false,
                currentRevision: "aaaaaaaaaaaa",
                targetRevision: "bbbbbbbbbbbb",
                futureDomain: { status: "published" },
              }),
            };
          },
          // A fresh instance: the kernel marshals a nil report, which is the JSON literal null.
          getLastServiceChange() {
            return { json: "null" };
          },
          // getLastConfigRecovery is deliberately NOT registered: the router answers the real
          // gRPC Unimplemented status, exactly as an older daemon would.
        });
      },
    }),
  );
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  const address = server.address();
  assert.ok(address !== null && typeof address === "object");
  baseUrl = `http://127.0.0.1:${address.port}`;
});

after(async () => {
  if (server?.listening !== true) {
    return;
  }
  await new Promise<void>((resolve, reject) => {
    server.close((error) => (error ? reject(error) : resolve()));
  });
});

function client() {
  return createClient(
    generated!.StartedService,
    createGrpcTransport({ baseUrl }),
  );
}

suite("configuration documents over gRPC", () => {
  it("reads a plan and keeps the fields this client does not know", async () => {
    const startedService = client();
    const result = await readConfigurationDocument<
      ServiceChangePlan & { futureDomain?: unknown }
    >(async () => (await startedService.previewServiceChange({ configContent: "{}" })).json);
    assert.equal(result.kind, "document");
    if (result.kind !== "document") {
      return;
    }
    assert.equal(result.document.liveOnly, true);
    assert.equal(result.document.targetRevision, "bbbbbbbbbbbb");
    assert.deepEqual(result.document.futureDomain, { status: "published" });
  });

  it("reads 'no record yet' as absent, not as an unsupported daemon", async () => {
    const startedService = client();
    const result = await readConfigurationDocument(
      async () => (await startedService.getLastServiceChange({})).json,
    );
    assert.deepEqual(result, { kind: "absent" });
  });

  it("reads the server's real Unimplemented status as an older kernel", async () => {
    const startedService = client();
    const result = await readConfigurationDocument(
      async () => (await startedService.getLastConfigRecovery({})).json,
    );
    assert.deepEqual(result, { kind: "unsupported" });
  });

  it("surfaces a document the daemon rejects as its own error", async () => {
    const startedService = client();
    await assert.rejects(
      readConfigurationDocument(
        async () => (await startedService.previewServiceChange({ configContent: "reject-me" })).json,
      ),
      /duplicate inbound tag/,
    );
  });

  it("does not call a dead transport an older kernel", async () => {
    const closed = createServer(
      connectNodeAdapter({
        routes: (router) => {
          router.service(generated!.StartedService, {});
        },
      }),
    );
    await new Promise<void>((resolve) => closed.listen(0, "127.0.0.1", resolve));
    const address = closed.address();
    assert.ok(address !== null && typeof address === "object");
    const startedService = createClient(
      generated!.StartedService,
      createGrpcTransport({
        baseUrl: `http://127.0.0.1:${address.port}`,
        
      }),
    );
    await new Promise<void>((resolve, reject) => {
      closed.close((error) => (error ? reject(error) : resolve()));
    });
    await assert.rejects(
      readConfigurationDocument(
        async () => (await startedService.getLastServiceChange({})).json,
      ),
      (error: unknown) => {
        assert.ok(error instanceof ConnectError);
        // The point of the assertion: this is NOT Unimplemented, so it must not become
        // `{kind: "unsupported"}`.
        assert.notEqual(error.code, Code.Unimplemented);
        return true;
      },
    );
  });
});
