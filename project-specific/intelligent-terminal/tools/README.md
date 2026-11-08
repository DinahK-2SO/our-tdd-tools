# Portable Local TDD Kit

This retained toolkit belongs to the Intelligent Terminal project profile.
Its source is `project-specific\intelligent-terminal\tools`; setup materializes it
at `.winpd\project-specific\intelligent-terminal\tools` in the dev worktree only.
Historical command examples below use `local-tdd-kit`; substitute the installed
toolbox path when using those examples in a generated workspace.

Shared process/evidence, Windows identity, request-ledger and GitHub observation
implementations now live in `common\tools` in the bundle. This project keeps its
legacy function entrypoints as adapters. Retain the complete common/project layout
when adopting or validating the toolkit; do not copy this project directory alone.

A self-contained, local-only test-driven-development kit for Intelligent Terminal.
It is designed to be cherry-picked as one commit onto an issue branch. It does not
register online automation and is not intended to merge into `main` unchanged.

## Fresh Machine

```powershell
# After cherry-picking the kit commit:
local-tdd-kit\install-tools.cmd
pwsh -File local-tdd-kit/bootstrap.ps1 -Check

Invoke-Pester local-tdd-kit/selftests/ItE2E.Unit.Tests.ps1 -Tag Unit
Invoke-Pester local-tdd-kit/selftests/ItE2E.Input.Tests.ps1 -Tag Input
```

Copy `TDD-WORKFLOW.template.md` into the issue's dev-only tracking location and
replace every placeholder before changing product code.

Read `TEST-BOUNDARIES.md` for publishable tests versus current CI execution and
`PRACTICE-CONFLICTS.md` for template corrections and remaining discussion points.

Before extracting lessons into main, classify the actual failure and existing
support using `TEST-BOUNDARIES.md`. A feature-fixture mistake, private comparator
bug or private screenshot requirement does not establish a public-framework gap.
Strengthen the relevant mechanism and its failure cases, not another acceptance system.

For a local-only investigation that must not add the kit to the feature diff,
copy the kit contents to an ignored `.local-tdd-kit-run\kit` directory instead.
Add `.local-tdd-kit-run/` to the repository's local Git exclude, record the
source kit commit in the task handoff, and run the copied selftests before use.
The selftests are location-independent; reports and provider evidence remain
under the ignored `.local-tdd-kit-run\artifacts` tree.

## Live Validation

An installed Intelligent Terminal package and an unlocked interactive desktop are
required. Pin the package under test:

```powershell
$env:ITE2E_PACKAGE = 'Dev'
Invoke-Pester local-tdd-kit/selftests/ItE2E.Live.Tests.ps1 -Tag Live
Invoke-Pester local-tdd-kit/selftests/ItE2E.AgentInput.Tests.ps1 -Tag AgentInput
```

`AgentInput` uses a local deterministic ACP fixture. It requires no provider login,
credential or network model response. It does not substitute for a contract-required real gate.

### UI keyboard regression evidence

For a focus or selection regression, record the physical key, the visible focused row and
its owning process, and the active tab ID separately. A row can receive focus without
being selected; checking only the active terminal can hide premature focus transfer.
Check both filtered and unfiltered lists, activation by Enter and pointer, and at least
one similar chord that must not activate (for example Ctrl+Enter). Send each tested chord
once; retrying a toggle can reverse a delayed successful action.

Classify a package that cannot start or a TAEF/UAP test host that cannot attach as
BLOCKED, not as a behavior RED. Compile the owning test, compare an unchanged canary,
and preserve the host error before treating any focused assertion as evidence. A
deterministic keyboard/UI case does not consume inference. Run a separate real gate only
when the contract requires it; retain explicit scoped dispositions of established gates.
Do not retroactively record an unrun gate as PASS.

For manual testing, follow the handoff in `TEST-BOUNDARIES.md`: verify the requested
deployment, restore owned fixture configuration, then transfer the normal app to
`USER_MANUAL_RESERVED`. A successful manual check does not release the app for
automatic input, redeployment or cleanup.

## Applicable Post-Push Acceptance

Record change kind, validation plan and `REAL_ACCEPTANCE_REQUIRED` with its reason.
Preparation/docs do not trigger deployment/inference by a new Git HEAD alone.
Deterministic tests/tooling run the applicable suites; product changes require affected-layer
build/integration evidence. Publishability does not prove the online pipeline executed a test.
Any narrower disposition of established gates must be explicit, not an implied PASS.

When real dependency acceptance is required, build/deploy **after push succeeds** and execute
its actual oracle on that exact product. Authentication-only acceptance proves real user
authorization and a usable session; real-model/tool acceptance additionally needs inference
and required side effects. Fixtures and unauthenticated handshakes cannot replace either.

Read the PR and remote publish heads before starting and after finishing; both must equal the clean
publish worktree's full SHA and this run's build/deploy/inference evidence. If the published HEAD
advances while the real gate is still required, rerun it before claiming that acceptance.
Use normal product entrypoints and a feature-specific observable outcome. Required user sign-in
is completed by the user, not automated credential handling. Inference uses an already authenticated
provider/model and a confirmed finite budget. Record fresh hashes, applicable real evidence and
inspected screenshots; restore settings/clipboard and scoped fixtures without altering credentials.

Any real-login/account/credential dependency is dev/local-only, even zero-token, as are
model-consuming harnesses, configuration and reports. Neither belongs in publish, formal
`test/e2e` or indirect CI calls. The existing pipeline can run an explicitly selected
local-only real-token suite via `-E2EPath`; its generic success status does not by itself establish
remote-head equality or real inference. Those remain required for that real contract.
Missing prerequisites/evidence or failed behavior blocks readiness. Only an explicit user
deferral/waiver for a named iteration can pause this requirement; record its scope, not a false PASS.
See `TDD-WORKFLOW.template.md` for the complete gate and required provider/task/budget fields.

## Build and Deploy

```powershell
pwsh -File local-tdd-kit/Invoke-BuildDeploy.ps1
pwsh -File local-tdd-kit/Verify-DeploymentFreshness.ps1
```

Read `BUILD-DEPLOY-E2E.md` before trusting a packaged E2E result. A green build alone
does not prove that the installed package or live processes contain that build.
Running exact-package processes are never closed implicitly; use
`-CloseRunningPackageProcesses` only when the run owns those processes.

Agent-driven runs must remain continuous across non-conflicting questions and status requests.
Keep an active-task ledger, answer the interruption briefly, then execute the next incomplete
action in the same response. Missing or truncated helper output is `unknown`: recover from the
owned terminal or durable pipeline journal first, and rerun only cheap idempotent checks.

### Phase-aware autopilot watchdogs

Before publication, use the **Pre-PR Prompt** in `TDD-WORKFLOW.template.md`.
After publication, use **Online PR review monitoring** in the generated dev-root
`AGENTS.md`, sourced from `common\templates\AGENTS.md` in the toolkit repository.
That shared workflow uses Copilot's built-in `/every` with a specific prompt;
there is no separate project polling script or recurring review prompt.
The default cadence is **30 minutes**, with a **one-hour no-progress ceiling**
for pending Terminal work. Recover at the current check when a task is
already idle for 30 minutes or its deadline expires before the next check; a watchdog
tick alone never resets that deadline.

Before publication, advance implementation, validation and the task's dependencies.
Do not resume a `PAUSED_USER_DISCUSSION` task because of a timer or completion reminder;
maintenance of this toolkit does not unpause an independent feature.
Do not inspect main/base before publication. After publication, reuse the existing
review/CI monitor and inspect main/base only for actual conflicts; resolve confirmed
conflicts without rewriting history. Never rebase unless the user explicitly asks,
and never rebuild or spend another request merely because main advanced. Keep the
watcher active while the PR is open. Replace the schedule at the phase transition rather
than running two writers. Record real scheduler identity and substantive progress
in local-only state; preserve process ownership, the current chat, dirty work,
credentials, paid-request budgets and human/write authorization.

For an uninterrupted bounded build/deploy/freshness/E2E cycle, use the durable runner:

```powershell
pwsh -File local-tdd-kit/Invoke-LocalTddPipeline.ps1 `
	-E2EPath test/e2e/tests/<Feature>.Tests.ps1

pwsh -File local-tdd-kit/Get-LocalTddPipelineStatus.ps1 `
	-JournalPath local-tdd-kit/artifacts/pipeline-<HEAD>-<UTC>/pipeline-state.json
```

The runner replaces its phase journal atomically so readers never observe partial JSON. It records
preflight, build/deploy/freshness, optional packaged E2E, and final source-fingerprint verification.
It deliberately does not pass `-Launch` to the build script; E2E
owns the exact window launch. An AI coding agent must still invoke the runner with synchronous
terminal execution and no tool timeout. The journal lets a later turn distinguish `passed`,
`failed`, live `running`, abandoned `interrupted`, and semantically corrupt `invalid` state, but
it cannot wake an agent turn that was already ended. If VS Code or the execution
host terminates the runner process, machine-side continuation also stops and status becomes
`interrupted`.

### WTA-only refresh

When only WTA changed, use a verified native build receipt and an exact clean source worktree:

```powershell
pwsh -File local-tdd-kit\Invoke-WtaRefresh.ps1 `
    -RepoRoot <CLEAN_PUBLISH_WORKTREE> `
    -NativeReceiptPath <PRIOR_NATIVE_BUILD_RECEIPT> `
    -OutDir <NEW_IGNORED_RUN_DIRECTORY>
```

The refresher builds the explicit MSVC target again; it does not relabel an old WTA binary.
It requires a full-scope, clean-source native receipt, unchanged native inputs and artifact hashes,
an unchanged package recipe, and one unused Dev registration at the recorded layout.
Only WTA's recipe source, staging file and installed file are refreshed. The receipt records the
fresh Cargo output separately when the clean source worktree differs from the installed layout.
The existing freshness verifier checks the resulting transfer hashes and preserved manifest.

There is no package registration, removal, version change, process shutdown, worktree switch or
stash operation. A refusal does not fall back to full deployment. Partial WTA writes are rolled
back, rollback failure is explicit, and concurrent user configuration changes are never overwritten.
Prepare the clean source worktree separately; this command will not rearrange dirty user work.
It preserves existing registration but does not diagnose or repair COM activation.

The durable pipeline can select the same path without calling the full deployment script:

```powershell
pwsh -File local-tdd-kit\Invoke-LocalTddPipeline.ps1 `
    -WtaOnly -NativeReceiptPath <PRIOR_NATIVE_BUILD_RECEIPT> `
    -E2EPath <FEATURE_TEST_PATH> -OutDir <NEW_RUN_DIRECTORY>
```

`-WtaOnly` rejects Release, `-SkipDeploy`, registration replacement and caller-narrowed source
scopes. `-SkipWtaTests` is available only when the owning workflow already accounts for those
tests; WTA product compilation is never skipped. The ordinary full-build path is unchanged.

### Bounded real-provider driver

`Invoke-LocalTddRealAcceptance.ps1` implements the existing post-push requirement for local
Copilot scenarios. It is not the optional `AiOracle.ps1` judge and is not part of formal E2E/CI.
Copy the JSON examples into ignored evidence, fill the publication identity and observed push
completion time, and obtain explicit approval for the task-scoped request limits:

```powershell
pwsh -File local-tdd-kit\Invoke-LocalTddRealAcceptance.ps1 `
    -RepoRoot <CLEAN_PUBLISH_WORKTREE> `
    -PublicationPath <PUBLICATION_JSON> -ReceiptPath <FRESH_DEPLOYED_RECEIPT> `
    -ScenarioPath <LOCAL_SCENARIO_PS1> -AuthorizationPath <APPROVED_BUDGET_JSON> `
    -BudgetPath <PERSISTENT_TASK_LEDGER_JSON> -OutDir <NEW_REAL_RUN_DIRECTORY> `
    -AllowRealInference
```

Both the switch and `approved: true` are required. The ledger reserves a request before attempting
submission and retains all outcomes. An interrupted reservation remains charged: there is no
automatic refund or retry. `totalLimit`, `perHeadLimit` and `timeoutSeconds` come from the explicit
authorization; increasing a limit never deletes earlier attempts.
The example authorization uses the general autopilot baseline `totalLimit: 8`,
`perHeadLimit: 2`, and `timeoutSeconds: 600`: up to four publish iterations with one diagnosed
retry per HEAD, while preventing an individual real-provider request from waiting indefinitely.
Use a smaller task-scoped window when the scenario needs fewer iterations; increases remain
explicit and retain every earlier attempt in the ledger.
If the user explicitly leaves the task-total budget uncapped, still authorize only a finite next
invocation and retain its deadline and cumulative ledger. Record that this is an operational
window, not a user-imposed task-total cap. Diagnose each retry before extending that window.

A scenario returns five callbacks: `Prepare(context)`, `Submit(context)`,
`HandleAction(context, action)`, `Verify(context)` and `Cleanup(context)`. Mutable state belongs
in `context.state` so cleanup can recover even after partial preparation. `Prepare` returns the
Copilot session ID, absolute JSONL event path, exact expected prompt and allowed command strings.
The provider may create that file only after submission. The runner never creates provider logs:
it waits within the same request deadline, requires actual matching request/response records,
and records whether the log was observed. A disappearing observed log or invalid complete record
fails explicitly; a log that never appears cannot pass or refund a submitted request.
`HandleAction` returns `pending` or `performed`, after verifying and driving the owned UI.
`Verify` returns `pending`, `failed`, or `passed` with equal string `expected`/`actual` values;
use exact text or a digest of the actual feature result. `Cleanup` must explicitly return true.
Callbacks must use bounded operations and preserve settings, clipboard, keyboard layout,
authentication and non-test processes.

`examples\RealUser.Marker.ps1` demonstrates a packaged Agent Pane to real Copilot to marker-file
round trip. It reuses the selected source worktree's current ItE2E and keyboard/clipboard helpers,
not a second harness. Missing helpers or invalid session/path metadata fail before request reservation. The example
uses the normal Copilot state directory; provide a task-local scenario for a different configured
directory. Add the feature's physical action and oracle before treating it as feature acceptance.
The example's product-side module imports are global because its callbacks execute from a module
and configuration helpers use dynamic closures. The offline scope regression loads only a fake
module and stops before product setup; it is not live acceptance.

The driver understands the product's final `## User Request` envelope, not arbitrary prompt
substrings. It distinguishes intermediate tool completion, final model response, unresolved
permissions and terminal command proposals. Only exact allowlisted commands can be acted on;
permission IDs are processed in order and performed actions are not repeated. A completed model
response still cannot pass until the feature observable and cleanup succeed. Model identity comes
from response events, not the initial UI label; unavailable usage remains unavailable.
Exact source-text comparisons use `StringComparison.Ordinal`; PowerShell's case-sensitive
comparison can still treat different Unicode representations as equal.

### Scenario and workflow lessons

- Model completion, a tool side effect and a stable rendered UI are separate milestones. A
  physical scenario must wait for its product-owned visible state before reading coordinates,
  and read them again after layout changes. Do not reuse a thinking-state rectangle for a
  completed-turn header.
- A valid terminal-tool round trip can end with empty assistant text. Choose an independent
  observable (such as exact file contents) and a known unique visible anchor; do not require
  a guessed reply sentence or bullet format.
- For supplementary Unicode input, prefer the existing physical clipboard/paste helper and
  exact draft-copy assertion. Preserve full clipboard formats and keyboard layout; raw key
  injection is not automatically equivalent to Unicode typing or paste.
- Declare scope, non-goals and a validation budget before implementation and review. For a
  test/tooling-only change, propose focused offline checks and obtain any explicit waiver
  needed by the owning workflow. Record covered heads/scope and unrun gates; never relabel
  historical deployment or real-inference results as new acceptance.
- Keep one representative unit case per distinct contract where possible, using existing E2E
  cases for the actual integration boundary. Add variants when evidence or risk justifies them,
  not one new test framework or matrix per review comment.
- Classify review findings as introduced, directly coupled, or inherited/out of scope. A
  severity label does not authorize a lifecycle redesign. Fix introduced defects; agree scope
  before larger work, and preserve valid out-of-scope findings in a separate tracker. A reply
  or green check is not proof that the underlying risk is fixed.
- Follow the root template's PR-description style: concise English what/how and actual
  validation evidence, without internal progress, budget or coordination notes. Within an
  existing PR-delivery task, generate and maintain the agent-authored description
  without a separate wording-approval gate; preserve teammate edits and explicit user pauses.
- Short, courteous won't-fix replies linking a real follow-up issue can keep reviewers focused.
  Edit only your own replies and preserve thread state; keep detailed reasoning in local evidence.
- Audit release-report attribution, not just checkboxes or command exit codes. A short title
  can match an unrelated test name. Preserve raw output and flag unearned coverage separately;
  do not alter test results or silently patch an unrelated reporter to make the report green.

### Final acceptance evidence

`examples\acceptance.example.json` defines the data contract; it deliberately cannot pass until
its placeholders and triage fields are filled. Use `New-LocalTddEvidenceReference` from
`LocalTdd.Evidence.psm1` to generate exact file references rather than typing hashes.
NUnit reports must be bound to the same head and deployment through their pipeline journals.
Current accepted reports must be nonempty and entirely passing, and include every required exact
test name. Mixed-failure or skipped reports are not silently overlaid with later results; retain
them as historical evidence and use explicit isolated passing runs for current acceptance.

When `contract.visual.required` is true, provide a current-head visual inventory with `head` and `images`. Each image has
`path`, `sha256`, Boolean `actual_pixels_available`, `inspection_status: "PASS"` and
`visual_integrity_status: "PASS"`. List every required original in `visual.requiredFrames`.
An image-limit placeholder, OCR, hash or contact sheet is not a pixel inspection. Keep baseline
RED and other historical images separately identified rather than relabeling them as current.
When false, no image inventory is required. This private gate does not change main's
best-effort screenshot helper or introduce a public screenshot/inspection requirement.

```powershell
pwsh -File local-tdd-kit\Get-LocalTddReviewSnapshot.ps1 `
    -PublicationPath <PUBLICATION_JSON> -OutPath <NEW_REVIEW_SNAPSHOT_JSON>
# Read the complete snapshot and spelling annotations; record the disposition in the contract.
pwsh -File local-tdd-kit\Test-LocalTddAcceptance.ps1 `
    -RepoRoot <CLEAN_PUBLISH_WORKTREE> -ContractPath <FILLED_ACCEPTANCE_JSON> `
    -OutPath <NEW_FINAL_ACCEPTANCE_JSON>
```

The final command verifies post-push ordering, artifact hashes, exact required cases, real
inference/observable/cleanup evidence and actual pixel-review declarations. It then rechecks the
current source/remote/PR/deployment and hashes a fresh version-2 review/check/thread snapshot
against the triaged one. It includes full review bodies and all check-annotation pages,
including warnings from green checks and checks owned by another repository. Truncated
collections, annotation retrieval/count failures and head/lifecycle changes during collection
fail explicitly. Changed or untriaged reviews/checks block closure; a shared-account reply is not
a gate and retained active threads are not automatically failures. Nothing is resolved,
dismissed or merged. Triage and screenshot declarations remain the reviewer's responsibility,
not conclusions inferred from a green check or a saved PNG. Human approval is reported separately.
Version-1 snapshots remain historical evidence: collect and triage a new version-2 snapshot;
do not edit a version field or relabel an old hash to claim annotation coverage.
This is the existing real-Copilot evidence contract, not a universal completion validator for
preparation, documentation, mock or authentication-only workflows. Do not fabricate real evidence
to satisfy it or weaken its real-inference schema for a different task.
PR metadata edits can create a new successful policy/check run without changing source. Compare
the new snapshot with the triaged one: inspect changed conclusions/annotations, retain the old
snapshot, then capture a fresh closing snapshot. Do not ignore the mismatch or rerun deployment
and inference merely to resolve a review-metadata-only change.

For offline tooling selftests, use the documented Pester entry point in a fresh shell:

```powershell
Invoke-Pester -Path local-tdd-kit\selftests -Tag Unit
```

These tests use synthetic packages, mocked Cargo/identity reads and local event replays. They do
not compile/deploy the product, manipulate live windows or submit model requests. Avoid wrapping
the selftests in another report runner: nested report selftests intentionally inherit an explicit
`ITE2E_ARTIFACT_ROOT`, so an outer artifact override changes their default-directory assumptions.

The report runner sets `ITE2E_ARTIFACT_ROOT` to `<OutDir>\artifacts`. Tests should use
`Get-ItArtifactPath` instead of issue-specific environment variables or fixed `current`
directories, so RED, GREEN, and exact-publish evidence cannot overwrite one another.
`summary.json`, Markdown and HTML distinguish discovered, selected, executed and filtered-out
counts plus passed/failed/skipped/inconclusive outcomes. Zero selection/execution, inconclusive
results and setup/cleanup failures are non-green. By default any selected skip is also non-green.
Use `-AllowSkipped` only when the caller explicitly accepts skips for that diagnostic run; never
use it for a required acceptance gate. An allowed mixed run is `passed_with_skips`, not "all passed";
allowing skips never makes an all-skipped run pass.

For an investigation, historical comparison or explicitly user-waived iteration, record a
product/validation split instead of claiming that an old package came from a later HEAD:

```powershell
pwsh -File local-tdd-kit/New-LocalTddValidationProvenance.ps1 `
    -ReceiptPath <PRODUCT_BUILD_RECEIPT> `
    -OutPath <RUN_ARTIFACTS>\validation-provenance.json `
    -RequireReusable
```

The command permits reuse only when the receipt's product HEAD is an ancestor, its recorded product
source paths are unchanged, and the validation worktree has no scoped dirty or untracked files.
It proves source equivalence only. A scoped tests/docs plan may reuse unchanged product inputs
with this explicit split, never claiming the old binary was built from the new validation HEAD.
It does not automatically waive any contract-required exact-head or real-acceptance gate.

## Public content preflight

Before a publish push or authorized public-text write, run
`Test-LocalTddPublication.ps1` as documented in `TEST-BOUNDARIES.md`. It audits the
complete new commit range and proposed title/body/comment files, returning pinned
commits and exact text hashes. Keep it in the private kit; do not import it into
publish to make tests run. It catches known private markers, not arbitrary secrets
or all dependency leaks, and never performs or authorizes the public write.

## Dev/publish reference isolation

Do not commit the publish pull-request number, URL, review-thread identifier, or a GitHub URL to the
publish branch into dev-only files or dev commit messages. GitHub can surface those references on a
public review timeline, including the surrounding dev-only text.

Keep the exact identifiers in the current process environment or ignored local evidence, then run
this before every dev push:

```powershell
pwsh -File local-tdd-kit/Test-DevPublishReferenceIsolation.ps1 `
    -BaseRef <DEV_REMOTE>/<DEV_BRANCH>
```

The script reads `LOCAL_TDD_PUBLISH_PR_NUMBER` and `LOCAL_TDD_PUBLISH_BRANCH`, scans every dev-only
commit message and added patch line after the base, and also scans current changed/untracked text
files. Safe blank patch lines and empty text files are valid input. A script or parameter-binding
error is a tooling failure, not a reference finding or a successful scan; fix it before push.
If a reference was already published, obtain explicit
user approval before rewriting history and use exact `--force-with-lease`; a rewrite does not
guarantee deletion of an existing public timeline event.

## Documents

- `TDD-WORKFLOW.template.md`: issue workflow template and placeholders
- `TEST-BOUNDARIES.md`: real-login exclusion, CI scope, applicability and honest result counts
- `PRACTICE-CONFLICTS.md`: observed template/tool conflicts, corrections and unresolved discussion
- `TOOLS.md`: tools, installation, APIs and input safety
- `BUILD-DEPLOY-E2E.md`: project layers, known failure modes and freshness gates
- `Invoke-LocalTddPipeline.ps1`: durable bounded workflow and atomic phase journal
- `Get-LocalTddPipelineStatus.ps1`: passed/failed/running/interrupted/invalid classification
- `New-LocalTddValidationProvenance.ps1`: product-HEAD versus validation-HEAD reuse manifest
- `Invoke-WtaRefresh.ps1`: constrained WTA-only build/refresh and rollback journal
- `Invoke-LocalTddRealAcceptance.ps1`: opt-in, budgeted Copilot request driver with feature callbacks
- `Get-LocalTddReviewSnapshot.ps1`: read-only material for explicit review triage
- `Test-LocalTddAcceptance.ps1`: exact-head evidence and current-state closing gate
- `Test-LocalTddPublication.ps1`: read-only public-candidate history and prose preflight
- `Test-DevPublishReferenceIsolation.ps1`: pre-push guard against dev-to-publish GitHub autolinks
- `FRAMEWORK-SOURCE.md`: snapshot provenance and update policy
- `examples/Feature.Template.Tests.ps1`: generic Pester starting point

## Artifact Policy

Everything under `local-tdd-kit/artifacts/` is ignored except its `.gitignore`.
Do not commit credentials, prompts, provider configs/homes, wire captures, logs,
screenshots, local paths or account identifiers. Sanitize and deliberately copy only
the small evidence selected for review.