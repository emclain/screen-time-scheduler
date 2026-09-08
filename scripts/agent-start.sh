#!/usr/bin/env bash
# agent-start.sh — bootstrap a single-issue agent session.
#
# Run this from the shared checkout root:
#   cd <your screen-time-scheduler checkout>
#   bash scripts/agent-start.sh
#
# On success: prints the worktree path and writes .agent-env there.
# On "no available work": prints a message and exits 0.
# On error: exits non-zero.

set -euo pipefail

# ── 1–2. Pull latest and initialise beads DB ──────────────────────────────
bash "$(dirname "$0")/bd-setup.sh"

# ── 3. Claim the highest-priority available issue ──────────────────────────
claimed=""
for id in $(bd ready --json --limit 10 2>/dev/null | jq -r '.[].id'); do
  if bd update "$id" --claim 2>/dev/null; then
    claimed="$id"
    break
  fi
done

if [ -z "$claimed" ]; then
  echo "No available work."
  exit 0
fi

echo "Claimed issue: $claimed"

# ── 3b. Push the claim to main so other agents see it as IN_PROGRESS ─────────
bd export > .beads/issues.jsonl
git add .beads/issues.jsonl
git diff --cached --quiet || git commit -m "bd sync: claim $claimed"
git push origin main

# ── 4. Create an isolated worktree + branch ────────────────────────────────
repo_name=$(basename "$(git rev-parse --show-toplevel)")
worktree="../${repo_name}-$claimed"

# Clean up any leftover worktree from a previous (failed) attempt
if [ -d "$worktree" ]; then
  git worktree remove --force "$worktree" 2>/dev/null || true
  git branch -D "work/$claimed" 2>/dev/null || true
fi

git worktree add "$worktree" -b "work/$claimed" origin/main

# ── 5. Copy beads config into the worktree ─────────────────────────────────
# Worktrees do not inherit .beads/ — copy config and port file so bd
# in the worktree connects to the same already-running server.
mkdir -p "$worktree/.beads"
cp -f .beads/config.yaml "$worktree/.beads/"
if [ -f .beads/dolt-server.port ]; then
  cp -f .beads/dolt-server.port "$worktree/.beads/"
fi

# ── 6. Write .agent-env ────────────────────────────────────────────────────
cat > "$worktree/.agent-env" <<EOF
export CLAIMED_ID=$claimed
export BEADS_ACTOR="agent-$(hostname)-$$"
EOF

echo ""
echo "Worktree ready: $worktree"
echo "Run:"
echo "  cd $worktree"
echo "  source .agent-env"
echo "  bd show \$CLAIMED_ID"
