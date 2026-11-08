# Intelligent Terminal project contract

Keep the original product instructions below. They remain authoritative for the
current product architecture, build commands, settings and compatibility rules.

## Project tooling

The dev-only Terminal toolkit is under
`.winpd\project-specific\intelligent-terminal\tools`. It contains the retained
ItE2E helpers, deterministic fixtures, build/deployment identity checks and
Terminal-specific real-provider scenarios.

The historical toolkit documents may use `local-tdd-kit` as their adoption path.
In this generated workspace, use the toolbox path above instead. Do not copy
these tools into publish to satisfy test dependencies.

## Product validation

- For unshipped changes, validate the intended publish revision through a freshly
  built Dev package. Explicitly pin the package selector; an installed package is
  not proof that the changed source ran.
- Build WTA with the explicit Windows target before packaging when WTA changed.
- Native compilation is not proof that TAEF test bodies or packaged E2E ran.
  Record actual execution and setup failures separately.
- For UI layout tests, mount a real rendered host and wait for observable layout.
  Preserve intentional protocol-only test fixtures.
- Real provider authentication/inference acceptance remains local-only and is
  required only by the active task contract.

## Ownership

Do not replace another worktree's Dev registration, clear settings, uninstall
packages, or close apps merely to prepare this task. Isolated test packages reuse
the production-installed hooks; do not alter global hook registrations.

When runtime validation is separately authorized, resolve current package,
executable, PID and creation-time identity. Preserve current chat ancestry and
user-controlled windows. A later manual-test handoff revokes automatic input and
cleanup until the user explicitly releases it.
