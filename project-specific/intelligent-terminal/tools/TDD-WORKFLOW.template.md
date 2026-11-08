# Local TDD Workflow Template

## Fill These Before Starting / 开始前必须替换

- `<LOCAL_TRACKING_LABEL>`: non-linking local label for the issue or regression
- `<USER_VISIBLE_CONTRACT>`: behavior that must remain true
- `<BASE_REF_AND_HASH>`: clean base used for the work
- `<DEV_BRANCH>`, `<PUBLISH_BRANCH>`, `<REMOTES>`, `<WORKTREES>`
- `<OWNING_CODE_PATH>`: code that directly computes or mutates the behavior
- `<CHEAP_DISCRIMINATING_CHECK>`: smallest check that can falsify the hypothesis
- `<RED_TEST_NAME>` and `<FOCUSED_TEST_COMMAND>`
- `<BUILD_SURFACES>`: WTA, SettingsModel, SettingsEditor, TerminalApp, protocol, package
- `<LIVE_E2E_CASES>` and `<PACKAGE_SELECTOR>` (normally `Dev`)
- `<REAL_USER_E2E_COMMAND>`, `<REAL_PROVIDER_MATRIX>`, `<REAL_USER_TASK>` and
  `<REAL_USER_EVIDENCE_DIR>`: applicable dev/local-only real dependency acceptance
- `<REAL_USER_COST_BOUND>`: confirmed finite invocation budget when real inference is required;
  authentication-only work must not invent token consumption
- `<LOCAL_ARTIFACT_DIR>` and `<SENSITIVE_DATA_RULES>`
- `<DEFINITION_OF_DONE>`
- `<CHANGE_KIND>`, `<VALIDATION_PLAN>` and `<COVERAGE_BUDGET>`: agreed scope and proportionate coverage
- `<REAL_ACCEPTANCE_REQUIRED>` and `<REAL_ACCEPTANCE_REASON>`: explicit applicability and disposition

Remove instructions that do not apply. Add issue-specific invariants, failure
signatures, environment prerequisites and exact acceptance oracles. Do not leave
angle-bracket placeholders in an active workflow.

Read `TEST-BOUNDARIES.md` for publication eligibility versus execution environment and
`PRACTICE-CONFLICTS.md` for adopted corrections and open policy questions. Do not expose the
unpublished framework, its paths or private machine-acceptance status in public deliverables.

## Task Contract

- Local tracking label: `<LOCAL_TRACKING_LABEL>`
- User-visible contract: `<USER_VISIBLE_CONTRACT>`
- Regression signature: `<EXACT_OLD_FAILURE>`
- Negative control: `<SIMILAR_INPUT_THAT_MUST_NOT_TRIGGER>`
- Owning code path: `<OWNING_CODE_PATH>`
- Integration boundary: `<PROCESS_PROTOCOL_UI_OR_PERSISTENCE_BOUNDARY>`
- Oracle priority: protocol/event, persisted state, structured log, rendered UI,
  then model output only when model output is itself under test.
- Change kind / validation plan: `<CHANGE_KIND>` / `<VALIDATION_PLAN>`
- Real acceptance required / reason: `<REAL_ACCEPTANCE_REQUIRED>` / `<REAL_ACCEPTANCE_REASON>`
- Current stage: `<CURRENT_STAGE>`; distinguish `PREPARATION`, `PAUSED_USER_DISCUSSION`, RED,
  implementation and acceptance. Preparation completion is not product completion.
- Track `ENGINEERING_COMPLETE`, `AWAITING_HUMAN_REVIEW`, PR lifecycle and
  `USER_MANUAL_RESERVED` separately; none grants another task's permissions.

### Live package selection

For an unshipped PR, default to `Dev` built and deployed from the exact publish HEAD.
Do not ask merely to choose Dev or Store: the PR under test determines the target.
An already installed Dev package or `Auto` cannot establish PR freshness; verify
source, staging, package, installed and live identities before the test. Set
`$env:ITE2E_PACKAGE = 'Dev'` in the same process as each live validation command.
Use Store only when the user explicitly requests a production baseline; label
those results as a baseline, never validation of unshipped PR code. Outside a PR,
ask if the target package is ambiguous. A default target does not authorize
closing user windows, uninstalling packages, or discarding settings.

### Authorized Dev window closure

Record the user's standing permission for Dev test-window closure in the active
task contract. Once granted, honor it without repeatedly asking. Classify
`WindowsTerminal.exe` processes by their installed package family and full
`Win32_Process.ExecutablePath`, not by process name:

| Product | Package family | Dev-test close permission |
| --- | --- | --- |
| Ordinary Windows Terminal | `Microsoft.WindowsTerminal_8wekyb3d8bbwe` | Never covered |
| Store Intelligent Terminal | `Microsoft.IntelligentTerminal_8wekyb3d8bbwe` | Never covered |
| Test Intelligent Terminal Dev | `IntelligentTerminal_rd9vj3e6a2mbr` | Covered only by an explicit standing permission |

Resolve Dev's current `InstallLocation` with `Get-AppxPackage`. Before closing,
record and immediately recheck the exact PID, `ExecutablePath` under that root,
and `CreationDate`; reject unknown paths and any PID in the current chat ancestry.
Try a graceful `CloseMainWindow` first. If it does not exit, recheck all
identities before `Stop-Process -Id <PID>`; never stop by name or terminate
Store, stock Terminal, or the chat for a Dev test. Re-enumerate to confirm the
owned Dev process exited, and preserve the latest settings/state before E2E.
This permission does not authorize uninstalling a package or clearing data.

### Manual-test handoff

Follow `TEST-BOUNDARIES.md` before handing a normal app to the user. Verify the
requested deployment and restore this run's fixture configuration using the
existing ownership/inactivity guards; retain backups if restoration is blocked.
Record `USER_MANUAL_RESERVED`, `UserControlled=true`, `AutomaticInputAllowed=false`
and `AutomaticCleanupAllowed=false` with fresh package/process identity in local
state. Earlier Dev-close permission does not override this transfer. A manual
success report covers only that path and does not authorize reclaiming the app.

## Branch and Scope

- Base: `<BASE_REF_AND_HASH>`
- Dev branch/worktree: `<DEV_BRANCH>` / `<DEV_WORKTREE>`
- Publish branch/worktree: `<PUBLISH_BRANCH>` / `<PUBLISH_WORKTREE>`
- Production / canonical repository remote: `<PRODUCTION_REMOTE>`
- Personal / fork repository remote: `<PERSONAL_OR_FORK_REMOTE>`
- Remote policy: `<REMOTES_AND_PUSH_POLICY>`
- Fill every branch-to-remote mapping explicitly; remote names are environment-specific.
  If a personal/fork remote exists, ask which non-publish branches should use it. If it
  does not exist, ask whether to add one. When the user declines or the project does not
  use forks, the personal/fork, dev, and publish fields may all explicitly name the same
  production repository remote.
- Push each branch only according to the filled mapping; never silently substitute a
  different remote.
- After each push, verify that the exact local SHA matches the intended remote branch.
- Product commits contain product behavior and durable tests only.
- Classify test code by dependencies, not directory names. Publish only regressions
  that run independently on frameworks already public in the target base. The
  unpublished TDD framework and its selftests, runners, acceptance scripts and
  experiments remain dev-only. Verify dependency resolution and test discovery in
  a clean publish worktree without the private kit; do not copy it in to make tests pass.
- Audit every new publish commit, not only the final tree. Private framework code,
  configuration, harnesses and artifacts must never appear in publish history and
  then be deleted by a later commit. Publishing shared framework code needs separate
  explicit authorization.
- Before each publish push or authorized public-text write, run
  `Test-LocalTddPublication.ps1` from the private kit against the clean candidate
  history and exact draft files. Follow the preflight in `TEST-BOUNDARIES.md`;
  retain its pinned commits/text hashes locally and rerun after any edit.
  A known-marker pass does not replace dependency review or authorize publication.
- Local tracking, orchestration, captures and credentials do not enter publish commits.
- Any real login, credentials, preauthenticated account/catalog/session dependency or model/quota
  request is dev/local-only, even zero-token. Keep its source, runner, fixture configuration and
  indirect calls out of publish and CI. Authentication coverage in publish uses synthetic protocol
  inputs; do not install/sign in to a real CLI to make unit tests pass.
- Deterministic packaged UI/COM/ConPTY E2E in an existing public framework can publish even if
  the current online runner does not execute it. Report eligibility and actual execution separately.
- Never revert unrelated user changes in a dirty worktree.

### Scope and validation budget

- Record `<CHANGE_KIND>` (product / tests-tooling / docs / preparation), `<VALIDATION_PLAN>`,
  `<COVERAGE_BUDGET>`, `<REAL_ACCEPTANCE_REQUIRED>` and its reason, plus explicit in-scope/non-goals.
- Keep the full affected-layer gates for product changes. Preparation/docs use accurate records
  and relevant document checks; deterministic tooling uses actual focused/relevant suites.
  Run real acceptance only when the contract requires it. Obtain explicit authorization before
  omitting an otherwise required build/deployment, physical run or inference gate.
  Record date, covered heads/scope, unrun items
  and conditions requiring reassessment. Historical evidence is not a new-head PASS.
- Prefer one representative unit regression per distinct contract and reuse existing E2E boundary
  coverage. Add variants for demonstrated risk, not one matrix or new fake framework per comment.
- Review the whole diff when reducing scope or test volume. Being in a test directory does not make
  a general lifecycle/configuration redesign part of an interaction regression.
- Before proposing a shared/public-framework improvement, record the observed failure,
  owning contract, existing support, missing behavior and destination. Follow the lesson
  classification in `TEST-BOUNDARIES.md`; do not turn private policy or incorrect helper
  use into a new main-framework mandate.

### Dev-to-publish reference isolation

- Never place the publish pull-request number, full URL, review-thread identifier, or a GitHub URL
  to the publish branch in a tracked dev file or dev commit message. GitHub can turn that text into
  a public timeline reference and expose dev-only or non-English handoff content.
- Keep exact online identifiers only in session environment variables, ignored artifacts, or other
  local state. Do not replace template placeholders with those values in tracked dev history.
- Before every dev push, set the identifiers locally and run:

  ```powershell
  pwsh -File local-tdd-kit/Test-DevPublishReferenceIsolation.ps1 `
      -BaseRef <DEV_REMOTE>/<DEV_BRANCH>
  ```

  `LOCAL_TDD_PUBLISH_PR_NUMBER` and `LOCAL_TDD_PUBLISH_BRANCH` are read from the current process
  environment. Do not echo their values into tracked reports or commit messages.
- Blank patch lines and empty text files are valid scan input. A script or parameter-binding
  failure blocks push until the tool is repaired and rerun; it is neither a reference finding nor
  a successful scan.
- If the gate finds a reference, fix it before push. If the reference was already pushed, stop and
  ask the user before any history rewrite. Use a local backup and exact `--force-with-lease`; never
  assume rewriting history will remove an existing public timeline event.

## Baseline

1. Cherry-pick the local TDD kit commit.
2. Run `local-tdd-kit\install-tools.cmd` and `bootstrap.ps1 -Check`.
3. Record `git status`, base hash and tool versions; resolve current installed identity for live work.
4. Run the nearest existing test before edits: `<BASELINE_COMMAND>`.
5. If live behavior is involved, verify package freshness before trusting it.

## Strict RED/GREEN Loop

For product behavior changes, follow all applicable layers below. For preparation/docs or
deterministic tooling, follow the recorded proportional plan without fabricating a product
deployment or model request. Keep required but unrun gates explicit.

1. Add or modify the smallest test in the existing framework.
2. Run `<FOCUSED_TEST_COMMAND>` and require RED for `<EXPECTED_RED_REASON>`.
3. Make the smallest grounded product edit.
4. Immediately rerun the same focused command; do not widen scope first.
5. If it fails locally, repair the same slice and rerun.
6. Run the nearest module/project suite.
7. Build/deploy only the affected layers, then run freshness verification.
8. Run `<LIVE_E2E_CASES>` against explicit `<PACKAGE_SELECTOR>`.
9. Record test totals, build result, receipt hash and artifact paths.
10. Commit/push according to the branch policy and complete the iteration's applicable gates.
    Product-input changes need fresh exact-head build/deploy. Test/docs-only changes may use an
    explicitly recorded unchanged-product provenance split; established real gates are not
    silently waived.

### Focused runner and oracle guardrails

- An aggregate TAEF wrapper such as `runut` can execute multiple discovery or architecture
  phases. If the requested test body passes but another phase reports no matching tests and the
  process exits nonzero, the command is not GREEN. Run the source-built `TE.exe` directly against
  the exact DLL from its required runtime directory:

  ```powershell
  Push-Location <TEST_RUNTIME_DIRECTORY>
  try {
      & <SOURCE_BUILT_TE_EXE> <EXACT_TEST_DLL> '/name:*<TEST_CLASS>::<TEST_METHOD>*'
      if ($LASTEXITCODE -ne 0) { throw "TAEF failed with exit code $LASTEXITCODE" }
  }
  finally {
      Pop-Location
  }
  ```

  Require a nonzero discovered test count, the expected test PASS, and process exit code `0`.
  Record the wrapper mismatch separately as infrastructure evidence.
- Distinguish discovered, selected, executed, filtered-out and skipped counts. No execution,
  all-skipped, inconclusive and setup/cleanup failures are non-green; accepted mixed skips are
  `passed_with_skips`, not verified coverage of skipped contracts.
- Assert instructions and available actions together. UI text positives need boundary negatives
  such as a toast versus numeric queue count and an empty draft versus localized placeholder.
  Protocol regressions must exercise the SDK/serialization/dispatch handoff, not only parser calls.
- Derive locale, resource, fixture, provider and case inventories at runtime. Compare coverage
  with the discovered set; do not hard-code today's count. For `.resw`, separately verify XML,
  BOM, EOL, locked tokens and cross-locale `<comment>` parity.
- A narrow source-structure RED is acceptable for a missing call, ordering constraint or
  ownership mutation at a hard-to-host UI/event/save boundary only when the invoked helper already
  has behavioral unit coverage. After the source RED turns GREEN, compile the owning project and
  run neighboring plus packaged behavior; source shape is not the final behavior oracle.
- Run Windows diff checks as
  `git -c core.whitespace=cr-at-eol diff --check`. A default diff check can mistake CRLF's `\r`
  for trailing whitespace; the CRLF-aware check does not replace explicit resource encoding tests.
- For physical window input, call `Test-WtPhysicalInputReady` once before the action. Treat failure
  there as an explicit external prerequisite; after it passes, any focus/ownership loss is FAIL.
  Use `Invoke-WtWindowWheel` and `Get-WtTermControlBounds` rather than feature-local SendInput/UIA.
- For font, reflow and responsive-TUI assertions, use `Get-WtCaptureGeometry` with content long
  enough to span the viewport. Do not assume rendered row count changes when font size changes.
- Write screenshots, captures and identity JSON through `Get-ItArtifactPath`. The report runner
  supplies `ITE2E_ARTIFACT_ROOT`; do not use a shared `current` directory that RED/GREEN can overwrite.

## Build and Deploy

- Changed layers: `<BUILD_SURFACES>`
- Focused build commands: `<FOCUSED_BUILD_COMMANDS>`
- Package command: `<PACKAGE_BUILD_COMMAND>`
- Deployment command: `<DEPLOY_COMMAND>`
- Freshness command:
  `pwsh -File local-tdd-kit/Verify-DeploymentFreshness.ps1`
- Require explicit-target WTA and Cargo/AppX/installed SHA-256 equality.
- Require installed Dev layout and live process paths to belong to this worktree.
- Set `ITE2E_PACKAGE=Dev`; a skipped test is not GREEN.
- For bounded build/test/deploy/E2E work, use direct synchronous terminal execution with no tool
  timeout. Never leave a required phase in the background and end the agent turn.
- If a runner unexpectedly returns a terminal ID, record it; do not poll, sleep, or duplicate the
  command. Continue only independent safe work, then retrieve final output from the platform's
  automatic completion notification. Do not start deploy or another dependent phase until the
  real exit code is zero.
- Do not reuse the persistent shell that owns a handed-off terminal ID. A second command can
  interrupt the active batch with Ctrl+C; use read-only tools or a separately isolated terminal.
- Prefer `Invoke-LocalTddPipeline.ps1 -E2EPath <LIVE_E2E_CASES>` for an interruption-sensitive
  exact-package cycle. Record its `pipeline-state.json` path and require final status `passed`.
- Keep build/deploy non-launching. `-Launch` can steal foreground focus and visibly flash; let the
  E2E harness launch and bind the exact PID/HWND only when UI interaction starts.
- Keep an explicit active-task ledger while automation runs. A status request, explanation, or other
  non-conflicting interleaved question does not complete the workflow: answer it briefly, then resume
  the next incomplete action in the same response and issue an actual tool call. Do not send a final
  answer while required phases, checklist items, or terminal/journal states remain incomplete unless
  the user explicitly pauses or redirects the work.
- Treat missing or truncated command output as `unknown`, never as pass. If a persistent terminal ID
  exists, keep it exclusive and consume only its automatic completion result. Otherwise inspect the
  process identity and durable journal/receipt/report first. Rerun only a cheap, idempotent check with
  synchronous no-timeout execution and filtered output; do not duplicate an expensive build merely
  because an execution helper lost its summary.
- Changed product bytes, including comments, invalidate source fingerprints. For unchanged product
  inputs in a scoped tests/docs plan, record product and validation HEADs plus artifact hashes;
  never relabel an old binary as newly built from the validation HEAD or silently waive real gates.

## Post-Push Real Dependency Local E2E

Retain this section when `<REAL_ACCEPTANCE_REQUIRED>` is true under the active contract.
It is not triggered merely by a changed Git HEAD. Preparation/internal records do not deploy a
product; deterministic test/tooling changes use the explicit plan. Changing established gates
still needs user disposition, never a convenient "not run" relabeled PASS.

When applicable, run this gate after push on a fresh exact-head deployment. Authentication-only
acceptance proves actual user authorization and session/reconnect, without requiring a model token.
A real model/provider/tool contract must produce inference and its required downstream effect.
Both harness categories stay dev/local-only, even zero-token real login.

1. Read the PR and remote publish heads after push; both must equal the clean publish worktree's
   exact full SHA, not merely an ancestor. Record the push-completion time.
2. Build and deploy that exact HEAD after push, using the appropriate affected layers and a fresh
   receipt. Incremental builds are allowed; old deployments, parent receipts, Store packages and
   dev-branch binaries cannot replace this step. Pin Dev and prove source/staging/install/live hashes.
3. Record `<REAL_PROVIDER_MATRIX>` and `<REAL_USER_TASK>`. Use the authorized normal product entry;
   when the scenario needs user sign-in, the user completes it without agent credential handling.
   For inference, record a user-confirmed finite `<REAL_USER_COST_BOUND>`. Ask if required selection
   or budget is unclear; do not automatically log in, refresh, switch accounts or alter credentials.
   If the user explicitly leaves the task total uncapped, still use a finite next-invocation
   authorization/deadline and retain the cumulative ledger. That window is not a user-imposed
   total cap or permission for blind retries.
4. Run `<REAL_USER_E2E_COMMAND>` from a dev-only harness and assert the actual contract. Real-model
   acceptance needs inference and required side effects; mocks, replay, capability handshakes or
   verbal tool claims cannot substitute. Real authentication needs actual user authorization and
   usable session/reconnect, not just an unauthenticated handshake; do not force an unrelated token.
5. Keep real-login/account-dependent and token-consuming test source, runners, configuration and evidence out of publish,
   the formal `test/e2e` suite and CI, including indirect calls. A default deterministic suite or
   a green pipeline journal alone does not prove real inference occurred.
6. Record push/build/deploy/action/completion times, full publish SHA, package path/hash,
   provider/version, oracles and fresh inspected UI screenshots. For inference include
   model/backend, observable usage and budget.
   If usage is unavailable, say so instead of inventing counts; retain real request/response and
   behavior evidence. Restore settings, clipboard and provider configuration in `finally`, preserve
   authentication, and clean up only this run's processes/workspace.
7. Re-read PR and remote publish heads at completion. If either advanced while this real gate is
   still required, retain old evidence as history and rerun on the latest published HEAD.
8. Unmet behavior or cleanup is FAIL; missing external prerequisites are BLOCKED; missing evidence
   is UNKNOWN. None, including not-run, permits a ready-for-merge claim. Only an explicit user
   deferral/waiver for a named iteration may stop the gate: record date, SHA, scope and unrun items
   as deferred/waived, never PASS, and never extend that exception beyond its approved scope.
   If the user explicitly covers later iterations within a named tests/tooling-only scope, record
   each covered head without restarting waived gates. Reassess before product changes or any work
   outside that authorization; never generalize the exception to unrelated tasks.

## Local Evidence and Security

- Evidence root: `<LOCAL_ARTIFACT_DIR>`
- Keep raw logs, screenshots, wire captures and provider configs ignored.
- Never commit credentials, tokens, account identifiers, prompts, local paths,
  isolated provider homes or unredacted session data.
- Copy only intentionally selected, sanitized evidence to a tracked review folder.
- Do not delete ignored local evidence merely because it is absent from Git status.
- Compare exact prompts, commands and observables with `StringComparison.Ordinal`. PowerShell's
  case-sensitive equality can still equate different Unicode representations.
- Treat model completion, tool side effects and stable rendered layout as separate prerequisites.
  Reacquire geometry after UI transitions; use the existing physical paste path plus exact draft
  copy for supplementary Unicode rather than assuming raw-key injection preserves it.
- Check required executed cases and report attribution. Short title substrings can falsely credit
  unrelated behavior; preserve raw reports and explicitly exclude false credits from acceptance.
- Interpret inherited checklist `[x]` coverage separately from current execution and preserve
  repeated rows in private comparisons. `contract.visual.required` governs this kit's
  screenshot evidence, not main's public framework.
- Re-resolve package registration, install location, hashes and owned process identity before
  each live phase. A historical receipt is not current deployment proof; do not adopt a user
  process or silently switch to Store when a previously registered Dev package is absent.

## Review Hygiene

- Verify each review comment against the owning code path before accepting it.
- Fix valid findings; explain declined findings with concrete behavior evidence.
- Distinguish introduced defects, directly coupled issues and inherited/out-of-scope limitations.
  Agree scope before general framework work. Preserve valid deferred findings in a real tracker
  and link it courteously; do not keep growing the diff to satisfy a repeated review headline.
- Keep detailed triage and fix evidence local. The only permitted review comment is
  an evidence-based won't-fix explanation. Do not post fix acknowledgements, progress
  or status replies, delete comments, or overwrite teammate PR prose. Sharing the
  authenticated account does not establish text ownership.
- Inspect visible inline/file-level comments, every relevant review body including
  suppressed findings, and generated/suppressed counts.
- Read the raw review body and recognize current zero-comment wording such as
  `Comments generated: 0 new`. If a status helper disagrees with the raw body, record the review
  ID, exact HEAD, inline-comment count, suppressed-section presence and parser output. Treat the
  discrepancy as a tooling bug; do not retrigger review or relax exact-head, settled-check or
  finding-triage gates. Replies from the shared account are not a completion gate;
  never post acknowledgements merely to satisfy a helper's reply counter.
- Newer Open/New overview formats need the same complete-body triage; a single wording regex is
  not an authoritative finding inventory.
- Inspect spelling check conclusions, all annotations and relevant log summaries;
  distinguish repository content issues from external dictionary/network,
  generated-file and workflow warnings.
- Collect and triage a version-2 review snapshot with actual annotation inventories.
  A missing page, retrieval error or changed head/lifecycle is not an empty finding
  list. Preserve old snapshots instead of relabeling them as newly inspected.
- Keep the publish diff limited to current product behavior.
- Preserve historical reasoning in dev-only tracking, not stale product comments/tests.
- Keep exact online review identifiers in ignored evidence; tracked dev workflows use local labels
  and head SHAs only.
- Check `git diff --check`, line endings, generated files and exact dirty paths.
- A PR metadata edit can replace a successful policy/check run without changing source. Compare
  the changed snapshot fields, triage new conclusions/annotations and refresh the closing snapshot;
  do not waive the mismatch or rerun deployment/inference solely for metadata-only changes.

## PR and Parallel Validation

- Once the publish branch is clean and has deterministic RED/GREEN, focused/full relevant
  source validation and any required exact-package evidence, ordinary-push it and create a PR.
  This permits review, not completion: all contract-required post-push gates must then run
  against that exact HEAD in parallel with online review.
- Read and follow the applicable repository PR template, preserving its headings, comments,
  checklist and ordering instead of substituting a generic body.
  The title is at most 20 words and **every description section** is at most 100 words.
  Fill placeholders accurately; unused sections may be empty or briefly marked not applicable.
  Do not invent issue references or checked results.
- Write PR descriptions in concise English, focused on what changes and how it works.
  The summary states the user-visible change and why it matters; the detailed section explains
  the key mechanism, scope and preserved behavior. Prefer short, reader-friendly bullets,
  not a file-by-file change diary or repeated claims.
- Validation states actual commands and results, with only the coverage limitations needed
  to interpret that evidence. Keep technical risks relevant to reviewers explicit and concise.
  Never label unrun, blocked or failed validation as PASS.
- Internal progress, unfinished-work notes, cost or authorization decisions, and task
  coordination belong on the dev branch, not in the PR description. Keep private framework
  paths, machine-specific evidence and raw logs out of public prose.
- Within an already requested PR-delivery task, generate and maintain the agent-authored
  description from these rules. Do not wait for per-description wording approval or confirmation.
  An explicit user request to draft only, discuss or pause still takes precedence.
- Preserve teammate edits when updating a description; change only clearly agent-authored
  text and do not infer authorship from a shared login. These writing rules do not authorize
  unrelated scope changes, publication of private content or merging the PR.
- Prefer automatic online review on PR creation or new commits. Do not duplicate an
  active current-head review. If startup explicitly fails, or a bounded wait finds no
  start and no current-head review in flight, request manually once and verify actual
  pickup; an API success alone is insufficient. Never use bot mentions or empty commits
  as triggers. Switch immediately to the 30-minute post-PR watcher and run exact
  publish-head local acceptance in parallel with online review and CI.
- On every published HEAD change, reassess affected inputs and the recorded applicable plan;
  merely reassociating old checks, reviews or local evidence is insufficient.
- Critically triage every visible, file-level, suppressed and spelling finding against
  the exact code and behavior; do not blindly accept automated comments or ignore green
  check annotations.
- Push valid fixes with deterministic evidence and record their dispositions locally,
  without fix-acknowledgement replies. Only won't-fix explanations may be commented,
  and those must leave the thread open.
- Never merge the PR to `main`. Never resolve, dismiss, close or clean up any active
  review thread, even when a later iteration fixed it or made it outdated. Leave all
  active comments for the user.

## Phase-Aware Autopilot Watchdogs

Start a real watchdog when the user enables autopilot, not only after publication.
Use one schedule per task at a **30-minute cadence**. Record its actual ID or owned
PID/start time, phase, last successful observation and checkpoints in local-only state.
Recover an existing watcher before creating another; no unconfigured cross-session
or always-on availability claims.

Each unfinished task records `last_progress_at`, evidence of real progress,
`next_action`, dependencies and `idle_deadline = last_progress_at + 1 hour`.
At each check, recover work already idle for 30 minutes or whose deadline will expire
before the next check. Progress its dependency, diagnose a failed/hung command, or
use a bounded authorized alternative instead of waiting indefinitely for another
user message. A tick, an unchanged remote state or "still running" without evidence
does not reset the progress clock. A genuinely progressing long build is not
terminated simply because its wall time exceeds an hour.

Honor explicit package-close authorization promptly by exact process ownership, but
never terminate the current chat ancestry or unrelated processes. The deadline is
not permission to discard changes, switch credentials, spend beyond a budget,
commit/push/publish, manufacture human approval or merge. Keep independent authorized
work moving when a genuine safety/permission boundary remains.
`PAUSED_USER_DISCUSSION` is not recoverable idleness. A watchdog or completion reminder cannot
unpause implementation; an independent maintenance authorization does not resume that feature.

The polling cadence is not a rebase cadence. Before a PR exists, this watchdog
does not inspect main/base. After publication, inspect the base only for actual
merge conflicts and resolve confirmed conflicts within authorization without
rewriting history. **Never rebase unless the user explicitly requests it.**
A base update alone does not trigger integration, build/deploy or paid validation.

### Pre-PR Prompt

Schedule this prompt every 30 minutes:

```text
Pre-PR autopilot progress watchdog. Read the active-task ledger, deadlines, owned
terminals and phase journals. Find each unfinished task's next executable step or
dependency and last substantive progress evidence. Recover work idle for 30 minutes
or whose one-hour no-progress deadline expires before the next check: inspect the
existing result, diagnose a failed/hung command, retry within authorization/budget,
choose a bounded alternative, or progress the dependency. Do not refresh timestamps
for this tick alone or abandon actionable work while waiting for another message.
Preserve dirty work, configuration, credentials, process ownership and the current
chat. Honor explicit package-close authorization without repeated permission loops;
never terminate the chat ancestry or unrelated processes or invent write authority.
Continue the agreed RED/GREEN and exact-source build/deploy/user-flow evidence.
Do not inspect main/base or perform rebases in this pre-PR watchdog. Serialize
authorized mutations; avoid duplicate writers, builds and foreground UI runs.
Report only meaningful changes; the progress deadline is not an integration request.
Stop when the requested work is complete or explicitly paused. On PR publication,
replace this schedule with the existing post-PR review/CI/base watchdog; do not run
two competing writers.
Never resume PAUSED_USER_DISCUSSION without explicit user authorization.
```

### Post-PR Handoff To Common

Use **Online PR review monitoring** in the generated dev-root `AGENTS.md`.
Its source in the toolkit repository is `common\templates\AGENTS.md`. Common owns
the Copilot `/every` prompt, schedule creation/recovery, evidence collection
requirements and lifecycle. Do not create a second project-specific scheduler
or copy a separate recurring review prompt here.

Record the pre-PR stop and post-PR start IDs/times when handing off. Review fixes
remain under the common post-PR schedule, not a restarted pre-PR loop. The
one-hour no-progress deadline above still applies to pending authorized repairs;
an unchanged observation does not refresh it or fabricate human approval.

Retain these Terminal workflow constraints alongside the common rules:

- Run applicable exact publish-head local acceptance in parallel with online
  review and CI. A changed publish head needs fresh applicable evidence; metadata,
  base advancement or a monitoring tick alone does not require deployment or
  another real-provider request when the tested product inputs have not changed.
- Serialize authorized repairs with active implementation, build/deploy and UI
  work. Preserve package/process ownership, the current chat and any manual-app
  reservation; monitoring is not permission to close or redeploy an application.
- Apply the public-writing boundaries from **PR and Parallel Validation** to
  scheduled follow-up, implementation and review-fix loops alike. Only explicitly
  permitted, evidence-based won't-fix explanations may be posted by the owning
  task, leaving threads open. Never post fix/progress acknowledgements, resolve,
  dismiss or close active threads, delete or rewrite previous comments, merge
  the PR, or overwrite teammate prose. A shared login is not proof of authorship.
- Preserve historical evidence when current merge-readiness changes. Keep
  credentials, request budgets, discussion pauses and synchronous bounded
  build/test execution unchanged.

## Definition of Done

Apply this checklist to the explicitly requested task/contract. Remove explained non-applicable
items, retain required unmet gates as blocked/not-run, and do not call completed preparation an
accepted product feature.

- [ ] `<USER_VISIBLE_CONTRACT>` is satisfied.
- [ ] Active task ledger is empty; no interleaved question ended the workflow early.
- [ ] Focused RED failed for the expected reason.
- [ ] Focused GREEN and relevant suites pass.
- [ ] Build receipt matches the current source fingerprint.
- [ ] Durable pipeline journal is `passed`; no required terminal or phase remains `running`.
- [ ] Product, staged package and installed hashes match.
- [ ] Live E2E targets the intended Dev package and process/window identity.
- [ ] The latest published HEAD passed its applicable gates; required real acceptance ran after
  push on the fresh exact deployment.
- [ ] Latest refs and evidence identify the appropriate product/validation layers with explicit provenance.
- [ ] No fixture, unauthenticated handshake or old package substituted for a required real gate.
- [ ] Any explicit user deferral/waiver records its iteration/scope and is not reported as PASS.
- [ ] Negative controls and existing behavior pass.
- [ ] Every skip is explained as an external prerequisite, not a product failure.
- [ ] Logs/telemetry contain no prohibited sensitive data.
- [ ] Product/dev-only branch scope is correct.
- [ ] When publishing, public-content preflight covers every new commit and the exact outgoing prose.
- [ ] Any manual handoff restored owned fixtures and retained the user's app/cleanup reservation.
- [ ] Real-login/account-dependent and token-consuming harnesses/evidence remain local-only,
  including zero-token checks, and cannot be invoked by publish/CI.
- [ ] `Test-DevPublishReferenceIsolation.ps1` passes for the complete dev-only range and current
  changed/untracked text files.
- [ ] Exact publish/review identifiers are local-only and absent from tracked dev history.
- [ ] PR title is at most 20 words; every description section is at most 100 words,
  following the repository template with concise English what/how and factual validation.
- [ ] The description contains no internal progress ledger and was maintained without a
  separate wording-approval gate within the requested PR-delivery task.
- [ ] Online review and same-HEAD local E2E ran in parallel.
- [ ] While the PR remains open, a real review/base-conflict watcher is active with
  a recorded heartbeat, or an explicit user pause/runner interruption is recorded.
- [ ] Visible, file-level, suppressed and spelling findings were critically triaged.
- [ ] Valid fixes are pushed; every active review thread remains unresolved.
- [ ] The agent did not merge the PR to `main`.
- [ ] Commits are pushed and remote synchronization is verified.
- [ ] Tracking is self-contained enough for another machine/engineer to continue.