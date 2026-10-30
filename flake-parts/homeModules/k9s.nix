{
  # inputs,
  # self,
  lib,
  ...
}: {
  # ------ Home-manager Modules ------ #
  flake.homeModules.k9s = {
    pkgs,
    config,
    ...
  }: let
    cfg = config.homeSpec.programs.k9s;
  in {
    options.homeSpec.programs.k9s.enable = lib.mkEnableOption "default k9s configuration";
    config = lib.mkIf cfg.enable {
      home.sessionVariables.K9S_SKIN = "dracula";
      programs.k9s = {
        enable = true;
        package = pkgs.unstable.k9s;
        skins.dracula = pkgs.fetchurl {
          url = "https://raw.githubusercontent.com/derailed/k9s/refs/heads/master/skins/dracula.yaml";
          sha256 = "10is0kb0n6s0hd2lhyszrd6fln6clmhdbaw5faic5vlqg77hbjqs";
        };
      };
    };
  };
}
