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

# ── 2. Detect filesystem and configure dolt mode ───────────────────────────
# VirtioFS (used when this repo is mounted into a Tart VM) doesn't support
# fsync, so embedded Dolt fails.  Detect it by checking the mount type;
# if on VirtioFS, use an external dolt sql-server whose data lives on the
# VM's local SSD instead.
REPO_ROOT_FOR_MOUNT="$(git rev-parse --show-toplevel)"
# Detect VirtioFS: macOS uses "AppleVirtIOFS", Linux uses "virtiofs".
# We check the device backing the repo root then look it up in mount/proc.
_DEVICE="$(df "$REPO_ROOT_FOR_MOUNT" 2>/dev/null | awk 'NR==2{print $1}')"
_ON_VIRTIOFS=false
if mount | grep -q "^$_DEVICE" && mount | grep "^$_DEVICE" | grep -qi "virtiofs\|AppleVirtIOFS"; then
  _ON_VIRTIOFS=true
elif grep -q " virtiofs " /proc/mounts 2>/dev/null && \
     awk -v d="$_DEVICE" '$1==d{print $3}' /proc/mounts | grep -q virtiofs; then
  _ON_VIRTIOFS=true
fi

BD_INIT_EXTRA_FLAGS=""
if [ "$_ON_VIRTIOFS" = "true" ]; then
  # ── VirtioFS VM: use external dolt server on local SSD ──────────────────
  DOLT_DATA_DIR="/Users/admin/.beads-dolt-server"
  DOLT_LOG="$DOLT_DATA_DIR/dolt-server.log"
  if ! lsof -i :3307 &>/dev/null 2>&1; then
    echo "Starting dolt sql-server (VirtioFS mode)..."
    mkdir -p "$DOLT_DATA_DIR"
    nohup /opt/homebrew/bin/dolt sql-server \
      --host 127.0.0.1 --port 3307 \
      --data-dir "$DOLT_DATA_DIR" \
      > "$DOLT_LOG" 2>&1 &
    for i in $(seq 1 10); do
      sleep 1
      lsof -i :3307 &>/dev/null && break
      echo "  waiting for dolt server... ($i)"
    done
  fi
  BD_INIT_EXTRA_FLAGS="--server --server-host 127.0.0.1 --server-port 3307 --server-user root"
fi

# ── 3. Ensure bd is initialised and up-to-date ─────────────────────────────
# Only run bd init if bd is broken (non-zero exit from bd list).
if ! bd list &>/dev/null 2>&1; then
  echo "Initialising beads database..."
  # shellcheck disable=SC2086
  bd init --force --prefix screen --from-jsonl --non-interactive \
    --skip-agents --skip-hooks $BD_INIT_EXTRA_FLAGS
fi
echo "Importing beads from issues.jsonl..."
# bd import exits non-zero when Dolt has nothing to commit (already in sync).
# Capture stderr so we can re-raise on real errors but swallow the no-op case.
import_err=$(bd import 2>&1) || {
  if ! echo "$import_err" | grep -q "nothing to commit"; then
    echo "$import_err" >&2; exit 1
  fi
}
