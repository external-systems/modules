{
  # inputs,
  # self,
  lib,
  ...
}: {
  # ------ Home-manager Modules ------ #
  flake.homeModules.xdg = {config, ...}: let
    cfg = config.homeSpec.xdg;
  in {
    options.homeSpec.xdg.enable = lib.mkEnableOption "default xdg configuration";
    config = lib.mkIf cfg.enable {
      xdg = {
        enable = true;
        configFile = {};
      };
    };
  };
}
