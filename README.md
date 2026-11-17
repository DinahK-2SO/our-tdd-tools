# our-tdd-tools

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

Run from the product directory, not from the toolkit. Replace `<...>` path
placeholders below with your own locations; they are documentation placeholders,
not default paths stored by setup:

```powershell
Set-Location '<PROJECT_ROOT>'

# Prepare the worktrees and leave the feature contract unfilled.
& '<TOOLKIT_ROOT>\setup.ps1' -Common @{ Keyword = 'navigation' }
```

With the defaults, this creates:

| Resource | Value in this example |
| --- | --- |
| Dev branch | `winpd/navigation-dev` |
| Publish branch | `winpd/navigation-publish` |
| Dev worktree | `<WORKTREE_PARENT>\<PROJECT_NAME>-navigation-dev` |
| Publish worktree | `<WORKTREE_PARENT>\<PROJECT_NAME>-navigation-publish` |
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
& '<TOOLKIT_ROOT>\setup.ps1' `
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
| `DevRemote` | Empty; do not configure a dev push target unless explicitly supplied |
| `PublishRemote` | Empty; do not configure a publish push target unless explicitly supplied |
| `BranchPrefix` | `winpd` |
| `WorktreeRoot` | Parent of the caller repository; explicit relative paths are repository-relative |
| `ProjectId` | `auto`; `common` explicitly disables project customization |
| `Offline` | `$false`; `$true` uses cached refs and does not claim remote freshness |

Worktree names use the primary checkout's repository name, the keyword, and the
`-dev`/`-publish` suffixes. The keyword accepts 1-64 ASCII letters, digits, dots,
underscores and hyphens, beginning with a letter or digit. Git validates branch
names too. Output paths may not overlap the caller or toolkit repository;
junctions and other reparse points are not supported in managed paths.

Terminal Project defaults are `IncludeTools = $true`, `PackageSelector = 'Dev'`,
and empty `ComClsid` / `CopilotConfigPath` overrides. The selector may instead be
an exact package family name for an isolated deployment; `Auto` is not accepted.
An explicit COM override must be a non-empty GUID, and a configuration path
override must be absolute. Unknown real targets are not replaced with mock values.
Setup only records these values in the contract: it does not query installed
packages, build, deploy, launch or read the selected configuration file.

The generated project contract explains the runtime bindings: `ITE2E_PACKAGE`,
`ITE2E_WT_COM_CLSID` and `ITE2E_COPILOT_CONFIG`. The relevant helpers also accept
explicit `-ComClsid` and `-ConfigPath` arguments. An unavailable explicit COM target
does not fall back to another brand. A package outside the known brand mappings
requires an explicit COM override before live checks; missing identity is an
error, not permission to probe unrelated packages. Leave optional overrides unset
for standard project identities and current-user path resolution.
Built-in User defaults remain `ChatLanguage = 'en'` and no `ProfilePath`.

### Independent push destinations

`BaseRemote` selects source history, not where either branch should be pushed.
To bind different push destinations, use names of remotes already configured in
the product repository:

```powershell
& '<TOOLKIT_ROOT>\setup.ps1' -Common @{
    Keyword = 'navigation'
    DevRemote = '<DEV_REMOTE_NAME>'
    PublishRemote = '<PUBLISH_REMOTE_NAME>'
}
```

Setup writes only the owned branches' local `branch.<name>.pushRemote` settings;
it never creates remotes, changes the caller branch's target or executes a push.
Unknown remote names and conflicting existing settings fail. Once a target has
been configured, reruns do not overwrite or restore a user-edited setting.
An empty value leaves the corresponding Git configuration unchanged, so resolve
that destination explicitly before publishing. The first authorized push may
still need `git push -u <REMOTE_NAME> <BRANCH_NAME>` to establish tracking.

When targets are unset, the generated `AGENTS.md` guides the agent to inspect the
current GitHub host/account, verify a same-name fork's relationship, write permission
and visibility, then propose dev/publish destinations and a separate PR base for
one user confirmation. Confirmed mappings are reused. Neither branch may contain
secrets or sensitive local state; dev is not private storage.
Discovery failures require clarification, not guessed targets. This is agent guidance,
not setup-time network discovery or authorization to push, create forks or switch accounts.

Offline example, after the needed remote-tracking refs have already been fetched:

```powershell
& '<TOOLKIT_ROOT>\setup.ps1' -Common @{
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
& '<TOOLKIT_ROOT>\setup.ps1' `
    -Common @{ Keyword = 'personal-task' } `
    -User @{
        ProfilePath = '<PRIVATE_PROFILE_DIRECTORY>'
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
`BaseBranch`, `DevRemote`, `PublishRemote`, `BranchPrefix` and `WorktreeRoot`. Precedence is common defaults,
project defaults, user defaults, then explicit Common arguments. These defaults
cannot redirect `WorkingDirectory`, `ProjectId` or `Offline`. Custom User schemas
cannot redefine built-in User parameter definitions.

A private profile may also declare `projectDefaults`, keyed by project ID:

```json
{
  "schemaVersion": 1,
  "projectDefaults": {
    "intelligent-terminal": { "PackageSelector": "Dev" }
  }
}
```

Only the selected project's entry is merged and validated against that project's
schema. Explicit `-Project` arguments override those private defaults; values for
another project do not enter the current namespace. This can supply local runtime
bindings without hard-coding them in shared source.

### Template fields and private preferences

Instruction fragments can reference declared scalar parameters using
`{{Common.Keyword}}`, `{{Project.PackageSelector}}` or `{{User.ExtraCheckLabel}}`.
Strings, integers and Booleans are expanded mechanically in one pass. Unknown
namespaces/parameters and non-scalar values fail before worktree creation.
Inserted values are not evaluated as expressions or recursively expanded.
Other `{{...}}` forms are rejected rather than evaluated.
Semantic placeholders such as `<FEATURE_GOAL>` remain unfilled, as do GitHub
Actions `${{ ... }}` expressions.

Add private writing/review preferences through a local profile's own schema,
defaults and instruction fragments. Shared templates follow the repository's
requirements and explicitly selected preferences rather than imposing a
maintainer's language, word limits or reply policy. Keep specific defaults in
an external profile directory or a local-only worktree's `user-specific\local`
directory, not in the shared branch. Selecting a private profile does not make
its generated dev contract safe to publish.

Secrets are not template values or ordinary setup parameters. Secret-labelled
fields and known credential markers are rejected; this is defense in depth, not
an exhaustive secret scanner. Credentials remain in the provider's credential
store. Git authorship and existing commit trailers are separate metadata and
are not rewritten by parameterization.

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
