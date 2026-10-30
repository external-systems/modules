{lib, ...}: {
  # ------ NixOS Modules ------ #
  flake.nixosModules.rancher = {config, ...}: let
    cfg = config.hostSpec.services.rancher;
  in {
    options.hostSpec.services.rancher.enable = lib.mkEnableOption "default rancher configuration";
    config = lib.mkIf (cfg.enable && config.services.k3s.role == "server") {
      services.k3s.disable = ["local-storage"];
    };
  };
}
