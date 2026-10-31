{
  description = "Development-only inputs for modules (the dev partition)";

  # Locked in dev/flake.lock, never in the main flake.lock. dev-nixpkgs
  # must lock the same rev as the root nixpkgs (checks.lock-sync; fix
  # with `sync-locks`).
  inputs = {
    dev-nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    treefmt-nix = {
      url = "github:numtide/treefmt-nix";
      inputs.nixpkgs.follows = "dev-nixpkgs";
    };

    # Docs + slides (documentation/flake-module.nix).
    presenting = {
      url = "github:external-systems/presenting";
      inputs.nixpkgs.follows = "dev-nixpkgs";
    };
  };

  outputs = _: {};
}
