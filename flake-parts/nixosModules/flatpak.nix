_: {
  # ------ NixOS Modules ------ #
  flake.nixosModules.flatpak = {
    config,
    pkgs,
    lib,
    ...
  }: let
    cfg = config.hostSpec.services.flatpak;
  in {
    options.hostSpec.services.flatpak.enable = lib.mkEnableOption "default flakpak configuration";

    config = lib.mkIf cfg.enable {
      services.flatpak.enable = true; # Enable Flatpak
      systemd.services.flatpak-repo = {
        wantedBy = ["multi-user.target"];
        path = [pkgs.flatpak];
        script = ''
          flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo
        '';
      };
      environment.systemPackages = with pkgs; [
        gnome-software # for flatpaks
      ];
    };
  };
}
