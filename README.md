# winpd-tdd

A layered setup toolkit for deterministic TDD workspace preparation, initially
extracted from the workflows developed alongside Intelligent Terminal.

This repository contains tooling and templates, not the Terminal product source.
The common planner separates toolkit and caller repositories. Terminal-specific
package identities, adapters and build assumptions live in the project profile.

## Quick start

Use **PowerShell 7.2 or newer** and Git on Windows. The toolkit must be a clean
checkout with a commit. For a new online task, its current branch must track an
upstream and its HEAD must equal that upstream's advertised HEAD. Update the
toolkit separately before invoking setup; setup never pulls or rewrites itself.
The product repository needs a commit and an accessible base remote.

Run from the product directory, not from the toolkit:

```powershell
Set-Location 'C:\ado\intelligent-terminal'

# Prepare the worktrees and leave the feature contract unfilled.
& 'C:\ado\winpd-tdd\setup.ps1' -Common @{ Keyword = 'navigation' }
```

With the defaults, this creates:

| Resource | Value in this example |
| --- | --- |
| Dev branch | `winpd/navigation-dev` |
| Publish branch | `winpd/navigation-publish` |
| Dev worktree | `C:\ado\intelligent-terminal-navigation-dev` |
| Publish worktree | `C:\ado\intelligent-terminal-navigation-publish` |
| Generated contract | `AGENTS.md` in dev |
| Toolbox and provenance | `.winpd\` in dev |

Both branches start at the same pinned remote base. The Intelligent Terminal
profile defaults to `main`; unrelated projects use their remote's default branch.
Caller files, staged changes and current branch are preserved. Publish remains
clean at the base. Setup creates no commits and performs no pushes.

The dev contract combines common, project, built-in user and optional private-user
instructions, followed by any original `AGENTS.md` from the pinned product base.
That original file is also preserved byte-for-byte under
`.winpd\original\AGENTS.md`. Semantic fields such as `<FEATURE_GOAL>` and
`<RED_ORACLE>` remain unfilled: the keyword is not a feature description.

The same command works in an unrelated repository, without Terminal installed.
It explicitly reports the `common` profile when no project matches.

## Independent parameter namespaces

The three dictionaries are validated separately; unknown keys and wrong types
fail before setup. All parameters have defaults. For example:

```powershell
& 'C:\ado\winpd-tdd\setup.ps1' `
    -Common @{ Keyword = 'navigation'; BaseRemote = 'upstream' } `
    -Project @{ IncludeTools = $true } `
    -User @{ ChatLanguage = 'zh-CN' }
```

Use `BaseRemote = 'upstream'` only when that remote exists; otherwise omit it or
select the appropriate configured remote. `IncludeTools` is a Terminal profile
parameter, not a Common or User parameter.

| Common parameter | Default |
| --- | --- |
| `WorkingDirectory` | Caller's filesystem directory; subdirectories resolve to their Git root |
| `Keyword` | `task`; supply a different keyword for each new task |
| `BaseRemote` | `origin`, otherwise the single unambiguous remote |
| `BaseBranch` | Project/user default, otherwise the selected remote's default branch |
| `BranchPrefix` | `winpd` |
| `WorktreeRoot` | Parent of the caller repository; explicit relative paths are repository-relative |
| `ProjectId` | `auto`; `common` explicitly disables project customization |
| `Offline` | `$false`; `$true` uses cached refs and does not claim remote freshness |

Worktree names use the primary checkout's repository name, the keyword, and the
`-dev`/`-publish` suffixes. The keyword accepts 1-64 ASCII letters, digits, dots,
underscores and hyphens, beginning with a letter or digit. Git validates branch
names too. Output paths may not overlap the caller or toolkit repository;
junctions and other reparse points are not supported in managed paths.

Terminal Project defaults are `IncludeTools = $true` and
`PackageSelector = 'Dev'`. Setup does not build, deploy or launch that package.
The selector is a preparation constraint, not proof of a later live-test target.
Built-in User defaults are `ChatLanguage = 'en'` and no `ProfilePath`.

Offline example, after the needed remote-tracking refs have already been fetched:

```powershell
& 'C:\ado\winpd-tdd\setup.ps1' -Common @{
    Keyword = 'offline-task'
    Offline = $true
    BaseBranch = 'main'
}
```

## Project and private user customization

Project selection checks an explicit `Common.ProjectId`, a repository-root
`.winpd-project.json` containing `{"projectId":"intelligent-terminal"}`, registered
remote repository names, then registered directory names. Directory matching is
an exact hint, not a security identity check. Unknown explicit IDs and ambiguous
matches fail; otherwise setup falls back to common-only.

Add a project under `project-specific\<id>\` with `project.json`, `defaults.json`,
`schema.json` and `setup.ps1`; use the shipped Terminal profile as a small example.
The descriptor's ID must match its directory. Templates and tools are explicit
contributions, not an unrestricted copy of that directory. Toolkit contributions
must be Git-tracked in the pinned clean checkout.

Keep personal customization outside the shared toolkit checkout. Copy the
nonsecret files in `user-specific\examples` to a private directory and adapt
`profile.json`. Select it explicitly:

```powershell
& 'C:\ado\winpd-tdd\setup.ps1' `
    -Common @{ Keyword = 'personal-task' } `
    -User @{
        ProfilePath = 'C:\ado\my-winpd-profile'
        ChatLanguage = 'zh-CN'
        ExtraCheckLabel = 'local-style'
    }
```

`ExtraCheckLabel` is declared by the example profile, not by the framework.
`ProfilePath` accepts a directory containing `profile.json` or that JSON file.
Alternatively set `WINPD_USER_PROFILE`; an explicit `User.ProfilePath` takes
precedence, including `''` to disable the environment-selected profile.

A private profile declares its own defaults/schema, instruction files, individual
tool files and optional `setupScript`. Only those files are materialized; setup
does not copy the whole profile directory or implicitly include `profile.json`.
Never put credentials in parameters or declared assets. Known credential-file
and token checks are defense in depth, not an exhaustive secret detector.
Plans can contain private paths and parameter values; keep them local.

Project and private-user `commonDefaults` may supply only `Keyword`, `BaseRemote`,
`BaseBranch`, `BranchPrefix` and `WorktreeRoot`. Precedence is common defaults,
project defaults, user defaults, then explicit Common arguments. These defaults
cannot redirect `WorkingDirectory`, `ProjectId` or `Offline`. Custom User schemas
cannot redefine built-in User parameter definitions.

### Hook contract

Each setup hook accepts `Phase`, `Context` and its own `Parameters`. Resolve all
schemas/defaults and run every layer's `Preflight` before creating resources.
Then apply common, project and user layers in that order, render the contract,
and verify. A private profile's hook runs after the built-in user hook.

- `Preflight`, `Apply` and `Verify` return exactly one dictionary with
  `Status = 'passed'`, or throw with a useful reason.
- `Plan` returns exactly one dictionary with `Instructions` and `ToolDirectories`
  arrays of relative paths. Private user tools must instead be individual files
  declared in `profile.json`.
- Context/parameter copies are read-only by contract; detected mutation fails.
  Hooks must not weaken another layer's required checks.
- `Preflight` and `Plan` must be read-only. Apply hooks must be idempotent and
  operate only on declared, owned task resources: an interrupted hook can rerun.

Hooks are **trusted executable code, not an OS sandbox**. Setup cannot prevent
arbitrary side effects in a malicious hook or analyze contradictions in
natural-language instructions. Inspect custom hooks before selecting them.

## Pinned tasks, ownership and recovery

The task identity combines the Git common directory and keyword. A private
journal at `<git-common-directory>\winpd\tasks\<task-id>.json` records the base and
toolkit pins, paths, branches, managed hashes, completed phases and failures.
A task-scoped lock prevents concurrent application. `.winpd\setup.json` is a
provenance manifest, not by itself proof that verification completed: the journal
and command result must report `ready`.

Rerun the same command to verify an untouched setup or retry a failed phase.
Already recorded resources and completed layers are reused, not duplicated.
When upstream main advances, an existing task keeps its original base rather
than silently rebasing. `PinSource = 'existing-task'` means the pins came from the
journal, not a new freshness check.

Reruns deliberately refuse a changed toolkit revision/location, parameters,
customization, caller HEAD/branch, owned worktree identity, user-edited managed
output or dirty publish worktree. Setup is preparation, not a task updater:
filling the generated contract or committing product work does not authorize
setup to overwrite it. Use a new keyword for a new task.

An unowned path/branch collision, malformed/older journal without pins, or
interrupted `creating` state requires inspection. Setup does not adopt uncertain
resources, delete them, reset history or force a rollback. A failed hook may have
partial effects; preserve the journal and inspect its phase/error before retry.

## Online PR review monitoring

Every project's generated contract includes the common online review workflow
from `common\templates\AGENTS.md`. After authorized PR publication, the agent
creates or recovers one Copilot CLI `/every` schedule using the supplied prompt,
with a default 30-minute interval. Common defines deduplication, current-head
review/check inspection, checkpoints, recovery and stop conditions.

The schedule runs in the owning Copilot session, not a separate polling script.
Setup does not create it during workspace preparation. Project-specific acceptance
and public-writing restrictions remain in the project layer; user instructions
can select another interval without silently removing the monitoring requirement.
Unavailable scheduling is reported as blocked, not replaced with an external job.

## Optional capabilities

`common\tools\README.md` describes shared process/evidence helpers, exact-window
Windows tools, screenshot capture, complete GitHub review snapshots, bounded
read-only PR observation, publication audits and an authorized Copilot judge.
Terminal-specific build, package, pane and real-provider flows remain under its
project profile. Personal tools can extend either workflow locally.

Setup only installs these capabilities. It does not start a watcher, send desktop
input, inspect screenshot pixels, switch accounts or call an AI provider.
Availability imposes no mandatory screenshot or model-request gate. Live calls
need explicit targets, authorization and, for inference, a finite request budget.

## Contents

| Path | Purpose |
| --- | --- |
| `common\templates\AGENTS.md` | Generic unfilled contract used by setup |
| `setup.ps1` | Layered local workspace setup |
| `common\` | Parameter validation, planning, owned materialization and shared capabilities |
| `project-specific\intelligent-terminal\` | Terminal instructions, tools, fixtures and legacy selftests |
| `user-specific\` | Default user layer and examples for explicitly selected local profiles |
| `docs\layered-setup-plan.md` | Implementation milestones and contracts |
| `tests\` | Planner, real temporary-Git setup, profile, common-tool and CLI regressions |
| `LICENSE` | Original Microsoft MIT license |

Maintain reusable instructions in the common, project and user layer templates;
setup composes them into the consuming project's `AGENTS.md`. Keep actual
personal profiles outside the shared branch; `user-specific\examples` contains
only generic examples.

## Import provenance

- Imported on November 8, 2026 from the Intelligent Terminal TDD working copy.
- The toolkit starts from the Intelligent Terminal TDD snapshot at
  `de7020e12960f235299be1ba12c010d707afdf84`.
- The source-mutation selftest now prepares and removes its own temporary `src`
  directory when needed, rather than assuming a product checkout provides it.
- `project-specific\intelligent-terminal\tools\FRAMEWORK-SOURCE.md` retains the earlier public ItE2E extraction
  provenance and source-maintenance history.
- No source-repository Git history, product implementation, machine configuration,
  provider data, screenshots, logs, or local acceptance receipts are imported.

References to Terminal source branches, product paths, and its release checklist
describe the original integration context. They are not authorization to modify
or publish another repository.

## Offline validation

Use the existing Windows/PowerShell prerequisites documented in
`project-specific\intelligent-terminal\tools\TOOLS.md`. From a checkout with a Git commit:

```powershell
$configuration = New-PesterConfiguration
$configuration.Run.Path = @(
    '.\tests'
    '.\project-specific\intelligent-terminal\tools\selftests'
)
$configuration.Filter.Tag = 'Unit'
$configuration.Run.Exit = $true
Invoke-Pester -Configuration $configuration
```

The Unit selection uses synthetic packages, mocks, and event replay. It does not
establish live product or real-provider acceptance. Do not wrap it in another
report runner or override `ITE2E_ARTIFACT_ROOT`; report selftests check their own
artifact-directory behavior.

The `Input`, `Live`, and `AgentInput` selections are separate desktop/app tests,
not part of this default offline check. The optional AI oracle and real-provider
acceptance paths remain opt-in and subject to their existing authorization gates.
The CLI cases use real child PowerShell processes and local bare Git remotes,
including an upstream that advances before and after preparation. These are
integration checks of setup, not live Terminal/provider acceptance.

Tests create isolated candidate snapshots from the current source, including
nonignored new files. Do not edit the source or run another suite concurrently:
one legacy selftest also briefly creates its own source-mutation fixture.

## Product integration limits

Some build/deploy scripts resolve the repository containing the kit and expect
Terminal's `src`, `tools\wta`, and build files there. This standalone repository
does not contain those inputs. Do not run that product pipeline here; use the
documented product-worktree adoption flow for an explicitly authorized integration.

Keep generated maintenance artifacts under the ignored `Generated Files`
directory. The imported kit also retains its existing ignored `artifacts`
directory. Never commit credentials or runtime/provider state.
