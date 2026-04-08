#!/usr/bin/env bash
# setup.sh — one-time setup for a fresh checkout or new container.
#
# Run once after cloning:
#   cd <your screen-time-scheduler checkout>
#   bash scripts/setup.sh

set -euo pipefail

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
bd import
bd list

echo ""
echo "Setup complete. Run 'bash scripts/agent-start.sh' to begin work."
