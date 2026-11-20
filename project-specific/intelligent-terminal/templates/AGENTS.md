# Intelligent Terminal project contract

Keep the original product instructions below. They remain authoritative for the
current product architecture, build commands, settings and compatibility rules.

## Project tooling

Project tools included: `{{Project.IncludeTools}}`. When enabled, the dev-only
Terminal toolkit is under `.winpd\project-specific\intelligent-terminal\tools`.
It contains the retained
ItE2E helpers, deterministic fixtures, build/deployment identity checks and
Terminal-specific real-provider scenarios.

The historical toolkit documents may use `local-tdd-kit` as their adoption path.
In this generated workspace, use the toolbox path above instead. Do not copy
these tools into publish to satisfy test dependencies.

## Product validation

- Prepared package selector: `{{Project.PackageSelector}}`.
- Optional COM endpoint override (blank means project defaults): {{Project.ComClsid}}
- Optional Copilot hook configuration path (blank means the current-user path): {{Project.CopilotConfigPath}}

For local packaged checks, set `ITE2E_PACKAGE` to the prepared selector.
If overrides are supplied, set `ITE2E_WT_COM_CLSID` and `ITE2E_COPILOT_CONFIG`
to those values for that check. Otherwise leave those overrides unset so the
project's standard identities and current-user path are resolved normally.
A package with no known brand mapping requires an explicit COM override before
live checks. Never use an invented identifier or silently switch targets when
resolution fails.

- Follow the original project's build and deployment rules for the files changed.
  Install or refresh the worktree's Dev package and run local tests without
  separate approval. For WTA-only changes, refresh the owned Dev layout with
  `Invoke-WtaRefresh.ps1` and a matching native build receipt rather than
  redeploying the full package. Use an isolated Dev package if another worktree
  owns the existing registration; pin its package family for the run.
  Identify the revision and artifact that actually ran.
- Build WTA with the explicit Windows target before packaging when WTA changed.
- Native compilation is not proof that TAEF test bodies or packaged E2E ran.
  Record actual execution and setup failures separately.
- For UI layout tests, mount a real rendered host and wait for observable layout.
  Preserve intentional protocol-only test fixtures.

## Published-head real-agent smoke

Start local verification immediately after opening the PR (including a draft)
and after every successful push that changes its remote head. The publishing
agent starts it as part of the open/push operation, not on the next review
monitor tick. Build and deploy Dev from the exact published SHA, then run one
real inference through the installed Agent Pane in parallel with online review
and CI. Do not delay opening the PR or wait for review before starting the test.
This applies even to docs-only and test-only PR heads. A dev-branch push, a
review comment or an unchanged head does not start another run.

Match the clean source SHA to both the PR head and remote publish branch.
Use an authorized local agent and budget. Verify the actual provider response
and a product-observable result; mocks and login alone do not count. Keep the
runner, receipts and raw evidence dev/local-only; keep credentials out of Git
and real requests out of CI. Missing prerequisites are BLOCKED, never PASS.

Keep only the newest head pending for each PR. Mark an unfinished older run
superseded and start the newest head without waiting for the old test result.
Release test-owned deployment/UI resources before reusing them; never stop a
user app or refund a spent request. On completion, recheck both remote heads
before crediting a result. Only the current SHA can satisfy acceptance.
The Terminal toolbox's `TDD-WORKFLOW.template.md` describes the runner and handoff.
After each successful open/push invoke `Invoke-LocalTddPublishedSmoke.ps1`
from the dev toolbox, with the clean publish checkout, immutable publication
record, private native receipt, a shared per-task state root and approved budget.
Run it alongside review. It signals the prior in-flight head and verifies the
remote head again before accepting the new result.

## Ownership

Do not replace another worktree's Dev registration, clear settings, uninstall
packages, or close apps merely to prepare this task. Isolated test packages reuse
the production-installed hooks; do not alter global hook registrations.

For live tests, launch a test-owned window and verify its package, executable,
PID and creation time before sending input or cleaning up. Preserve current chat
ancestry and user-controlled windows. A manual-test handoff revokes automatic
input and cleanup for that window until the user explicitly releases it.
