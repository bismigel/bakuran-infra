{
  # Colmena deployment configuration for NixOS nodes
  # Deploy with: colmena apply

  meta = {
    # Specify nixpkgs version (optional)
    # nixpkgs = import (fetchTarball "https://github.com/NixOS/nixpkgs/archive/nixos-24.05.tar.gz") {};

    # Use local nixpkgs
    nixpkgs = import <nixpkgs> {};

    description = "Bakuran Sosyal k3s cluster";

    # Default SSH options for all nodes
    nodeSpecialArgs = {};
    nodeDefaults = {
      deployment = {
        # Default user (can be overridden per node)
        targetUser = "root";
        
        # Build options
        buildOnTarget = false; # Build locally and copy closure
        # buildOnTarget = true; # Build on target (requires more resources on target)
        
        # Optional: SSH keys for authentication
        # sshOpts = [ "-i" "/path/to/ssh/key" ];
        
        # Optional: Enable sudo for non-root users
        # useSudo = true;
      };
    };
  };

  # ========== PRODUCTION NODES ==========
  
  # Calamansi server (192.168.2.81) - Intel server with fresh NixOS
  "calamansi" = { name, nodes, pkgs, ... }: {
    imports = [ ./configuration.nix ];
    
    deployment = {
      targetHost = "192.168.2.81";
      targetUser = "root"; # Use root since we installed with root access
      # targetPort = 22; # Default SSH port
    };

    # Node-specific overrides
    networking.hostName = "calamansi";
    
    # Enable k3s as server (control plane)
    services.k3s.enable = true;
    services.k3s.role = "server";
    
    # Optional: k3s configuration
    services.k3s.extraFlags = "--disable=traefik --disable=servicelb";
    
    # Optional: Set cluster token for joining agents
    # services.k3s.token = "your-secret-token-here";
    
    # Optional: Enable flannel CNI
    # services.k3s.clusterInit = true;
    
    # Firewall (adjust as needed)
    networking.firewall = {
      enable = true;
      allowedTCPPorts = [ 
        22    # SSH
        6443  # k3s API server
        80    # HTTP
        443   # HTTPS
      ];
      allowedUDPPorts = [ 
        8472  # flannel VXLAN
      ];
    };
    
    # User configuration (already in configuration.nix, can override here)
    users.users.calamansi = {
      openssh.authorizedKeys.keys = [
        # Add your SSH public key here
        # "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI..."
      ];
    };
  };

  # ========== ADDITIONAL NODES TEMPLATE ==========
  
  # Template for additional k3s agent nodes
  # Uncomment and customize for each new node
  /*
  "agent1" = { name, nodes, pkgs, ... }: {
    imports = [ ./configuration.nix ];
    
    deployment = {
      targetHost = "192.168.2.XX";
      targetUser = "root";
    };

    networking.hostName = "agent1";
    
    # Join as k3s agent
    services.k3s.enable = true;
    services.k3s.role = "agent";
    services.k3s.serverAddr = "https://calamansi:6443";
    services.k3s.token = "your-secret-token-here"; # Must match server token
    
    networking.firewall = {
      enable = true;
      allowedTCPPorts = [ 22 ];
      allowedUDPPorts = [ 8472 ];
    };
  };
  */

  # ========== LOCAL TEST NODE (OPTIONAL) ==========
  
  # For testing deployment locally (requires NixOS on local machine)
  /*
  "localhost" = { name, nodes, pkgs, ... }: {
    imports = [ ./configuration.nix ];
    
    deployment = {
      targetHost = "localhost";
      targetUser = "root";
      buildOnTarget = true;
    };

    networking.hostName = "testnode";
    
    # Don't enable k3s for local test
    services.k3s.enable = false;
  };
  */
}