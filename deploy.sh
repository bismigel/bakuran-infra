#!/bin/bash
set -euo pipefail

HOST="${1:-calamansi}"
TARGET="root@192.168.2.81"
SSH_OPTS="-o StrictHostKeyChecking=no -i ~/.ssh/id_ed25519"

CLOSURE_PATH="/tmp/nixos-build-$HOST/result"

echo "==> Building configuration for $HOST..."
nix build ".#nixosConfigurations.$HOST.config.system.build.toplevel" \
  --out-link "$CLOSURE_PATH"

PROFILE_TARGET=$(readlink "$CLOSURE_PATH")

echo "==> Copying to $TARGET..."
nix copy --to "ssh://$TARGET" "$CLOSURE_PATH"

echo "==> Activating on $TARGET..."
ssh $SSH_OPTS "$TARGET" "
  rm -f /nix/var/nix/profiles/system
  ln -s $PROFILE_TARGET /nix/var/nix/profiles/system
  $PROFILE_TARGET/bin/switch-to-configuration switch
"

echo "==> Done!"
