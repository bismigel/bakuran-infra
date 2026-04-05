# Colmena Deployment Guide

This guide explains how to deploy NixOS configurations to your servers using Colmena.

## Prerequisites

### 1. Install Colmena

On your local machine (Arch Linux):

```bash
# Install from AUR or using your preferred method
yay -S colmena
# or
paru -S colmena
# or build from source
nix-env -iA nixos.colmena
```

On NixOS or with Nix installed:
```bash
nix-shell -p colmena
# or add to environment.systemPackages in configuration.nix
```

### 2. SSH Access to Target Nodes

Ensure you can SSH to your servers as root (or a user with sudo privileges):

```bash
# Test SSH connection to calamansi
ssh root@192.168.2.81
```

If using SSH keys, add your public key to `users.users.root.openssh.authorizedKeys.keys` or `users.users.calamansi.openssh.authorizedKeys.keys` in your configuration.

### 3. Prepare Configuration

Edit `configuration.nix` to set:
- Hostname (if different from "calamansi")
- User passwords (generate with `mkpasswd -m sha-512`)
- SSH authorized keys
- Any additional packages or services

## Configuration Structure

### `configuration.nix`
Base system configuration shared by all nodes. Contains:
- Boot configuration
- Network settings
- User accounts
- System packages
- Common services

### `colmena.nix`
Deployment-specific configuration. Defines:
- Node hostnames and IP addresses
- Node-specific overrides
- Service enablement (k3s, etc.)
- Firewall rules
- Deployment parameters

## Deployment Steps

### 1. Test Configuration

Validate your NixOS configuration syntax:

```bash
# Build configuration locally to check for errors
nix-build '<nixpkgs/nixos>' -A system -I nixos-config=./configuration.nix
```

### 2. Test Colmena Evaluation

Check if Colmena can evaluate your configuration:

```bash
colmena eval
```

### 3. Deploy to Single Node

Deploy to the calamansi server:

```bash
# Apply configuration to calamansi
colmena apply --on calamansi

# Or deploy to all nodes
colmena apply
```

### 4. Monitor Deployment

Watch the deployment progress:

```bash
# Follow logs during deployment
colmena apply --verbose

# Check node status after deployment
colmena exec -- whoami
colmena exec -- hostname
```

## Common Colmena Commands

| Command | Description |
|---------|-------------|
| `colmena apply` | Deploy configuration to all nodes |
| `colmena apply --on <node>` | Deploy to specific node |
| `colmena apply --verbose` | Show detailed output |
| `colmena eval` | Evaluate configuration without deploying |
| `colmena exec -- <command>` | Run command on all nodes |
| `colmena exec-on <node> -- <command>` | Run command on specific node |
| `colmena repl` | Interactive Nix expression evaluation |
| `colmena build` | Build configurations locally |

## Node Management

### Adding a New Node

1. Edit `colmena.nix` to add a new node definition
2. Set `targetHost` to the node's IP address
3. Configure node-specific settings
4. Deploy:

```bash
colmena apply --on <new-node-name>
```

### Removing a Node

1. Remove node definition from `colmena.nix`
2. (Optional) Clean up on target node manually

## k3s Cluster Deployment

### Initial Server Setup

The `colmena.nix` includes k3s configuration for `calamansi` as a server:

```nix
services.k3s.enable = true;
services.k3s.role = "server";
services.k3s.extraFlags = "--disable=traefik --disable=servicelb";
```

### Adding Agent Nodes

Uncomment and customize the agent template in `colmena.nix`:

1. Set `targetHost` to agent IP
2. Configure `services.k3s.serverAddr` to point to server
3. Set `services.k3s.token` (must match server token or use server node token file)

### Getting k3s Configuration

After deploying the server, get the kubeconfig:

```bash
# On the server
cat /etc/rancher/k3s/k3s.yaml

# Or via Colmena
colmena exec-on calamansi -- cat /etc/rancher/k3s/k3s.yaml
```

## Troubleshooting

### Common Issues

1. **SSH Connection Failed**
   - Check network connectivity
   - Verify SSH service is running on target
   - Confirm credentials/SSH keys

2. **Build Failures**
   - Check Nix syntax: `nix-instantiate --eval configuration.nix`
   - Ensure all referenced packages exist
   - Check for missing dependencies

3. **Permission Denied**
   - Use `targetUser = "root"` or configure sudo
   - Add `useSudo = true` in deployment settings

4. **k3s Not Starting**
   - Check logs: `journalctl -u k3s`
   - Verify firewall ports are open
   - Ensure sufficient memory/disk space

### Debugging Commands

```bash
# Check Colmena evaluation
colmena eval --debug

# Test SSH connection
colmena exec -- echo "Test"

# View node build results
colmena build

# Check active configuration on node
colmena exec-on calamansi -- nixos-rebuild dry-activate
```

## Security Considerations

1. **Use SSH Keys**: Replace password authentication with SSH keys
2. **Set Strong Passwords**: Generate secure password hashes
3. **Restrict SSH**: Change `PermitRootLogin` to `"prohibit-password"`
4. **Configure Firewall**: Enable firewall with minimal open ports
5. **Regular Updates**: Use `colmena apply` to deploy security updates

## Advanced Topics

### Rolling Updates

Deploy with zero downtime:

```bash
# Deploy to one node at a time
colmena apply --on node1
colmena apply --on node2
```

### Secrets Management

For sensitive data (passwords, tokens):

1. Use age encryption with sops-nix
2. Store encrypted secrets in repository
3. Decrypt during deployment

### CI/CD Integration

Automate deployment with GitHub Actions or GitLab CI:

```yaml
# Example GitHub Actions workflow
- name: Deploy with Colmena
  run: |
    nix-shell -p colmena --run "colmena apply"
```

## References

- [Colmena Documentation](https://colmena.cli.rs/)
- [NixOS Manual](https://nixos.org/manual/nixos/stable/)
- [k3s Documentation](https://docs.k3s.io/)
- [NixOS Wiki](https://nixos.wiki/)