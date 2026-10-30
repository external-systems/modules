{
  # inputs,
  # self,
  lib,
  ...
}: {
  # ------ NixOS Modules ------ #
  flake.nixosModules.sound = {config, ...}: let
    cfg = config.hostSpec.hardware.sound;
  in {
    options.hostSpec.hardware.sound.enable = lib.mkEnableOption "default sound configuration";

    config = lib.mkIf cfg.enable {
      services.pipewire = {
        enable = true;
        jack.enable = true;
        pulse.enable = true;
        alsa.enable = true;
      };
    };
  };
}
