/** Internal key for Anthropic-only request data carried through Responses translation. */
export const ANTHROPIC_EXTRAS_KEY = "__ocxAnthropicExtras";

/** Anthropic-only request fields that may survive the translated request path. */
export interface AnthropicExtras {
  safeguards?: unknown;
  anthropicBeta?: string;
}

/** Read the validated proxy carrier without exposing malformed values to adapters. */
export function readAnthropicExtras(body: unknown): AnthropicExtras | undefined {
  if (body === null || typeof body !== "object" || Array.isArray(body)) return undefined;
  const carrier = (body as Record<string, unknown>)[ANTHROPIC_EXTRAS_KEY];
  if (carrier === null || typeof carrier !== "object" || Array.isArray(carrier)) return undefined;
  const extras = carrier as Record<string, unknown>;
  const result: AnthropicExtras = {};
  if (extras.safeguards !== undefined) result.safeguards = extras.safeguards;
  if (typeof extras.anthropicBeta === "string" && extras.anthropicBeta.length > 0) {
    result.anthropicBeta = extras.anthropicBeta;
  }
  if (result.safeguards === undefined && result.anthropicBeta === undefined) return undefined;
  return result;
}

/** Remove the proxy carrier before a Responses adapter can serialize the raw body. */
export function stripAnthropicExtras(body: unknown): unknown {
  if (body === null || typeof body !== "object" || Array.isArray(body)
    || !Object.hasOwn(body, ANTHROPIC_EXTRAS_KEY)) return body;
  const copy = { ...(body as Record<string, unknown>) };
  delete copy[ANTHROPIC_EXTRAS_KEY];
  return copy;
}
