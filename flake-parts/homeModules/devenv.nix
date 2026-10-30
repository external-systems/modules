{lib, ...}: {
  # ------ Home-manager Modules ------ #
  flake.homeModules.devenv = {
    config,
    pkgs,
    ...
  }: let
    cfg = config.homeSpec.programs.devenv;
  in {
    options.homeSpec.programs.devenv = {
      # devenv 2.x developer-environments CLI (pkgs.devenv, from
      # the consumer's overlay); `devenv mcp` is available for MCP clients
      # that invoke it themselves.
      enabled = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Whether to install devenv (developer environments CLI).";
      };
      # devenv 2.x native auto-activation (no direnv, no .envrc): the bash
      # hook spawned by `devenv hook bash` detects devenv projects
      # (devenv.nix in cwd or an ancestor) on every directory change and,
      # for trusted projects (`devenv allow`), starts a `devenv shell`
      # subshell that exits automatically when leaving the project.
      autoActivate.enabled = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Register the devenv 2.x native auto-activation hook in bash.
          No-ops outside devenv projects and when direnv already
          activated a devenv environment (DEVENV_ROOT set).
        '';
      };
    };
    config = lib.mkIf cfg.enabled {
      home.packages = [
        pkgs.devenv
      ];
      # initExtra (end of ~/.bashrc) so the hook wraps the PROMPT_COMMAND
      # already chained by the direnv/starship integration above it.
      programs.bash.initExtra = lib.mkIf cfg.autoActivate.enabled ''
        eval "$(${lib.getExe pkgs.devenv} hook bash)"
      '';
    };
  };
}
