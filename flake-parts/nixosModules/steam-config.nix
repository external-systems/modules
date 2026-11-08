# Declarative Steam settings through steam-config-nix
# (https://github.com/different-name/steam-config-nix): GE-Proton as
# Steam's default compatibility tool, and room for per-game settings
# (launch options, Proton builds, winetricks) under
# programs.steam.config.apps.
#
# Its NixOS module runs a patcher for every normal user
# (steam-config-patcher@<user>), so one setting covers the Gaming Mode
# user and everyone who runs Steam from their own desktop. The patcher
# edits Steam's own config files, which only works with Steam closed:
# with onSteamRunning = "wait" a change lands the next time Steam exits
# (Switch to Desktop, logout, reboot). Gaming Mode keeps Steam open, so
# "close" would end the session on every deploy.
{inputs, ...}: {
  flake.nixosModules.steam-config = {
    config,
    lib,
    pkgs,
    ...
  }: let
    cfg = config.hostSpec.system.gaming.steamConfig;
  in {
    imports = [inputs.steam-config-nix.nixosModules.default];

    options.hostSpec.system.gaming.steamConfig = {
      enable = lib.mkEnableOption ''
        declarative Steam settings (steam-config-nix) for every user,
        wherever Steam is installed (programs.steam.enable)
      '';
      defaultCompatTool = lib.mkOption {
        type = with lib.types; nullOr (either str package);
        default = pkgs.proton-ge-bin;
        defaultText = lib.literalExpression "pkgs.proton-ge-bin";
        example = "proton_experimental";
        description = ''
          Steam Play's default compatibility tool for games without their
          own: a package containing one, or the internal name of an
          installed tool. null leaves Steam's setting alone. A game's own
          choice in Steam, or programs.steam.config.apps.<id>.compatTool,
          still wins.
        '';
      };
      onSteamRunning = lib.mkOption {
        type = lib.types.enum ["wait" "close" "force-close" "skip"];
        default = "wait";
        example = "close";
        description = ''
          What to do when a change must be written while Steam runs
          (programs.steam.config.onSteamRunning). "wait" applies it when
          Steam next exits; "close" ends Gaming Mode on every deploy.
        '';
      };
    };

    config = lib.mkIf (cfg.enable && config.programs.steam.enable) {
      programs.steam.config = {
        enable = true;
        inherit (cfg) defaultCompatTool onSteamRunning;
      };

      # The patcher fails for a user who never opened Steam ("could not
      # locate a Steam installation", the same three folders it checks),
      # and a failed unit makes every deploy report a failed activation.
      # A failing ExecCondition skips the unit instead.
      systemd.services."steam-config-patcher@".serviceConfig.ExecCondition = let
        steamInstalled = pkgs.writeShellScript "steam-installed" ''
          for dir in "$HOME/.steam/root" "$HOME/.steam/steam" "$HOME/.local/share/Steam"; do
            [ -d "$dir" ] && exit 0
          done
          echo "no Steam install for $USER yet: skipped"
          exit 1
        '';
      in "${steamInstalled}";
    };
  };
}
