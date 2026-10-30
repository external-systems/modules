{
  # inputs,
  # self,
  lib,
  ...
}: {
  # ------ Home-manager Modules ------ #
  flake.homeModules.starship = {config, ...}: let
    cfg = config.homeSpec.programs.starship;
  in {
    options.homeSpec.programs.starship.enable = lib.mkEnableOption "default starship configuration";
    config = lib.mkIf cfg.enable {
      programs.starship = {
        enable = true;
        settings = {
          aws.disabled = true;
          gcloud.disabled = true;
          kubernetes = {
            disabled = false;
            detect_env_vars = ["KUBECONFIG"];
          };
          git_branch.style = "242";
          directory = {
            style = "bold blue";
            truncate_to_repo = true;
            truncation_length = 10;
          };
          direnv.disabled = false;
          python.disabled = false;
          ruby.disabled = true;
          hostname.ssh_only = false;
          hostname.style = "bold green";
          nix_shell.symbol = "❄";
          git_status = {
            ahead = "↑";
            behind = "↓";
            diverged = "↕";
            modified = "!";
            staged = "±";
            renamed = "→";
          };
        };
      };
    };
  };
}
