{
  # inputs,
  # self,
  lib,
  ...
}: {
  # ------ NixOS Modules ------ #
  flake.nixosModules.wayland = {
    pkgs,
    config,
    ...
  }: let
    cfg = config.hostSpec.services.wayland;
  in {
    options.hostSpec.services.wayland.enable = lib.mkEnableOption "default wayland configuration";
    config = lib.mkIf cfg.enable {
      # Turn on wayland support for some electron apps
      environment.sessionVariables.NIXOS_OZONE_WL = "1";

      # GTK portal for GTK apps. The desktop picks its own backends (Plasma
      # ships kde-portals.conf), so no global portals.conf is written here.
      xdg.portal = {
        enable = true;
        extraPortals = [pkgs.xdg-desktop-portal-gtk];
      };
    };
  };
}
