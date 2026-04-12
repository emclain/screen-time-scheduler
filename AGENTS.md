# Goals

See [RESEARCH.md](RESEARCH.md) for the overall goals, scope, and background
of this project.

# Work Tracking

As a work tracking system, we use Beads (see instructions below)
https://github.com/steveyegge/beads
instead of unstructured markdown or Claude memory files. Start with a
plan and work your way through breaking it down into smaller pieces,
filing beads as you go.

If you find issues impeding your work, file them as beads rather than
context switching to try to fix them.

Work in small bites, file beads as you go, and push your changes
without my prompting. When you reach the end of your context window,
prefer to use beads as your memory and quit rather than compacting.

# Agent Instructions

This project uses **bd** (beads) for issue tracking. Run `bd onboard` to get started.

## Two modes

Agents are used in two ways:

- **Ad-hoc** — investigate, plan, answer a question, or do a focused task
  directed by the user. Does not autonomously claim issues. Follows the
  Ad-hoc Workflow below.

- **Issue work** — claim an open issue, implement it, and land it. Follows the
  Issue Workflow below.

If you're not sure which mode you're in, wait for instructions rather than
claiming an issue.

Both modes share the same **Land** and **Reflect** obligations — all changes
must be committed and pushed before stopping.

## Setup (fresh checkout)

For a brand-new checkout (installs `bd` CLI if absent):

```bash
bash scripts/setup.sh
```

## Beads state and `main`

`.beads/issues.jsonl` on `main` is the **canonical beads database** shared by
all agents, whether running in worktrees, fresh checkouts, or containers.

`bd-setup.sh` rebuilds the local Dolt DB from this file at the start of every
session. The Dolt DB itself is runtime state and is never committed to git.

**This means every `bd export` must land on `main`.** An export committed only
to a feature branch is invisible to other agents until it merges. Both workflows
below ensure this: ad-hoc agents work directly on `main`; issue-work agents
push their export commit via `work/<id>:main` in `agent-land.sh`.

## Ad-hoc Workflow

### 1. Start

```bash
bash scripts/bd-setup.sh
```

This pulls latest from `origin/main` and rebuilds the local beads DB from
`issues.jsonl`. Then wait for instructions.

### 2. Work

Do the directed work. Stay narrowly focused on what was asked. If you notice
related problems or tempting tangents, file a bead and move on.

```bash
git add <files>
git commit -m "<message>"
```

### 3. Land

File beads for anything you noticed but didn't work on:

```bash
bd create --title="..." --type=task --priority=<n>
```

Export beads state and push everything:

```bash
bd export > .beads/issues.jsonl
git add .beads/issues.jsonl
git diff --cached --quiet || git commit -m "bd sync: <description>"
git fetch origin main
git merge origin/main
git push
```

### 4. Reflect

Same obligations as Issue Workflow step 4 — see below.

## Git Policy

**Never rebase.** Always use merge to integrate changes between branches. Rebase rewrites history and creates problems when branches are shared.

```bash
git fetch origin
git merge origin/<branch>   # not git rebase
```

### Pushing to GitHub

If `git push` fails with authentication or "no remote" errors, check whether credentials
are available in the environment before giving up:

```bash
# Check for GitHub token
echo $GITHUB_TOKEN
echo $GH_TOKEN

# Check for configured remote
git remote -v

# If token exists but remote is missing, configure it:
git remote add origin https://${GITHUB_TOKEN}@github.com/<owner>/<repo>.git
# or for GH_TOKEN:
git remote set-url origin https://${GH_TOKEN}@github.com/<owner>/<repo>.git
```

If credentials exist, use them to push. If no credentials are available and no remote
is configured, ask the user to pull the changes locally and use the Merge workflow
to integrate them.

## Issue Workflow

Each agent works on **exactly one issue**, then stops.

> **⚠️ CRITICAL: Always pull before claiming**
>
> Before claiming any work, you MUST have the latest code from `origin/main`.
> Use `agent-start.sh` — it handles this automatically. If you manually run
> `bd update <id> --claim` without pulling first, you will work on stale code
> and create merge conflicts or duplicate work.

### 1. Start

```bash
cd <your screen-time-scheduler checkout>
bash scripts/agent-start.sh
```

(`agent-start.sh` calls `bd-setup.sh` automatically — no need to run it separately.)

The script pulls from `origin/main`, claims the highest-priority available
issue, and creates an isolated git worktree for it. If it prints
"No available work", stop.

Then source the environment file — this must be done in your shell so that
`CLAIMED_ID` is available to subsequent commands:

```bash
source .agent-env
```

### 2. Work

```bash
bd show $CLAIMED_ID   # review the issue
```

Do the work. Stay narrowly focused on what the issue describes. If you notice
related problems or tempting tangents, file a bead and move on.

```bash
git add <files>
git commit -m "<message>"
```

### 3. Land

File beads for anything you noticed but didn't work on:

```bash
bd create --title="..." --type=task --priority=<n>
```

Then run the landing script:

```bash
bash scripts/agent-land.sh
```

This script: closes the issue, pushes via a fetch-merge-retry loop, exports
beads state, commits and pushes that, then removes the worktree. Work is not
complete until `git push` succeeds — the script handles retries.

### 4. Reflect

Before stopping, review the session for friction, gaps, or follow-up work.
This step is **not optional**.

For every issue encountered (missing steps, unclear instructions, new edge cases):

- **If a script failed or was incomplete:** fix it in-place.
- **If instructions in this file were wrong or missing:** update them.
- **If the fix requires deeper investigation:** file a bead instead.

The goal: the next agent should be able to run `bash scripts/agent-start.sh`,
do their work, and run `bash scripts/agent-land.sh` with no manual intervention.

**Stop after one issue.** Do not loop back to claim another.

<!-- BEGIN BEADS INTEGRATION v:1 profile:minimal hash:ca08a54f -->
## Beads Issue Tracker

This project uses **bd (beads)** for issue tracking. Run `bd prime` to see full workflow context and commands.

### Quick Reference

```bash
bd ready              # Find available work (info only)
bd show <id>          # View issue details
bd close <id>         # Complete work
```

> **Do NOT manually run `bd update <id> --claim`** — use `agent-start.sh` instead.
> It pulls latest code first, preventing stale-branch issues.

### Rules

- Use `bd` for ALL task tracking — do NOT use TodoWrite, TaskCreate, or markdown TODO lists
- Run `bd prime` for detailed command reference and session close protocol
- Use `bd remember` for persistent knowledge — do NOT use MEMORY.md files

> **Note:** `bd dolt push` always fails in this environment — no dolt remote is configured.
> Use `bd export > .beads/issues.jsonl` + git commit + push instead (handled by `agent-land.sh`).
<!-- END BEADS INTEGRATION -->
