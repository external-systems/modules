{
  description = "external-systems modules flake — reusable NixOS and home-manager modules for downstream flakes";

  inputs = {
    # Shared-input authority for the org: nixpkgs, flake-parts and
    # import-tree come from the artifact flake, so consumers that already
    # follow pkgs lock nothing new.
    pkgs.url = "github:external-systems/pkgs";
    nixpkgs.follows = "pkgs/nixpkgs";
    flake-parts.follows = "pkgs/flake-parts";
    import-tree.follows = "pkgs/import-tree";

    # Home-manager: nixosModules.default imports its NixOS module, and the
    # git/ssh/openshell-gateway modules write home-manager.sharedModules.
    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # KDE: homeModules.plasma-manager configures programs.plasma.
    plasma-manager = {
      url = "github:nix-community/plasma-manager";
      inputs = {
        nixpkgs.follows = "nixpkgs";
        home-manager.follows = "home-manager";
      };
    };

    # Jovian NixOS: imported by nixosModules.jovian.
    jovian = {
      url = "github:Jovian-Experiments/Jovian-NixOS";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Whisper Dictation: nixosModules.whisper-dictation wraps its package.
    # nixpkgs is deliberately NOT followed: the module re-wraps the
    # package against upstream's own pinned nixpkgs.
    whisper-dictation.url = "github:jacopone/whisper-dictation";
  };

  outputs = inputs:
    inputs.flake-parts.lib.mkFlake {inherit inputs;} {
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];

      imports = [
        inputs.flake-parts.flakeModules.partitions
        inputs.home-manager.flakeModules.home-manager
        (inputs.import-tree ./flake-parts)
      ];

      # Checks, formatter and devShell are evaluated only on demand; a
      # consumer reading nixosModules/homeModules never touches them.
      partitionedAttrs = {
        checks = "dev";
        devShells = "dev";
        formatter = "dev";
      };

      partitions.dev.module = ./dev/flake-module.nix;
    };
}
