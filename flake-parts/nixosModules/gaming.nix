# Gaming on a machine several people use, and on a Steam Deck.
#
# - `user`: a dedicated, unprivileged Gaming Mode user (a Deck's player).
#   It lives outside the jovian module on purpose: the jovian module is
#   often only on in a gaming boot entry (gaming-specialisation.nix), but
#   the user must keep owning its files in every entry.
#
# - `steamSharing`: every Linux user keeps a Steam library of their own.
#   Steam assumes it owns all of its files (it chmods them, sets their
#   times, deletes and rebuilds folders), so a library several users
#   write breaks in rotating ways. Sharing happens below Steam instead:
#   reflink copies (btrfs: instant, no extra space) that the receiving
#   user owns, and btrfs-dedup.nix for what users download on their own.
#   - `steam-copy-game --from <user> --to <user> <appid>` (sudo, Steam
#     of the receiving user closed): the game, its shader cache and its
#     install record, so the other user neither downloads it nor
#     compiles its shaders.
#   - steam-shader-sync (at boot and every 15 minutes): the biggest
#     shader cache of every game goes to the other users who have the
#     game installed, so a game's shaders compile once. Users whose
#     Steam runs are skipped.
#   _steam-sharing.sh has both.
{
  flake.nixosModules.gaming = {
    config,
    lib,
    pkgs,
    ...
  }: let
    cfg = config.hostSpec.system.gaming;
    sharing = cfg.steamSharing;
    jovian = config.hostSpec.system.jovian or {};

    sharingApp = name: main:
      pkgs.writeShellApplication {
        inherit name;
        runtimeInputs = with pkgs; [coreutils findutils gnugrep gnused glibc.getent procps util-linux];
        text = builtins.readFile ./_steam-sharing.sh + "\n${main} \"$@\"\n";
      };
    copyGame = sharingApp "steam-copy-game" "copy_game";
    shaderSync = sharingApp "steam-shader-sync" "sync_shaders";
  in {
    options.hostSpec.system.gaming = {
      user = {
        enable = lib.mkOption {
          type = lib.types.bool;
          # `or`: nixosModules.gaming also works without nixosModules.jovian.
          default = (jovian.gamingMode or false) && (jovian.user or null) == cfg.user.name;
          defaultText = lib.literalExpression "hostSpec.system.jovian.gamingMode && hostSpec.system.jovian.user == name";
          example = true;
          description = ''
            Whether to declare the dedicated Gaming Mode user: a normal
            user without wheel, docker, SSH keys or a usable password,
            hidden from the SDDM login screen. Only Gaming Mode's
            autologin starts its session. On by default when Gaming Mode
            logs in as it.
          '';
        };
        name = lib.mkOption {
          type = lib.types.str;
          default = "gamer";
          example = "player";
          description = ''
            Name of the dedicated Gaming Mode user. Not "steam": that is
            also the program and its processes.
          '';
        };
        uid = lib.mkOption {
          type = lib.types.int;
          default = 1500;
          example = 1600;
          description = ''
            Fixed uid, so the files it owns on game disks keep their
            owner across reinstalls.
          '';
        };
        extraGroups = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = ["video" "audio" "input" "networkmanager"];
          example = ["video" "audio" "input" "networkmanager" "dialout"];
          description = "Groups the Gaming Mode user is in. Never wheel or docker.";
        };
      };

      steamSharing = {
        enable = lib.mkEnableOption ''
          sharing Steam games and shader caches between the users' own
          libraries by reflink copies (steam-copy-game, steam-shader-sync);
          see this file's header. Needs the libraries on one btrfs
          filesystem
        '';
        users = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = lib.attrNames (lib.filterAttrs (_: user: user.isNormalUser) config.users.users);
          defaultText = lib.literalExpression "every normal user (isNormalUser)";
          example = ["alice" "bob"];
          description = "Users whose shader caches steam-shader-sync shares.";
        };
      };
    };

    config = lib.mkMerge [
      (lib.mkIf cfg.user.enable {
        users.users.${cfg.user.name} = {
          isNormalUser = true;
          inherit (cfg.user) uid extraGroups;
          description = "Steam Gaming Mode";
          # Locked: no password works at the login screen, a TTY or SSH.
          # SDDM's autologin does not ask for one.
          hashedPassword = "!";
        };

        # Not in the login screen's user list (nor Plasma's Switch User).
        services.displayManager.sddm.settings.Users.HideUsers = cfg.user.name;

        # Plasma as this user (Switch to Desktop) must never lock: there
        # is no password to unlock with.
        systemd.tmpfiles.settings.gaming-user = let
          home = config.users.users.${cfg.user.name}.home;
          owned = {
            user = cfg.user.name;
            inherit (config.users.users.${cfg.user.name}) group;
          };
        in {
          "${home}/.config".d = owned // {mode = "0700";};
          "${home}/.config/kscreenlockerrc"."f+" =
            owned
            // {
              mode = "0644";
              # Real newlines: the NixOS tmpfiles module escapes them.
              argument = "[Daemon]\nAutolock=false\nLockOnResume=false\n";
            };
        };
      })

      (lib.mkIf sharing.enable {
        assertions =
          map (user: {
            assertion = config.users.users ? ${user};
            message = "hostSpec.system.gaming.steamSharing.users: \"${user}\" is not a user on this machine.";
          })
          sharing.users;

        environment.systemPackages = [copyGame];

        systemd = {
          services.steam-shader-sync = {
            description = "Share Steam shader caches between users";
            # At boot, before anyone's Steam starts.
            before = ["display-manager.service"];
            wantedBy = ["multi-user.target"];
            serviceConfig = {
              Type = "oneshot";
              ExecStart = lib.escapeShellArgs ([(lib.getExe shaderSync)] ++ sharing.users);
              Nice = 19;
              IOSchedulingClass = "idle";
            };
          };
          timers.steam-shader-sync = {
            description = "Share Steam shader caches between users";
            wantedBy = ["timers.target"];
            timerConfig = {
              OnBootSec = "5min";
              OnUnitActiveSec = "15min";
            };
          };
        };
      })
    ];
  };
}
