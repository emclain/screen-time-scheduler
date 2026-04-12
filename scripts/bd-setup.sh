#!/usr/bin/env bash
# bd-setup.sh — pull latest and ensure the beads database is ready.
#
# Shared by agent-start.sh (issue work) and ad-hoc agent sessions.
# Safe to run multiple times: git pull is a no-op when up-to-date,
# bd init only runs if bd is broken, and bd import uses upsert semantics.
#
# Usage (from repo root):
#   source scripts/bd-setup.sh
# or:
#   bash scripts/bd-setup.sh

set -euo pipefail

# ── 0. Commit any dirty issues.jsonl before pulling ───────────────────────
# A previous session may have written beads without exporting+committing.
# Committing here prevents the merge from aborting due to local changes.
if ! git diff --quiet .beads/issues.jsonl 2>/dev/null || \
   ! git diff --cached --quiet .beads/issues.jsonl 2>/dev/null; then
  echo "Committing local issues.jsonl changes before pull..."
  git add .beads/issues.jsonl
  git diff --cached --quiet || git commit -m "bd sync: commit local issues.jsonl before pull"
fi

# ── 0b. Register the issues.jsonl merge driver (idempotent) ──────────────
# The driver auto-resolves concurrent agent writes by taking newest updated_at
# per issue ID. Must be configured per-clone; .gitattributes maps the driver.
REPO_ROOT="$(git rev-parse --show-toplevel)"
git config merge.beads-jsonl.name "Beads JSONL merge driver (newest updated_at wins)" 2>/dev/null || true
git config merge.beads-jsonl.driver \
  "python3 \"$REPO_ROOT/scripts/merge-issues-jsonl.py\" %O %A %B" 2>/dev/null || true

# ── 0c. Set beads role ────────────────────────────────────────────────────
# Agents use the emclain-agent GitHub identity, which is a contributor.
git config beads.role contributor 2>/dev/null || true

# ── 1. Pull latest ─────────────────────────────────────────────────────────
# Must happen first so the agent sees all files (PLAN.md, DESIGN.md, etc.)
# and the freshest issues.jsonl before populating the local Dolt DB.
echo "Pulling latest from origin..."
git pull --no-rebase origin main

# ── 2. Ensure bd is initialised and up-to-date ─────────────────────────────
# The embedded Dolt DB is gitignored and starts empty on every fresh
# container. bd import (upsert) rebuilds it from the git-tracked issues.jsonl.
# Only run bd init if bd itself is broken (non-zero exit from bd list).
if ! bd list &>/dev/null 2>&1; then
  echo "Initialising beads database..."
  bd init --force --prefix screen
fi
echo "Importing beads from issues.jsonl..."
# bd import exits non-zero when Dolt has nothing to commit (already in sync).
# Capture stderr so we can re-raise on real errors but swallow the no-op case.
import_err=$(bd import 2>&1) || {
  if ! echo "$import_err" | grep -q "nothing to commit"; then
    echo "$import_err" >&2; exit 1
  fi
}
