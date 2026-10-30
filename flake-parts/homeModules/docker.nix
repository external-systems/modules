{
  # inputs,
  # self,
  lib,
  ...
}: {
  # ------ Home-manager Modules ------ #
  flake.homeModules.docker = {
    config,
    pkgs,
    ...
  }: let
    cfg = config.homeSpec.programs.docker;
  in {
    options.homeSpec.programs.docker.enable = lib.mkEnableOption "default docker configuration";

    config = lib.mkIf cfg.enable {
      # lazydocker
      programs.lazydocker = {
        enable = true;
        package = pkgs.unstable.lazydocker;
        settings = {
          commandTemplates = {
            dockerCompose = "docker compose";
          };
          customCommands.containers = [
            {
              name = "Bash";
              attach = true;
              command = "docker exec -it {{ .Container.ID }} bash";
              serviceNames = [];
            }
            {
              name = "Shell";
              attach = true;
              command = "docker exec -it {{ .Container.ID }} sh";
              serviceNames = [];
            }
          ];
        };
      };
      home.sessionVariables.COMPOSE_BAKE = "true";
    };
  };
}
