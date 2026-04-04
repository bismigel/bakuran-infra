{
  # Example Colmena deployment configuration for a k3s cluster
  # Replace with actual node hostnames and IP addresses

  meta = {
    # Nixpkgs configuration
    nixpkgs = import <nixpkgs> {};

    # Deployment options
    description = "k3s cluster deployment";

    # SSH options
    nodeSpecialArgs = {};
    nodeDefaults = {
      deployment = {
        targetHost = "192.168.1.100"; # Replace with actual IP
        targetUser = "root";
        # targetPort = 22;
        # buildOnTarget = true;
      };
    };
  };

  # Node definitions
  "node1" = { config, pkgs, ... }: {
    imports = [ ./configuration.nix ];
    networking.hostName = "node1";
    services.k3s.enable = true;
    services.k3s.role = "server";
  };

  "node2" = { config, pkgs, ... }: {
    imports = [ ./configuration.nix ];
    networking.hostName = "node2";
    services.k3s.enable = true;
    services.k3s.role = "agent";
  };

  # Add more nodes as needed
}