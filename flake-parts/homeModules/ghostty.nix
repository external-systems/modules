{
  # inputs,
  # self,
  lib,
  ...
}: {
  # ------ Home-manager Modules ------ #
  flake.homeModules.ghostty = {config, ...}: let
    cfg = config.homeSpec.programs.ghostty;
  in {
    options.homeSpec.programs.ghostty.enable = lib.mkEnableOption "default ghostty configuration";

    config = lib.mkIf cfg.enable {
      programs.ghostty = {
        enable = true;
        settings = {
          theme = "Cyberpunk Scarlet Protocol";
          font-size = 15;
        };
      };
    };
  };
}
