# Template versus practice conflicts

Recorded October 10, 2026; PR-description policy amended October 16, 2026.
Publication, evidence and manual-handoff lessons amended November 3, 2026.
These are internal workflow findings, not product PR validation claims or an
instruction to repair unrelated feature code.

Compared sources:

- TDD source baseline `987a294dc2fd1e1d64c1b06358e12f45d24e3f6b`.
- Companion root-template baseline `de9e955a205c35c486ca505b52f252550db05d5c`;
  the original root `AGENTS.md` blobs matched.
- Reviewed implementation/acceptance records from the prior dev source
  `08bf748b07f3d2f6768baf8ad3ff13e763e5934c`.
- Actual offline regressions and current maintenance receipts are ignored under
  `artifacts\practice-sync-20261010`.

## Adopted corrections

| ID | Previous requirement or gap | Actual practice/evidence | Correction |
| --- | --- | --- | --- |
| PC01 | No-token checks were described as publishable without excluding real authentication dependencies | Real login and authenticated catalog/session checks can require credentials while spending zero model tokens | Publication is based on dependencies: all real-account tests/runners stay dev/local-only, even zero-token |
| PC02 | Framework-independent tests and online execution were not clearly separated | A deterministic packaged auth fixture is publishable but needs a suitable packaged/desktop runner; ARM64 build success did not execute its Cargo tests | Classify publication and execution separately; CI success covers only actual configured jobs |
| PC03 | Every published iteration, including tests/docs, unconditionally required a fresh model token | Preparation/doc pushes ran no provider; tests/tooling used bounded deterministic checks and explicit lightweight scopes. Real first-user authentication was observed before any inference | Select applicable gates from the contract/change kind; preserve explicit disposition of established gates and exact product-versus-validation provenance |
| PC04 | The template stage/checklist was centered on implementation through full delivery | The user requested template commit/push followed by a discussion pause | Preparation completion is not product completion; no generic reminder/watchdog overrides the pause |
| PC05 | The local report counted filtered inventory as an undifferentiated total, and allowing skips could produce a green all-skipped run | The new offline regressions failed on zero executed/all-skipped and inconclusive runs; a selected-count run lacked structured counts | Report discovered/selected/executed/filtered counts; zero execution and inconclusive outcomes stay non-green, accepted mixed skips stay explicit |
| PC06 | `LocalTdd.Evidence.psm1` required the latest open-thread comment to come from the shared account | Root guidance prohibits routine fix acknowledgements; the new offline regression failed on an independently authored retained thread despite complete current-head triage | Retain exact-head/annotation/finding triage and human approval checks; do not require or manufacture shared-account replies |
| PC07 | A prior deployed receipt was easy to treat as present runtime identity | Inspection found Release registered while an earlier accepted Dev registration was absent | Re-resolve the selected package before live phases; stale registration is not a product RED, current PASS or permission to switch targets |
| PC08 | Public/internal separation focused primarily on framework dependencies and artifacts | A harmless shipped comment naming an internal tooling path still violated the user-requested public boundary | Audit public prose/code comments as well as imports and every new publish commit |
| PC09 | PR prose could become an internal progress ledger, and per-description wording confirmation could stall an already requested delivery | The user required reader-focused what/how prose and explicitly rejected another description-confirmation gate | Generate concise English descriptions from the repository template and recorded style/length rules; keep validation factual, internal progress on dev, teammate edits intact, and explicit user pauses effective |
| PC10 | Private acceptance requirements and fixture mistakes were classified as missing public-framework features | Existing public helpers and landed regressions already covered much of the behavior; main had no universal screenshot gate | Classify the failure, contract and existing support before proposing extraction; keep declared private visual acceptance private |
| PC11 | The public-content rule existed but was not enforced before writing | A clean final tree does not audit earlier commits, and safe code does not imply safe PR prose | Run the read-only public-content preflight on each new commit and exact outgoing prose; retain dependency and disclosure review beyond known markers |
| PC12 | A snapshot could declare annotations triaged without capturing their contents | Offline regressions accepted absent annotations, incomplete collections and a lifecycle transition; green checks did not expose the missing evidence | Capture complete review bodies and annotation pages/counts, hash their contents and recheck head/state; reject missing inventories rather than requiring shared-account replies |
| PC13 | Checklist coverage totals and repeated IDs were misread as public report defects | Inherited unit credits are not current execution; an ID-keyed private comparison lost repeated rows | Interpret actual runner counts separately and preserve ordered checklist rows; fix the comparator rather than changing correct report behavior |
| PC14 | Automated test ownership was carried into a manual handoff | Retained fixture configuration and historical package identity could be mistaken for shipped defaults or continuing process ownership | Use existing restoration guards, verify the normal app and record manual ownership; require renewed authorization before automation or cleanup |

These corrections do not turn failed or unrun checks into PASS. No real-provider
gate still required by an active contract is silently removed. The real-Copilot
acceptance helper remains strict; it is invoked only for a matching real workflow.

## Still requiring discussion

### D01: Exact real acceptance matrix for presentation-only refactors

The reusable rule is that generic client UI can be covered deterministically,
while provider authentication/model behavior requires its own actual evidence.
The exact provider matrix and any real request budget for a new presentation
feature must still be agreed. Do not infer account changes, full provider
matrix testing or a waiver of a previously agreed real gate from this maintenance.

### D02: Registration relocation versus data-preserving deployment

Current `Invoke-BuildDeploy.ps1 -ReplaceExistingDevRegistration` retains an explicit
legacy removal path with `-PreserveApplicationData`. Current feature practice used
guarded data-preserving registration/deployment without uninstalling a package.
Standing permission to close Dev windows does not authorize package removal.

No deployment/removal code is changed or executed here. Prefer the repository's
current supported data-preserving path, and refuse an ad hoc uninstall to bypass
a lock/layout/version check. A future helper change needs its own transaction,
recovery and configuration-preservation tests and explicit operation scope.

### D03: Completing all automation versus recording human/environment gates

The scoped task may finish preparation or a validated deterministic slice while
a real-provider, native-host or human-review gate remains blocked. The record
must name which task/contract is complete; it must not call the whole feature
accepted. This maintenance does not decide how any unresolved feature gate is waived.

### D04: Additional identity and exact-text implementation checks

The root template still describes a GUI-oriented Copilot identity check. Its CLI-only
observability was not independently reproduced during this maintenance; do not invent
an account confirmation or switch/login/logout to manufacture one.

Some evidence comparisons still use PowerShell `-cne` despite the documented ordinal
comparison rule. Those comparisons were not included in the reproduced five defects
or changed here. A follow-up requires an actual normalization negative control before
any broader primitive change; no new proof is claimed from the prose requirement alone.

## Reusable lessons, not additional product scope

- Unit tests use injected/fictitious provider invocations and preserve negative
  missing-installation paths; a local installed CLI must not mask a CI dependency.
- Protocol tests cover SDK/serialization/dispatch, not only direct parser calls.
- Related UI instructions and actions are asserted together.
- UI predicates have boundary negatives: numeric count versus toast, placeholder
  versus nonempty draft, and valid source versus foreign/stale progress.
- Capabilities are scoped by observed version and entrypoint; a resolved
  installation prerequisite is removed from the defect backlog.
- Previously tested helper protections, source identity and privacy are preserved
  rather than loosened to achieve an attractive report.

## Validation and change ownership

The five new failing report/reply regressions were reproduced before runtime-helper
edits. Their first focused rerun passed all 19 selected tests. Final checks additionally
cover all report formats and the existing zero-selection control.
The table below records that earlier maintenance, not execution evidence for later changes.

| Maintenance check | Result | Ignored receipt directory |
| --- | --- | --- |
| Report/reply RED | 19 selected, 14 passed, five expected failures | `artifacts\practice-sync-20261010\red` |
| Document-entrypoint RED | Nine selected, six passed, three expected failures | `artifacts\practice-sync-20261010\policy-red` |
| Final report/triage controls | 20 selected/executed/passed, zero failed/skipped/inconclusive | `artifacts\practice-sync-20261010\focused-final` |
| Policy and existing package-selection controls | Nine selected/executed/passed | `artifacts\practice-sync-20261010\policy-green` |
| Complete offline Unit selection | 148 discovered, 126 selected/executed/passed, 22 filtered out; zero failures/skips/inconclusive or setup failures; exit zero | `artifacts\practice-sync-20261010\offline-unit` |

The 22 non-Unit cases were not executed or credited. These receipts establish local
toolkit behavior, not real provider, browser, current package or hosted CI acceptance.
Intentional negative fixtures emit failures/reference findings inside synthetic
repositories; the overall selected selftests passed. No model requests or product
deployments occurred. Root templates were checked for identical Git blobs and bytes.

Only this TDD source and the required companion root template are maintenance
targets. Paused authentication dev/publish branches and the prior dev queue
assertion correction remain untouched. No product PR, model call, login,
application-control change, package deployment or process shutdown is part of this work.
