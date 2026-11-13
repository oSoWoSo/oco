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

const SHA = "bffeb74224043ba2feb48d137756c8a9331c449a";

function pushPayload(overrides = {}) {
  return {
    ref: "refs/heads/OCO",
    before: "0000000000000000000000000000000000000000",
    after: SHA,
    repository: { full_name: "oSoWoSo/oco" },
    pusher: { login: "zenobit" },
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

test("closed pull request events dispatch so merge/close state mirrors", async () => {
  const originalFetch = globalThis.fetch;
  let captured;
  globalThis.fetch = async (url, options) => {
    captured = { url, options };
    return new Response(null, { status: 204 });
  };
  try {
    const response = await worker.fetch(
      signedRequest(pullRequestPayload({ action: "closed" })),
      ENV,
    );
    assert.equal(response.status, 202);
    assert.deepEqual(JSON.parse(captured.options.body), {
      event_type: "codeberg_pr",
      client_payload: { action: "closed", number: 12 },
    });
  } finally {
    globalThis.fetch = originalFetch;
  }
});

test("unsupported actions, non-OCO bases, and mirror heads are ignored", async (t) => {
  const originalFetch = globalThis.fetch;
  globalThis.fetch = async () => assert.fail("ignored webhook must not call GitHub");
  const cases = [
    ["assigned action", pullRequestPayload({ action: "assigned" })],
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

test("unknown event type and invalid payload are rejected without dispatch", async () => {
  const eventResponse = await worker.fetch(
    signedRequest(pullRequestPayload(), { event: "delete" }),
    ENV,
  );
  assert.equal(eventResponse.status, 202);
  assert.deepEqual(await eventResponse.json(), { ignored: true });

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

test("valid OCO push dispatches codeberg_push with ref, SHAs, and pusher", async () => {
  const originalFetch = globalThis.fetch;
  let captured;
  globalThis.fetch = async (url, options) => {
    captured = { url, options };
    return new Response(null, { status: 204 });
  };
  try {
    const response = await worker.fetch(
      signedRequest(pushPayload({ before: "28e1879d029cb852e4844d9c718537df08844e03" }), { event: "push" }),
      ENV,
    );
    assert.equal(response.status, 202);
    assert.deepEqual(await response.json(), { dispatched: true });
    assert.equal(captured.url, "https://api.github.com/repos/oSoWoSo/oco/dispatches");
    assert.deepEqual(JSON.parse(captured.options.body), {
      event_type: "codeberg_push",
      client_payload: {
        ref: "refs/heads/OCO",
        before: "28e1879d029cb852e4844d9c718537df08844e03",
        after: SHA,
        full_name: "oSoWoSo/oco",
        pusher: "zenobit",
      },
    });
  } finally {
    globalThis.fetch = originalFetch;
  }
});

test("push on non-OCO refs and push with zero after SHA are ignored", async (t) => {
  const originalFetch = globalThis.fetch;
  globalThis.fetch = async () => assert.fail("ignored push must not call GitHub");
  const cases = [
    ["non-OCO ref", pushPayload({ ref: "refs/heads/main" })],
    ["branch deletion", pushPayload({ after: "0000000000000000000000000000000000000000", before: SHA })],
    ["other repository", pushPayload({ repository: { full_name: "other/oco" } })],
  ];
  try {
    for (const [name, payload] of cases) {
      await t.test(name, async () => {
        const response = await worker.fetch(signedRequest(payload, { event: "push" }), ENV);
        assert.equal(response.status, 202);
        assert.deepEqual(await response.json(), { ignored: true });
      });
    }
  } finally {
    globalThis.fetch = originalFetch;
  }
});
