#!/usr/bin/env bash
# tart-dev.sh — Launch sequoia-xcode16 VM with project directory mounted
# and an SSH session with agent forwarding.
#
# Usage:
#   bash scripts/tart-dev.sh [vm-name]
#
# Default VM: sequoia-xcode16
# Mounts: repo root → /Volumes/project inside the VM
#
# After this script runs, $SSH_AUTH_SOCK on the host is forwarded so
# git operations inside the VM use your local SSH agent.

set -euo pipefail

VM="${1:-sequoia-xcode16}"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SHARE_NAME="project"
# macOS guests mount all VirtioFS shares under /Volumes/My Shared Files/<tag>
GUEST_MOUNT="/Volumes/My Shared Files/${SHARE_NAME}"
SSH_USER="admin"
SSH_OPTS="-A -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=5"

# ── 1. Check prerequisites ─────────────────────────────────────────────────
if ! command -v tart &>/dev/null; then
  echo "Error: tart not found. Install with: brew install cirruslabs/cli/tart" >&2
  exit 1
fi

if [[ -z "${SSH_AUTH_SOCK:-}" ]]; then
  echo "Warning: SSH_AUTH_SOCK is not set — agent forwarding will not work." >&2
  echo "  Start your SSH agent:  eval \"\$(ssh-agent -s)\" && ssh-add" >&2
fi

# ── 2. Start VM if not already running ────────────────────────────────────
STATE=$(tart list 2>/dev/null | awk -v vm="$VM" '$2 == vm { print $NF }')
if [[ "$STATE" == "running" ]]; then
  echo "VM '${VM}' is already running."
else
  echo "Starting VM '${VM}' with share '${SHARE_NAME}' → ${REPO_ROOT} ..."
  tart run "$VM" \
    --dir="${SHARE_NAME}:${REPO_ROOT}" \
    --no-graphics \
    &
  TART_PID=$!
  # Trap to stop the VM if this script is killed before we hand off to SSH
  trap 'echo "Stopping VM..."; tart stop "$VM" 2>/dev/null || true; wait $TART_PID 2>/dev/null || true' EXIT INT TERM
fi

# ── 3. Wait for SSH to become available ───────────────────────────────────
echo "Waiting for VM to boot and accept SSH..."
MAX_WAIT=120
ELAPSED=0
VM_IP=""
while [[ $ELAPSED -lt $MAX_WAIT ]]; do
  VM_IP=$(tart ip "$VM" 2>/dev/null || true)
  if [[ -n "$VM_IP" ]]; then
    if ssh $SSH_OPTS "${SSH_USER}@${VM_IP}" "true" 2>/dev/null; then
      break
    fi
  fi
  sleep 3
  ELAPSED=$((ELAPSED + 3))
done

if [[ -z "$VM_IP" ]]; then
  echo "Error: timed out waiting for VM IP." >&2
  exit 1
fi
echo "VM IP: ${VM_IP}"

# ── 4. Wait for VirtioFS auto-mount ──────────────────────────────────────
# macOS guests auto-mount VirtioFS shares at /Volumes/<name> — no manual
# mount_virtiofs call needed. Just wait for the mount to appear.
echo "Waiting for VirtioFS share to auto-mount at ${GUEST_MOUNT}..."
MOUNT_WAIT=30
MOUNT_ELAPSED=0
until ssh $SSH_OPTS "${SSH_USER}@${VM_IP}" "test -d '${GUEST_MOUNT}'" 2>/dev/null; do
  sleep 2
  MOUNT_ELAPSED=$((MOUNT_ELAPSED + 2))
  if [[ $MOUNT_ELAPSED -ge $MOUNT_WAIT ]]; then
    echo "Warning: ${GUEST_MOUNT} not visible after ${MOUNT_WAIT}s — continuing anyway." >&2
    break
  fi
done
echo "  Share available at ${GUEST_MOUNT}"

# ── 5. Unlock login keychain (required for Claude auth in headless sessions) ─
echo "Unlocking login keychain (enter VM password when prompted)..."
ssh $SSH_OPTS -t "${SSH_USER}@${VM_IP}" \
  "security unlock-keychain ~/Library/Keychains/login.keychain-db"

# ── 6. Hand off interactive SSH session ───────────────────────────────────
# Disable the EXIT trap — we want the VM to keep running after we disconnect.
trap - EXIT INT TERM

echo ""
echo "Connecting to ${SSH_USER}@${VM_IP} (agent forwarding enabled)..."
echo "  Project mounted at: ${GUEST_MOUNT}"
echo "  Use 'tart stop ${VM}' when done."
echo ""

exec ssh $SSH_OPTS "${SSH_USER}@${VM_IP}"
