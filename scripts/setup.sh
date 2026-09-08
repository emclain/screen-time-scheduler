#!/usr/bin/env bash
# setup.sh — one-time setup for a fresh checkout or new container.
#
# Run once after cloning:
#   cd <your screen-time-scheduler checkout>
#   bash scripts/setup.sh

set -euo pipefail

# ── 0. Fix git remote if SSH is unavailable but GITHUB_TOKEN exists ───────
# Sandboxed environments often lack SSH but have a token in the environment.
if [[ -n "${GITHUB_TOKEN:-}" ]]; then
  CURRENT_REMOTE=$(git remote get-url origin 2>/dev/null || echo "")
  if [[ "$CURRENT_REMOTE" == git@github.com:* ]]; then
    # Extract owner/repo from git@github.com:owner/repo.git
    REPO_PATH="${CURRENT_REMOTE#git@github.com:}"
    NEW_REMOTE="https://x-access-token:${GITHUB_TOKEN}@github.com/${REPO_PATH}"
    echo "Reconfiguring git remote from SSH to HTTPS (GITHUB_TOKEN detected)..."
    git remote set-url origin "$NEW_REMOTE"
  fi
fi

# ── 1. Install the bd CLI if not already present ──────────────────────────
if ! command -v bd &>/dev/null; then
  echo "Installing bd CLI..."
  curl -sSL https://raw.githubusercontent.com/steveyegge/beads/main/scripts/install.sh | bash
else
  echo "bd already installed: $(command -v bd)"
fi

# ── 1b. Install dolt if not already present ───────────────────────────
# bd stores everything in Dolt and does NOT bundle it. Without dolt on PATH
# every bd command fails with "Dolt server unreachable", which reads like a
# server problem rather than a missing dependency.
if ! command -v dolt &>/dev/null; then
  echo "Installing dolt..."
  if command -v brew &>/dev/null; then
    brew install dolt
  else
    echo "ERROR: dolt is not installed and Homebrew is unavailable." >&2
    echo "Install it manually: https://docs.dolthub.com/introduction/installation" >&2
    exit 1
  fi
else
  echo "dolt already installed: $(command -v dolt)"
fi

# ── 1c. Install the bd git guard ──────────────────────────────────────────
# bd must never mutate git in this repo; see AGENTS.md and bead screen-tm2.
bash "$(dirname "$0")/install-bd-git-guard.sh"

# ── 2. Pull latest ────────────────────────────────────────────────────────
echo "Pulling latest from origin..."
git pull --no-rebase origin main

# ── 3. Initialise the beads database ─────────────────────────────────────
echo "Initialising beads database..."
bd init --force --prefix screen

# Fix .beads permissions to suppress warnings that pollute stdout
if [[ -d .beads ]]; then
  chmod 700 .beads
fi

bd import
bd list

# ── 4. Register the issues.jsonl merge driver ────────────────────────────
# The driver auto-resolves concurrent agent writes by taking newest updated_at
# per issue ID. The .gitattributes file maps the driver to issues.jsonl.
echo "Registering beads-jsonl merge driver..."
REPO_ROOT="$(git rev-parse --show-toplevel)"
git config merge.beads-jsonl.name "Beads JSONL merge driver (newest updated_at wins)"
git config merge.beads-jsonl.driver \
  "python3 \"$REPO_ROOT/scripts/merge-issues-jsonl.py\" %O %A %B"

# ── 5. Install git hooks ──────────────────────────────────────────────────
echo "Installing git hooks..."
cp scripts/pre-commit.hook .git/hooks/pre-commit
chmod +x .git/hooks/pre-commit

echo ""
echo "Setup complete. Run 'bash scripts/agent-start.sh' to begin work."
