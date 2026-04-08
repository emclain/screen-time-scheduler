#!/usr/bin/env bash
# agent-land.sh — land completed work and clean up the worktree.
#
# Run this from inside the worktree (after sourcing .agent-env):
#   source .agent-env
#   bash scripts/agent-land.sh
#
# Requires: CLAIMED_ID set in environment (via .agent-env).

set -euo pipefail

if [ -z "${CLAIMED_ID:-}" ]; then
  echo "ERROR: CLAIMED_ID is not set. Did you source .agent-env?" >&2
  exit 1
fi

# ── 1. Close the issue ────────────────────────────────────────────────────
echo "Closing issue $CLAIMED_ID..."
bd close "$CLAIMED_ID"

# ── 2. Push work branch to main (retry on race) ───────────────────────────
echo "Pushing work/$CLAIMED_ID to main..."
while true; do
  git fetch origin main
  git merge origin/main --no-edit
  git push origin "work/$CLAIMED_ID:main" && break
  echo "Push rejected — another instance landed first, retrying..."
  sleep 1
done

# ── 3. Export beads state and push ────────────────────────────────────────
echo "Syncing beads state..."
bd export > .beads/issues.jsonl
git add .beads/issues.jsonl
git diff --cached --quiet || git commit -m "bd sync: update issues.jsonl after $CLAIMED_ID"

while true; do
  git fetch origin main
  git merge origin/main --no-edit
  git push origin "work/$CLAIMED_ID:main" && break
  echo "Push rejected — retrying..."
  sleep 1
done

# ── 4. Clean up worktree ──────────────────────────────────────────────────
echo "Cleaning up worktree..."
worktree_path="$(pwd)"
main_checkout="$(dirname "$(git rev-parse --path-format=absolute --git-common-dir)")"
cd "$main_checkout"
git worktree remove --force "$worktree_path"
git branch -d "work/$CLAIMED_ID" 2>/dev/null || true

echo ""
echo "Done. Issue $CLAIMED_ID landed and pushed."
