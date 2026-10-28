/**
 * The remote-profile request against a stubbed `fetch`.
 *
 * Run with `node --test "src/**​/*.test.ts"` (Node runs TypeScript directly).
 *
 * # Why this exists
 *
 * Two of the rules this feature rests on are invisible from the outside until they are
 * violated on someone else's machine:
 *
 *   the profile content is the FIRST response's body, always - some providers answer a
 *   Clash User-Agent with a different node set or a different format, so a compatibility
 *   retry that replaced the body would silently change the user's subscription
 *
 *   a failed quota retry is not a failed update - the quota is optional metadata, and it
 *   was optional before this feature existed
 *
 * Neither is reachable through Electron's main process, which is why the request was moved
 * out of `profiles.ts` into a module that takes its `fetch`.
 */
import assert from "node:assert/strict";
import { describe, it } from "node:test";

import {
  fetchRemoteProfile,
  type FetchLike,
} from "./subscriptionFetch";
import { SUBSCRIPTION_QUOTA_COMPATIBILITY_USER_AGENTS, SUBSCRIPTION_USER_AGENT } from "./subscription";

const USER_AGENT = "SFW (sing-box 0.1.5; language en_US)";
const PROFILE_URL = "https://provider.test/sub?token=abc";

const VALID_CONFIG_A = JSON.stringify({ outbounds: [{ type: "direct", tag: "A" }] });
const VALID_CONFIG_B = JSON.stringify({ outbounds: [{ type: "direct", tag: "B" }] });

interface RecordedRequest {
  url: string;
  userAgent: string | null;
  authorization: string | null;
}

interface StubResponse {
  status?: number;
  statusText?: string;
  body?: string;
  headers?: Record<string, string>;
}

/** A `fetch` that answers by User-Agent and records what it was asked. */
function stubFetch(
  responder: (userAgent: string, request: RecordedRequest) => StubResponse,
): { fetch: FetchLike; requests: RecordedRequest[] } {
  const requests: RecordedRequest[] = [];
  const fetchImplementation: FetchLike = async (input, init) => {
    const headers = new Headers(init.headers);
    const userAgent = headers.get("User-Agent") ?? "";
    const request: RecordedRequest = {
      url: String(input),
      userAgent: headers.get("User-Agent"),
      authorization: headers.get("Authorization"),
    };
    requests.push(request);
    const answer = responder(userAgent, request);
    const status = answer.status ?? 200;
    return new Response(answer.body ?? "", {
      status,
      statusText: answer.statusText ?? (status === 200 ? "OK" : ""),
      headers: answer.headers,
    });
  };
  return { fetch: fetchImplementation, requests };
}

describe("subscription User-Agent", () => {
  it("is the fixed sing-box identity carried by the body request", async () => {
    const { fetch, requests } = stubFetch(() => ({ body: VALID_CONFIG_A }));
    await fetchRemoteProfile(PROFILE_URL, {
      userAgent: SUBSCRIPTION_USER_AGENT,
      fetchImplementation: fetch,
    });
    assert.equal(SUBSCRIPTION_USER_AGENT, "sing-box/1.15.0");
    assert.equal(requests[0].userAgent, "sing-box/1.15.0");
  });
});

describe("fetchRemoteProfile", () => {
  it("returns the body and the quota from a single request", async () => {
    const { fetch, requests } = stubFetch(() => ({
      body: VALID_CONFIG_A,
      headers: { "subscription-userinfo": "upload=1; download=2; total=10; expire=2000000000" },
    }));
    const result = await fetchRemoteProfile(PROFILE_URL, {
      userAgent: USER_AGENT,
      fetchImplementation: fetch,
    });
    assert.equal(result.content, VALID_CONFIG_A);
    assert.equal(result.quota?.quota?.upload, 1);
    assert.equal(result.quota?.quota?.total, 10);
    // One request: nothing to recover, so nothing was retried.
    assert.equal(requests.length, 1);
    assert.equal(requests[0].userAgent, USER_AGENT);
  });

  it("keeps the primary body when the compatibility retry carries a DIFFERENT one", async () => {
    // THE rule. The provider gates the header behind a Clash User-Agent AND answers that
    // User-Agent with a different subscription. The saved configuration must be A.
    const { fetch, requests } = stubFetch((userAgent) =>
      userAgent === USER_AGENT
        ? { body: VALID_CONFIG_A }
        : {
            body: VALID_CONFIG_B,
            headers: { "subscription-userinfo": "download=20; total=100" },
          },
    );
    const result = await fetchRemoteProfile(PROFILE_URL, {
      userAgent: USER_AGENT,
      fetchImplementation: fetch,
    });
    assert.equal(result.content, VALID_CONFIG_A, "the retry's body must never become the profile");
    assert.notEqual(result.content, VALID_CONFIG_B);
    // The header came from the retry, which is the only thing a retry is for.
    assert.equal(result.quota?.quota?.download, 20);
    assert.equal(result.quota?.quota?.total, 100);
    assert.equal(requests.length, 2);
    assert.equal(requests[0].userAgent, USER_AGENT);
    assert.equal(requests[1].userAgent, SUBSCRIPTION_QUOTA_COMPATIBILITY_USER_AGENTS[0]);
  });

  it("keeps the body when the provider answers the retry with an error page", async () => {
    const { fetch } = stubFetch((userAgent) =>
      userAgent === USER_AGENT
        ? { body: VALID_CONFIG_A }
        : { status: 404, body: "<html>not found</html>" },
    );
    const result = await fetchRemoteProfile(PROFILE_URL, {
      userAgent: USER_AGENT,
      fetchImplementation: fetch,
    });
    assert.equal(result.content, VALID_CONFIG_A);
    assert.equal(result.quota, undefined);
  });

  it("treats a failed retry as no quota, not as a failed update", async () => {
    // A retry that throws is the same outcome as a retry with no header: keep what we have.
    const requests: string[] = [];
    const fetch: FetchLike = async (_input, init) => {
      const userAgent = new Headers(init.headers).get("User-Agent") ?? "";
      requests.push(userAgent);
      if (userAgent === USER_AGENT) {
        return new Response(VALID_CONFIG_A, { status: 200 });
      }
      throw new Error("connect ETIMEDOUT");
    };
    const result = await fetchRemoteProfile(PROFILE_URL, {
      userAgent: USER_AGENT,
      fetchImplementation: fetch,
    });
    assert.equal(result.content, VALID_CONFIG_A);
    assert.equal(result.quota, undefined);
  });

  it("reports no quota - not an empty one - when no retry carries the header either", async () => {
    // `undefined` is what tells the caller "keep the last known snapshot"; an empty object
    // would tell it "this provider reports nothing", which is a different state.
    const { fetch, requests } = stubFetch(() => ({ body: VALID_CONFIG_A }));
    const result = await fetchRemoteProfile(PROFILE_URL, {
      userAgent: USER_AGENT,
      fetchImplementation: fetch,
    });
    assert.equal(result.quota, undefined);
    // The bounded retry list is the bound on what a headerless provider costs.
    assert.equal(requests.length, 1 + SUBSCRIPTION_QUOTA_COMPATIBILITY_USER_AGENTS.length);
  });

  it("does not retry when the retry's answer is a redirect to a body it never reads", async () => {
    // A non-200 retry is not the header's home, so the NEXT compatibility agent is tried and
    // the primary body is untouched.
    const { fetch, requests } = stubFetch((userAgent) => {
      if (userAgent === USER_AGENT) {
        return { body: VALID_CONFIG_A };
      }
      if (userAgent === SUBSCRIPTION_QUOTA_COMPATIBILITY_USER_AGENTS[0]) {
        return { status: 302, body: VALID_CONFIG_B };
      }
      return { body: VALID_CONFIG_B, headers: { "subscription-userinfo": "total=5" } };
    });
    const result = await fetchRemoteProfile(PROFILE_URL, {
      userAgent: USER_AGENT,
      fetchImplementation: fetch,
    });
    assert.equal(result.content, VALID_CONFIG_A);
    assert.equal(result.quota?.quota?.total, 5);
    assert.equal(requests.length, 3);
  });

  it("fails the update on a non-200 primary", async () => {
    const { fetch } = stubFetch(() => ({ status: 401, statusText: "Unauthorized", body: "denied" }));
    await assert.rejects(
      () => fetchRemoteProfile(PROFILE_URL, { userAgent: USER_AGENT, fetchImplementation: fetch }),
      /HTTP 401 Unauthorized: denied/,
    );
  });

  it("does not retry a failed primary", async () => {
    // A different User-Agent does not turn a 500 into a subscription, and retrying would
    // triple the cost of every failed update.
    const { fetch, requests } = stubFetch(() => ({ status: 500, body: "boom" }));
    await assert.rejects(() =>
      fetchRemoteProfile(PROFILE_URL, { userAgent: USER_AGENT, fetchImplementation: fetch }),
    );
    assert.equal(requests.length, 1);
  });

  it("preserves the URL basic-auth behaviour", async () => {
    const { fetch, requests } = stubFetch(() => ({ body: VALID_CONFIG_A }));
    await fetchRemoteProfile("https://user%40example.test:p%40ss@provider.test/sub", {
      userAgent: USER_AGENT,
      fetchImplementation: fetch,
    });
    assert.equal(
      requests[0].authorization,
      `Basic ${Buffer.from("user@example.test:p@ss").toString("base64")}`,
    );
    // The credentials are stripped from the URL that is actually sent.
    assert.ok(!requests[0].url.includes("user%40example.test"));
    assert.ok(!requests[0].url.includes("@provider.test"));
  });

  it("rejects a response that exceeds the profile size limit", async () => {
    const { fetch } = stubFetch(() => ({
      body: "x".repeat(64),
      headers: { "content-length": "64" },
    }));
    await assert.rejects(
      () =>
        fetchRemoteProfile(PROFILE_URL, {
          userAgent: USER_AGENT,
          fetchImplementation: fetch,
          maximumProfileBytes: 16,
        }),
      /exceeds 16 bytes/,
    );
  });

  it("reports the stored header as valid only when it parses to something", async () => {
    // A present-but-unusable header parses to `{}` and IS authoritative: the provider
    // stopped reporting numbers, which must not leave a week-old figure looking current.
    const { fetch } = stubFetch(() => ({
      body: VALID_CONFIG_A,
      headers: { "subscription-userinfo": "upload=abc; total=-1" },
    }));
    const result = await fetchRemoteProfile(PROFILE_URL, {
      userAgent: USER_AGENT,
      fetchImplementation: fetch,
    });
    assert.notEqual(result.quota, undefined, "a present header must be reported as present");
    assert.deepEqual(result.quota?.quota, { updatedAt: result.quota?.quota?.updatedAt });
    assert.equal(typeof result.quota?.quota?.updatedAt, "number");
  });
});
