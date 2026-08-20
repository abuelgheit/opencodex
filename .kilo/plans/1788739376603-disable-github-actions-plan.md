# Disable all GitHub Actions workflows

## Objective and business impact

Disable GitHub Actions at the repository level for `abuelgheit/opencodex`, so none of the repository's 15 currently tracked workflows can start while the setting remains disabled. Preserve every workflow definition unchanged so automation can be restored without reconstructing workflow files.

This intentionally suspends CI, release publication, documentation deployment, service lifecycle checks, issue and pull-request enforcement/labeling, cleanup schedules, and stale-issue automation. Required GitHub status checks may remain pending or unavailable, which can block pull-request merges until Actions is re-enabled or repository rules are adjusted separately.

## Current state

- Repository: `abuelgheit/opencodex` (from the configured `origin`).
- Tracked workflow definitions: 15 `.yml` files under `.github/workflows/`.
- The workflow directory and this plan path were clean when inspected.
- Authenticated GitHub API access was unavailable during planning, so current Actions permission state, active runs, and required status-check rules must be checked during execution.
- `.github/AGENTS.md` and `MAINTAINERS.md` classify GitHub Actions changes as a security boundary requiring explicit security review.

## Implementation step 1 — Disable Actions for the repository

### Approval gate

Obtain explicit approval for this step from an authorized maintainer/security reviewer before changing the repository setting. This is both the user approval required to execute the plan and the repository's required security review record.

### Exact files and settings

- Repository files added: 0.
- Repository files modified: 0.
- Repository files deleted: 0.
- GitHub repository setting modified: Actions permissions for `abuelgheit/opencodex`, setting `enabled` to `false` through the official repository Actions permissions API (equivalent to **Settings → Actions → General → Disable actions**).
- Workflow YAML files remain in `.github/workflows/` unchanged.
- This planning artifact is outside the implementation change count: `.kilo/plans/1788739376603-disable-github-actions-plan.md` (1 added local file).

### Execution sequence

1. Confirm authenticated GitHub access targets `abuelgheit/opencodex` and that the authenticated identity has repository administration permission.
2. Read and record the current repository Actions permissions with `GET /repos/abuelgheit/opencodex/actions/permissions` so the prior setting is known for rollback.
3. Read active/queued workflow runs and required status-check rules. Report any running jobs that may continue and any merge rules that will be blocked; do not modify rulesets or branch protections because that is outside this step.
4. Set repository Actions permissions with `PUT /repos/abuelgheit/opencodex/actions/permissions` and JSON body `{ "enabled": false }` (for example, `gh api --method PUT repos/abuelgheit/opencodex/actions/permissions -F enabled=false`).
5. Do not delete workflow files, alter triggers, disable workflows one by one, change branch protections, or cancel existing runs unless separately approved.

### Technical and business choices

- Use the repository-level setting rather than editing 15 workflow files. GitHub documents that disabling Actions for a repository prevents workflows from running, while retaining the workflow definitions and their history.
- Preserve workflow source and per-workflow state to make rollback a single setting change.
- Keep branch/ruleset changes out of scope. Disabling required checks is materially different from disabling workflow execution and requires a separate plan and approval if desired.
- Do not claim that an already-running job was stopped. Repository disablement is verified as prevention of workflow execution while disabled; existing run handling is reported separately.

### Dependencies

- An authenticated GitHub CLI/API session.
- Repository administration permission for `abuelgheit/opencodex`.
- Organization or enterprise policy must permit changing the repository's Actions setting.
- Explicit security review from an authorized maintainer.

### Risks and mitigations

- **Merges can be blocked by required checks that no longer run.** Inspect and report required status checks before disabling; leave protections unchanged unless separately approved.
- **Release and deployment paths become unavailable.** Preserve all workflow files and record the previous Actions permission object for rollback.
- **Issue/PR governance automation stops.** Explicitly include enforcement, labeling, triage, cleanup, and stale automation in the impact report.
- **Existing runs may still be active.** Inspect and report queued/in-progress runs; cancellation is not implied by this plan.
- **Wrong-repository or insufficient-privilege change.** Verify the remote owner/name and authenticated identity before the write; stop on mismatch or authorization failure.
- **Organization policy may override repository controls.** Treat a rejected API write or a post-write `enabled` value other than `false` as a blocker/failure, not success.

### Verification

1. Read `GET /repos/abuelgheit/opencodex/actions/permissions` after the update and require `enabled: false`.
2. Confirm the 15 tracked `.github/workflows/*.yml` files are unchanged and the implementation creates no repository diff.
3. Re-list queued/in-progress runs and report their state without claiming cancellation.
4. Report required status-check contexts that may now block merges, if authenticated API access exposes them.
5. Do not dispatch a workflow merely to test disablement; the permissions response is the authoritative non-destructive verification.

### Rollback

Restore the recorded prior Actions permission object. If the previous state was the normal enabled policy, set `enabled` back to `true` together with its prior `allowed_actions`/selected-action policy, then verify the returned permission state. Do not alter workflow files during rollback.

## Scope summary

- Implementation steps: 1.
- Implementation file changes: 0 added, 0 modified, 0 deleted.
- GitHub settings changed: 1 repository-level Actions permission.
- Plan artifacts: 1 added local file.
