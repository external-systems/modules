{lib, ...}: {
  # ------ NixOS Modules ------ #
  flake.nixosModules.bluetooth = {config, ...}: let
    cfg = config.hostSpec.hardware.bluetooth;
  in {
    options.hostSpec.hardware.bluetooth.enable =
      lib.mkEnableOption "Bluetooth, powered on at boot"
      // {
        # A Bluetooth device in the machine's nixos-facter report (facter
        # itself only sets hardware.bluetooth.enable).
        default = (config.hardware.facter.report.hardware.bluetooth or []) != [];
        defaultText = lib.literalMD "a Bluetooth device in `hardware.facter.report`";
      };

    config = lib.mkIf cfg.enable {
      hardware.bluetooth = {
        enable = true;
        powerOnBoot = true;
      };
    };
  };
}
