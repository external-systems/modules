{
  # inputs,
  # self,
  lib,
  ...
}: {
  # ------ Home-manager Modules ------ #
  flake.homeModules.ksshaskpass = {
    pkgs,
    config,
    ...
  }: let
    cfg = config.homeSpec.programs.ksshaskpass;
    ksshaskpass = lib.getExe pkgs.kdePackages.ksshaskpass;
  in {
    options.homeSpec.programs.ksshaskpass.enable = lib.mkEnableOption "default ksshaskpass configuration";

    config = lib.mkIf cfg.enable {
      home.packages = [pkgs.kdePackages.ksshaskpass];
      home.sessionVariables = {
        SSH_ASKPASS = ksshaskpass;
        SSH_ASKPASS_REQUIRE = "prefer";
      };
      xdg.configFile = {
        "autostart/ssh-add.desktop".text = lib.mkAfter ''
          [Desktop Entry]
          Exec=env SSH_ASKPASS="${ksshaskpass}" SSH_ASKPASS_REQUIRE=prefer ssh-add -q
          Name=ssh-add
          Type=Application
          X-KDE-autostart-after=panel
        '';
        "plasma-workspace/env/ssh-agent-startup.sh" = {
          text = ''
            #!/bin/sh
            export SSH_ASKPASS="${ksshaskpass}"
            export SSH_ASKPASS_REQUIRE="prefer"
            [ -n "$SSH_AGENT_PID" ] || eval "$(ssh-agent -s)"
          '';
          executable = true;
        };
        "plasma-workspace/shutdown/ssh-agent-shutdown.sh" = {
          text = ''
            #!/bin/sh
            [ -z "$SSH_AGENT_PID" ] || eval "$(ssh-agent -k)"
          '';
          executable = true;
        };
      };
    };
  };
}
