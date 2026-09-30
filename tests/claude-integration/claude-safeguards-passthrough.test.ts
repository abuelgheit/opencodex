import { afterEach, beforeEach, expect, test } from "bun:test";
import { handleClaudeMessages } from "../../src/server/claude-messages";
import type { OcxConfig } from "../../src/types";
import { createTestTranslatorBudget } from "../helpers/translator-budget";

let originalFetch: typeof fetch;

beforeEach(() => { originalFetch = globalThis.fetch; });
afterEach(() => { globalThis.fetch = originalFetch; });

const safeguards = [{ type: "dangerous_tool_use", classifier_context: { source: "test" } }];
const beta = "dangerous-tool-use-2026-09-03";

function config(adapter: "anthropic" | "openai-chat", baseUrl: string): OcxConfig {
  return {
    port: 0,
    defaultProvider: "test",
    providers: {
      test: {
        adapter,
        baseUrl,
        apiKey: "test-key",
        authMode: "key",
        models: ["claude-sonnet-5"],
        allowPrivateNetwork: true,
      },
    },
  } as OcxConfig;
}

function request(stream: boolean): Request {
  return new Request("http://localhost/v1/messages", {
    method: "POST",
    headers: { "content-type": "application/json", "anthropic-beta": beta },
    body: JSON.stringify({ model: "claude-sonnet-5", max_tokens: 32, stream, safeguards, messages: [{ role: "user", content: "hi" }] }),
  });
}

function anthropicFrames(): string {
  return [
    `event: message_start\ndata: ${JSON.stringify({ type: "message_start", message: { usage: { input_tokens: 1 } } })}\n\n`,
    `event: content_block_start\ndata: ${JSON.stringify({ type: "content_block_start", index: 0, content_block: { type: "text", text: "" } })}\n\n`,
    `event: content_block_delta\ndata: ${JSON.stringify({ type: "content_block_delta", index: 0, delta: { type: "text_delta", text: "ok" } })}\n\n`,
    `event: content_block_stop\ndata: ${JSON.stringify({ type: "content_block_stop", index: 0 })}\n\n`,
    `event: message_delta\ndata: ${JSON.stringify({ type: "message_delta", delta: { stop_reason: "end_turn", safeguard_results: safeguards }, usage: { output_tokens: 1 } })}\n\n`,
    "event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n",
  ].join("");
}

function openAiFrames(): string {
  return [
    `data: ${JSON.stringify({ type: "response.created", response: { id: "resp_test", status: "in_progress" } })}\n\n`,
    `data: ${JSON.stringify({ type: "response.output_text.delta", delta: "ok" })}\n\n`,
    `data: ${JSON.stringify({ type: "response.completed", response: { id: "resp_test", status: "completed", usage: { input_tokens: 1, output_tokens: 1 } } })}\n\n`,
  ].join("");
}

async function run(body: string, providerConfig: OcxConfig): Promise<Response> {
  globalThis.fetch = (async (_input: RequestInfo | URL, init?: RequestInit) => {
    const upstream = new Request("http://upstream.test", init);
    const payload = await upstream.text();
    return new Response(providerConfig.providers.test?.adapter === "anthropic" ? anthropicFrames() : openAiFrames(), {
      headers: { "content-type": "text/event-stream" },
      status: 200,
    });
  }) as typeof fetch;
  const req = new Request("http://localhost/v1/messages", {
    method: "POST",
    headers: { "content-type": "application/json", "anthropic-beta": beta },
    body,
  });
  return handleClaudeMessages(req, providerConfig, { model: "", provider: "" });
}

test("translated Claude requests preserve safeguards on native Anthropic and return streamed results", async () => {
  const cfg = config("anthropic", "https://api.anthropic.com");
  let seen: Record<string, unknown> | undefined;
  globalThis.fetch = (async (_input: RequestInfo | URL, init?: RequestInit) => {
    const req = new Request("http://upstream.test", init);
    seen = await req.json() as Record<string, unknown>;
    return new Response(anthropicFrames(), { headers: { "content-type": "text/event-stream" } });
  }) as typeof fetch;
  const response = await handleClaudeMessages(request(true), cfg, { model: "", provider: "" });
  const text = await response.text();
  expect(seen?.safeguards).toEqual(safeguards);
  expect(String(seen?.__ocxAnthropicExtras)).toBe("undefined");
  // Parse the translated client stream so the verdict is asserted on its exact terminal frame.
  // Keep the parsed frames to also prove the verdict is not duplicated elsewhere.
  const clientFrames = text.split("\n\n").filter(frame => frame.trim()).map(frame => {
    // Extract the event name and JSON payload from each emitted SSE frame.
    const event = /^event: ([^\n]+)$/m.exec(frame)?.[1];
    const data = /^data: ([\s\S]+)$/m.exec(frame)?.[1];
    return { event, data: data === undefined ? undefined : JSON.parse(data) as Record<string, unknown> };
  });
  // The terminal message_delta is the only frame allowed to carry the verdict.
  const messageDelta = clientFrames.find(frame => frame.event === "message_delta");
  expect(messageDelta?.data && (messageDelta.data.delta as Record<string, unknown>)?.safeguard_results).toEqual(safeguards);
  expect(clientFrames.filter(frame => frame.event !== "message_delta")
    .every(frame => !JSON.stringify(frame.data).includes('"safeguard_results"'))).toBe(true);
});

test("non-stream Claude responses expose safeguard_results at top level", async () => {
  const cfg = config("anthropic", "https://api.anthropic.com");
  const response = await run(JSON.stringify({ model: "claude-sonnet-5", max_tokens: 32, stream: false, safeguards, messages: [{ role: "user", content: "hi" }] }), cfg);
  const body = await response.json() as Record<string, unknown>;
  expect(body.safeguard_results).toEqual(safeguards);
});

test("non-Anthropic routes omit safeguards and the caller beta", async () => {
  const cfg = config("openai-chat", "https://openai.example.test/v1");
  let seen: Record<string, unknown> | undefined;
  globalThis.fetch = (async (_input: RequestInfo | URL, init?: RequestInit) => {
    seen = await new Request("http://upstream.test", init).json() as Record<string, unknown>;
    return new Response(openAiFrames(), { headers: { "content-type": "text/event-stream" } });
  }) as typeof fetch;
  const response = await handleClaudeMessages(request(true), cfg, { model: "", provider: "" });
  await response.text();
  expect(JSON.stringify(seen)).not.toContain("safeguards");
  expect(JSON.stringify(seen)).not.toContain(beta);
});
