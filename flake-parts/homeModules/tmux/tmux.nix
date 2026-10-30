{
  # inputs,
  # self,
  lib,
  ...
}: {
  # ------ Home-manager Modules ------ #
  flake.homeModules.tmux = {
    pkgs,
    config,
    ...
  }: let
    cfg = config.homeSpec.programs.tmux;
  in {
    options.homeSpec.programs.tmux.enable = lib.mkEnableOption "default tmux configuration";
    config = lib.mkIf cfg.enable {
      programs.tmux = {
        enable = true;

        package = pkgs.unstable.tmux;

        # Set the prefix key. Overrules the "shortcut" option when set.
        prefix = "C-a";

        # Automatically spawn a session if trying to attach and none are running.
        newSession = true;

        # Base index for windows and panes.
        baseIndex = 1;

        # Use 24 hour clock.
        clock24 = true;

        # Maximum number of lines held in window history.
        historyLimit = 8000;

        # Less command delay
        escapeTime = 20;

        # Set the $TERM variable.
        terminal = "screen-256color";

        plugins = with pkgs.unstable.tmuxPlugins; [
          tmux-fzf
          pass
        ];

        extraConfig = builtins.readFile ./tmux.conf;
      };
    };
  };
}
