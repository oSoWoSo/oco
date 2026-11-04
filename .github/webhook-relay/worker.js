const GITHUB_DISPATCH_URL = "https://api.github.com/repos/oSoWoSo/oco/dispatches";
const SUPPORTED_ACTIONS = new Set(["opened", "reopened", "synchronize", "edited"]);
const SUPPORTED_EVENTS = new Set(["push", "pull_request"]);
const MAX_PAYLOAD_BYTES = 1_048_576;

function jsonResponse(status, body) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json; charset=utf-8" },
  });
}

async function readBody(request) {
  if (!request.body) return new Uint8Array();

  const reader = request.body.getReader();
  const chunks = [];
  let size = 0;
  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    size += value.byteLength;
    if (size > MAX_PAYLOAD_BYTES) {
      await reader.cancel();
      return null;
    }
    chunks.push(value);
  }

  const body = new Uint8Array(size);
  let offset = 0;
  for (const chunk of chunks) {
    body.set(chunk, offset);
    offset += chunk.byteLength;
  }
  return body;
}

async function hasValidSignature(body, signature, secret) {
  if (!/^[0-9a-f]{64}$/i.test(signature)) return false;
  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["verify"],
  );
  const signatureBytes = Uint8Array.from(
    signature.match(/.{2}/g),
    (byte) => Number.parseInt(byte, 16),
  );
  return crypto.subtle.verify("HMAC", key, signatureBytes, body);
}

function isRelevantPullRequest(payload) {
  const pr = payload.pull_request;
  return (
    SUPPORTED_ACTIONS.has(payload.action) &&
    Number.isSafeInteger(pr?.number) &&
    pr.number > 0 &&
    pr.base?.ref === "OCO" &&
    typeof pr.head?.ref === "string" &&
    !pr.head.ref.startsWith("mirror/")
  );
}

function isRelevantPush(payload) {
  const ref = payload.ref;
  const after = payload.after;
  // Branch creation/deletion pushes carry all-zero SHAs; only forward real
  // updates to refs/heads/OCO.
  return (
    ref === "refs/heads/OCO" &&
    typeof after === "string" &&
    /^[0-9a-f]{40}$/.test(after) &&
    !/^0+$/.test(after) &&
    payload.repository?.full_name === "oSoWoSo/oco"
  );
}

export default {
  async fetch(request, env) {
    if (request.method !== "POST") {
      return jsonResponse(405, { error: "POST required" });
    }
    if (!env.FORGEJO_WEBHOOK_SECRET || !env.GITHUB_TOKEN) {
      return jsonResponse(503, { error: "Webhook relay is not configured" });
    }
    if (request.headers.get("content-type")?.split(";")[0].trim() !== "application/json") {
      return jsonResponse(415, { error: "application/json required" });
    }
    const event = request.headers.get("x-forgejo-event");
    if (!SUPPORTED_EVENTS.has(event)) {
      return jsonResponse(202, { ignored: true });
    }

    const body = await readBody(request);
    if (body === null) return jsonResponse(413, { error: "Payload too large" });

    const signature = request.headers.get("x-forgejo-signature") ?? "";
    if (!(await hasValidSignature(body, signature, env.FORGEJO_WEBHOOK_SECRET))) {
      return jsonResponse(401, { error: "Invalid webhook signature" });
    }

    let payload;
    try {
      payload = JSON.parse(new TextDecoder().decode(body));
    } catch {
      return jsonResponse(400, { error: "Invalid JSON payload" });
    }

    let eventType;
    let clientPayload;
    if (event === "push") {
      if (!isRelevantPush(payload)) {
        return jsonResponse(202, { ignored: true });
      }
      eventType = "codeberg_push";
      clientPayload = {
        ref: payload.ref,
        before: payload.before,
        after: payload.after,
        full_name: payload.repository.full_name,
        pusher: payload.pusher?.login ?? payload.sender?.login ?? "unknown",
      };
    } else {
      if (!isRelevantPullRequest(payload)) {
        return jsonResponse(202, { ignored: true });
      }
      eventType = "codeberg_pr";
      clientPayload = {
        action: payload.action,
        number: payload.pull_request.number,
      };
    }

    let response;
    try {
      response = await fetch(GITHUB_DISPATCH_URL, {
        method: "POST",
        headers: {
          accept: "application/vnd.github+json",
          authorization: `Bearer ${env.GITHUB_TOKEN}`,
          "content-type": "application/json",
          "user-agent": "oco-codeberg-webhook",
        },
        body: JSON.stringify({
          event_type: eventType,
          client_payload: clientPayload,
        }),
      });
    } catch {
      return jsonResponse(502, { error: "GitHub dispatch request failed" });
    }

    if (response.status !== 204) {
      return jsonResponse(502, { error: "GitHub rejected the repository dispatch" });
    }
    return jsonResponse(202, { dispatched: true });
  },
};