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
    options.homeSpec.programs.media = {
      enable = lib.mkEnableOption "default media configuration";
      packages = lib.mkOption {
        type = lib.types.listOf lib.types.package;
        default = with pkgs; [
          mpv
          imagemagick
        ];
        defaultText = lib.literalExpression "with pkgs; [mpv imagemagick]";
        description = "Media packages to install.";
      };
    };
    config = lib.mkIf cfg.enable {
      home.packages = cfg.packages;
    };
  };
}
