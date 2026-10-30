_: {
  # ------ NixOS Modules ------ #
  flake.nixosModules.nix-ld = {
    config,
    pkgs,
    lib,
    ...
  }: let
    cfg = config.hostSpec.services.nix-ld;
  in {
    options.hostSpec.services.nix-ld.enable = lib.mkEnableOption "default nix-ld configuration";

    config = lib.mkIf cfg.enable {
      # nix-ld
      programs.nix-ld = {
        enable = true;
        libraries = with pkgs; [
          stdenv.cc.cc
        ];
      };
    };
  };
}
