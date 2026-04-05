#!/bin/bash
set -euo pipefail

HOST="${1:-calamansi}"
TARGET="root@192.168.2.81"
SSH_OPTS="-o StrictHostKeyChecking=no -i ~/.ssh/id_ed25519"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "==> Syncing configuration files to $TARGET..."
ssh $SSH_OPTS "$TARGET" "mkdir -p /etc/nixos/hosts/calamansi /etc/nixos/modules"
scp $SSH_OPTS "$SCRIPT_DIR"/flake.nix "$SCRIPT_DIR"/flake.lock "$TARGET:/etc/nixos/"
scp $SSH_OPTS "$SCRIPT_DIR"/hosts/"$HOST"/*.nix "$TARGET:/etc/nixos/hosts/$HOST/"
scp $SSH_OPTS "$SCRIPT_DIR"/modules/*.nix "$TARGET:/etc/nixos/modules/"

echo "==> Building configuration for $HOST..."
ssh $SSH_OPTS "$TARGET" "cd /etc/nixos && nixos-rebuild build --flake .#$HOST"

CLOSURE=$(ssh $SSH_OPTS "$TARGET" "readlink /nix/var/nix/profiles/system")

echo "==> Activating on $TARGET..."
ssh $SSH_OPTS "$TARGET" "cd /etc/nixos && nixos-rebuild switch --flake .#$HOST"

echo "==> Done! Profile: $CLOSURE"
