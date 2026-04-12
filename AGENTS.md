# Goals

See [RESEARCH.md](RESEARCH.md) for goals, scope, and background.

# Work Tracking

Use [Beads](https://github.com/steveyegge/beads) (`bd`) for all issue tracking — not markdown files or Claude memory. File beads as you go, work in small bites, and push without prompting. When approaching context limits, prefer filing beads and stopping over compacting.

If you hit a blocking problem, file it as a bead rather than context-switching to fix it.

# Agent Instructions

## Two modes

- **Ad-hoc** — directed by the user; does not autonomously claim issues. Follows the Ad-hoc Workflow below.
- **Issue work** — claims an open issue, implements it, lands it. Follows the Issue Workflow below.

If unsure which mode you're in, wait for instructions before claiming anything.

Both modes share the same **Land** and **Reflect** obligations — all changes must be committed and pushed before stopping.

## Setup (fresh checkout)

```bash
bash scripts/setup.sh   # installs bd CLI if absent
```

## Beads state and `main`

`.beads/issues.jsonl` on `main` is the **canonical beads database** shared by all agents — worktrees, fresh checkouts, and containers all rebuild from it. The Dolt DB is runtime state and is never committed to git.

**Every `bd export` must land on `main`.** An export on a feature branch is invisible to other agents until merged. Both workflows below guarantee this: ad-hoc agents work on `main` directly; issue-work agents push via `work/<id>:main`.

## Ad-hoc Workflow

### 1. Start

```bash
bash scripts/bd-setup.sh
```

Pulls `origin/main` and rebuilds the local beads DB. Then wait for instructions.

### 2. Work

Stay narrowly focused on what was asked. File a bead for anything noticed but out of scope, then move on.

```bash
git add <files>
git commit -m "<message>"
```

### 3. Land

File beads for follow-up work, then export and push:

```bash
bd create --title="..." --type=task --priority=<n>   # repeat as needed

bd export > .beads/issues.jsonl
git add .beads/issues.jsonl
git diff --cached --quiet || git commit -m "bd sync: <description>"
git fetch origin main && git merge origin/main
git push
```

### 4. Reflect

Review for friction, gaps, or follow-up. For every issue encountered:

- **Script failed or incomplete** → fix it in-place
- **Docs wrong or missing** → update this file
- **Needs deeper investigation** → file a bead

## Git Policy

**Never rebase.** Always merge.

```bash
git fetch origin
git merge origin/<branch>
```

### Pushing to GitHub

If `git push` fails with auth or "no remote" errors:

```bash
echo $GITHUB_TOKEN; echo $GH_TOKEN   # check for credentials
git remote -v                         # check remote

# If token exists but remote is missing:
git remote add origin https://${GITHUB_TOKEN}@github.com/<owner>/<repo>.git
```

If no credentials exist, ask the user to pull and integrate locally.

## Issue Workflow

Each agent works on **exactly one issue**, then stops.

> **⚠️ Always pull before claiming.** Use `agent-start.sh` — it handles this. Running `bd update <id> --claim` manually risks stale code and merge conflicts.

### 1. Start

```bash
cd <checkout>
bash scripts/agent-start.sh
source .agent-env
```

Pulls `origin/main`, claims the highest-priority available issue, and creates a git worktree. If "No available work", stop.

### 2. Work

```bash
bd show $CLAIMED_ID
```

Stay narrowly focused on what the issue describes. File a bead for anything noticed but out of scope, then move on.

```bash
git add <files>
git commit -m "<message>"
```

### 3. Land

File beads for follow-up work, then run the landing script:

```bash
bd create --title="..." --type=task --priority=<n>   # repeat as needed
bash scripts/agent-land.sh
```

The script closes the issue, merges and pushes to `main` with retries, exports beads state, commits and pushes it, then removes the worktree.

### 4. Reflect

Same obligations as Ad-hoc step 4. The goal: the next agent should be able to run `agent-start.sh`, do their work, and run `agent-land.sh` with no manual intervention.

**Stop after one issue.**

<!-- BEGIN BEADS INTEGRATION v:1 profile:minimal hash:ca08a54f -->
## Beads Reference

- Use `bd` for ALL task tracking — not TodoWrite, TaskCreate, or markdown
- Use `bd remember` for persistent knowledge — not MEMORY.md files
- `bd dolt push` always fails here — export via git instead (both scripts handle this)
- Run `bd prime` for full command reference
<!-- END BEADS INTEGRATION -->
