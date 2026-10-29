import assert from "node:assert/strict";
import { createHmac, webcrypto } from "node:crypto";
import test from "node:test";
import worker from "./worker.js";

globalThis.crypto ??= webcrypto;

const SECRET = "test-forgejo-secret";
const ENV = { FORGEJO_WEBHOOK_SECRET: SECRET, GITHUB_TOKEN: "test-github-token" };

function pullRequestPayload(overrides = {}) {
  return {
    action: "opened",
    number: 12,
    pull_request: {
      number: 12,
      base: { ref: "OCO" },
      head: { ref: "fix-package" },
    },
    ...overrides,
  };
}

function signedRequest(payload, { event = "pull_request", secret = SECRET } = {}) {
  const body = JSON.stringify(payload);
  const signature = createHmac("sha256", secret).update(body).digest("hex");
  return new Request("https://worker.example/", {
    method: "POST",
    headers: {
      "content-type": "application/json",
      "x-forgejo-event": event,
      "x-forgejo-signature": signature,
    },
    body,
  });
}

test("valid OCO pull request dispatches action and number to GitHub", async () => {
  const originalFetch = globalThis.fetch;
  let captured;
  globalThis.fetch = async (url, options) => {
    captured = { url, options };
    return new Response(null, { status: 204 });
  };
  try {
    const response = await worker.fetch(signedRequest(pullRequestPayload()), ENV);
    assert.equal(response.status, 202);
    assert.deepEqual(await response.json(), { dispatched: true });
    assert.equal(captured.url, "https://api.github.com/repos/oSoWoSo/oco/dispatches");
    assert.equal(captured.options.headers.authorization, "Bearer test-github-token");
    assert.deepEqual(JSON.parse(captured.options.body), {
      event_type: "codeberg_pr",
      client_payload: { action: "opened", number: 12 },
    });
  } finally {
    globalThis.fetch = originalFetch;
  }
});

test("invalid signatures never dispatch to GitHub", async () => {
  const originalFetch = globalThis.fetch;
  globalThis.fetch = async () => assert.fail("invalid webhook must not call GitHub");
  try {
    const response = await worker.fetch(
      signedRequest(pullRequestPayload(), { secret: "wrong-secret" }),
      ENV,
    );
    assert.equal(response.status, 401);
  } finally {
    globalThis.fetch = originalFetch;
  }
});

test("unsupported actions, non-OCO bases, and mirror heads are ignored", async (t) => {
  const originalFetch = globalThis.fetch;
  globalThis.fetch = async () => assert.fail("ignored webhook must not call GitHub");
  const cases = [
    ["closed action", pullRequestPayload({ action: "closed" })],
    ["other base", pullRequestPayload({ pull_request: {
      number: 12, base: { ref: "other" }, head: { ref: "fix-package" },
    } })],
    ["mirrored head", pullRequestPayload({ pull_request: {
      number: 12, base: { ref: "OCO" }, head: { ref: "mirror/github/pr-2" },
    } })],
  ];
  try {
    for (const [name, payload] of cases) {
      await t.test(name, async () => {
        const response = await worker.fetch(signedRequest(payload), ENV);
        assert.equal(response.status, 202);
        assert.deepEqual(await response.json(), { ignored: true });
      });
    }
  } finally {
    globalThis.fetch = originalFetch;
  }
});

test("wrong event type and invalid payload are rejected without dispatch", async () => {
  const eventResponse = await worker.fetch(
    signedRequest(pullRequestPayload(), { event: "push" }),
    ENV,
  );
  assert.equal(eventResponse.status, 202);

  const originalFetch = globalThis.fetch;
  globalThis.fetch = async () => assert.fail("invalid JSON must not call GitHub");
  try {
    const body = "{";
    const signature = createHmac("sha256", SECRET).update(body).digest("hex");
    const request = new Request("https://worker.example/", {
      method: "POST",
      headers: {
        "content-type": "application/json",
        "x-forgejo-event": "pull_request",
        "x-forgejo-signature": signature,
      },
      body,
    });
    const response = await worker.fetch(request, ENV);
    assert.equal(response.status, 400);
  } finally {
    globalThis.fetch = originalFetch;
  }
});
