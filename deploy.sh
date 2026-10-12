#!/bin/bash
# Legacy helper: copy the flake to /etc/nixos on the target and nixos-rebuild switch.
# Prefer deploy-rs:  nix run github:serokell/deploy-rs -- .#<host>
set -euo pipefail

HOST="${1:?usage: ./deploy.sh <host>   (calamansi-intel | sitaw-amd)}"
case "$HOST" in
  calamansi-intel) TARGET="root@192.168.2.81" ;;
  sitaw-amd)       TARGET="root@192.168.2.82" ;;
  *) echo "unknown host: $HOST (expected calamansi-intel or sitaw-amd)" >&2; exit 1 ;;
esac
SSH_OPTS="-o StrictHostKeyChecking=no -i ~/.ssh/id_ed25519"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "==> Syncing configuration files to $TARGET..."
ssh $SSH_OPTS "$TARGET" "mkdir -p /etc/nixos/hosts/$HOST /etc/nixos/modules"
scp $SSH_OPTS "$SCRIPT_DIR"/flake.nix "$SCRIPT_DIR"/flake.lock "$TARGET:/etc/nixos/"
scp $SSH_OPTS "$SCRIPT_DIR"/hosts/"$HOST"/*.nix "$TARGET:/etc/nixos/hosts/$HOST/"
scp $SSH_OPTS "$SCRIPT_DIR"/modules/*.nix "$TARGET:/etc/nixos/modules/"

echo "==> Building configuration for $HOST..."
ssh $SSH_OPTS "$TARGET" "cd /etc/nixos && nixos-rebuild build --flake .#$HOST"

echo "==> Activating on $TARGET..."
ssh $SSH_OPTS "$TARGET" "cd /etc/nixos && nixos-rebuild switch --flake .#$HOST"

echo "==> Done!"
