# Layered setup implementation plan

## Goal and scope

Turn the initial toolkit snapshot into a deterministic, three-layer setup system.
Running `setup.ps1` from a product repository prepares dev/publish worktrees and
an unfilled development contract without changing the caller's working files.
The framework's development commits are pushed after each completed milestone;
the generated product workflow is not pushed by setup.

The first supported project profile is Intelligent Terminal. A minimal unrelated
Git repository must also work without Terminal, WTA, MSIX, installed applications,
or real provider accounts.

## Milestones

| Step | Deliverable | Completion evidence |
| --- | --- | --- |
| 1 | This plan and the initial contracts | Reviewed scope and defaults; commit and direct `git push` |
| 2 | Configuration, identification, and read-only planning | Focused RED/GREEN tests for independent parameter namespaces, defaults, unknown keys, project matching, path resolution, and pinned inputs |
| 3 | Safe worktree creation and managed materialization | Real temporary Git repositories prove same-base worktrees, preserved caller state, clean publish output, reruns, collisions, and partial recovery |
| 4 | Project and local-user extensions | Intelligent Terminal and generic setup paths, extension ordering, original AGENTS preservation, and private user inputs |
| 5 | Reusable capabilities and Terminal adapters | Offline regression coverage for extracted Windows, review, and AI primitives; no product-specific execution in common setup |
| 6 | End-to-end verification and documentation | Complete offline suites, two-project setup scenarios, final source/remote parity, and a documented command interface |

Each behavioral slice starts with the smallest failing test, implements only that
behavior, then runs the affected tests before committing. Keep failed evidence
under ignored `Generated Files`. Every completed milestone uses an ordinary
commit followed by the command `git push`; never rewrite published history.

## Repository layout

```text
setup.ps1
common\
  setup.ps1
  defaults.json
  schema.json
  templates\
  tools\
project-specific\
  intelligent-terminal\
    project.json
    setup.ps1
    defaults.json
    schema.json
    templates\
    tools\
user-specific\
  setup.ps1
  defaults.json
  schema.json
  templates\
  examples\
tests\
```

Common setup owns orchestration, Git resources, managed outputs, and the final
manifest. Platform/provider capabilities are optional tool groups, not mandatory
acceptance gates. Terminal package/build/agent-pane behavior belongs to the
Intelligent Terminal profile.

Repository-maintainer instructions and personal account restrictions are not
automatically distributed as common instructions to every product.

## Parameters and defaults

- Accept separate `Common`, `Project`, and `User` parameter dictionaries.
  Each namespace has a schema and defaults; reject unknown keys and invalid types.
- Capture the caller's filesystem directory before loading layers. Resolve its Git
  root independently of the toolkit's directory.
- Use a stable default task keyword, `task`; callers can supply a keyword for a new
  task. Do not invent a feature description or silently add random branch suffixes.
- Default worktrees are siblings of the caller repository, with explicit dev and
  publish suffixes. Validate Git names and filesystem boundaries before writing.
- Resolve the base remote/branch explicitly. Prefer the selected remote's declared
  default branch when no branch is supplied; do not assume every project uses main.
- Pin the product base and toolkit HEAD for the whole run. With an upstream
  configured, check that the running toolkit is current before applying; stale or
  dirty toolkit source must not silently masquerade as the latest version.
  Updating a running toolkit in place is outside setup. An explicit offline/pinned
  mode records that it did not establish remote freshness.
- Recognize an explicit project ID first, then a repository marker, known repository
  identity, and a registered directory-name hint. Ambiguity fails; an unknown project
  can use the explicitly reported common-only profile.
- A local user profile is optional. Shared examples contain no credentials.
  Personal source files and runtime state are never copied wholesale.
- Setup performs no implicit product push, application shutdown, installation,
  deployment, credential change, or real model request.

## Layer contract

Resolve all three layers before applying any setup operation:

```text
Resolve declarations and parameters
  -> Preflight
  -> Pin inputs and create Plan
  -> Apply common, project, user
  -> Verify and persist completion
```

Each layer receives a versioned context with the toolkit root, caller repository
identity and resolved inputs. Planning/application also provide the pinned base,
branches and dev/publish/journal paths. Parameters remain namespaced. Extensions
cannot silently mutate another layer's parameters.

Layer contributions declare instruction fragments, tools, prerequisites, and
managed operations. Common renders the final AGENTS template once in a stable
order. Preserve original project instructions and leave semantic fields such as
the feature goal and RED oracle unfilled.

Ordinary preferences may override documented defaults; checks/tools may accumulate.
Required project contracts and safety boundaries cannot be silently disabled by a
later layer. Conflicting declarations fail before mutations.

Project hooks come from the pinned toolkit. User extensions are locally selected
code, not a sandbox: their origin and permitted output scope must be visible.
Plan/preflight hooks are read-only by contract, and violations must not be reported
as a successful preview.

## Ownership and recovery

- Create both worktrees from the same pinned base. Only dev receives the toolkit,
  generated contract, and customization content; publish remains at the product base.
- Do not checkout, stash, reset, rebase, or overwrite the caller's working tree.
- Use a task-scoped lock and an atomic state journal for concurrent/repeated setup.
- Record created resources, managed paths, hashes, completed phases and input
  fingerprints. Do not persist raw user parameters or personal provider/session data.
- Repeat the same task without duplicate worktrees or appended instructions.
  A user-edited managed file is not overwritten; report the mismatch.
- A changed main does not silently rebase an existing task: reuse its journaled
  pins and identify that source in the result. A changed toolkit revision/location
  or caller identity refuses the rerun rather than automatically upgrading it.
- Failed setup returns a non-success status with a resumable record. Do not use
  forced deletion or discard user work to manufacture a clean rollback.
- The dev provenance manifest identifies the exact base/toolkit and input
  fingerprint. Paths and verification status live in the private task journal;
  only a verified `ready` journal/result completes setup.

## Validation boundaries

Use temporary repositories, bare fixture remotes, fake layer hooks, mocked provider
events, and declared offline Unit tests. Include existing AGENTS files, dirty caller
state, absent product directories, reruns, unknown parameters, ambiguous identities,
path traversal attempts, name collisions, interrupted application, and user edits.

Preserve the imported process/account/privacy guards. Native input, installed-package
tests, actual PR publication, and real provider inference need separate authorization
and are not part of this implementation's validation.
