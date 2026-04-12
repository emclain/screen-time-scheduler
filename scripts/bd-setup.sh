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
bd import
