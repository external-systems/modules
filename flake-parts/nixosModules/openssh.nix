{
  # inputs,
  # self,
  lib,
  ...
}: {
  # ------ NixOS Modules ------ #
  flake.nixosModules.openssh = {config, ...}: let
    cfg = config.hostSpec.services.openssh;
  in {
    options.hostSpec.services.openssh.enable = lib.mkEnableOption "default openssh configuration";
    config = lib.mkIf cfg.enable {
      # Enable the OpenSSH daemon.
      services.openssh = {
        enable = true;
        openFirewall = true;
        startWhenNeeded = true;
        ports = [22];
        settings = {
          PasswordAuthentication = false;
          KbdInteractiveAuthentication = false;
        };
      };
    };
  };
}
