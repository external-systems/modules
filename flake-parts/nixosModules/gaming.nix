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
#   Both also copy Steam's own record of the cache (config.vdf), or the
#   receiver's Steam replays every pipeline in it again
#   (_steam-shader-record.py). _steam-sharing.sh has both. They run as
#   root in a systemd sandbox that can only write below /home and the
#   game libraries; every replace or delete in a user's folders runs as
#   that user. Game libraries are `<libraryRoot>/<user>` (tmpfiles); a
#   library elsewhere in a user's libraryfolders.vdf is ignored.
#
# - `dedup`: bees (btrfs-dedup.nix) on the root btrfs filesystem, on by
#   default with steamSharing, frozen while any Steam game runs.
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

    shaderRecord = pkgs.writers.writePython3Bin "steam-shader-record" {
      libraries = [pkgs.python3Packages.vdf];
    } (builtins.readFile ./_steam-shader-record.py);

    sharingApp = name: main:
      pkgs.writeShellApplication {
        inherit name;
        runtimeInputs = with pkgs; [coreutils findutils gnugrep gnused glibc.getent procps shaderRecord systemd util-linux];
        text = builtins.readFile ./_steam-sharing.sh + "\n${main} \"$@\"\n";
      };
    shaderSync = sharingApp "steam-shader-sync" "sync_shaders";

    # Both run as root in this sandbox: they may only write below /home
    # and the game libraries, and keep only the capabilities to read
    # every user's files, hand files over and drop to a user.
    sandbox = {
      ProtectSystem = "strict";
      ReadWritePaths = ["-/home" "-${dirOf sharing.libraryRoot}"];
      PrivateTmp = true;
      PrivateNetwork = true;
      NoNewPrivileges = true;
      ProtectKernelTunables = true;
      ProtectKernelModules = true;
      ProtectKernelLogs = true;
      ProtectControlGroups = true;
      ProtectClock = true;
      RestrictSUIDSGID = true;
      RestrictRealtime = true;
      LockPersonality = true;
      SystemCallArchitectures = "native";
      CapabilityBoundingSet = ["CAP_CHOWN" "CAP_FOWNER" "CAP_DAC_OVERRIDE" "CAP_DAC_READ_SEARCH" "CAP_SETUID" "CAP_SETGID"];
      Environment = "STEAM_LIBRARY_ROOT=${sharing.libraryRoot}";
    };
    # The same sandbox as `systemd-run -p` properties.
    sandboxArgs = lib.concatLists (lib.mapAttrsToList (name: value: [
        "-p"
        "${name}=${
          if lib.isBool value
          then lib.boolToString value
          else if lib.isList value
          then lib.concatStringsSep " " value
          else value
        }"
      ])
      sandbox);
    copyGameUnsandboxed = sharingApp "steam-copy-game-unsandboxed" "copy_game";
    # steam-copy-game runs from a root shell, so it starts itself as a
    # transient unit in the sandbox; its output and exit code stay the
    # caller's.
    copyGame = pkgs.writeShellApplication {
      name = "steam-copy-game";
      runtimeInputs = [pkgs.coreutils pkgs.systemd];
      text = ''
        if [ "$(id -u)" != 0 ]; then
          exec ${lib.getExe copyGameUnsandboxed} "$@"
        fi
        exec systemd-run --quiet --pipe --wait --collect --service-type=exec \
          ${lib.escapeShellArgs sandboxArgs} \
          ${lib.getExe copyGameUnsandboxed} "$@"
      '';
    };

    # Root filesystem, for bees' default (dedup).
    root = config.fileSystems."/" or null;
    rootBtrfs = root != null && root.fsType == "btrfs";
    beesUnits = map (name: "beesd@${name}.service") (lib.attrNames config.hostSpec.system.btrfsDedup.filesystems);

    # A Steam game runs while one of Steam's `reaper SteamLaunch AppId=`
    # processes does (every game, desktop and Gaming Mode, any user).
    pauseBees = pkgs.writeShellApplication {
      name = "bees-pause-while-playing";
      runtimeInputs = [pkgs.procps pkgs.systemd pkgs.coreutils];
      text = ''
        units=(${lib.escapeShellArgs beesUnits})
        while :; do
          if pgrep -f 'SteamLaunch AppId=' >/dev/null; then want=frozen; else want=running; fi
          for unit in "''${units[@]}"; do
            state=$(systemctl show -P FreezerState "$unit")
            if [ "$want" = frozen ] && [ "$state" = running ] && systemctl -q is-active "$unit"; then
              systemctl freeze "$unit" && echo "a game is running: $unit paused"
            elif [ "$want" = running ] && [ "$state" = frozen ]; then
              systemctl thaw "$unit" && echo "no game is running: $unit resumed"
            fi
          done
          sleep 10
        done
      '';
    };
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
          description = ''
            Users whose shader caches steam-shader-sync shares, and who
            get a game library in `libraryRoot`.
          '';
        };
        libraryRoot = lib.mkOption {
          type = lib.types.str;
          default = "/srv/steam/users";
          example = "/mnt/games/users";
          description = ''
            Folder of the users' game libraries: each user in `users` gets
            `<libraryRoot>/<user>` (mode 0700, theirs), to add in Steam
            (Settings > Storage) once. Must be on the same btrfs
            filesystem as the users' homes. steam-copy-game and
            steam-shader-sync only use these libraries and each user's
            Steam folder, and may only write below /home and the parent
            of this folder.
          '';
        };
      };

      dedup = {
        enable = lib.mkOption {
          type = lib.types.bool;
          default = sharing.enable && rootBtrfs;
          defaultText = lib.literalExpression ''steamSharing.enable && config.fileSystems."/".fsType == "btrfs"'';
          example = false;
          description = ''
            Whether bees deduplicates the root btrfs filesystem
            (hostSpec.system.btrfsDedup, filesystem `root`): what users
            download on their own (the same game, Proton prefixes, shader
            caches) is stored once. It runs in every boot entry. On by
            default with steamSharing when / is btrfs.
          '';
        };
        pauseWhilePlaying = lib.mkOption {
          type = lib.types.bool;
          default = true;
          example = false;
          description = ''
            Freeze bees (systemctl freeze) while any user runs a Steam
            game, and thaw it when the last game exits, checked every 10
            seconds. bees' idle CPU and I/O priority does not keep it off
            a fast NVMe disk (the "none" I/O scheduler ignores I/O
            classes), so a game would otherwise share the disk and page
            cache with it. Applies to every hostSpec.system.btrfsDedup
            filesystem.
          '';
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
          # Each user's game library, theirs alone.
          tmpfiles.settings.steam-libraries =
            {
              ${sharing.libraryRoot}.d = {
                user = "root";
                group = "root";
                mode = "0755";
              };
            }
            // lib.listToAttrs (map (user:
              lib.nameValuePair "${sharing.libraryRoot}/${user}" {
                d = {
                  inherit user;
                  inherit (config.users.users.${user}) group;
                  mode = "0700";
                };
              })
            sharing.users);

          services.steam-shader-sync = {
            description = "Share Steam shader caches between users";
            # At boot, before anyone's Steam starts.
            before = ["display-manager.service"];
            wantedBy = ["multi-user.target"];
            serviceConfig =
              sandbox
              // {
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

      (lib.mkIf cfg.dedup.enable {
        assertions = [
          {
            assertion = rootBtrfs || config.hostSpec.system.btrfsDedup.filesystems ? root;
            message = ''hostSpec.system.gaming.dedup: / is not btrfs; set hostSpec.system.btrfsDedup.filesystems.root.spec, or dedup.enable = false.'';
          }
        ];
        hostSpec.system.btrfsDedup = {
          enable = true;
          filesystems.root.spec = lib.mkIf rootBtrfs (lib.mkDefault (
            if root.device != null
            then root.device
            else "LABEL=${root.label}"
          ));
        };
      })

      (lib.mkIf (cfg.dedup.enable && cfg.dedup.pauseWhilePlaying) {
        systemd.services.bees-pause-while-playing = {
          description = "Pause bees while a Steam game runs";
          after = beesUnits;
          wantedBy = ["multi-user.target"];
          # Never leave bees frozen behind.
          postStop = "${lib.getExe' pkgs.systemd "systemctl"} thaw ${lib.escapeShellArgs beesUnits} || true";
          serviceConfig = {
            ExecStart = lib.getExe pauseBees;
            Restart = "always";
            RestartSec = 10;
          };
        };
      })
    ];
  };
}
