# Common tool capabilities

This directory is materialized into the dev-only toolbox. Shared tools are
capabilities, not mandatory gates. Platform/provider-specific operations retain
their explicit targets, prerequisites and authorization requirements.

| Module or script | Capability |
| --- | --- |
| `Winpd.Core.psm1` | Atomic evidence JSON, evidence hashing and bounded owned-child execution |
| `windows\Winpd.Windows.psm1` | Exact HWND/PID identity, target-specific Windows App CLI operations and capture status |
| `github\Winpd.Review.psm1` | Complete PR/check/annotation snapshots and bounded read-only observation |
| `github\Test-WinpdPublication.ps1` | Candidate-history/prose checks for known private toolkit markers |
| `github\Test-WinpdReferenceIsolation.ps1` | Dev-to-publish reference checks using explicit runtime identifiers |
| `ai\Winpd.Ai.psm1` | Request authorization/ledger, Copilot event reads and an explicitly authorized bounded Copilot judge |

These modules import without a Terminal checkout. Windows APIs are loaded only
when their Windows capability is invoked. A screenshot result is not pixel
inspection or product acceptance, and the optional capture capability imposes no
global visual gate.

PR observation never replies, requests reviews, resolves threads or merges.
Recurring PR monitoring uses Copilot CLI's built-in `/every` with the specific
prompt and lifecycle rules in the generated dev-root `AGENTS.md` section
**Online PR review monitoring**. The common template is the source of those rules;
these scripts do not create or replace that schedule.

`Get-WinpdReviewSnapshot` collects evidence for an observation. The separate
`Watch-WinpdPullRequest` helper is bounded, defaults to one observation and records
`RunnerActive=false` when it finishes. It is not the recurring scheduler; do not
run its polling loop inside `/every` or alongside that schedule. Missing network
evidence is UNKNOWN, not a retained green status.

The Copilot judge requires both `-AllowInference` and an approved finite request
authorization. It uses the current account and no permission-skipping options.
Reservations remain charged after failure or interruption. A completed request
with a false verdict remains a false verdict; neither result substitutes for the
project's own observable assertions.

The publication checks detect declared/known markers, not arbitrary secrets or
all semantic disclosure. They do not authorize a public write. Keep runtime
identifiers, account material, logs and provider state out of product history.
