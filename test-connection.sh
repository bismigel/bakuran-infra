#!/bin/bash
set -e

echo "=== Testing SSH connection to calamansi ==="

# Test SSH connection
if sshpass -p 'Adobolover123!' ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null root@192.168.2.81 "echo '✓ SSH connection successful'; hostname"; then
    echo "✓ SSH test passed"
else
    echo "✗ SSH test failed"
    echo "Make sure:"
    echo "1. Server is running at 192.168.2.81"
    echo "2. SSH service is enabled"
    echo "3. Password is correct (currently using 'Adobolover123!')"
    exit 1
fi

echo ""
echo "=== Checking NixOS version ==="
sshpass -p 'Adobolover123!' ssh -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null root@192.168.2.81 "nixos-version"

echo ""
echo "=== Checking essential services ==="
sshpass -p 'Adobolover123!' ssh -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null root@192.168.2.81 "systemctl is-active sshd || echo 'SSH service not active'"

echo ""
echo "=== Testing sudo access for calamansi user ==="
if sshpass -p 'Adobolover123!' ssh -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null calamansi@192.168.2.81 "echo '✓ Logged in as calamansi'; sudo -n true 2>/dev/null && echo '✓ Sudo access available' || echo '⚠ Sudo may require password'"; then
    echo "✓ Calamansi user accessible"
else
    echo "✗ Calamansi user test failed"
fi

echo ""
echo "=== Deployment checklist ==="
echo "1. [✓] SSH connection works"
echo "2. [ ] Install colmena on local machine (see DEPLOYMENT.md)"
echo "3. [ ] Configure colmena.nix for your setup"
echo "4. [ ] Run: colmena eval"
echo "5. [ ] Run: colmena apply --on calamansi"