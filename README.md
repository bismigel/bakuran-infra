# Bakuran Sosyal

NixOS configuration for a Kubernetes (k3s) server cluster managed with Colmena.

## Overview

This repository contains NixOS configurations for setting up a k3s cluster using Colmena for deployment management. The configuration is designed for a clean NixOS installation with essential packages and services.

## Configuration

The main configuration file is `configuration.nix` which includes:

- Systemd-boot EFI bootloader
- NetworkManager for networking
- OpenSSH server with root login enabled (adjust for production)
- k3s and colmena packages
- Basic development tools (vim, curl, git)

## Usage

### Initial Setup

1. Generate hardware configuration on target system:
   ```bash
   sudo nixos-generate-config --root /mnt
   ```

2. Copy `configuration.nix` to `/mnt/etc/nixos/` and customize:
   - Set hostname
   - Configure users and passwords
   - Adjust package list

3. Install NixOS:
   ```bash
   sudo nixos-install
   ```

### Cluster Deployment with Colmena

See `colmena.nix` example for multi-node deployment.

## Security Notes

- Default configuration permits root SSH with password authentication
- Change passwords and use SSH keys in production
- Review firewall and service exposure

## Development

Use `nix-shell` for development environment (if `shell.nix` exists).

## License

MIT