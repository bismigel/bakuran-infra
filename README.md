# Bakuran SOSYAL - NixOS k3s Cluster Guide

A personal learning environment for Kubernetes and NixOS on a single-server k3s cluster.

## Table of Contents

1. [Quick Reference](#quick-reference)
2. [NixOS Basics](#nixos-basics)
3. [Kubernetes/k3s Basics](#kubernetesk3s-basics)
4. [Manual Deployment](#manual-deployment)
5. [Day-to-Day Operations](#day-to-day-operations)
6. [Troubleshooting](#troubleshooting)
7. [Next Steps](#next-steps)

---

## Quick Reference

```bash
# Deploy changes to server
./deploy.sh calamansi

# SSH to server
ssh -i ~/.ssh/id_ed25519 root@192.168.2.81

# Get kubeconfig from server
ssh -i ~/.ssh/id_ed25519 root@192.168.2.81 "cat /etc/rancher/k3s/k3s.yaml" > ~/.kube/config

# Check cluster status
kubectl get nodes
kubectl get pods -A
```

---

## NixOS Basics

### How NixOS Works

NixOS is a Linux distribution where **the entire OS is configured declaratively**.
Instead of modifying files directly, you write Nix expressions that describe
your desired system state. Nix then builds and activates that configuration.

```
configuration.nix → nix build → /nix/store → activation
```

Key concepts:
- **Derivations**: Build recipes for packages/configs
- **Store**: Read-only directory (`/nix/store`) containing all built artifacts
- **Profiles**: Symlinks to specific generations of your OS configuration
- **Generations**: Snapshots of your OS configuration (like Time Machine)

### Your Configuration Structure

```
bakuran-sosyal/
├── flake.nix                    # Flake definition (inputs, outputs)
├── hosts/
│   └── calamansi/
│       └── default.nix          # Host-specific config (disk, networking, k3s)
├── modules/
│   ├── base.nix                 # Shared config (SSH, users, packages)
│   └── k3s.nix                 # k3s package and service config
├── deploy.sh                    # Deployment script
└── secrets/                     # For SOPS-AGE secrets (future)
```

### Key Files Explained

#### `flake.nix`
```nix
{
  description = "Bakuran SOSYAL - NixOS k3s cluster";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";
  };

  outputs = { self, nixpkgs }: {
    nixosConfigurations = {
      calamansi = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        modules = [
          ./hosts/calamansi/default.nix
        ];
      };
    };
  };
}
```
- Declares which nixpkgs version to use
- Defines the `nixosConfigurations` that can be built
- Each host maps to a NixOS system configuration

#### `hosts/calamansi/default.nix`
```nix
{ config, pkgs, lib, ... }:

{
  imports = [
    ../../modules/base.nix
    ../../modules/k3s.nix
  ];

  networking.hostName = "calamansi";

  fileSystems."/" = { device = "/dev/sda1"; fsType = "ext4"; };
  fileSystems."/boot" = { device = "/dev/sda2"; fsType = "vfat"; };

  services.k3s = {
    enable = true;
    role = "server";
    clusterInit = true;
    extraFlags = toString [
      "--disable" "traefik"
      "--disable" "servicelb"
      "--write-kubeconfig-mode" "0644"
    ];
  };

  networking.firewall = {
    enable = true;
    allowedTCPPorts = [ 22 6443 80 443 ];
    allowedUDPPorts = [ 8472 ];
  };
}
```
- `imports`: Include shared modules
- `fileSystems`: Define mount points and their source devices
- `services.k3s`: Configure k3s (server mode, cluster init, disabled components)
- `networking.firewall`: Define firewall rules

#### `modules/base.nix`
```nix
{ config, pkgs, ... }:

{
  boot.loader.systemd-boot.enable = true;
  
  services.openssh = {
    enable = true;
    settings = {
      PermitRootLogin = "yes";
      PasswordAuthentication = true;
    };
  };

  users.users.calamansi = {
    isNormalUser = true;
    extraGroups = [ "wheel" "networkmanager" ];
    openssh.authorizedKeys.keys = [ "ssh-ed25519 AAAA..." ];
  };

  environment.systemPackages = with pkgs; [ vim curl git htop ];
}
```
- Bootloader configuration
- SSH server settings
- User accounts and SSH keys
- Base packages available to all users

### NixOS Commands

```bash
# Build configuration (locally)
nix build .#nixosConfigurations.calamansi.config.system.build.toplevel

# Dry-run to check for errors
nix build .#nixosConfigurations.calamansi.config.system.build.toplevel --dry-run

# Show what changed in configuration
nix eval .#nixosConfigurations.calamansi.config.system.build.toplevel --json | jq

# List available NixOS options
nix eval .#nixosConfigurations.calamansi.config --json | jq 'keys' | head -50

# Search for packages
nix search nixpkgs kubernetes
nix search nixpkgs prometheus

# Clean up old generations (on server)
nixos-rebuild list-generations
nix-env --delete-generations 1 2 3 --profile /nix/var/nix/profiles/system

# Rollback (on server)
nixos-rebuild switch --rollback
```

### Learning Resources

- [NixOS Manual](https://nixos.org/manual/nixos/stable/)
- [Nixpkgs Manual](https://nixos.org/manual/nixpkgs/stable/)
- [Nix Pills](https://nixos.org/guides/nix-pills/) - Learn Nix lang
- [Zero to Nix](https://zero-to-nix.com/) - Interactive tutorial
- [NixOS Wiki](https://nixos.wiki/)

---

## Kubernetes/k3s Basics

### What is k3s?

k3s is a lightweight Kubernetes distribution by Rancher (SUSE). It bundles:
- Kubernetes API server, controller manager, scheduler
- etcd (or embedded SQLite for single-node)
- Container runtime (containerd)
- CNI (flannel by default)
- Core DNS

All in a single binary (~100MB) that runs as a systemd service.

### Architecture

```
┌─────────────────────────────────────────┐
│           k3s Server Node               │
│                                         │
│  ┌─────────┐  ┌─────────┐  ┌────────┐  │
│  │  API    │  │ Scheduler│  │Controller│ │
│  │ Server  │  │         │  │ Manager  │ │
│  └────┬────┘  └────┬────┘  └────┬────┘  │
│       │              │             │      │
│  ┌────┴──────────────┴─────────────┴──┐  │
│  │           kube-apiserver            │  │
│  └────────────────┬────────────────────┘  │
│                   │                        │
│  ┌────────────────┴────────────────────┐  │
│  │  etcd / SQLite (datastore)         │  │
│  └─────────────────────────────────────┘  │
│                   │                        │
│  ┌────────────────┴────────────────────┐  │
│  │        containerd runtime           │  │
│  │  ┌─────┐ ┌─────┐ ┌─────┐ ┌─────┐  │  │
│  │  │ Pod │ │ Pod │ │ Pod │ │ Pod │  │  │
│  │  └─────┘ └─────┘ └─────┘ └─────┘  │  │
│  └─────────────────────────────────────┘  │
└─────────────────────────────────────────┘
```

### Core Concepts

#### Pods
Smallest deployable unit. Contains one or more containers sharing network/storage.
```yaml
apiVersion: v1
kind: Pod
metadata:
  name: nginx
spec:
  containers:
  - name: nginx
    image: nginx:alpine
    ports:
    - containerPort: 80
```

#### Deployments
Manages Pods, handles rolling updates and rollbacks.
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nginx
spec:
  replicas: 3
  selector:
    matchLabels:
      app: nginx
  template:
    metadata:
      labels:
        app: nginx
    spec:
      containers:
      - name: nginx
        image: nginx:alpine
```

#### Services
Network abstraction to access Pods.
```yaml
apiVersion: v1
kind: Service
metadata:
  name: nginx
spec:
  type: ClusterIP  # ClusterIP, NodePort, LoadBalancer, ExternalName
  selector:
    app: nginx
  ports:
  - port: 80
    targetPort: 80
```

#### Namespaces
Logical isolation for resources.
```bash
kubectl create namespace production
kubectl get namespaces
```

### kubectl Commands

```bash
# Cluster info
kubectl cluster-info
kubectl get nodes
kubectl describe node <node-name>

# Workloads
kubectl get pods
kubectl get deployments
kubectl get replicasets
kubectl get pods -A                     # All namespaces
kubectl get pods -n kube-system         # System pods
kubectl get pods -l app=nginx           # Filter by label

# Logs & Exec
kubectl logs <pod-name>
kubectl logs -f <pod-name>              # Follow
kubectl logs <pod-name> -c <container>  # Specific container
kubectl exec -it <pod-name> -- /bin/sh # Shell into pod

# Apply/ Delete
kubectl apply -f deployment.yaml
kubectl delete -f deployment.yaml
kubectl delete pod <pod-name>

# Debugging
kubectl describe pod <pod-name>
kubectl get events --sort-by='.lastTimestamp'
kubectl top nodes                        # Requires metrics-server
kubectl top pods -A

# Port forwarding (for local dev)
kubectl port-forward svc/nginx 8080:80

# Rollouts
kubectl rollout status deployment/nginx
kubectl rollout undo deployment/nginx
kubectl rollout history deployment/nginx
```

### Deploying Your First App

```bash
# Create a namespace
kubectl create namespace demo

# Deploy nginx
kubectl create deployment nginx --image=nginx:alpine -n demo

# Scale to 3 replicas
kubectl scale deployment nginx --replicas=3 -n demo

# Expose via NodePort
kubectl expose deployment nginx --port=80 --type=NodePort -n demo

# Check status
kubectl get all -n demo
kubectl get svc -n demo

# Access (NodePort is accessible via http://192.168.2.81:<node-port>)
kubectl get svc -n demo
```

### Ingress (HTTP Routing)

Since we disabled Traefik, you'll need to install an Ingress controller later.

```bash
# Install nginx-ingress (example)
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.9.0/deploy/static/provider/cloud/deploy.yaml
```

### Persistent Storage

k3s includes a Local Path Provisioner for PVCs:

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: my-data
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: local-path
  resources:
    requests:
      storage: 1Gi
---
apiVersion: v1
kind: Pod
metadata:
  name: app-with-storage
spec:
  containers:
  - name: app
    image: nginx
    volumeMounts:
    - name: data
      mountPath: /data
  volumes:
  - name: data
    persistentVolumeClaim:
      claimName: my-data
```

### Learning Resources

- [kubernetes.io/docs/tutorials/](https://kubernetes.io/docs/tutorials/)
- [kubectl Cheat Sheet](https://kubernetes.io/docs/reference/kubectl/quick-reference/)
- [Learn Kubernetes Basics](https://kubernetes.io/docs/tutorials/kubernetes-basics/)
- [k3s Documentation](https://docs.k3s.io/)

---

## Manual Deployment

### How deploy.sh Works

```bash
#!/bin/bash
set -euo pipefail

HOST="${1:-calamansi}"
TARGET="root@192.168.2.81"
SSH_OPTS="-o StrictHostKeyChecking=no -i ~/.ssh/id_ed25519"

CLOSURE_PATH="/tmp/nixos-build-$HOST/result"

# Step 1: Build the NixOS configuration locally
echo "==> Building configuration for $HOST..."
nix build ".#nixosConfigurations.$HOST.config.system.build.toplevel" \
  --out-link "$CLOSURE_PATH"

PROFILE_TARGET=$(readlink "$CLOSURE_PATH")

# Step 2: Copy the closure to the server
echo "==> Copying to $TARGET..."
nix copy --to "ssh://$TARGET" "$CLOSURE_PATH"

# Step 3: Activate the new configuration
echo "==> Activating on $TARGET..."
ssh $SSH_OPTS "$TARGET" "
  rm -f /nix/var/nix/profiles/system
  ln -s $PROFILE_TARGET /nix/var/nix/profiles/system
  $PROFILE_TARGET/bin/switch-to-configuration switch
"

echo "==> Done!"
```

### Deployment Workflow

```bash
# 1. Edit your configuration
vim hosts/calamansi/default.nix

# 2. Build locally (dry-run first to catch errors)
nix build ".#nixosConfigurations.calamansi.config.system.build.toplevel" --dry-run

# 3. Deploy
./deploy.sh calamansi

# 4. Verify
ssh root@192.168.2.81 "systemctl status k3s"
```

### Common Configuration Changes

#### Add a package
```nix
# In modules/base.nix, add to environment.systemPackages:
environment.systemPackages = with pkgs; [
  vim curl git htop tree wget
  kubernetes-helm  # Add helm
  k9s              # Add k9s TUI
];
```

#### Open a firewall port
```nix
# In hosts/calamansi/default.nix:
networking.firewall = {
  enable = true;
  allowedTCPPorts = [ 22 6443 80 443 30000 ];  # Add 30000
  allowedUDPPorts = [ 8472 ];
};
```

#### Change k3s settings
```nix
# In hosts/calamansi/default.nix:
services.k3s = {
  enable = true;
  role = "server";
  clusterInit = true;
  # Change extraFlags as needed
  extraFlags = toString [
    "--disable" "traefik"
    "--disable" "servicelb"
    "--write-kubeconfig-mode" "0644"
    "--kube-apiserver-arg" "max-requests-inflight=0"  # Example
  ];
};
```

---

## Day-to-Day Operations

### On the NixOS Server

```bash
# SSH in
ssh -i ~/.ssh/id_ed25519 root@192.168.2.81

# Check system
systemctl status k3s
systemctl status systemd-resolved
journalctl -u k3s -f                    # Follow k3s logs
htop

# Check NixOS generations
nixos-rebuild list-generations

# Rollback if needed
nixos-rebuild switch --rollback

# Clean old generations (keep last 2)
nix-env --delete-generations 1 2 3 --profile /nix/var/nix/profiles/system
```

### On Your Local Machine

```bash
# Manage Kubernetes
export KUBECONFIG=~/.kube/config  # Or copy from server
kubectl get nodes
kubectl get pods -A

# Use k9s (TUI for Kubernetes)
# Install: nix install k9s
k9s

# Use helm
helm list -A
helm repo update
helm install prometheus prometheus-community/kube-prometheus-stack
```

---

## Troubleshooting

### k3s Won't Start

```bash
# Check logs
journalctl -u k3s -n 100

# Check service status
systemctl status k3s

# Restart
systemctl restart k3s

# Common issues:
# - Port 6443 already in use
# - etcd datastore corruption (reinitialize)
```

### Can't Connect to Cluster

```bash
# On server: check k3s is running
systemctl is-active k3s

# Check kubeconfig permissions
ls -la /etc/rancher/k3s/k3s.yaml

# Copy kubeconfig
ssh root@192.168.2.81 "cat /etc/rancher/k3s/k3s.yaml" > ~/.kube/config
chmod 600 ~/.kube/config
```

### Pod Stuck in Pending

```bash
kubectl describe pod <name>
# Common causes:
# - No nodes available (cluster not ready)
# - PVC not bound (storage issue)
# - Image pull failure
```

### Pod Stuck in CrashLoopBackOff

```bash
kubectl logs <pod-name>
# Check for:
# - Application errors
# - Missing environment variables
# - Volume mount issues
```

### Network Issues

```bash
# Check CoreDNS
kubectl get pods -n kube-system
kubectl logs -n kube-system <coredns-pod>

# Check network policies
kubectl get networkpolicies -A

# Check services
kubectl get svc -A
kubectl describe svc <name>
```

---

## Next Steps

### GitOps with ArgoCD or Flux

GitOps = Git is the source of truth for your cluster state.

```bash
# Install ArgoCD
kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argocd/ArgoCD/v2.9.0/manifests/install.yaml

# Or use Flux (more k8s-native)
# See: https://fluxcd.io/docs/installation/
```

### Observability Stack

#### Prometheus + Grafana (Monitoring)

```bash
# Add helm repo
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update

# Install kube-prometheus-stack
helm install prometheus prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --create-namespace

# Port-forward to access
kubectl port-forward -n monitoring svc/prometheus-grafana 3000:80
```

#### OpenTelemetry (Tracing)

```bash
# Install OTel operator
kubectl apply -f https://github.com/open-telemetry/opentelemetry-operator/releases/latest/download/opentelemetry-operator.yaml

# Create collector
kubectl apply -f - <<EOF
apiVersion: opentelemetry.io/v1alpha1
kind: OpenTelemetryCollector
metadata:
  name: otel-collector
  namespace: monitoring
spec:
  mode: deployment
  config: |
    receivers:
      otlp:
        protocols:
          grpc:
          http:
    exporters:
      logging:
    service:
      pipelines:
        traces:
          receivers: [otlp]
          exporters: [logging]
EOF
```

### What's Already Running

```bash
# Metrics server (built into k3s)
kubectl get pods -n kube-system -l k8s-app=metrics-server

# Traefik is disabled - if you need ingress:
kubectl apply -f https://raw.githubusercontent.com/traefik/traefik/v3.0/crates/traefik/

# Or nginx-ingress:
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.9.0/deploy/static/provider/cloud/deploy.yaml
```

---

## Project Structure Reference

```
bakuran-sosyal/
├── flake.nix              # ← Edit this to add more hosts or inputs
├── flake.lock             # Auto-generated, commit this
├── deploy.sh              # ← Run this to deploy
├── hosts/
│   └── calamansi/
│       └── default.nix    # ← Main host config (disk, network, k3s)
├── modules/
│   ├── base.nix           # ← Shared settings (users, SSH, packages)
│   └── k3s.nix            # ← k3s-specific packages
└── README.md              # This guide
```

---

## Key Management

### SSH Public Key

The SSH public key for user authentication is stored in `flake.nix`:

```nix
specialArgs = {
  sshPubKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIH+soIiTQA3y96cqgaPluR9i9Z9qCdypdSfH/w0KiYrb labanos@bakuran";
};
```

To update/add a new key:
1. Add your public key to `flake.nix` in the `sshPubKey` attribute
2. Deploy: `./deploy.sh calamansi`

### Private Keys & Secrets

For sensitive data (passwords, private keys, API tokens), use SOPS with AGE encryption.

Setup:
```bash
# Install age and sops
nix shell nixpkgs#age nixpkgs#sops

# Generate AGE key
age-keygen -o secrets/age.key

# Create .sops.yaml to define encryption rules
```

Example `.sops.yaml`:
```yaml
keys:
  - &admin age/age1abc123...
creation_rules:
  - path_regex: secrets/.*
    key_groups:
      - age: [*admin]
```

Then encrypt a secret file:
```bash
sops --encrypt secrets/db-passwords.yaml > secrets/db-passwords.yaml.age
```

---

## Cheat Sheet

```bash
# === Deploy ===
./deploy.sh calamansi                    # Deploy config changes

# === NixOS ===
nix build .#nixosConfigurations.calamansi.config.system.build.toplevel --dry-run  # Validate
ssh -i ~/.ssh/id_ed25519 root@192.168.2.81  # SSH to server

# === Kubernetes ===
kubectl get nodes                        # Check nodes
kubectl get pods -A                      # All pods
kubectl get svc -A                       # All services
kubectl apply -f app.yaml               # Deploy app
kubectl delete -f app.yaml              # Remove app

# === Debugging ===
kubectl describe pod <name>              # Pod details
kubectl logs <pod-name>                 # Pod logs
kubectl exec -it <pod> -- sh            # Shell into pod
journalctl -u k3s -n 50                 # k3s logs (server)

# === Cleanup ===
ssh root@192.168.2.81 "nix-env --delete-generations old --profile /nix/var/nix/profiles/system"  # Clean old NixOS gens
```
