{
  # inputs,
  # self,
  lib,
  ...
}: {
  # ------ NixOS Modules ------ #
  flake.nixosModules.docker = {
    config,
    pkgs,
    ...
  }: let
    cfg = config.hostSpec.services.docker;
  in {
    options.hostSpec.services.docker.enable = lib.mkEnableOption "default docker configuration";

    config = lib.mkIf cfg.enable {
      virtualisation = {
        oci-containers.backend = "docker";
        podman = {
          enable = true;
          package = pkgs.unstable.podman;
          autoPrune.enable = true;
        };
        docker = {
          enable = true;
          package = pkgs.unstable.docker;
          logDriver = "json-file";
          daemon.settings = {
            fixed-cidr-v6 = "fd00::/80";
            ipv6 = true;
          };
          autoPrune.enable = true;
        };
      };
    };
  };
}
