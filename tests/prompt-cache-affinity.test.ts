import { afterEach, describe, expect, test } from "bun:test";
import { handleChatCompletions } from "../src/server/chat-completions";
import type { OcxConfig } from "../src/types";
import { createHash } from "node:crypto";
import { addPromptCacheSessionAffinity, sessionIdFromPromptCacheKey } from "../src/lib/prompt-cache-affinity";

const originalFetch = globalThis.fetch;
afterEach(() => { globalThis.fetch = originalFetch; });

describe("prompt cache affinity", () => {
  test("formats a deterministic UUID-shaped session id from the cache key", () => {
    const key = "stable-cache-key";
    const first = sessionIdFromPromptCacheKey(key);
    const second = sessionIdFromPromptCacheKey(key);

    expect(first).toBe(second);
    expect(first).toMatch(/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-8[0-9a-f]{3}-[0-9a-f]{12}$/);
    expect(first).toBe(sessionIdFromPromptCacheKey(key));
    expect(first).not.toBe(sessionIdFromPromptCacheKey("different-cache-key"));
  });

  test("hashes only the cache key and is independent of process restarts", () => {
    const key = "restart-stable-key";
    const expected = createHash("sha256").update(key).digest("hex");
    expect(sessionIdFromPromptCacheKey(key)).toBe(
      `${expected.slice(0, 8)}-${expected.slice(8, 12)}-4${expected.slice(13, 16)}-8${expected.slice(17, 20)}-${expected.slice(20, 32)}`,
    );
  });

  test("preserves explicit session_id and session-id headers", () => {
    const sessionId = "explicit-session-id";
    const headers = new Headers({ session_id: sessionId });
    addPromptCacheSessionAffinity(headers, "cache-key");
    expect(headers.get("session_id")).toBe(sessionId);

    const alternateHeaders = new Headers({ "session-id": sessionId });
    addPromptCacheSessionAffinity(alternateHeaders, "cache-key");
    expect(alternateHeaders.get("session-id")).toBe(sessionId);
  });

  test("does not synthesize an id without a string cache key", () => {
    const headers = new Headers();
    addPromptCacheSessionAffinity(headers, undefined);
    expect(headers.has("session_id")).toBe(false);
  });
});


// Upstream's audited contract (tests/responses/chat-conversation-affinity.test.ts, audit 133
// R2#3) makes a bare `prompt_cache_key` a shared cache cohort, not a conversation identity: a
// key that several conversations share must NOT become one synthesized session_id, because that
// would coalesce distinct conversations in provider state. The lib helpers below stay (they are
// still used for Claude's metadata-derived per-session key), but the Chat path deliberately does
// not synthesize from the body key alone. This case pins that boundary.
test("a bare prompt_cache_key on the Chat wire does not synthesize a session id", async () => {
  const seen: Array<{ sessionId: string | null; sessionDashId: string | null }> = [];
  globalThis.fetch = (async (_input: RequestInfo | URL, init?: RequestInit) => {
    const headers = new Headers(init?.headers);
    seen.push({ sessionId: headers.get("session_id"), sessionDashId: headers.get("session-id") });
    return Response.json({
      id: "resp_prompt_cache",
      status: "completed",
      output: [{ type: "message", role: "assistant", content: [{ type: "output_text", text: "ok" }] }],
    });
  }) as typeof fetch;
  const config = {
    port: 0,
    defaultProvider: "openai",
    providers: {
      openai: {
        adapter: "openai-responses",
        baseUrl: "https://chatgpt.com/backend-api/codex",
        authMode: "forward",
        codexAccountMode: "direct",
      },
    },
  } as OcxConfig;
  const response = await handleChatCompletions(
    new Request("http://localhost/v1/chat/completions", {
      method: "POST",
      headers: { "content-type": "application/json", authorization: "Bearer caller" },
      body: JSON.stringify({
        model: "openai/gpt-test",
        stream: false,
        prompt_cache_key: "shared-cache-cohort",
        messages: [{ role: "user", content: "hi" }],
      }),
    }),
    config,
    { model: "", provider: "" },
  );
  await response.text();
  for (const wire of seen) {
    expect(wire.sessionId).toBeNull();
    expect(wire.sessionDashId).toBeNull();
  }
});

