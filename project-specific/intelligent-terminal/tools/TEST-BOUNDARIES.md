# Test admission and validation boundaries

This is internal workflow guidance. It does not publish the local TDD toolkit or
authorize exposing its implementation in a product PR.

## Classify lessons before changing a framework

For each proposed improvement, record the observed failure, the owning contract,
existing support, the smallest missing behavior and the intended destination.
Separate an already-fixed feature fixture, incorrect helper use, evidence
misinterpretation and a reproduced shared-framework defect. A private acceptance
requirement is not evidence that the public framework is deficient.

Only propose public helper extraction for a demonstrated public precision or
reuse need. Observation helpers must not focus, scroll or otherwise perform the
product action to make their assertion pass. Rendered fixtures need a real host
and actual layout readiness; do not change an intentional protocol-only setup
just because a rendered test called it incorrectly.

Keep policy ownership explicit. This kit's `contract.visual.required` controls
its visual-evidence gate; it does not impose screenshot capture or human image
review on main's existing test framework. Missing images only fail a contract
that requires them. Retain positive behavior and custom-binding coverage when
removing a default shortcut; do not permanently prohibit reuse of the old chord.
Public review-parser compatibility and native CI are separate tooling concerns,
not a reason to migrate private orchestration into public E2E.

## Two independent decisions

Classify each test by both **publication eligibility** and **execution environment**.
A test can belong in publish and still need a local packaged/interactive runner.
Conversely, zero-token execution does not make a real-account test publishable.

| Test dependency and purpose | Publish branch | Execution |
| --- | --- | --- |
| Deterministic parsing, reducers, commands and protocol tests with fixtures | Allowed in the target base's existing public framework | Configured CI job or local runner |
| Mock-provider packaged UI, COM, ConPTY and persistence tests | Allowed with declared reproducible prerequisites and owned cleanup | Suitable CI runner or local packaged runner |
| Installation/discovery integration checks without real authentication or inference | Allowed when reproducible; unit tests must not require a real provider CLI installation | Explicitly provisioned runner or deterministic filesystem fixture |
| Real login, credentials, an already-authenticated account, or account-dependent catalog/session checks | Dev/local-only, even zero-token | Explicitly authorized local acceptance |
| Real model inference, provider quota, or real-model-driven tool acceptance | Dev/local-only | Authorized local acceptance with a finite invocation budget |
| This unpublished framework, its selftests, orchestration and experiments | Dev/local-only | Internal local validation |

**Publish tests must not depend on real login**, even zero-token login or
authenticated reconnect. This includes free accounts, saved authentication and
apparently harmless capability checks that require credentials.
The runner, imported helpers, fixture setup, configuration and indirect calls
must obey the same boundary. Moving a file into `test/e2e` does not authorize it.

Authentication functionality can have publishable coverage: simulate advertised
methods, authentication responses, browser progress, cancellation and retries.
Use fictional invocation inputs for unit tests and preserve missing-installation
errors. Do not install or sign in to a real CLI merely to make a unit test pass.

Model behavior is a separate acceptance target. A mock may prove routing and
state transitions, but not a model's actual result or provider-side authentication.
Real shell effects produced by a deterministic fixture are not automatically
real-model acceptance.

Before dev-to-publish transfer:

1. Inspect the complete new commit range, dependency imports and invocation paths.
2. Prove tests discover and run in a clean publish worktree without this private kit.
3. Confirm no test consumes provider quota or depends on an authenticated account.
4. Keep real-acceptance source, runners and reports dev/local-only; keep credentials
   and sensitive account/provider state out of Git entirely.
5. Audit public descriptions, documentation and code comments for internal toolkit
   names/paths and private machine-acceptance status, not only executable imports.

### Public-write preflight

Run the private helper from the dev/kit worktree before each publish push or
authorized public title, body or comment write:

```powershell
pwsh -File local-tdd-kit\Test-LocalTddPublication.ps1 `
    -RepoRoot <CLEAN_PUBLISH_WORKTREE> -BaseRef <PUBLISH_BASE_COMMIT> `
    -HeadRef <PUBLISH_HEAD> -TextPath <CANDIDATE_TEXT_FILES>
```

Omit `-TextPath` only for a commit-only audit. Keep draft files ignored or outside
the candidate worktree. The helper checks every new commit's message, paths and
added text, including private files added and removed before the final tree.
It also scans the exact proposed prose and returns its hashes with pinned commit
identities. Any subsequent edit invalidates that result; send only the audited
bytes and recheck the target head/lifecycle before the authorized write.

This is a known-marker audit, not a complete dependency or secret scanner,
proof of test execution, or permission to publish. Inspect dependencies, binary
content and task-specific private disclosures separately. Tool/read failures
block the operation; they are not a clean audit. Keep audit output local rather
than pasting it into public prose. This command is for public candidates, not
for publishing the intentionally private toolkit to its designated source branch.

## What online checks establish

Report what the configured jobs actually executed, not all tests in the repository.
For the product build template examined at source
`8f2a6d9723eb6e762ec63e997207942e56d371a0`,
`build\pipelines\templates-v2\job-build-project.yml` runs WTA Cargo tests for x64
and x86 and skips that task for ARM64. Native compilation and MSIX validation
are not proof that native test bodies or all packaged UI/E2E suites ran.
Reinspect the selected revision when the pipeline configuration changes.

Build-feed or signing authorization is not an AI-provider account or quota.
CI tests must not rely on developer provider credentials. Interactive desktop,
packaged activation, clipboard and native test-host prerequisites must be declared;
they cannot be assumed from a successful hosted build.

Keep three evidence categories separate:

- Online CI: exact job/platform, command, executed counts, skips and exit status.
- Deterministic local integration: exact product binary/package, fixture and oracle.
- Real dependency acceptance: actual provider/user entrypoint and observed result.

One green category does not silently satisfy another category required by the
feature contract.

## Validation is scoped to the actual contract

Record `CHANGE_KIND`, `VALIDATION_PLAN`, `REAL_ACCEPTANCE_REQUIRED` and its reason
before implementation. Keep explicit authorization for a narrower plan when it
changes previously agreed gates; never infer a waiver from a convenient result.

| Change or acceptance target | Required evidence |
| --- | --- |
| Preparation, discussion or dev-only documentation | Accurate stage/scope, relevant document checks and remote proof if pushed; no product deployment or inference |
| Deterministic tests/tooling with unchanged product inputs | Actual focused/relevant tests and dependency checks; no automatic model request just because a Git HEAD changed |
| Product behavior | Focused RED/GREEN, relevant full tests/build and observable integration coverage for the affected layers |
| Real authentication only | Real user action and authenticated session/reconnect when required; producing a model token is not itself an authentication oracle |
| Real model/provider/tool contract | Real inference and required downstream effect on the exact approved product, in a dev/local-only runner |

Document/test-only publication uses the recorded proportional plan. If the existing
feature contract still requires a real acceptance gate, changing only tests or docs
does not waive it; record explicit disposition rather than manufacturing PASS.
An external-system feature cannot replace its required real workflow with a mock.

When product inputs change, build/deploy and validate the affected exact publish
HEAD with fresh fingerprints/hashes. If only validation/docs inputs changed,
reuse an earlier product artifact only with explicit product-versus-validation
provenance and verified unchanged product inputs. Never describe an old binary
as newly built from the validation HEAD. A changed product path, even a comment,
invalidates a byte-level source fingerprint.

Post-push real acceptance is required when the active contract says so. Keep
its exact-head, post-push ordering, budget, cleanup and privacy checks intact.
`Test-LocalTddAcceptance.ps1` validates the existing real-Copilot evidence contract;
it is not a universal completion checker for unrelated documentation/mock work.
Do not weaken that real-evidence schema to mark a non-real workflow accepted.

## Counts and acceptance status

For Pester reports distinguish:

- `discovered`: the result's complete test inventory.
- `selected`: discovered minus filtered-out/not-run tests.
- `executed`: passing, failing or inconclusive outcomes; skipped cases do not
  establish executed coverage, even if a runtime skip guard ran.
- `filteredOut`, `passed`, `failed`, `skipped`, `inconclusive` and setup/cleanup
  failures, with the actual runner exit code.

`Invoke-LocalTddReport.ps1` writes these fields to `summary.json`, Markdown and
HTML. No selected tests, no executed tests, inconclusive results and setup/cleanup
failures are non-green. `-AllowSkipped` is explicit caller disposition, not
permission to call an all-skipped run a pass. A mixed accepted-skip run is
`passed_with_skips`, not proof that the skipped contract was verified.

Check required exact test names and measurable oracles, not only passing totals.
Pair UI positives with negatives: a toast must not match its numeric count,
an empty draft can contain a placeholder, and instructions must match available
actions. A parser-only test does not establish SDK/wire dispatch.

Main's release-report `[x]` inventory can retain earlier unit coverage; it is not
the number of tests executed in this E2E run. Compare checklist rows in their
original order and retain repeated IDs rather than collapsing them into an
ID-keyed dictionary. A faulty private comparator does not establish a defect in
the public report generator.

Keep environment, fixture and product failures distinct. A native host failing
before assertions is not behavior RED. Preserve the error and an unchanged
canary result; a successful build does not prove execution. A usable host that
exposes an unmounted rendered fixture is a fixture failure, not another external
skip. Alternative-runner evidence names its actual revision and executed bodies;
it never relabels the original blocked run or a newer revision as passed.

## Manual-test handoff and retained ownership

Use existing configuration transactions and exact-process protections; a failed
handoff is not permission to weaken them or rewrite product defaults.

1. Verify the requested source, installed package and payload. Reuse an already
   matching deployment rather than rebuilding merely to repeat a handoff.
2. Finish owned fixture cleanup and confirm prior configuration bytes or prior
   absence were restored. Restore only when the existing inactivity/ownership
   checks permit it. If blocked, preserve the verified backups and report the
   conflict; never adopt an unowned process or overwrite concurrent user state.
3. Launch through the normal registered entrypoint without this run's test
   profiles or fixture overrides. Verify the exact package, executable path,
   process creation time, PID/HWND and responsive window before handing it over.
4. Persist `USER_MANUAL_RESERVED`, `UserControlled=true`,
   `AutomaticInputAllowed=false` and `AutomaticCleanupAllowed=false` with that
   identity in ignored/session state. This is an ownership transfer: earlier
   test-window close permission does not authorize later input, settings edits,
   deployment replacement, process shutdown or worktree/package cleanup.
5. Resume automation only after a new explicit release/authorization and fresh
   identity checks. "Tested, works" confirms only the stated manual path; it is
   neither blanket acceptance nor permission to reclaim the app.

## Stages, issues and safety

Preparation and paused discussion are real stages. Commit/push permission for
records does not authorize implementation, provider calls or a product PR.
Finish the explicitly requested preparation task, then stop when instructed;
do not restart it because of a generic completion reminder or watchdog tick.

Keep issue classification independent of test status: observed report,
source-confirmed mismatch, reproduced defect, external blocker and closed
expected behavior are different facts. Preserve versions/source/entrypoint and
initial failed evidence. Do not generalize one old provider capture to all versions.
Close a finding when new evidence disproves it; do not keep it on the repair list.

Re-resolve package registration, install location, binary hashes and process
ownership before each live phase. A historical receipt is not current installation
proof or permission to adopt a user process. Never switch to Store silently.
Protect the current chat, authenticated providers and unrelated worktrees.

Track engineering completion, human approval, PR lifecycle and runtime ownership
separately. `ENGINEERING_COMPLETE`, `AWAITING_HUMAN_REVIEW`, `MERGED` and
`USER_MANUAL_RESERVED` are not interchangeable. If a PR transitions during a
poll, re-read its final head/state before any follow-up. Merge/closure stops only
the task's watcher; it does not release a manual app or authorize cleanup.

Review completeness is established by exact-head findings/annotation triage and
code evidence, not shared-account reply counts. Keep reviewer-owned threads open;
do not post routine acknowledgements, self-approve or merge to satisfy tooling.

Review snapshots include complete fetched bodies and actual check annotations,
even for successful checks. Incomplete review/thread/check pagination and failed
annotation retrieval are not empty finding inventories. Inspect the contents,
not just a "No open issues" heading or a parser flag; retained discussions and
human approval remain separate from engineering acceptance.

The conflict inventory in `PRACTICE-CONFLICTS.md` distinguishes adopted corrections
from questions still requiring discussion. Keep maintenance commits out of feature
publish branches.
