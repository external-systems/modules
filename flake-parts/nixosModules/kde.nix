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

      # The wayland module sets xdg.portal.config.common (wlr, gtk), which
      # NixOS prefers over Plasma's own kde-portals.conf, so Plasma sessions
      # lost the KDE portal: screen sharing, file dialogs, and the
      # RemoteDesktop/InputCapture portals that Steam Remote Play and remote
      # input use. A desktop-specific file wins over portals.conf.
      xdg.portal.config.kde.default = ["kde" "gtk"];

      environment = {
        sessionVariables.NIXOS_OZONE_WL = "1";
        systemPackages = with pkgs; [
          hardinfo2 # System information and benchmarks for Linux systems
        ];
      };
    };
  };
}
