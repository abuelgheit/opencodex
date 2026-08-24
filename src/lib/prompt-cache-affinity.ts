import { createHash } from "node:crypto";

/** Format a 32-hex value as a UUID-shaped id with UUID version/variant bits. */
export function uuidFromHex(hex32: string): string {
  const h = (hex32 + "0".repeat(32)).slice(0, 32);
  return `${h.slice(0, 8)}-${h.slice(8, 12)}-4${h.slice(13, 16)}-8${h.slice(17, 20)}-${h.slice(20, 32)}`;
}

/** Derive a stable UUID-shaped session id from an arbitrary prompt-cache key. */
export function sessionIdFromPromptCacheKey(promptCacheKey: string): string {
  return uuidFromHex(createHash("sha256").update(promptCacheKey).digest("hex"));
}

/** Add synthesized session affinity without replacing either caller-owned session header. */
export function addPromptCacheSessionAffinity(headers: Headers, promptCacheKey: unknown): void {
  if (typeof promptCacheKey !== "string" || headers.has("session_id") || headers.has("session-id")) return;
  headers.set("session_id", sessionIdFromPromptCacheKey(promptCacheKey));
}
