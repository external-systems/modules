# Dev partition: lint, module eval checks, formatter and devShell. A
# consumer of nixosModules/homeModules never evaluates it.
{
  inputs,
  lib,
  self,
  ...
}: {
  perSystem = {
    pkgs,
    system,
    ...
  }: let
    tools = with pkgs; [alejandra statix deadnix];

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
    formatter = pkgs.alejandra;

    devShells.default = pkgs.mkShellNoCC {packages = tools;};

    checks =
      {
        lint = pkgs.runCommand "lint" {nativeBuildInputs = tools;} ''
          cd ${lib.sources.sourceFilesBySuffices self [".nix"]}
          alejandra --check --quiet .
          statix check .
          deadnix --fail .
          touch $out
        '';
      }
      # The fleet is x86_64-linux; jovian and the GPU modules are not
      # meant for aarch64.
      // lib.optionalAttrs (system == "x86_64-linux") {
        eval-all-enabled = pkgs.writeText "eval-all-enabled" (
          builtins.unsafeDiscardStringContext machine.config.system.build.toplevel.drvPath
        );
      };
  };
}
