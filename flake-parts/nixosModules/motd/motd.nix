{
  # inputs,
  # self,
  lib,
  ...
}: {
  # ------ NixOS Modules ------ #
  flake.nixosModules.motd = {
    pkgs,
    config,
    ...
  }: let
    cfg = config.hostSpec.services.motd;
  in {
    options.hostSpec.services.motd = {
      enable = lib.mkEnableOption "default motd configuration";
      sshMotd = lib.mkOption {
        type = lib.types.str;
        default = builtins.readFile ./sshMotd.sh;
        description = "MOTD for SSH logins";
      };
      localMotd = lib.mkOption {
        type = lib.types.str;
        default = builtins.readFile ./localMotd.sh;
        description = "MOTD for local logins";
      };
    };

    config = lib.mkIf cfg.enable {
      programs.bash.interactiveShellInit = let
        runtimeInputs = with pkgs; [
          coreutils
          gawk
          procps
          busybox
        ];
        sshMotd = pkgs.writeShellApplication {
          name = "sshMotd";
          inherit runtimeInputs;
          text = cfg.sshMotd;
        };
        localMotd = pkgs.writeShellApplication {
          name = "localMotd";
          inherit runtimeInputs;
          text = cfg.localMotd;
        };
      in ''
        if [ -n "$SSH_CONNECTION" ] && [ -z "$MOTD_DISPLAYED" ]; then
          export MOTD_DISPLAYED=1
          ${sshMotd}/bin/sshMotd
        elif [ -z "$SSH_CONNECTION" ] && [ -z "$MOTD_DISPLAYED" ]; then
          export MOTD_DISPLAYED=1
          ${localMotd}/bin/localMotd
        fi
      '';
    };
  };
}
