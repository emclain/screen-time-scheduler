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

# ── 4. Install git hooks ──────────────────────────────────────────────────
echo "Installing git hooks..."
cp scripts/pre-commit.hook .git/hooks/pre-commit
chmod +x .git/hooks/pre-commit

echo ""
echo "Setup complete. Run 'bash scripts/agent-start.sh' to begin work."
