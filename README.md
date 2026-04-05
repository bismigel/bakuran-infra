# Bakuran Sosyal

NixOS configuration for a Kubernetes (k3s) server cluster managed with Colmena.

## Overview

This repository contains NixOS configurations for setting up a k3s cluster using Colmena for deployment management. The configuration is designed for a clean NixOS installation with essential packages and services.

## Quick Start

### 1. Install Colmena
```bash
# Install Nix package manager first
curl -L https://nixos.org/nix/install | sh

# Install colmena
nix-env -iA nixpkgs.colmena

# Alternative: Use project shell (if Nix is installed)
nix-shell shell.nix
```

### 2. Configure Your Node
Edit `colmena.nix`:
- Set `targetHost` to your server IP (192.168.2.81 for calamansi)
- Configure passwords and SSH keys in `configuration.nix`

### 3. Deploy
```bash
# Test configuration
colmena eval

# Deploy to calamansi
colmena apply --on calamansi
```

### 4. Access k3s Cluster
```bash
# Get kubeconfig from server
colmena exec-on calamansi -- cat /etc/rancher/k3s/k3s.yaml
```

For detailed instructions, see [DEPLOYMENT.md](DEPLOYMENT.md).

## Configuration

The main configuration file is `configuration.nix` which includes:

- Systemd-boot EFI bootloader
- NetworkManager for networking
- OpenSSH server with root login enabled (adjust for production)
- k3s and colmena packages
- Basic development tools (vim, curl, git)

## Deployment with Colmena

See `colmena.nix` for node definitions and `DEPLOYMENT.md` for comprehensive deployment guide.

## Security Notes

- Default configuration permits root SSH with password authentication
- Change passwords and use SSH keys in production
- Review firewall and service exposure

### Generating Password Hashes

To generate a SHA-512 password hash for NixOS configuration:

```bash
mkpasswd -m sha-512
# or using openssl:
openssl passwd -6 -salt $(openssl rand -hex 4)
```

Replace the `hashedPassword` field in `configuration.nix` with the generated hash.

## Development

Use `nix-shell` for development environment (if `shell.nix` exists).

## License

MIT