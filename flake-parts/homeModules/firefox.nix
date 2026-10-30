{
  # inputs,
  # self,
  lib,
  ...
}: {
  # ------ Home-manager Modules ------ #
  flake.homeModules.firefox = {config, ...}: let
    cfg = config.homeSpec.programs.firefox;
  in {
    options.homeSpec.programs.firefox.enable = lib.mkEnableOption "default firefox configuration";
    config = lib.mkIf cfg.enable {
      programs.firefox = {
        enable = true;
        configPath = "${config.xdg.configHome}/mozilla/firefox";
      };
    };
  };
}
