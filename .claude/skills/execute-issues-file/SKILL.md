---
name: execute-issues-file
description: Execute one version's issues directly from its local specification/roadmap/implementation/vA.B-issues.md file (no GitHub). Implement -> validate -> commit -> push each issue in dependency order, then write an execution report. The offline, file-driven counterpart of execute-issues.
---

# Skill: Execute Issues From File

Execute the issues for one version **straight from its already-generated issues file** —
`specification/roadmap/implementation/vA.B-issues.md` — with **no GitHub involvement** (no upload, no issue lookup,
no closing). Implement, validate, commit, and push each issue in dependency order, then write an
execution report.

This is the offline counterpart of `execute-issues`: same implementation discipline, but the issue
list comes from the local markdown file instead of `gh issue list`, and there are no GitHub issues to
close.

## Usage

```
/execute-issues-file <vA.B | path-to-issues-file> [--issue SLATE-###] [--dry-run]
```

- `/execute-issues-file v2.1` → executes `specification/roadmap/implementation/v2.1-issues.md`
- `/execute-issues-file @specification/roadmap/implementation/v3.2-issues.md`
- `--issue SLATE-###` → only that issue (its file-listed deps must already be committed)
- `--dry-run` → print the execution plan without making changes

> [!IMPORTANT]
> **Generate every line fresh.** A complete earlier build of this same spec exists in this repo's git
> history (on `main`, tagged `v6.1.0`) — you must **NEVER** `git checkout`/`cherry-pick`/merge code
> from history or any other ref to satisfy an issue. The generated run is the point.

## Instructions

### Step 0: Verify prerequisites & read the file

1. Confirm we are on the working dev branch and the tree is clean (`git status`).
2. Resolve the target to `specification/roadmap/implementation/vA.B-issues.md` and **read it** — the Issues Summary
   Table (IDs, titles, size, area, dependencies), the Dependency Tree, and each detailed
   `### SLATE-### …` section. **No `gh` is used.**
3. Read [specification/ROADMAP.md](../../../specification/ROADMAP.md) for the version goal + the `vA.B` DoD/Tests,
   [specification/ARCHITECTURE.md](../../../specification/ARCHITECTURE.md) for the contracts, and
   [specification/MISSION.md](../../../specification/MISSION.md) for scope (MVP vs later).
4. Establish a **green baseline** (`pytest` + strict `mypy`) so a later failure is attributable.

### Step 1: Build the execution queue (from the file)

- Parse the SLATE-### IDs + titles from the file's summary table; order them by the file's
  **Dependency Tree** (issues with no unmet dependency first).
- **Skip issues already implemented** — an issue whose ID already appears in a prior commit
  (`git log --grep "SLATE-###:"`) is done; skip it (resumability).
- With `--issue SLATE-###`, execute only that one (verify its file-listed deps are already committed).
- Show the ordered plan and proceed (stop here if `--dry-run`).

### Step 2: Execute each issue (loop, in dependency order)

For each issue:

1. **Announce:** `--- Starting SLATE-###: {title} ---`.
2. **Read** its detailed section from the issues file (What needs to be done / Acceptance criteria).
3. **Implement** per `CLAUDE.md` + `specification/ARCHITECTURE.md`, routed by component
   ([ARCHITECTURE.md](../../../specification/ARCHITECTURE.md) §Components): `server/` (all meaning —
   pages/assets over HTTP, the WS live channel, sessions, handlers), `firmware/` (Tab5: renderer,
   applicator, cache, shell, tokens; renders what it is sent, decides nothing), `components/` (the
   design system as data — definitions + action registry + manifest), `apps/` (pages only, no logic).
   A **seam change** (a **wire message**, the **dynamic-property set**, a **component contract / the
   manifest**, the **action registry**, **tokens/roles**, **session binding**, or **cache honesty**) updates
   `specification/ARCHITECTURE.md` **and** its contract test in the **same** commit. Strict typing;
   simplicity-first (don't pull later phases in early).
4. **Validate:** the server pytest suite **on `192.168.1.197`** via `tools/deploy` (sync → remote
   pytest → restart on green; local runs only as a pre-v1.1 bootstrap), `ruff check server tests` and
   `mypy server` (strict); an issue touching `firmware/` also runs `idf.py build` + a USB flash/smoke
   when device-visible — **external services are mocked by default and the fake device drives the
   wire; a live call is permitted but opt-in.** Walk each acceptance criterion against
   the phase DoD/Tests in `specification/ROADMAP.md`. Record pass/fail.
5. **Commit** (one issue = one commit; only code that passes validation):
   ```bash
   git commit -m "$(cat <<'EOF'
   SLATE-###: {title}

   {1-2 sentence summary of what was implemented}

   Co-Authored-By: <the running model's trailer> <noreply@anthropic.com>
   EOF
   )"
   ```
   (No `Closes #…` line — there is no GitHub issue.)
6. **Push:** `git push`.
7. **Log** the issue ID + title, commit hash, files, validation result, status.

### Step 3: Handle failures

If implementation or validation fails: do **not** commit broken code; `git checkout -- .` to revert;
log the failure; then ask the user — continue to the next issue (if nothing depends on the failed one)
or stop.

### Step 3b: No automatic version bump

Do **not** change the version (VERSION/RELEASE.txt/tag) here — that is `/release-version`, on explicit
confirmation. If any issue failed or was skipped, do **not** treat the version as complete.

### Step 4: Write the execution report

Write `specification/roadmap/implementation/vA.B-execution-report.md`: a summary table (completed/failed/skipped),
a per-issue table (RF ID · title · status · commit · files · tests), detailed results with the
validation checklist, and next steps. Commit + push it (an `RF`/`docs` message with the trailer).
(No GitHub mapping section — this run never touched GitHub.)

## Important Rules

- **File-driven, no GitHub.** The issue list, details, and dependency order come from the local
  `*-issues.md` file. Never `gh issue list`/`create`/`close`. No `vA.B-github-report.md` is written.
- **Generate every line fresh** — never recover code from git history or another ref.
- **One issue = one commit.** Never mix work across IDs; never work on two issues at once.
- **Dependency order.** Never start an issue whose file-listed dependencies aren't committed.
- **No broken code.** Only commit what passes `pytest` + strict `mypy`.
- **Tests ship with the feature; the LLM is mocked by default** — no paid API call in tests/validation.
- **Meaning lives on the server**; the firmware renders what it is sent and reports events;
  **contracts stay stable** (seam change → `specification/ARCHITECTURE.md` + contract test in the same commit);
  **the action registry is the boundary**; **secrets stay in `server/.env`**.
- **Ask on ambiguity.** If an issue's scope is unclear, ask rather than guess.
- **Progress updates.** Print a short status line after each issue.
