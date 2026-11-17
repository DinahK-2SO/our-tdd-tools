# Development contract

This task is prepared, not implemented or accepted. Machine identities and setup
provenance are recorded in `.winpd\setup.json`. Fill the semantic fields before
changing product behavior; do not infer them from the branch keyword.

## Scope

- Feature: `<FEATURE_NAME>`
- User-visible goal: `<FEATURE_GOAL>`
- Preserved behavior: `<INVARIANTS>`
- Out of scope: `<OUT_OF_SCOPE>`
- Current stage: `PREPARATION`
- Required validation and why: `<VALIDATION_PLAN>`
- Real dependency acceptance required and why: `<REAL_ACCEPTANCE_REQUIRED>`

## RED / GREEN

1. Reconstruct the user path and identify the owning abstraction.
2. Choose the smallest observable regression and a relevant negative control.
3. Run it before the fix and retain the actual failure.
4. Make the smallest behavior-preserving implementation.
5. Run the focused case, then the affected neighboring checks.
6. Bind the results to the tested source, artifact and environment.

- RED oracle: `<RED_ORACLE>`
- Focused command: `<FOCUSED_COMMAND>`
- Required neighboring checks: `<NEIGHBORING_CHECKS>`
- GREEN oracle: `<GREEN_ORACLE>`

## Validation boundaries

Prefer product-owned observable state over model prose. A mock proves its declared
boundary, not a real provider outcome. Only require screenshots or real-model
acceptance when the active task contract calls for them.

Distinguish execution, filtered inventory, skips, setup failures and environment
blockers. An unrun or blocked requirement is not PASS. Preserve failed evidence.
Preparation completion, engineering completion, human approval and merge are
different states.

## Ownership and publication

Keep the toolbox, private customizations and local evidence out of product publish
history. Transfer only self-contained product changes and tests that use the
product's own public test framework. Do not copy private tooling to satisfy missing
test dependencies in publish.

Preserve original project instructions, unrelated changes, credentials, settings,
current chat ancestry and user-controlled apps. Never force cleanup or switch
accounts to obtain a passing result. Model requests, application control and
publication require their own explicit authorization.

Before any authorized publication, inspect every candidate commit and exact
outgoing text. Review full current-head findings and annotations, not only a
headline or reply count. Do not claim a watcher is active unless it was started
and its lifecycle is recorded.

Use the repository's PR template and selected user profile for public language,
length limits and review interaction preferences. Keep actual validation results
and preserve other authors' work. A personal preference does not authorize public
writes, thread resolution or merging. Confirm each branch's push target before
publishing; the source `BaseRemote` is not its push destination.

## Confirm push destinations

Resolve missing targets before the first publish; setup itself remains non-interactive.

1. Reuse explicit `DevRemote` / `PublishRemote` or task-confirmed mappings; do not ask again
   unless they change. Inspect Git fetch/push URLs and branch settings. Identify the
   canonical repository and PR base separately from branch storage; do not assume `origin`.
2. For unresolved GitHub targets, use that host's identity:
   `gh api --hostname <host> user --jq .login`. Check `<login>/<repo-name>` through
   the same host's API; verify the fork network (parent/source), `permissions.push`
   and visibility. A same-name unrelated repo is not a candidate. Failed or inaccessible
   reads are UNKNOWN, not proof of absence; ask rather than switch accounts.
3. For unresolved targets, prefer a verified writable personal fork (both branches
   if neither is set), with the canonical repository as PR base. If no related fork
   is found, suggest the source repository only when writable; otherwise ask for
   targets or permission to create a fork.
   Never infer write permission from ownership alone.
4. Present one confirmation: account/host, dev repo + branch, publish repo + branch,
   PR base repo + branch, and repository visibility. Let the user override either
   target. For non-GitHub or unavailable discovery, ask for explicit mappings.
   Neither branch may contain secrets or sensitive local state; dev is not private storage.
5. After confirmation, record mappings in ignored task state and configure remotes /
   branch `pushRemote` only as authorized; preserve existing conflicting settings.
   Target confirmation does not authorize a push. Do not create forks or change
   authentication without separate approval.

## Online PR review monitoring

This common workflow applies to every project's authorized PR-delivery task.
Setup only prepares these instructions; it does not start a schedule or require
a PR during preparation.

After publication or takeover of an open PR, create or recover exactly one
recurring prompt using Copilot CLI's built-in `/every` scheduling. Use its
built-in scheduling tool when available to the agent; the command below is the
interactive equivalent, not a PowerShell command. Default to 30 minutes unless
the user explicitly chooses another interval. Do not add a polling script,
background job or operating-system scheduled task as a second scheduler.

Before creating a schedule, inspect the current session's schedules and the
task's local record. Reuse an existing matching schedule. At a pre-PR/post-PR
transition, replace only this task's progress schedule rather than creating
competing loops. Record the actual schedule ID, owning session, cadence, target,
phase, last successful observation and review checkpoints in ignored
`Generated Files` or session state. Keep exact online identifiers out of tracked
dev files. Verify registration; displaying the command is not creating a schedule.

Use this specific prompt in Copilot's prompt input, with the selected target
already recorded in local-only state:

```text
/every 30m Follow the "Online PR review monitoring" section of AGENTS.md for this task's local-only PR target. Collect complete current-head review and CI results, compare the previous checkpoint, triage new findings within existing authorization, and stop only this task's schedule on PR merge/closure or explicit user pause/stop.
```

Each scheduled invocation performs one observation and follows these rules:

- Read current PR lifecycle/head, full review bodies including overview and
  suppressed findings, inline/file comments, checks and annotations, approval
  and mergeability. A green check or reply count is not an empty finding list.
- Reuse the common review snapshot helper when useful; data collection is not
  scheduling. Do not start a `Watch-WinpdPullRequest` polling loop inside `/every`.
  Recheck head and lifecycle after collection before acting on the snapshot.
- Compare with the prior checkpoint, critically triage new findings against the
  exact source, and notify only on meaningful changes. Missing pages, failed
  authentication/network reads or stale results are UNKNOWN, never GREEN.
  Preserve the last successful observation without relabeling it as current.
- Monitoring is read-only. Queue already-authorized repairs behind the active
  writer/build/UI run; a timer grants no permission to push, comment, request
  reviews, resolve threads, merge, alter credentials, control applications or
  consume a separate provider budget. Preserve discussion and manual-app ownership.
- Observe the actual remote base separately from a cached PR base. Investigate
  possible conflicts with exact refs and non-mutating checks; never integrate
  every base update or rebase without explicit authorization. A changed publish
  head needs its applicable validation, not relabeled old evidence. A monitoring
  tick alone does not require deployment or real-provider acceptance.
- Keep the schedule active while the PR remains open, including after engineering
  completion, review convergence or a manual handoff awaiting human approval.
  Stop only this task's schedule when the PR is MERGED or CLOSED or the user
  explicitly pauses/stops. Record the stop reason; do not clean up packages,
  worktrees or user-controlled applications as part of stopping monitoring.

The schedule fires only while its owning interactive session is running. On
resume, inspect any restored schedule and recheck the target before creating a
replacement. Record interruptions honestly; do not promise monitoring while the
session is closed. If the built-in scheduler is unavailable, report monitoring
as BLOCKED and identify the prerequisite, rather than silently falling back to
a script. Enable CLI experimental features only with the user's authorization
if this installation requires them for `/every`.

## Handoff

- Current result and evidence: `<RESULT_AND_EVIDENCE>`
- Unverified or blocked scope: `<OPEN_ITEMS>`
- Next authorized action: `<NEXT_ACTION>`

A user discussion pause cannot be lifted by a timer or completion reminder.
After a manual-app handoff, automatic input and cleanup remain disabled until
the user explicitly releases that ownership.
