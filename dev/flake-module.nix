# Dev partition: the org base (treefmt, lock-sync, docs) from pkgs and
# the module eval check. A consumer of nixosModules/homeModules never
# evaluates it.
{
  inputs,
  lib,
  self,
  ...
}: {
  imports = [
    inputs.org-pkgs.flakeModules.dev
    ../documentation/module.nix
  ];

  perSystem = {
    pkgs,
    system,
    ...
  }: let
    # Every hostSpec/homeSpec toggle on, evaluated down to the system
    # derivation. Only instantiated, never built: the check fails when a
    # module stops evaluating, not when a package fails to build.
    machine = inputs.nixpkgs.lib.nixosSystem {
      modules = [
        (import ./fixtures/nixos.nix {inherit inputs self;})
        {nixpkgs.hostPlatform = system;}
      ];
    };
  in {
    # Formatting and lint: checks.treefmt (pkgs flakeModules.dev).
    # The fleet is x86_64-linux; jovian and the GPU modules are not meant
    # for aarch64.
    checks = lib.optionalAttrs (system == "x86_64-linux") {
      eval-all-enabled = pkgs.writeText "eval-all-enabled" (
        builtins.unsafeDiscardStringContext machine.config.system.build.toplevel.drvPath
      );
    };
  };
}
