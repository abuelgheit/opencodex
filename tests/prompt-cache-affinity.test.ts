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


test("canonical ChatGPT forward synthesizes stable session affinity after final auth selection", async () => {
  const seen: Array<{ key: unknown; sessionId: string | null; sessionDashId: string | null }> = [];
  globalThis.fetch = (async (_input: RequestInfo | URL, init?: RequestInit) => {
    const headers = new Headers(init?.headers);
    const body = JSON.parse(String(init?.body ?? "{}")) as Record<string, unknown>;
    seen.push({
      key: body.prompt_cache_key,
      sessionId: headers.get("session_id"),
      sessionDashId: headers.get("session-id"),
    });
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
  const request = (key: string, headers: Record<string, string> = {}) => new Request("http://localhost/v1/chat/completions", {
    method: "POST",
    headers: { "content-type": "application/json", authorization: "Bearer caller", ...headers },
    body: JSON.stringify({
      model: "openai/gpt-test",
      stream: false,
      prompt_cache_key: key,
      messages: [{ role: "user", content: "hi" }],
    }),
  });

  for (const req of [request("cache-a"), request("cache-a"), request("cache-b")]) {
    const response = await handleChatCompletions(req, config, { model: "", provider: "" });
    expect(response.status).toBe(200);
    await response.text();
  }
  const explicit = await handleChatCompletions(
    request("cache-a", { session_id: "caller-session" }),
    config,
    { model: "", provider: "" },
  );
  expect(explicit.status).toBe(200);
  await explicit.text();

  expect(seen).toHaveLength(4);
  expect(seen.map(item => item.key)).toEqual(["cache-a", "cache-a", "cache-b", "cache-a"]);
  expect(seen[0]?.sessionId).toBe(seen[1]?.sessionId);
  expect(seen[0]?.sessionId).not.toBe(seen[2]?.sessionId);
  expect(seen[0]?.sessionId).toMatch(/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-8[0-9a-f]{3}-[0-9a-f]{12}$/);
  expect(seen[0]?.sessionDashId).toBeNull();
  expect(seen[3]?.sessionId).toBe("caller-session");
});

test("official OpenAI API-key Responses routes do not get synthesized session affinity", async () => {
  let sessionId: string | null = "unexpected";
  globalThis.fetch = (async (_input: RequestInfo | URL, init?: RequestInit) => {
    sessionId = new Headers(init?.headers).get("session_id");
    return Response.json({ id: "resp_official", status: "completed", output: [] });
  }) as typeof fetch;
  const response = await handleChatCompletions(
    new Request("http://localhost/v1/chat/completions", {
      method: "POST",
      headers: { "content-type": "application/json", authorization: "Bearer official-key" },
      body: JSON.stringify({
        model: "openai-apikey/gpt-test",
        stream: false,
        prompt_cache_key: "official-key",
        messages: [{ role: "user", content: "hi" }],
      }),
    }),
    {
      port: 0,
      defaultProvider: "openai-apikey",
      providers: {
        "openai-apikey": {
          adapter: "openai-responses",
          baseUrl: "https://api.openai.com/v1",
          authMode: "key",
          apiKey: "configured-key",
        },
      },
    } as OcxConfig,
    { model: "", provider: "" },
  );
  expect(response.status).toBe(200);
  await response.text();
  expect(sessionId).toBeNull();
});
