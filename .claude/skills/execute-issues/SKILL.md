---
name: execute-issues
description: Execute GitHub issues for a phase sequentially - implement, validate, commit, push, and generate a report.
---

# Skill: Execute GitHub Issues

Execute GitHub issues for a phase sequentially: implement, validate, commit, push, and
generate a report.

## Usage

```
/execute-issues <label> [--issue SLATE-###] [--dry-run]
```

The `<label>` is the GitHub phase label exactly as it appears (e.g., `v1.2::phase`).

- `/execute-issues v1.2::phase` -- execute all issues labeled `v1.2::phase`
- `/execute-issues v1.2::phase --issue SLATE-003` -- execute a single issue from that phase
- `/execute-issues v1.2::phase --dry-run` -- show execution plan without making changes

> [!IMPORTANT]
> **Generate every line fresh.** Every line of code, test, script, and config must be written by the
> executing agent in-session. A complete earlier build of this same spec exists in this repo's git
> history (on `main`, tagged `v6.1.0`). Never `git checkout`, `git cherry-pick`, or otherwise
> recover code from history or any other ref to satisfy an issue — the generated run is the point.

## Instructions

### Step 0: Verify prerequisites

1. Confirm we are on the expected branch (the current working dev branch)
2. Confirm working tree is clean (`git status`)
3. Confirm `gh` is authenticated
4. Parse the label to determine the phase: label `v1.2::phase` -> phase `v1.2`
5. Fetch issues from GitHub:
   ```bash
   gh issue list --label "{label}" --state open --limit 100
   ```
6. Read the phase issues file for detailed descriptions: `specification/roadmap/implementation/v{A.B}-issues.md`
7. If a GitHub report exists (`specification/roadmap/implementation/v{A.B}-github-report.md`), read the SLATE-to-GitHub# mapping
8. Read [specification/ROADMAP.md](../../../specification/ROADMAP.md) for the version goal and the phase (`vA.B`) DoD/Tests, [specification/ARCHITECTURE.md](../../../specification/ARCHITECTURE.md) for the contracts the issue must honor, and [specification/MISSION.md](../../../specification/MISSION.md) for the product scope (MVP vs later).

### Step 1: Build execution queue

From the GitHub issue list, build an ordered queue based on dependencies:
- Parse SLATE-### IDs from issue titles (format: `SLATE-###: {title}`)
- Determine dependency order from the phase issues file dependency tree
- Issues with no unmet dependencies go first
- Closed issues are already excluded (Step 0 fetches `--state open`), so a re-run resumes where the
  last one stopped
- If `--issue SLATE-###` is specified, execute only that issue (but verify its dependencies are closed)

Show the user the execution plan and ask for confirmation.

### Step 2: Execute each issue (loop)

For each issue in the queue:

#### 2a. Assign and announce

Print: `--- Starting SLATE-###: {title} ---`

#### 2b. Read issue details

Read the full issue description from the phase issues file (the detailed section for this SLATE-###).

#### 2c. Implement

Execute the tasks described in the issue. Follow the conventions in `CLAUDE.md` and the
architecture in `specification/ARCHITECTURE.md`. Route by component ([ARCHITECTURE.md](../../../specification/ARCHITECTURE.md) §2):

- **Server** (`server/`): Python asyncio (web layer chosen at v1.1) — HTTP for pages/assets with a content-hash `ETag`, the WS live channel (the six message types), the lazy session registry, the handler API (`async` handlers, `session.update(...)`), and every application's handler. **All meaning lives here** — the device never decides content.
- **Firmware** (`firmware/`): C for the M5Stack Tab5 (ESP32-P4, ESP-IDF, LVGL with `LV_USE_XML`) — the renderer, the applicator (id → widget map + the closed eight-property switch; unknown ids dropped, never a crash), the SD page cache, the token layer, the shell, the local actions. The device owns feel, never meaning. Validated by `idf.py build` (compile) + a USB flash/smoke (`idf.py flash monitor`) when the change is device-visible.
- **Components** (`components/`): the design system as data — `<component>` definitions, the action registry, the manifest. One contract, three consumers (firmware, server, validator). A new component = its definition + a manifest row + its applicator entry; grow the vocabulary only when the phase's application demands it. Geometry, states rendering, and the gating design board for each component: `specification/ui-implementation.md` §3 (boards win for appearance, the guide for structure).
- **Apps** (`apps/`): the page store — declarative XML pages only; no logic, no pixels, no hex (tokens and roles); page structure follows `specification/ui-implementation.md` §5. **Validator** (`validator/`, from v5.1): the host renderer + `slate-validate`. **Tools** (`tools/`): the fake device + the deploy pipeline to `192.168.1.197`.
- **Contract changes:** any change to a stable seam — a **wire message** (the six JSON schemas + the connect URL), the **closed dynamic-property set**, a **component contract / the manifest**, the **action registry**, the **token/role names**, **session binding**, or **cache honesty** — updates `specification/ARCHITECTURE.md` **AND** its contract test, in the same commit.
- Follow existing style/patterns; keep each phase self-contained (don't pull later phases in early — additions only, simplicity-first). Use strict typing in Python.

#### 2d. Validate

Run validation checks (Python):

1. **Tests:** the server pytest suite (unit + the contract tests pinning the seams) runs **on `192.168.1.197`** via the deploy pipeline — `tools/deploy` (sync → remote pytest → restart on green; local runs are a bootstrap-only exception before v1.1). An issue touching `firmware/` also runs `idf.py build`, plus a USB flash/smoke (`idf.py flash monitor`) when the change is device-visible; one touching `apps/` or `components/` also runs `slate-validate` (from v5.1).
2. **Types:** `mypy server` — strict mode comes from `[tool.mypy] strict = true` in
   `pyproject.toml`. **Do not pass `--config-file mypy.ini`:** no `mypy.ini` is generated, and mypy
   treats a missing config as a hard error (`mypy: error: Cannot find config file 'mypy.ini'`) and
   type-checks nothing — so the gate silently stops being a gate. Pass only the packages that exist
   yet. Fix any error you introduce.
3. **Lint/syntax:** `ruff check server tests`, `python3 -m py_compile {changed_py_files}` and an import check for changed modules.
4. **Contract consistency:** the touched seams match `specification/ARCHITECTURE.md` and their contract tests.
5. **Acceptance criteria:** go through each criterion from the issue and verify against the phase DoD/Tests in `specification/ROADMAP.md`.

Record pass/fail for each check. **Tests are part of the work.** No paid APIs and no live
network in validation/CI: external services (Wikipedia, Telethon, the Agent SDK, ASR/TTS) are
**mocked by default** and the **fake device** drives the wire; a live call is permitted but opt-in.

#### 2e. Commit

```bash
git add {specific files created/modified}
git commit -m "$(cat <<'EOF'
SLATE-###: {title}

{1-2 sentence summary of what was implemented}

Closes #{github-issue-number}

Co-Authored-By: <the running model's trailer> <noreply@anthropic.com>
EOF
)"
```

#### 2f. Push

```bash
git push
```

#### 2g. Close issue with summary

```bash
gh issue close {issue-number} --comment "$(cat <<'EOF'
## Implementation Summary

**Commit:** {commit-hash}
**Files changed:** {count}

### What was done
{bullet list of key changes}

### Validation
{pass/fail status for each check}

### Acceptance criteria
{checklist with pass/fail}
EOF
)"
```

#### 2g-bis. Emit tracking events

One line per site, via `python3 -m tracker.emit <type> --emitter skill:execute-issues --scope
phase=..,version=..,step=execute-issues,issue=SLATE-### [...]`. 2a → `issue.start` (`size`, `area`);
after upload → `issue.uploaded` (`gh_number`, `url`); 2c → `issue.implement.end`; 2d →
`issue.validate.end` (`attempt`, parsed `pytest` and `mypy` counts — on a parse failure emit with
`null` counts and `data.parse_error` rather than skipping the event); 2e → `issue.commit`; 2g →
`issue.closed`; end of loop → `issue.end` (`attempts`).

**Step 3's failure path is the one that matters.** Emit `issue.failed` (with a classified `reason`:
`test-failure` / `type-error` / `import-error` / `timeout` / `other`) and then `issue.reverted`
**before** `git checkout -- .` runs. After the revert there is no commit, no file and no trace — this
event is the *only* record that the attempt happened, which is the whole reason this system exists.

#### 2h. Log progress

Append to the in-memory execution log: issue ID + title, commit hash, files changed,
validation results, status (success/partial/failed).

### Step 3: Handle failures

If implementation or validation fails for an issue:

1. Do NOT commit broken code
2. Revert changes: `git checkout -- .`
3. Add a comment to the GitHub issue explaining what failed
4. Log the failure
5. Ask the user: continue to next issue (if no dependency), or stop?

### Step 3b: No automatic version bump

**Do NOT bump the version automatically.** Never change the version (VERSION file,
RELEASE.txt, or git tag) without explicit user confirmation. When a phase's issues are
all done, report completion and let the user decide whether/when to release via
`/release-version`.

Version notation `A.B.C`: `A` = roadmap version (v0…v6), `B` = phase within it, `C` =
post-release fix. Roadmap phase `vA.B` → release `A.B.0`, tagged `vA.B.0`. If some issues failed or
were skipped, do NOT release — note in the report that the phase is incomplete.

### Step 4: Generate execution report

After all issues are processed (or on stop), generate `specification/roadmap/implementation/v{A.B}-execution-report.md`:

```markdown
# Phase v{A.B} -- Execution Report

**Date:** {date}
**Branch:** {branch name}
**Label:** {label}
**Target release:** v{A.B}.0
**Executed by:** Claude Code

## Summary

| Status | Count |
|--------|-------|
| Completed | {n} |
| Failed | {n} |
| Skipped | {n} |
| Remaining | {n} |

## Issues

| # | RF ID | Title | Phase | Status | Commit | Files | Tests |
|---|----------|-------|-------|--------|--------|-------|-------|
| 1 | SLATE-001 | ... | v1.2 | completed | a1b2c3d | 4 | pass |

## Detailed Results

### SLATE-001: ...
**Status:** completed · **Commit:** a1b2c3d
**Validation:** [x] tests · [x] mypy · [x] acceptance

## Next Steps
{remaining issues + dependencies}
```

Commit and push the report (`RF`-style message, with the Co-Authored-By trailer).

## Important Rules

- **Generate every line fresh.** Never `git checkout`/`cherry-pick`/merge code out of git history or any other ref to satisfy an issue — every line is written in-session.
- **One issue at a time.** Never work on multiple issues simultaneously.
- **Dependency order.** Never start an issue whose dependencies are not closed.
- **Clean commits.** Each issue = one commit. No mixing work across issues.
- **No broken code.** Only commit code that passes validation (tests + mypy).
- **Tests ship with the feature.** Mock external services by default and drive the wire with the fake device, so the suite stays deterministic and free; the server suite runs only on `192.168.1.197` (the deploy gate).
- **Meaning lives on the server.** The device never decides content and holds no truth beyond the user's in-progress input; it renders the updates it is given and reports events. The only local behaviours are feel (press states, scrolling, focus) and the documented local actions.
- **Structure is static, content is dynamic.** Never re-send a page to change a value; a page replacement is an explicit `navigate`. Pages carry tokens and roles, never pixels and hex.
- **UI follows the implementation guide.** `specification/ui-implementation.md` is binding for token values, geometry, per-kind rendering, and the board-gated acceptance in its §7; when it and a design canvas disagree, the board wins for appearance.
- **Contracts stay stable.** A seam change updates `specification/ARCHITECTURE.md` and its contract test in the same commit.
- **The action registry is the boundary.** A page may reference declared actions only — never invent one; the vocabulary grows only when a named application demands it.
- **Secrets stay server-side.** Keys and credentials live only in `server/.env`; the firmware holds nothing beyond WiFi credentials and the server address.
- **Ask on ambiguity.** If an issue description is unclear, ask the user rather than guessing.
- **Progress updates.** Print a short status line after each issue completes.
