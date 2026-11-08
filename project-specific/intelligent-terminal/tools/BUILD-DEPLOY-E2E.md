# Build, Deploy, and Freshness for Local E2E

## The Five Layers

1. **Source**: the current Git `HEAD` plus tracked/untracked product edits.
2. **Product outputs**: source-matched `wtcli.exe`, explicit-target Cargo
   `wta.exe`, and C++/WinRT/XAML binaries.
3. **Package staging**: CascadiaPackage flat outputs and the appx recipe source
   map. The recipe maps explicit-target Cargo WTA to package-root `wta.exe` and
   identifies the exact sources for Terminal, `wtcli`, WinMD and resources. The
   loose `AppX` layout is materialized by deployment, not by every package build.
4. **Installed package**: Dev package family `IntelligentTerminal_rd9vj3e6a2mbr`.
5. **Live processes**: `WindowsTerminal.exe`, packaged `wta.exe`, and packaged `wtcli.exe`
   executing from that exact installed layout.

A successful compiler exit proves only layer 2. A trustworthy E2E run proves all
five layers refer to the same source snapshot.

Read `TEST-BOUNDARIES.md` before choosing gates. Publication eligibility is separate
from actual online execution, and real-login dependencies are dev/local-only even zero-token.

## Product Project Layers

| Changed surface | Focused validation/build | Must package/deploy? |
|---|---|---|
| WTA Rust | explicit-target `cargo test` then `cargo build` | Yes before full packaged E2E; package must contain matching hash |
| Settings model/IDL | SettingsModel tests/project, generated WinMD | Yes |
| Settings editor XAML/resources | TerminalSettingsEditor | Yes |
| TerminalApp C++ | TerminalApp | Yes |
| Terminal protocol or `wtcli` | owning protocol/CLI project | Yes |
| Windows host/window | WindowsTerminal | Yes |
| Static hook/assets/manifests | CascadiaPackage, clean staging when globs change | Yes |
| Pure local test/docs script | relevant Pester/document checks | No build by HEAD change alone; follow the explicit applicable plan and established gate dispositions |

Focused builds are the fast discriminating check. `CascadiaPackage` is the final
integration build because it gathers all product outputs into the staged AppX.

## Applicable Post-Push Deployment and Real Dependency Gate

Pre-push builds allow publication for review; they do not complete required acceptance.
Record `REAL_ACCEPTANCE_REQUIRED` and the validation plan rather than requiring inference for
all changed HEADs. Preparation/dev-only records do not deploy a product. Deterministic tests/docs
use their explicit plan; any change to established real/exact-head gates needs scoped disposition.

When a post-push real dependency gate is required, read PR/remote heads, require exact clean
publish HEAD equality, then build/deploy that revision and create a fresh receipt.
Correct incremental builds are allowed; old packages or parent receipts do not replace this gate.
Run the explicitly selected dev-only harness through normal product entrypoints.
Authentication-only acceptance proves actual user authorization and a usable session;
model/tool acceptance requires a real inference round and its specified downstream result.
Keep all real-account/login-dependent or token-consuming source, configuration and reports
local-only, outside publish, formal `test/e2e` and indirect CI calls.
Default Live/AgentInput examples are deterministic coverage, not proof of a real dependency gate.

Record push/build/deploy/inference timestamps, exact source/package/live identity, provider/model,
available usage, behavior oracles and fresh inspected UI screenshots. Complete scoped cleanup and
re-read the PR/remote heads at the end. A newer head still covered by this real gate needs a fresh cycle.
FAIL, BLOCKED, UNKNOWN and not-run prohibit completion or ready-for-merge claims.
Only explicit user deferral/waiver for a named iteration can pause this requirement; record the
date, SHA and scope without reporting PASS. Dev-only handoff/template pushes are not product pushes.

## Canonical Local Cycle

```powershell
# Builds/tests WTA first, then CascadiaPackage, deploys Dev, writes a receipt,
# and verifies source/artifact/install hashes.
pwsh -File local-tdd-kit/Invoke-BuildDeploy.ps1

# If another worktree owns the registration, inspect the current repository's
# data-preserving deployment path. Do not uninstall or replace it as a lock workaround.

# If this exact registered Dev layout is running, process shutdown is separately explicit.
pwsh -File local-tdd-kit/Invoke-BuildDeploy.ps1 -CloseRunningPackageProcesses

$env:ITE2E_PACKAGE = 'Dev'
pwsh -File local-tdd-kit/Verify-DeploymentFreshness.ps1
Invoke-Pester local-tdd-kit/selftests -Tag Live
```

For an AI-driven or otherwise interruption-sensitive complete cycle, keep all bounded phases in
one durable process:

```powershell
pwsh -File local-tdd-kit/Invoke-LocalTddPipeline.ps1 `
   -E2EPath test/e2e/tests/<Feature>.Tests.ps1
```

The runner atomically replaces `pipeline-state.json` under a unique ignored artifact directory,
so readers never observe partial JSON. Every phase is recorded as `running`, then `passed` or
`failed`, with timestamps, exit code, exact HEAD, hash-protected run-local receipt snapshot and report paths.
After E2E it recomputes the receipt's complete source fingerprint, not only HEAD. If the process disappears while the journal still says
`running`, `Get-LocalTddPipelineStatus.ps1` reports `interrupted`. A prior build receipt is never
accepted: the shared receipt is moved aside before build, and the new receipt must match the exact
HEAD, current source fingerprint and current build phase.

### Agent/autopilot execution contract

- Build, test, install, package, deploy and E2E are bounded one-shot work. When the available
   terminal tool supports it, an agent must run them through direct synchronous execution with no
   tool timeout, even when they take many minutes. Do not use a short-lived execution subagent or
   async/background mode.
- A tool timeout that returns a terminal ID is a handoff, not completion. The model cannot be
   awakened by process completion after its turn ends. Never say “will continue when complete”
   and end the turn while required work remains.
- Preserve the terminal ID from an unexpected handoff. Do not poll, sleep, or start a duplicate
   command. Continue only safe work that does not depend on the result. On the platform's automatic
   completion notification, retrieve the final output with that ID and classify the phase from its
   real exit code before proceeding.
- Treat the handed-off terminal as exclusively owned until its final completion. Do not send a new
   command through a default persistent shell that may reuse it: some runners interrupt the active
   batch with Ctrl+C and expose a `Terminate batch job` prompt. Use read-only tools or a separately
   isolated terminal while waiting. If this prompt appears accidentally, answer `N` and preserve
   the original workflow.
- A handed-off build does not authorize deploy, freshness verification, or tests that consume its
   output. Those dependent phases remain blocked until final output proves a zero exit. Evidence
   review, nearby reads, and documentation may continue while the build runs.
- If background execution is unavoidable, launch the durable pipeline rather than one phase. The
   machine can then finish every remaining phase and journal the outcome only while its process
   survives; host/VS Code cancellation is classified as `interrupted`. A later user/platform turn
   is still required before the model can interpret any outcome.
- Do not bundle expensive phases inside a wrapper that itself has a short wait limit. Either use
   the durable pipeline or execute each phase synchronously and inspect its result before the next.

### Foreground activation and visible flicker

`Invoke-BuildDeploy.ps1 -Launch` starts the Dev package through Explorer. Windows may activate the
new Terminal window, visibly flash or move focus away from VS Code. This does not terminate
`Code.exe`, but it can disrupt foreground-sensitive UI/input tests. Build/deploy without `-Launch`
by default; launch only immediately before a test that needs a live window. The durable pipeline
never passes `-Launch` and lets its E2E suite own launch, PID/HWND and cleanup.

The generated receipt is `local-tdd-kit/artifacts/build-receipt.json` and is ignored.
It records product and local-framework fingerprints, HEAD, configuration, exact paths and SHA-256 hashes.
Pass `-SourcePaths` to conservatively extend the fingerprint for issue-specific
inputs outside the built-in product/package roots.

For any `-SkipDeploy` run, the receipt still proves every recipe source matches the current AppX
layout (`installVerified=false`). Installed-package and live-process gates apply only after a Debug
deployment. The script always rebuilds CascadiaPackage and rejects stale AppX payloads; it never
certifies reused Terminal staging as fresh.

## Freshness Gates

Before accepting E2E evidence, require all of these:

1. The current source fingerprint equals the build receipt.
2. Current-source `wtcli.exe` is built first and placed before aliases/packages
   on `PATH` while WTA integration tests run.
3. Cargo explicit-target `wta.exe` exists.
4. Cargo, package-output and installed `wta.exe` SHA-256 hashes are identical,
   and the recipe maps package-root `wta.exe` to the explicit-target Cargo path.
5. The installed Dev package `InstallLocation` is this worktree's AppX directory.
6. Every recipe source (`WindowsTerminal.exe`, `wtcli.exe`, protocol WinMD,
   `resources.pri`, and WTA) hashes to the corresponding AppX destination; installed layout
   checks then confirm the registered package points at that exact AppX.
7. Running Terminal/WTA process paths are under that same install location.
8. E2E explicitly selects `Dev`; `Auto` is not acceptable for local-package proof.

## Problems Encountered and Guardrails

### `cargo test` did not refresh the product binary

Cargo test builds test targets. It is not evidence that the package-ready
`wta.exe` was rebuilt. Always run:

```powershell
cargo build --target x86_64-pc-windows-msvc --manifest-path tools/wta/Cargo.toml
```

### WTA tests picked up an old `wtcli.exe`

Hook/integration tests execute `wtcli` from `PATH`. A WindowsApps alias or older
installed package can lack commands present in the current source, causing false
failures such as “arguments were not expected: agent-hook”. Build the focused
`src/tools/wtcli` project first, require its `--help` to advertise the expected
command, and prepend only that output directory while running WTA tests.

### MSBuild silently selected stale WTA

`CascadiaPackage.wapproj` chooses the first existing binary in this order:

1. explicit target + matching profile
2. host target + matching profile
3. explicit target + fallback profile
4. host target + fallback profile

Therefore a stale explicit-target binary wins over a newly built host-target
binary. Always use the explicit target and matching Debug/Release profile.

### New C++ flag with old packaged WTA

Terminal can start a helper with a newly added argument while a stale WTA does
not recognize it; the helper exits immediately. Build WTA first, package second,
then compare hashes before deployment.

### Package staging used `PreserveNewest`

Incremental packaging can leave a stale file when timestamp ordering is
unexpected. Hash comparison is authoritative. If staging differs from Cargo,
remove the staged file or clean the package output and rebuild; never deploy and
hope.

### E2E accidentally selected the Store package

`Auto` prefers Store when both Store and Dev resolve. Store and Dev also have
independent settings/state. Set `ITE2E_PACKAGE=Dev` for local build validation.

### Dev registration pointed at another worktree

Loose Dev packages retain their AppX `InstallLocation`. Building one worktree
does not update a package registered from another. The deployment script refuses
this mismatch unless replacement is explicit and preserves application data.

Before considering a cross-worktree update, compare the fresh build and existing
registration **without changing either**:

```powershell
$recipe = '<SOURCE_WORKTREE>\src\cascadia\CascadiaPackage\bin\x64\Debug\CascadiaPackage.build.appxrecipe'
$msix = '<SOURCE_WORKTREE>\src\cascadia\CascadiaPackage\AppPackages\<DEBUG_PACKAGE>.msix'
$plan = & .\local-tdd-kit\Compare-AppxRecipeToDevLayout.ps1 -RecipePath $recipe -MsixPath $msix
$plan | Select-Object EntryCount, MsixEntryCount, NeedsUpdateCount, RecipeAndManifestMatch
```

The comparison parses all recipe entries with `Get-AppxRecipePackageSources.ps1`
(including URI-escaped SDK paths), hashes each source, its corresponding MSIX entry,
and the registered Dev layout, and reports any changed files and scale-qualified
profile icons deliberately omitted from the MSIX. It checks package identity and
reports **both** manifest hashes and versions: a version mismatch is evidence of
divergence, not permission to overwrite the registered manifest. Counts are discovered
from the current recipe, never fixed to a historical build. The script does not
build, register, close processes, replace files, or prove the source Git HEAD; pair
its output with a current source fingerprint and build receipt before trusting it.

This is a diagnostic plan, **not a deployment command**. A future transfer would
need separately approved ownership/idle-process checks, explicit backup paths,
atomic per-file replacement with rollback, and post-transfer hash verification.
`-ReplaceExistingDevRegistration` instead uses `Remove-AppxPackage
-PreserveApplicationData`; do not treat it as a harmless file-lock workaround or
assume it preserves every user-managed cache. Preserve settings/state and only the
specific session/cache files the test actually mutates; never overwrite Windows-
managed `SystemAppData` hives or stop an unrelated/current-chat process.

### Live processes locked package files

First prove each process was launched by this run or has explicit standing close
permission, then verify its executable path under the exact Dev `InstallLocation`.
Package membership alone is not test ownership. Never kill every `WindowsTerminal.exe` or `wta.exe` by name;
that can destroy unrelated sessions, Store instances, or the terminal hosting the current
conversation. `Invoke-BuildDeploy.ps1` refuses to close a running current-layout package unless
`-CloseRunningPackageProcesses` is supplied. Registration replacement is separately explicit via
`-ReplaceExistingDevRegistration`.

First enumerate and record the exact path and PID. Stop only those explicit PIDs,
then repeat the path-based inventory and require zero remaining processes. Do not
pass unresolved variables, wildcards or process names to a destructive cleanup
command.

### Deployment failed with `resources.pri` mapping error `0x800704C8`

This can be a transient user-mapped-section lock left while the previous Dev
package process is exiting. Inspect Restart Manager or enumerate exact package
process paths before retrying. If no persistent owner remains, retry the same
deployment once; if an owner remains, record its PID/path and stop it only when this
run owns it or has explicit close permission, never when it hosts the current chat.
Do not use an ad hoc `Remove-AppxPackage` as a file-lock workaround. The legacy
`-ReplaceExistingDevRegistration` flag performs removal with `-PreserveApplicationData`;
window-close permission does not authorize it. Prefer the selected repository revision's
supported data-preserving deployment path. Its replacement/rollback policy remains
a separately scoped issue in `PRACTICE-CONFLICTS.md`.

### A nonbehavioral source edit invalidated the receipt

The source fingerprint hashes bytes under `SourcePaths`, not compiler semantics.
A code-comment-only edit therefore makes the old receipt stale even when the
runtime behavior is unchanged. Rebuild and run freshness verification from the new
HEAD before claiming an exact-head receipt. For unchanged product inputs in a tests/docs
plan, record both product and validation identities before any scoped reuse. That does not
automatically waive established real/exact-head gates or make the old binary a new-head build.

### Full solution failures hid the focused result

The full solution can fail for unrelated SDK/.NET/reference-pack prerequisites.
Use the smallest owning project for RED/GREEN, then build CascadiaPackage for the
packaged acceptance gate. Record unrelated full-build blockers separately.

### Startup and native test-host failures are not behavior RED

Run a fresh Debug package startup smoke before interpreting a physical UI test.
A missing localized resource may fail-fast before a window exists; inspect the
generated PRI key path and matching PDB location rather than blaming the input
handler. RESW names ending in `.Text` can appear as `/Text` in PRI resource paths.
Do not hard-code a single incident's resource keys into the workflow.

Build the native test and its packaged TestHost separately. Run the exact DLL and
test name using `te.exe`, plus an unchanged canary. If both are blocked before
assertions by test-host RPC `0x8007000E`, record the environment as BLOCKED, not
as a failing behavior test or a passing unit test. Do not blindly retry, use an
unsupported `/inproc` mode for UAP tests, or substitute package E2E results for
the blocked native test; keep those results separately attributed.

### Generated WinRT/XAML artifacts were stale or raced

Settings model changes must regenerate their WinMD before consumers; Settings
editor XAML must produce generated headers/XBF before TerminalApp consumes them.
For release installers, use the repository wrappers that prebuild these layers
and clean shared outputs. Do not run x64 and ARM64 release packaging in parallel.

### Deployment began before build completion

Wait for a real zero exit code. A still-running or backgrounded build is not a
successful build, and deploying its previous recipe simply re-registers old code.

### The agent stopped after a background handoff

This is an orchestration failure, not a build result. In observed tool versions, short execution
helpers stopped waiting at about two minutes while leaving the command alive; that duration is
implementation-dependent, not a stable contract. If the agent then ends its turn, the
completion event cannot start another turn. Re-run the bounded workflow synchronously with no
tool timeout, or inspect the durable pipeline journal in the next available turn. If a terminal ID
was returned, retain it, do not poll or sleep, and use the platform's automatic completion
notification to retrieve the final output once. Continue independent evidence or documentation
work while waiting, but never deploy old output or start a dependent phase. Do not claim success
from an old receipt and do not end the task solely because one required validation is still running.

### Logs came from an old process/version

After launch, verify process paths and use the current package-version log
directory. Capture process IDs at test start; do not infer ownership from a
global filename alone.

## Manual Inspection Commands

```powershell
$pkg = Get-AppxPackage | Where-Object PackageFamilyName -eq 'IntelligentTerminal_rd9vj3e6a2mbr'
$pkg | Select-Object PackageFullName, InstallLocation, Version

$cargo = 'tools/wta/target/x86_64-pc-windows-msvc/debug/wta.exe'
$staged = 'src/cascadia/CascadiaPackage/bin/x64/Debug/AppX/wta.exe'
$installed = Join-Path $pkg.InstallLocation 'wta.exe'
Get-FileHash $cargo, $staged, $installed -Algorithm SHA256

Get-Process WindowsTerminal,wta -ErrorAction SilentlyContinue |
    Select-Object Id, ProcessName, Path
```