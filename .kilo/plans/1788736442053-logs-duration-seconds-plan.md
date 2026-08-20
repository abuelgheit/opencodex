# Logs duration display in seconds

## Scope

One implementation step, changing **2 files** total:

- Modified: `gui/src/pages/Logs.tsx`
- Modified: `gui/tests/logs-auto-refresh.test.tsx`
- Added: 0 implementation files
- Deleted: 0 files

Generated output under `gui/dist/` will not be edited or committed as part of this step.

## Purpose and business impact

Display request and attempt durations on the Logs page in seconds (`s`) instead of milliseconds (`ms`). This makes longer request durations easier to scan while retaining millisecond-level precision for short requests.

The change is presentation-only. The API payload and internal `durationMs` fields remain measured in milliseconds, so there is no server, persistence, or wire-format migration.

## Implementation step 1: Convert all Logs-page duration displays

### Production change

In `gui/src/pages/Logs.tsx`:

1. Add a small shared duration formatter that:
   - accepts the existing millisecond value and locale tag;
   - divides the value by 1,000;
   - formats at most three fractional digits, preserving millisecond precision in the seconds representation;
   - trims unnecessary trailing zeroes through `Intl.NumberFormat` behavior;
   - appends the technical unit literal `s`.
2. Use that formatter for every visible `durationMs` rendering on the page:
   - the main logs table duration column;
   - the selected request's Performance detail section;
   - each row in the attempts table.
3. Leave time-to-first-output (`firstOutputMs`) unchanged because the request specifically targets duration, and TTFT is a separate metric.
4. Keep property/type names such as `durationMs` unchanged because they describe the API's actual unit.

Expected examples:

- `42` ms renders as `0.042s`.
- `1,000` ms renders as `1s`.
- `1,500` ms renders as `1.5s`.

No new translation key is needed: `gui/AGENTS.md` explicitly permits technical unit abbreviations next to numbers.

### Regression tests

In `gui/tests/logs-auto-refresh.test.tsx`:

1. Add or extend focused assertions proving that the overview duration renders in seconds and no longer renders its millisecond form.
2. Open the request detail and assert that its Performance duration uses the same seconds representation.
3. Extend the existing attempts-detail coverage to assert converted seconds values for attempt durations and reject the prior `ms` forms.

The assertions will cover all three rendering locations so one surface cannot regress independently.

## Dependencies

- Existing React Logs page and `Intl.NumberFormat`; no new package dependency.
- Existing `LanguageProvider` test harness and Logs fixtures.
- Existing API contract supplying numeric `durationMs` values.

## Risks and mitigations

- **Risk: precision loss for sub-second durations.** Mitigation: allow up to three fractional digits, preserving millisecond precision after conversion.
- **Risk: inconsistent units between overview, detail, and attempts.** Mitigation: route all three displays through one formatter and test each surface.
- **Risk: accidental API/schema change.** Mitigation: retain all `durationMs` fields and convert only at render time.
- **Risk: unintended TTFT unit change.** Mitigation: explicitly leave `firstOutputMs` rendering in milliseconds.
- **Risk: locale formatting differences.** Mitigation: use the page's existing locale tag consistently and assert the default English test output.

## Verification

After implementation:

1. Run the focused GUI regression test:
   - `cd gui && bun test tests/logs-auto-refresh.test.tsx`
2. Run the required GUI production build once:
   - `cd gui && bun run build`
3. Review the complete two-file diff line by line, confirming:
   - exactly the three intended duration surfaces changed;
   - TTFT remains in milliseconds;
   - no API types or payload parsing changed;
   - no generated `gui/dist/` output was added to the implementation diff.

Implementation and verification begin only after explicit approval of this plan.
