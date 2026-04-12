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

- **Ad-hoc** — investigate, plan, answer a question, or do a focused task that
  doesn't map to an existing issue. Read this file for context, then wait for
  instructions. The Workflow section below does not apply.

- **Issue work** — claim an open issue, implement it, and land it. Follow the
  Workflow section below.

If you're not sure which mode you're in, wait for instructions rather than
claiming an issue.

## Setup (fresh checkout)

```bash
bash scripts/setup.sh
```

This script: installs the `bd` CLI if absent, pulls latest, initialises the
beads database, runs `bd import`, and runs `bd list` to confirm the database
is healthy.

> **Note:** The Dolt database is runtime state (not in git). `setup.sh` rebuilds
> it from `.beads/issues.jsonl` on every fresh checkout or container.

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

### 1. Start

```bash
cd <your screen-time-scheduler checkout>
bash scripts/agent-start.sh
```

The script pulls from `origin/main` first, then claims the highest-priority
available issue and creates an isolated git worktree for it. If it prints
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
bd ready              # Find available work
bd show <id>          # View issue details
bd update <id> --claim  # Claim work
bd close <id>         # Complete work
```

### Rules

- Use `bd` for ALL task tracking — do NOT use TodoWrite, TaskCreate, or markdown TODO lists
- Run `bd prime` for detailed command reference and session close protocol
- Use `bd remember` for persistent knowledge — do NOT use MEMORY.md files

> **Note:** `bd dolt push` always fails in this environment — no dolt remote is configured.
> Use `bd export > .beads/issues.jsonl` + git commit + push instead (handled by `agent-land.sh`).
<!-- END BEADS INTEGRATION -->
