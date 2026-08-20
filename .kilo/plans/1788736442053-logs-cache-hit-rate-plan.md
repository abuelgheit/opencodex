# Logs table cache-hit percentage

## Goal and business impact

Add a cache-hit percentage column to the main Logs table so operators can see, per request, how much of the input prompt was served from cache without opening request details.

The value is presentation-only and will use usage data already returned by the Logs API. There is no server, persistence, or API-schema change.

## Scope and step boundaries

This task requires **13 modified implementation files**, so it is divided into two sequential implementation steps to keep each step at or below the 10-file limit.

### Step 1 — Add localized column copy

**9 files modified, 0 added, 0 deleted:**

1. `gui/src/i18n/en.ts`
2. `gui/src/i18n/de.ts`
3. `gui/src/i18n/fr.ts`
4. `gui/src/i18n/ko.ts`
5. `gui/src/i18n/zh.ts`
6. `gui/src/i18n/zh-TW.ts`
7. `gui/src/i18n/ru.ts`
8. `gui/src/i18n/ja.ts`
9. `gui/src/i18n/tr.ts`

Add two keys to every locale catalog beside the existing Logs token/rate keys:

- `logs.col.cacheHit`: a concise localized Cache hit column heading.
- `logs.metric.cacheHitTitle`: a localized tooltip explaining that the value is the percentage of input tokens served from cache.

The English source wording will be:

- Heading: `Cache hit`
- Tooltip: `Percentage of input tokens served from cache`

Translations will preserve that meaning and remain concise enough for a narrow table column. This step changes no rendered component yet; adding all locale entries together keeps the compile-checked `TKey` catalogs synchronized.

#### Step 1 dependencies

- English remains the source of truth for `TKey`.
- Every non-English catalog is `Record<TKey, string>` and therefore must receive both keys in the same step.

#### Step 1 risks and mitigations

- **Missing locale key:** update all nine catalogs and run the exact-key-set test.
- **Untranslated or oversized wording:** use native concise terminology in each catalog, with the fuller meaning in the tooltip.
- **i18n lint regression:** run the repository-provided GUI i18n lint.

#### Step 1 verification

Run from the repository root:

1. `cd gui && bun test tests/i18n-locales.test.ts`
2. `cd gui && bun run lint:i18n`
3. `cd gui && bun run build`

Review the complete nine-file diff and confirm only the two approved keys were added to each locale.

Implementation must stop after Step 1 and wait for explicit approval before Step 2.

---

### Step 2 — Render and test the cache-hit column

**4 files modified, 0 added, 0 deleted:**

1. `gui/src/pages/Logs.tsx`
2. `gui/src/styles.css`
3. `gui/tests/logs-auto-refresh.test.tsx`
4. `gui/tests/viewport-scroll-caps.test.ts`

#### Calculation and display behavior

In `gui/src/pages/Logs.tsx`, add a small pure formatter/helper for a request's cache-hit percentage:

1. Obtain cache-read tokens through the existing `cacheSplit(log).read` helper. This preserves the existing precedence:
   - use `cacheReadInputTokens` when explicitly supplied;
   - otherwise derive reads from legacy `cachedInputTokens` and cache writes where necessary.
2. Use `usage.inputTokens` as the denominator because the canonical usage convention defines it as total input, inclusive of cache reads and writes.
3. Return an em dash (`—`) when:
   - usage is absent;
   - cache-read data is absent rather than explicitly reported as zero;
   - input tokens are non-finite or less than or equal to zero;
   - the resulting ratio is non-finite.
4. Otherwise clamp the ratio to `[0, 1]`, round to the nearest whole percentage, and append `%`.

Expected examples:

- `cacheReadInputTokens: 75`, `inputTokens: 100` → `75%`
- explicitly reported zero cache reads with positive input → `0%`
- missing cache-read data → `—`
- malformed over-reporting, such as 120 cache-read tokens for 100 input tokens → `100%`

No estimated marker will be added: the percentage reflects the cache counters supplied for that row, while unavailable counters remain visibly unavailable.

#### Table placement and structure

Add the new right-aligned, monospaced column immediately after **Tokens** and before **tok/s**:

- Add `logs-col-cache-hit` to the `<colgroup>`.
- Add the localized `logs.col.cacheHit` header with `logs.metric.cacheHitTitle` as its tooltip.
- Render the calculated value for every request row.
- Increase both virtual-spacer `colSpan` values from 10 to 11.

The existing token cell remains unchanged and continues to show total tokens plus cache read/write token counts; the new column adds the normalized percentage rather than replacing that detail.

#### Layout choices

In `gui/src/styles.css`:

- Add a fixed width and nowrap/minimum-width behavior for `logs-col-cache-hit`.
- Keep all eleven percentage widths totaling exactly 100%.
- Allocate **8%** to the cache-hit column by narrowing lower-priority flexible columns while preserving readable time, status, duration, and metric values:
  - Time: 10%
  - Tokens: 9%
  - Cache hit: 8%
  - tok/s: 7%
  - Cost: 8%
  - Model: 13%
  - Effort: 9%
  - Provider: 11%
  - Status: 8%
  - Request: 9%
  - Duration: 8%
- Increase the table minimum width from `1100px` to `1180px` so the additional fixed-layout metric column scrolls horizontally instead of compressing all content further on narrow viewports.
- Retain existing body-cell clipping and table virtualization behavior.

#### Regression tests

In `gui/tests/logs-auto-refresh.test.tsx`:

- Update the layout schema expectation from ten to eleven ordered columns, placing `logs-col-cache-hit` after `logs-col-tokens`.
- Give the primary fixture explicit cache-read usage and assert the rendered percentage.
- Add focused row cases proving:
  - a normal cache hit renders the rounded percentage;
  - explicit zero reads render `0%`;
  - missing cache-read data renders `—` rather than implying `0%`;
  - over-reported cache reads clamp to `100%`.
- Assert both virtual-spacer cells span all 11 columns when virtualization produces them, or add an equivalent source/DOM assertion if the current harness does not produce both spacers reliably.

In `gui/tests/viewport-scroll-caps.test.ts`:

- Rename/update the fixed-layout test from ten to eleven columns.
- Assert the new ordered width map, eleven-column count, exact 100% sum, and the new `1180px` table minimum width.

#### Step 2 dependencies

- Step 1's translation keys must exist before this step uses them.
- Existing `cacheSplit` behavior and canonical usage semantics remain authoritative.
- No new runtime or package dependency.

#### Step 2 risks and mitigations

- **Incorrect denominator or double-counted cache tokens:** divide cache reads by inclusive `inputTokens`; do not add cache counters to the denominator.
- **Missing data shown as a false zero:** distinguish `undefined` from an explicitly reported numeric zero.
- **Malformed provider counters exceed 100%:** clamp to the valid range.
- **Header/body/spacer mismatch:** update colgroup, header, row, both spacer colSpans, and schema tests together.
- **Table crowding:** rebalance widths to 100% and increase the horizontal-scroll minimum width.
- **Regression to the already-approved seconds display:** preserve duration formatting and its existing assertions unchanged.

#### Step 2 verification

Run from the repository root:

1. `cd gui && bun test tests/logs-auto-refresh.test.tsx tests/viewport-scroll-caps.test.ts`
2. `cd gui && bun run build`

Then review the complete four-file Step 2 diff line by line, including helper edge cases, table semantics, widths, spacer spans, tests, and confirmation that no generated `gui/dist/` files were added to the diff.

## Out of scope

- Backend/API changes or adding a persisted `cacheHitRate` field to individual logs.
- Changing cache-cost calculations, Usage-page aggregates, request details, filters, sorting, exports, or token-counter semantics.
- Replacing the existing cache read/write token lines in the Tokens cell.
- Decimal percentages; this column uses rounded whole percentages to remain scannable.

## Total planned implementation footprint

- **13 modified files**
- **0 added implementation files**
- **0 deleted files**

The plan document itself is one additional new planning file and is not part of the implementation footprint.
