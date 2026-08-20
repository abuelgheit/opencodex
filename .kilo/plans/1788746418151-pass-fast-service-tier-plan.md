# Plan: Preserve caller `service_tier: "fast"` on the OpenAI wire

## Purpose and business impact

When an eligible caller explicitly sends `service_tier: "fast"`, OpenCodex currently recognizes it as canonical Fast intent but rewrites the outbound OpenAI request to `service_tier: "priority"`. OpenAI documents `fast` as an accepted request alias, so OpenCodex should preserve the caller's lowercase `fast` value on the wire while retaining its internal canonical classification as priority/Fast.

This makes the upstream request match the operator's explicit request and makes request logs prove that the literal wire value was `fast`.

## Scope and behavioral choices

### In scope

- Preserve an explicit, lowercase caller value `service_tier: "fast"` as outbound `"fast"` on eligible OpenAI service-tier routes.
- Continue treating that wire value as canonical priority for Fast eligibility, outcome, and accounting semantics.
- Update focused characterization and observability tests.

### Explicitly unchanged

- An explicit caller value `"priority"` remains `"priority"`.
- Config-forced Fast (`fastMode: true`) continues to use the provider policy's canonical wire value, currently `"priority"`.
- Forced Fast continues to override unrelated caller tiers such as `"flex"` with `"priority"`.
- `fastMode: false`, unsupported-route stripping, foreign-tier forwarding, response-authority policy, billing attribution, and OpenAI response parsing remain unchanged.
- Uppercase/noncanonical input such as `"FAST"` remains normalized through the existing canonical wire mapping rather than forwarding a potentially invalid enum spelling.
- No live OpenAI request or credential use is included.

## Implementation step 1 — decision semantics and regression coverage

### Files

1. Modify `src/providers/fastwire.ts`
2. Modify `tests/routing/fastwire-characterization-wire.test.ts`
3. Modify `tests/routing/fastwire-observability.test.ts`

Changed-file count for this step:

- Added: 0
- Modified: 3
- Deleted: 0
- Total: 3

### Technical changes

#### `src/providers/fastwire.ts`

- Refine inherited canonical-tier decision handling so that an exact lowercase caller value `fast` produces a `TierDecision` whose emitted value is `fast` instead of looking up and emitting the canonical `priority` wire value.
- Keep `priority`, forced Fast, and other canonical-policy mappings unchanged.
- Extend canonical wire interpretation so an emitted service-tier value of `fast` is still recognized internally as canonical `priority`.
- Ensure `createAdapterTierMetadata` records:
  - `wireKind: "service-tier"`
  - `wireValue: "fast"`
  - `canonical: "priority"`
  - `fastOutcome: "applied"`
  - `confirmation: "assumed"` until authoritative response evidence changes it.
- Keep the decision in the existing `set` form so `applyServiceTierGate` recognizes it as a policy-approved canonical decision and does not drop it.

#### `tests/routing/fastwire-characterization-wire.test.ts`

- Change the eligible literal-lowercase `fast` characterization from expecting outbound `priority` to expecting outbound `fast`.
- Keep explicit assertions that `priority` stays `priority` and forced Fast still emits `priority`.
- Preserve or add coverage showing uppercase `FAST` follows existing normalization behavior rather than being forwarded verbatim.
- Exercise the final serialized adapter request body, not only the intermediate parsed option.

#### `tests/routing/fastwire-observability.test.ts`

- Add or update focused coverage for an emitted literal `fast` wire value.
- Assert it remains canonically classified as priority/Fast and does not regress to `unknown` or `downgraded` merely because the wire alias is `fast`.
- Retain existing non-authoritative OpenAI response behavior; this step does not change how returned `service_tier: "default"` is interpreted.

## Dependencies

- Existing `TierDecision`, `canonicalFastTierMarker`, `canonicalFromWire`, `tierValueAfterDecision`, and `createAdapterTierMetadata` behavior in `src/providers/fastwire.ts`.
- Existing Responses and Chat adapters already serialize the settled tier decision, so no adapter edit is planned unless verification produces direct evidence that the approved behavior cannot be achieved through the shared decision layer. Such evidence would be reported as a blocker rather than expanding scope automatically.

## Risks and mitigations

- **Risk: wire value `fast` is no longer recognized as canonical priority in observability/accounting.**
  - Mitigation: update canonical wire interpretation and assert the complete tier outcome in focused tests.
- **Risk: configured Fast unintentionally changes from `priority` to `fast`.**
  - Mitigation: preserve the forced-Fast branch and retain an explicit test expecting `priority`.
- **Risk: arbitrary casing is forwarded to OpenAI.**
  - Mitigation: preserve only exact lowercase `fast`; retain canonical mapping for `FAST`.
- **Risk: unsupported providers start receiving service tiers.**
  - Mitigation: do not alter capability checks or service-tier gating; retain relevant characterization assertions.
- **Risk: a shared decision change affects both Responses and Chat serialization.**
  - Mitigation: verify both existing characterization suites and inspect the complete three-file diff line by line.

## Verification

Run, in order:

```bash
bun test tests/routing/fastwire-characterization-wire.test.ts
bun test tests/routing/fastwire-observability.test.ts
bun run typecheck
bun run privacy:scan
```

Because this is a multi-file runtime change, also run:

```bash
bun run test:changed
```

Acceptance criteria:

1. A supported caller request with exact lowercase `service_tier: "fast"` has `service_tier: "fast"` in the final serialized OpenAI request body.
2. Its adapter metadata reports `wireValue: "fast"` and canonical priority with an applied outcome.
3. Explicit `priority` and config-forced Fast still serialize as `priority`.
4. Unsupported/default-suppressed routes retain their current drop behavior.
5. All focused tests, typecheck, privacy scan, and changed-test selection pass.
6. The final reviewed diff contains only the three approved files and no generated or unrelated changes.

## Review classification policy

- Any failure of the acceptance criteria, typecheck, privacy scan, or relevant tests is a required correction within this approved step.
- Broader changes to response authority, pricing, provider capability, configuration, docs, or unrelated tier aliases are optional/out of scope and will not be implemented in this step.
