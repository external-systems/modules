{
  # inputs,
  # self,
  lib,
  ...
}: {
  # ------ Home-manager Modules ------ #
  flake.homeModules.password-store = {
    pkgs,
    config,
    ...
  }: let
    cfg = config.homeSpec.programs.password-store;
  in {
    options.homeSpec.programs.password-store.enable = lib.mkEnableOption "default password-store configuration";
    config = lib.mkIf cfg.enable {
      programs.password-store = {
        enable = true;
        package = pkgs.unstable.pass;
      };
    };
  };
}
