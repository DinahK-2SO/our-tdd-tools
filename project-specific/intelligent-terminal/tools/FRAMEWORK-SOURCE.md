# Framework Source and Update Policy

The standalone ItE2E snapshot was extracted from `test/e2e` at:

- repository base: `origin/main`
- source commit: `c4b1f7d230ed0d411bfc79a2c396f80073b5e902`
- extraction date: 2026-08-20

Included upstream surfaces:

- `test/e2e/ItE2E/**`
- deterministic `test/e2e/fixtures/**`
- Unit and Live self-tests
- the local HTML/NUnit/Markdown report runner

Excluded by design:

- feature-specific suites, including Markdown tests
- release-checklist wiring and online automation
- authenticated AI-oracle tests
- policy/elevation helpers
- screenshots, logs, provider homes, wire captures and local artifacts

Local additions:

- verified HWND/PID identity
- left/right client-coordinate single/double click through Win32 `SendInput`
- stepped physical drag and exact UIA text-range geometry
- cross-process foreground-input serialization
- fail-closed existing-process ownership with explicit close opt-in
- present/absent settings and state backup transactions with crash recovery
- named OS key chords
- deterministic Win32 input probe
- deterministic offline ACP agent-input self-test
- explicit opt-in guard for the copied optional AI oracle
- build receipt and deployment freshness validation
- framework-source fingerprinting and source-to-AppX verification for build-only receipts
- structured discovered/selected/executed/filtered-out counts and fail-closed
  zero-execution/inconclusive/setup reporting, with explicit accepted mixed skips
- portable TDD workflow and tool/build documentation
- bounded Copilot request ledger, event replay and local-only real-acceptance callbacks
- receipt-constrained WTA refresh with native/source guards and WTA rollback
- current-head acceptance evidence, visual inventory and review snapshot validation
- provider-created event-log readiness and ordinal exact-text acceptance oracles
- module-scoped reference callback imports and proportional scope/validation guidance
- real-login exclusion regardless of token cost, observed CI scope and task applicability
- exact-head review triage without a shared-account reply requirement
- complete review/check pagination guards, hashed annotation inventories and lifecycle rechecks
- read-only public-candidate history/prose audit with exact text hashes

`TEST-BOUNDARIES.md` is the internal admission/execution contract;
`PRACTICE-CONFLICTS.md` records corrections and still-unresolved policy choices.
These maintenance additions do not change the frozen upstream extraction commit.

These additions are local orchestration, not a wholesale refresh of the frozen ItE2E snapshot.
The real marker example deliberately reuses current product-side ItE2E helpers from its selected
validation worktree. Offline selftests validate the tools; they do not establish live acceptance
of a deployed product or spend a real-provider request budget.

This directory is intentionally a snapshot so one commit remains cherry-pickable
even if `main` later restructures `test/e2e`. To update it, compare the source
directories at a named main commit, port only relevant framework changes, rerun all
self-tests, and update the source commit above. Do not blindly recopy feature suites.

## Shared Framework Maintenance

- With user approval, contribute reusable local fixes and their regression cases
  to this toolkit repository's designated shared branch, rather than leaving
  them only in feature dev copies.
- Maintain shared templates in their owning common or project layer and verify
  their generated contracts.
  Personal fork layouts and companion-branch conventions belong in private user
  profiles, not in the shared framework.
- Follow explicitly configured remote mappings, verify the intended remote head,
  and keep framework maintenance commits out of feature publish branches. Import
  the updated toolkit snapshot when preparing the next feature dev branch.
- If a source worktree contains paused or independent commits, use a clean maintenance worktree
  based on the verified remote head. Do not force-update that worktree or silently include its
  paused patches. Do not synchronize other repositories or branches unless explicitly requested.