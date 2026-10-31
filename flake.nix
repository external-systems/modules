{
  description = "external-systems modules flake — reusable NixOS and home-manager modules for downstream flakes";

  inputs = {
    # Shared-input authority for the org: nixpkgs, flake-parts and
    # import-tree come from the artifact flake, so consumers that already
    # follow it lock nothing new. Named org-pkgs, never pkgs: `pkgs` is
    # the nixpkgs package set everywhere else.
    org-pkgs.url = "github:external-systems/pkgs";
    nixpkgs.follows = "org-pkgs/nixpkgs";
    flake-parts.follows = "org-pkgs/flake-parts";
    import-tree.follows = "org-pkgs/import-tree";

    # Consumer-facing inputs only; dev-only inputs go in dev/flake.nix.

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

    # Agent skills: homeModules.agents links the composed skills tree
    # (lib.mkSkillsTree) into every enabled agent.
    skills = {
      url = "github:external-systems/skills";
      inputs.org-pkgs.follows = "org-pkgs";
    };

    # MCP-NixOS: homeModules.agents' nixos MCP server. nixpkgs is NOT
    # followed: its python overrides recurse on the pkgs nixpkgs pin.
    mcp-nixos.url = "github:utensils/mcp-nixos";

    # Whisper Dictation: nixosModules.whisper-dictation wraps its package.
    # nixpkgs is deliberately NOT followed: the module re-wraps the
    # package against upstream's own pinned nixpkgs.
    whisper-dictation.url = "github:jacopone/whisper-dictation";
  };

  outputs = inputs:
    inputs.flake-parts.lib.mkFlake {inherit inputs;} {
      # Exposes debug.options / currentSystem.options, which nixd
      # (.vscode/settings.json) reads for flake-parts option hints.
      debug = true;

      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];

      imports = [
        inputs.flake-parts.flakeModules.partitions
        inputs.home-manager.flakeModules.home-manager
        (inputs.import-tree ./flake-parts)
      ];

      # Apps, checks, the formatter and docs are evaluated only on demand;
      # a consumer reading nixosModules/homeModules never fetches
      # dev/flake.nix's inputs. The dev shell is devenv (devenv.yaml), not
      # a flake output.
      partitionedAttrs = {
        apps = "dev";
        checks = "dev";
        formatter = "dev";
        # Docs/slides: `nix build .#documentation` (pkgs flakeModules.dev).
        legacyPackages = "dev";
      };

      partitions.dev = {
        module = ./dev/flake-module.nix;
        extraInputsFlake = ./dev;
      };
    };
}
