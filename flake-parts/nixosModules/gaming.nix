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
#   <path>/users/<user>/steamapps/    <user> 0700 (manifests, compatdata,
#     common -> <path>/common          shadercache, downloading)
#
# Each user adds <path>/users/<user> once as a library in Steam's Storage
# settings. A game another user already installed then installs by
# verifying the files in common/, with no download.
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

    setupScript = path: ''
      install -d -m 0755 -o root -g root ${lib.escapeShellArg path} ${lib.escapeShellArg "${path}/users"}
      install -d -m 2775 -o root -g ${libs.group} ${lib.escapeShellArg "${path}/common"}
      # Group-writable whatever umask Steam runs with; setgid keeps the
      # group on new directories. Never setgid files: the Steam Linux
      # Runtime refuses setgid executables.
      setfacl -m g:${libs.group}:rwx,d:g:${libs.group}:rwx ${lib.escapeShellArg "${path}/common"}
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
        '')
        libs.users}
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
              argument = "[Daemon]\\nAutolock=false\\nLockOnResume=false\\n";
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

        # A service per path rather than tmpfiles: RequiresMountsFor keeps
        # it from running when a nofail disk is missing, so no stray
        # folders appear on the root filesystem.
        systemd.services = lib.listToAttrs (map (path:
          lib.nameValuePair "steam-library-${utils.escapeSystemdPath path}" {
            description = "Shared Steam library at ${path}";
            wantedBy = ["multi-user.target"];
            unitConfig.RequiresMountsFor = path;
            path = [pkgs.acl pkgs.coreutils];
            serviceConfig = {
              Type = "oneshot";
              RemainAfterExit = true;
            };
            script = setupScript path;
          })
        libs.paths);
      })
    ];
  };
}
