_: {
  # ------ NixOS Modules ------ #
  flake.nixosModules.intel = {
    config,
    pkgs,
    lib,
    ...
  }: let
    cfg = config.hostSpec.hardware.cpu.intel;
  in {
    options.hostSpec.hardware.cpu.intel.enable = lib.mkEnableOption "default intel configuration";

    config = lib.mkIf cfg.enable {
      hardware.graphics = {
        enable = true;
        extraPackages = with pkgs; [
          intel-media-driver
          intel-compute-runtime
        ];
      };
    };
  };
}
