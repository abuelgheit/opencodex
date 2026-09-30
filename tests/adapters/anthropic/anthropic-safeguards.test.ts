import { describe, expect, test } from "bun:test";
import { createAnthropicAdapter } from "../../../src/adapters/anthropic";
import type { AdapterEvent, OcxParsedRequest, OcxProviderConfig } from "../../../src/types";
import { createTestTranslatorBudget } from "../../helpers/translator-budget";

const extras = {
  safeguards: [{ type: "dangerous_tool_use", classifier_context: { source: "test" } }],
  anthropicBeta: "dangerous-tool-use-2026-09-03",
};

function parsed(_anthropicExtras = extras): OcxParsedRequest {
  return {
    modelId: "claude-sonnet-5",
    stream: true,
    options: {},
    context: { messages: [{ role: "user", content: "hi", timestamp: 0 }] },
    _anthropicExtras,
  };
}

function provider(baseUrl: string): OcxProviderConfig {
  return { adapter: "anthropic", baseUrl, apiKey: "test-key", authMode: "key" } as OcxProviderConfig;
}

async function requestBody(baseUrl: string): Promise<{ body: Record<string, unknown>; headers: Record<string, string> }> {
  const request = await createAnthropicAdapter(provider(baseUrl)).buildRequest(parsed(), {
    headers: new Headers(),
    translatorBudget: createTestTranslatorBudget(),
  });
  return { body: JSON.parse(String(request.body)) as Record<string, unknown>, headers: request.headers };
}

describe("Anthropic safeguard passthrough", () => {
  test("native Anthropic emits safeguards and caller beta", async () => {
    const request = await requestBody("https://api.anthropic.com");
    expect(request.body.safeguards).toEqual(extras.safeguards);
    expect(request.headers["anthropic-beta"]).toContain(extras.anthropicBeta);
  });

  test("compatible non-native endpoints emit neither field", async () => {
    const request = await requestBody("https://anthropic-gateway.example.test");
    expect(request.body.safeguards).toBeUndefined();
    expect(request.headers["anthropic-beta"]).toBeUndefined();
  });

  test("streaming safeguard results become a terminal adapter event", async () => {
    const results = [{ type: "dangerous_tool_use", status: { type: "unsupported" } }];
    const frames = [
      `event: message_delta\ndata: ${JSON.stringify({ type: "message_delta", delta: { stop_reason: "end_turn", safeguard_results: results } })}\n\n`,
      "event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n",
    ].join("");
    const events: AdapterEvent[] = [];
    for await (const event of createAnthropicAdapter(provider("https://api.anthropic.com")).parseStream(
      new Response(frames), createTestTranslatorBudget(),
    )) events.push(event);
    expect(events.at(-1)).toEqual({ type: "done", usage: undefined, stopReason: "end_turn", safeguardResults: results });
  });

  test("missing upstream safeguard results stay absent", async () => {
    const events: AdapterEvent[] = [];
    for await (const event of createAnthropicAdapter(provider("https://api.anthropic.com")).parseStream(
      new Response("event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n"), createTestTranslatorBudget(),
    )) events.push(event);
    expect(events.at(-1)).toEqual({ type: "done", usage: undefined });
  });
});
