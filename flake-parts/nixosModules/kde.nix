{
  # inputs,
  # self,
  lib,
  ...
}: {
  # ------ NixOS Modules ------ #
  flake.nixosModules.kde = {
    pkgs,
    config,
    ...
  }: let
    cfg = config.hostSpec.services.kde;
  in {
    options.hostSpec.services.kde.enable = lib.mkEnableOption "default kde configuration";
    config = lib.mkIf cfg.enable {
      # Hardware accelleration
      hardware.graphics.enable = lib.mkForce true;
      networking.networkmanager.enable = lib.mkForce true;

      # KDE Desktop
      services = {
        orca.enable = false;
        desktopManager.plasma6.enable = true;
        displayManager.sddm = {
          enable = true;
          wayland.enable = true;
        };

        xserver = {
          enable = false;
          excludePackages = [pkgs.xterm]; # remove xterm
          xkb = {
            layout = "us";
            variant = "";
          };
        };
      };

      programs.xwayland.enable = true;

      environment = {
        sessionVariables.NIXOS_OZONE_WL = "1";
        systemPackages = with pkgs; [
          hardinfo2 # System information and benchmarks for Linux systems
        ];
      };
    };
  };
}
