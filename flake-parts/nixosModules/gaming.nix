# Gaming on a shared machine: a dedicated, unprivileged Gaming Mode user
# and Steam libraries whose game files several Linux users share.
#
# Both live outside the jovian module on purpose: the jovian module is
# often only on in a gaming boot entry (gaming-specialisation.nix), but
# the user must keep owning its files, and KDE Steam in the developer
# entry must see the same libraries.
#
# Sharing a whole Steam library between Linux users breaks Proton: Wine
# refuses a prefix (steamapps/compatdata/<appid>) another user owns, and
# Proton chmods its own files after updates. So only the game files are
# shared (https://github.com/ValveSoftware/Proton/issues/4820):
#
#   <path>/common/                    root:<group> 2775 + default ACL
#   <path>/shadercache/               root:<group> 2775 (shaderCache)
#   <path>/users/<user>/steamapps/    <user> 0700 (manifests, compatdata,
#     common -> <path>/common          downloading)
#     shadercache -> <path>/shadercache
#
# steam-library-register@<user> adds <path>/users/<user> to each user's
# Steam as a library, and by default makes the first one where new games
# install (_steam-library-register.py has the files it writes). A game
# another user already installed then installs into it by verifying the
# files in common/, with no download. Steam must have run once for the
# user, and it only takes effect while Steam is closed: the next deploy
# or boot after the user first opens Steam, or when Steam next exits.
#
# Steam does not write game files in common/: it downloads into the
# user's own steamapps/downloading and moves them in, so they keep that
# user's group (users) and mode (no group write) and miss the folder's
# default ACL. Another user's Steam can then read the game but not update
# or verify it ("missing file privileges"). steam-library-share@<user>
# hands that user's files in common/ and shadercache/ to the group with group write, as
# the user (an owner may chgrp to a group it is in): at boot, on every
# deploy, and every few minutes from a timer. It never follows symlinks
# and never touches another user's files.
{
  flake.nixosModules.gaming = {
    config,
    lib,
    pkgs,
    utils,
    ...
  }: let
    cfg = config.hostSpec.system.gaming;
    libs = cfg.sharedLibraries;
    jovian = config.hostSpec.system.jovian or {};

    # The filesystem a path lives on: the longest fileSystems mount
    # point that contains it (disko generates these entries).
    fsOf = path: let
      contains = mp: mp == "/" || path == mp || lib.hasPrefix "${mp}/" path;
      mounts = lib.filter (fs: contains fs.mountPoint) (lib.attrValues config.fileSystems);
    in
      lib.foldl' (best: fs:
        if best == null || lib.stringLength fs.mountPoint > lib.stringLength best.mountPoint
        then fs
        else best)
      null
      mounts;

    groupOf = user: config.users.users.${user}.group;

    libraryUnit = path: "steam-library-${utils.escapeSystemdPath path}.service";

    shareScript = ''
      user=$(id -un)
      for common in ${lib.escapeShellArgs (lib.concatMap (path: ["${path}/common"] ++ lib.optional libs.shaderCache "${path}/shadercache") libs.paths)}; do
        [ -d "$common" ] || continue
        # A file Steam is moving can vanish between find and the change:
        # report and carry on, the next run gets the rest.
        find "$common" -xdev -user "$user" ! -type l ! -group ${libs.group} \
          -exec chgrp ${libs.group} {} + || echo "some files kept their group" >&2
        find "$common" -xdev -user "$user" \( -type f -o -type d \) ! -perm -g+w \
          -exec chmod g+rwX {} + || echo "some files kept their mode" >&2
        find "$common" -xdev -user "$user" -type d ! -perm -g+s \
          -exec chmod g+s {} + || echo "some folders kept their mode" >&2
      done
    '';

    registerLibraries = pkgs.writers.writePython3Bin "steam-library-register" {
      libraries = with pkgs.python3Packages; [psutil vdf];
    } (builtins.readFile ./_steam-library-register.py);

    setupScript = path: ''
      install -d -m 0755 -o root -g root ${lib.escapeShellArg path} ${lib.escapeShellArg "${path}/users"}
      install -d -m 2775 -o root -g ${libs.group} ${lib.escapeShellArg "${path}/common"}
      # Group-writable whatever umask Steam runs with; setgid keeps the
      # group on new directories. Never setgid files: the Steam Linux
      # Runtime refuses setgid executables.
      setfacl -m g:${libs.group}:rwx,d:g:${libs.group}:rwx ${lib.escapeShellArg "${path}/common"}
      ${lib.optionalString libs.shaderCache ''
        install -d -m 2775 -o root -g ${libs.group} ${lib.escapeShellArg "${path}/shadercache"}
        setfacl -m g:${libs.group}:rwx,d:g:${libs.group}:rwx ${lib.escapeShellArg "${path}/shadercache"}
      ''}
      ${lib.concatMapStrings (user: let
          home = "${path}/users/${user}";
        in ''
          install -d -m 0700 -o ${user} -g ${groupOf user} ${lib.escapeShellArg home} ${lib.escapeShellArg "${home}/steamapps"}
          if [ -d ${lib.escapeShellArg "${home}/steamapps/common"} ] && [ ! -L ${lib.escapeShellArg "${home}/steamapps/common"} ]; then
            echo "${home}/steamapps/common is a folder, not the shared link: move its games into ${path}/common, then restart this service" >&2
          else
            ln -sfn ${lib.escapeShellArg "${path}/common"} ${lib.escapeShellArg "${home}/steamapps/common"}
            chown -h ${user}:${groupOf user} ${lib.escapeShellArg "${home}/steamapps/common"}
          fi
          ${lib.optionalString libs.shaderCache (shaderCacheScript path user)}
        '')
        libs.users}
    '';

    # One Vulkan/DXVK/Mesa shader cache per game for everyone: the same
    # GPU and Mesa build compile the same shaders. A user's own caches
    # move into the shared one; of two caches for one game the bigger,
    # more complete one stays (it is only a cache). Never while that
    # user's Steam runs.
    shaderCacheScript = path: user: let
      shared = lib.escapeShellArg "${path}/shadercache";
      own = lib.escapeShellArg "${path}/users/${user}/steamapps/shadercache";
    in ''
      if [ -d ${own} ] && [ ! -L ${own} ]; then
        if pgrep -u ${user} -x steam >/dev/null; then
          echo "${user}'s Steam is running: its shader cache moves into ${path}/shadercache at the next boot" >&2
        else
          for cache in ${own}/* ${own}/.[!.]*; do
            [ -e "$cache" ] || [ -L "$cache" ] || continue
            name=$(basename "$cache")
            if [ -e ${shared}/"$name" ] || [ -L ${shared}/"$name" ]; then
              # Two caches of one game: keep the bigger, more complete one.
              if [ "$(du -sb -- "$cache" | cut -f1)" -gt "$(du -sb -- ${shared}/"$name" | cut -f1)" ]; then
                rm -rf -- ${shared}/"$name"
                mv -T -- "$cache" ${shared}/"$name"
                echo "${user}: shader cache $name replaces a smaller shared one" >&2
              else
                rm -rf -- "$cache"
                echo "${user}: ${path}/shadercache/$name is as big, dropping ${user}'s copy" >&2
              fi
            else
              mv -T -- "$cache" ${shared}/"$name"
              echo "${user}: shader cache $name moved into ${path}/shadercache" >&2
            fi
          done
          rmdir ${own}
        fi
      fi
      if [ ! -e ${own} ] || [ -L ${own} ]; then
        ln -sfn ${shared} ${own}
        chown -h ${user}:${groupOf user} ${own}
      fi
    '';
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

      sharedLibraries = {
        enable = lib.mkEnableOption ''
          Steam libraries whose game files (steamapps/common) are shared
          by every user in `users`, one download per game; see this
          file's header
        '';
        paths = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = ["/srv/games"];
          example = ["/mnt/steam" "/mnt/games2"];
          description = ''
            Library roots, one per disk. Each must be at or under a mount
            point in fileSystems (for example one disko declares); nothing
            here formats or mounts a disk. A path on a disk mounted
            `nofail` that is missing at boot is skipped, not created on
            the root filesystem. ZFS datasets need acltype=posixacl and
            xattr=sa.
          '';
        };
        users = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = lib.attrNames (lib.filterAttrs (_: user: user.isNormalUser) config.users.users);
          defaultText = lib.literalExpression "every normal user (isNormalUser), the Gaming Mode user included";
          example = ["gamer" "alice"];
          description = "Users who get a library folder on every path and join `group`.";
        };
        group = lib.mkOption {
          type = lib.types.str;
          default = "gamers";
          example = "games";
          description = "Group that owns and may write the shared game files.";
        };
        shaderCache = lib.mkOption {
          type = lib.types.bool;
          default = true;
          example = false;
          description = ''
            Share each game's shader cache (Steam's Vulkan pre-compiled
            shaders, Mesa, DXVK, VKD3D) between the users too, in
            <path>/shadercache, so a game's shaders compile once for
            everyone. Users' existing caches move in at the next boot.
            Deleting a game's shader cache in Steam deletes it for all.
          '';
        };
        makeDefault = lib.mkOption {
          type = lib.types.bool;
          default = true;
          example = false;
          description = ''
            Make each user's library on the first path Steam's default
            install location, for every Steam account of that user (the
            star in Steam's Storage settings), so games installed from
            Gaming Mode land in the shared library too. A default picked
            in Steam is set back on the next deploy or boot; false
            leaves the choice to each user.
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

      (lib.mkIf libs.enable {
        assertions =
          [
            {
              assertion = libs.users != [];
              message = "hostSpec.system.gaming.sharedLibraries: no users share the libraries; set users or add a normal user.";
            }
          ]
          ++ map (path: {
            assertion = lib.hasPrefix "/" path && !(lib.hasSuffix "/" path);
            message = "hostSpec.system.gaming.sharedLibraries.paths: \"${path}\" must be absolute, without a trailing slash.";
          })
          libs.paths
          ++ map (user: {
            assertion = config.users.users ? ${user};
            message = "hostSpec.system.gaming.sharedLibraries.users: \"${user}\" is not a user on this machine.";
          })
          libs.users;

        warnings = lib.concatMap (path: let
          fs = fsOf path;
        in
          lib.optional (fs != null && fs.fsType == "zfs")
          "hostSpec.system.gaming.sharedLibraries: ${path} is on ZFS (${fs.device}); set acltype=posixacl and xattr=sa on that dataset, or the shared ACLs fail.")
        libs.paths;

        users.groups.${libs.group}.members = libs.users;

        systemd = {
          # A service per path rather than tmpfiles: RequiresMountsFor keeps
          # it from running when a nofail disk is missing, so no stray
          # folders appear on the root filesystem.
          services =
            lib.listToAttrs (map (path:
              lib.nameValuePair (lib.removeSuffix ".service" (libraryUnit path)) {
                description = "Shared Steam library at ${path}";
                wantedBy = ["multi-user.target"];
                # Moves shader caches: done before Gaming Mode's Steam starts.
                before = ["display-manager.service"];
                unitConfig.RequiresMountsFor = path;
                path = [pkgs.acl pkgs.coreutils pkgs.procps];
                serviceConfig = {
                  Type = "oneshot";
                  RemainAfterExit = true;
                };
                script = setupScript path;
              })
            libs.paths)
            // {
              # Runs as the user. Type=exec, left inactive after it ends,
              # like steam-config-patcher@: every activation starts it
              # again, and a deploy never waits while it waits for Steam
              # to close.
              "steam-library-register@" = {
                description = "Register the shared Steam libraries with %i's Steam";
                after = map libraryUnit libs.paths;
                # At boot, before Gaming Mode's autologin starts Steam.
                before = ["display-manager.service"];
                serviceConfig = {
                  Type = "exec";
                  User = "%i";
                  ExecStart = lib.escapeShellArgs (
                    [(lib.getExe registerLibraries)]
                    ++ lib.optional libs.makeDefault "--make-default"
                    ++ libs.paths
                  );
                };
              };

              "steam-library-share@" = {
                description = "Share %i's game files in the shared Steam libraries";
                after = map libraryUnit libs.paths;
                before = ["display-manager.service"];
                path = [pkgs.coreutils pkgs.findutils];
                serviceConfig = {
                  Type = "oneshot";
                  User = "%i";
                  Group = libs.group;
                  Nice = 19;
                  IOSchedulingClass = "idle";
                };
                script = shareScript;
              };
            };
          timers = lib.listToAttrs (map (user:
            lib.nameValuePair "steam-library-share-${user}" {
              description = "Share ${user}'s game files in the shared Steam libraries";
              wantedBy = ["timers.target"];
              timerConfig = {
                OnBootSec = "2min";
                OnUnitActiveSec = "3min";
                Unit = "steam-library-share@${user}.service";
              };
            })
          libs.users);
          targets.multi-user.wants =
            map (user: "steam-library-register@${user}.service") libs.users
            ++ map (user: "steam-library-share@${user}.service") libs.users;
        };
      })
    ];
  };
}
