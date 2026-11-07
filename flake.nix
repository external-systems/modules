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

    # Consumer-facing inputs only. No dev inputs: formatting and docs come
    # from org-pkgs (flakeModules.default).

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

    # steam-config-nix: nixosModules.steam-config declares Steam's
    # default compatibility tool (GE-Proton) and per-game settings for
    # every user. Its `systems` input only lists x86_64-linux and is
    # left as is.
    steam-config-nix = {
      url = "github:different-name/steam-config-nix";
      inputs = {
        nixpkgs.follows = "nixpkgs";
        flake-parts.follows = "flake-parts";
      };
    };

    # Agent skills: homeModules.agents links the composed skills tree
    # (lib.mkSkillsTree) into every enabled agent.
    skills = {
      url = "github:external-systems/skills";
      inputs.org-pkgs.follows = "org-pkgs";
    };

    # MCP-NixOS: homeModules.agents' nixos MCP server. nixpkgs is NOT
    # followed: its python overrides recurse on the pkgs nixpkgs pin.
    # flake-parts is eval-only, so it follows ours (two fewer lock nodes).
    mcp-nixos = {
      url = "github:utensils/mcp-nixos";
      inputs.flake-parts.follows = "flake-parts";
    };

    # Whisper Dictation: nixosModules.whisper-dictation wraps its package.
    # Follows our nixpkgs, so the package and the typelibs the module adds
    # come from one nixpkgs (one fewer nixpkgs in consumers' locks).
    whisper-dictation = {
      url = "github:jacopone/whisper-dictation";
      inputs.nixpkgs.follows = "nixpkgs";
    };
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
        # treefmt, docs + slides, lock-sync: everything from pkgs.
        inputs.org-pkgs.flakeModules.default
        inputs.home-manager.flakeModules.home-manager
        (inputs.import-tree ./flake-parts)
        # Module eval checks and their fixtures.
        ./tests/flake-module.nix
        ./tests/vm-tests.nix
        ./documentation/flake-module.nix
      ];
    };
}
