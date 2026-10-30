{
  # inputs,
  # self,
  lib,
  ...
}: {
  # ------ NixOS Modules ------ #
  flake.nixosModules.bluetooth = {config, ...}: let
    cfg = config.hostSpec.hardware.bluetooth;
  in {
    options.hostSpec.hardware.bluetooth.enable = lib.mkEnableOption "default bluetooth configuration";

    config = lib.mkIf cfg.enable {
      hardware.bluetooth = {
        enable = true;
        powerOnBoot = true;
      };
    };
  };
}
