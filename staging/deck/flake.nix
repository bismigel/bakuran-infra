{
  description = "Disposable Steam Deck staging node";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    nixos-generators = {
      url = "github:nix-community/nixos-generators";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, nixos-generators }: {
    nixosConfigurations.staging-deck = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        ./configuration.nix
        ./hardware.nix
      ];
    };

    packages.x86_64-linux.default = nixos-generators.nixosGenerate {
      system = "x86_64-linux";
      format = "raw-efi";
      modules = [
        ./configuration.nix
        ./hardware.nix
      ];
    };
  };
}
