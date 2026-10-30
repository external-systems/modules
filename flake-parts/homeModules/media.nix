{
  # inputs,
  # self,
  lib,
  ...
}: {
  # ------ Home-manager Modules ------ #
  flake.homeModules.media = {
    pkgs,
    config,
    ...
  }: let
    cfg = config.homeSpec.programs.media;
  in {
    options.homeSpec.programs.media.enable = lib.mkEnableOption "default media configuration";
    config = lib.mkIf cfg.enable {
      home.packages = with pkgs.unstable; [
        mpv
        imagemagick
      ];
    };
  };
}
