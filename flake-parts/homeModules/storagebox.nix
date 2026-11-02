{lib, ...}: {
  # ------ Home-manager Modules ------ #
  # Per-user Hetzner Storage Box mounts: zero or more boxes per user, each
  # reached as its own login (the main account or a sub-account; which one
  # is a values choice, not a module choice). Every box is
  #   - an rclone sftp remote "storagebox-<name>" (programs.rclone),
  #   - a FUSE mount under the user's home, run as a systemd *user* unit
  #     (no root, no allow_other: only this user sees the files),
  #   - an ssh alias "storagebox-<name>" (programs.ssh.matchBlocks), so
  #     `ssh`, `sftp` and `rsync storagebox-<name>:path ...` just work.
  #
  # The login comes from the values flake in the consumer (no account ids
  # here). The SSH key is one clan vars keypair per Linux user,
  # "storagebox-ssh-<user>", declared by nixosModules/storagebox.nix and
  # fed back as keyFile; install its public half on every box the user
  # mounts (command in that file). Until the key is generated keyFile is
  # null and this module renders nothing.
  #
  # startOn = "login" starts the mount with default.target. User units
  # cannot use systemd .automount (automount units are system-only), so a
  # mount either runs for the whole session or is started by hand
  # ("manual": systemctl --user start 'rclone-mount:<path>@storagebox-<name>').
  flake.homeModules.storagebox = {
    config,
    pkgs,
    ...
  }: let
    cfg = config.homeSpec.programs.storagebox;

    box = types:
      types.submodule ({name, ...}: {
        options = {
          enabled = lib.mkEnableOption "this Storage Box mount" // {default = true;};
          user = lib.mkOption {
            type = types.str;
            description = "Storage Box login: the main account (u123456) or a sub-account (u123456-sub1). Take it from the values flake.";
            example = "u000000-sub1";
          };
          host = lib.mkOption {
            type = types.str;
            description = "SSH host of the login, normally <user>.your-storagebox.de. Take it from the values flake.";
            example = "u000000-sub1.your-storagebox.de";
          };
          port = lib.mkOption {
            type = types.port;
            default = 23;
            description = "SSH/SFTP port. 23 serves the full SSH command set (rsync, borg); 22 is SFTP/SCP only.";
          };
          keyFile = lib.mkOption {
            type = types.nullOr types.str;
            default = cfg.keyFile;
            defaultText = lib.literalExpression "config.homeSpec.programs.storagebox.keyFile";
            description = "Private key for this login. Defaults to the user's clan-generated key.";
          };
          mountPoint = lib.mkOption {
            type = types.str;
            default = "${config.home.homeDirectory}/storagebox/${name}";
            defaultText = lib.literalExpression ''"''${config.home.homeDirectory}/storagebox/<name>"'';
            description = "Where the box is mounted.";
          };
          remotePath = lib.mkOption {
            type = types.str;
            default = "";
            description = "Directory on the box to mount; empty mounts the login's root (a sub-account's root is its base directory).";
            example = "BACKUPS";
          };
          startOn = lib.mkOption {
            type = types.enum ["login" "manual"];
            default = "login";
            description = "\"login\": mount with the user session (default.target). \"manual\": only when started with systemctl --user.";
          };
          checkers = lib.mkOption {
            type = types.ints.between 1 10;
            default = 2;
            description = "Concurrent rclone checkers. Storage Boxes allow 10 concurrent connections per login.";
          };
          vfs = {
            cacheMaxSize = lib.mkOption {
              type = types.str;
              default = "5G";
              description = "rclone --vfs-cache-max-size.";
            };
            cacheMaxAge = lib.mkOption {
              type = types.str;
              default = "10m";
              description = "rclone --vfs-cache-max-age.";
            };
            dirCacheTime = lib.mkOption {
              type = types.str;
              default = "1m";
              description = "rclone --dir-cache-time.";
            };
          };
          extraOptions = lib.mkOption {
            type = types.attrsOf (types.nullOr (types.oneOf [types.bool types.int types.str]));
            default = {};
            description = "Extra rclone mount flags (without the leading --), merged over the defaults.";
            example = {vfs-read-ahead = "256M";};
          };
        };
      });

    # Mounts that can start now: enabled and with a key on disk.
    active = lib.filterAttrs (_: b: b.enabled && b.keyFile != null) cfg.boxes;
  in {
    options.homeSpec.programs.storagebox = {
      enabled = lib.mkEnableOption "per-user Hetzner Storage Box mounts";

      keyFile = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Deployed path of the user's clan-generated Storage Box key (storagebox-ssh-<user>). Internal: set by nixosModules/storagebox.nix via home-manager.sharedModules; never set it in a profile.";
      };

      boxes = lib.mkOption {
        type = lib.types.attrsOf (box lib.types);
        default = {};
        description = "Storage Box logins to mount, keyed by a short name (the rclone remote and ssh alias become storagebox-<name>).";
        example = lib.literalExpression ''
          {
            main = {
              inherit (values.storageboxes.main.subAccounts.alice) user host port;
            };
          }
        '';
      };
    };

    config = lib.mkIf (cfg.enabled && active != {}) {
      programs = {
        rclone = {
          enable = true;
          remotes = lib.mapAttrs' (name: b:
            lib.nameValuePair "storagebox-${name}" {
              config = {
                type = "sftp";
                inherit (b) host user port;
                key_file = b.keyFile;
              };
              mounts.${b.remotePath} = {
                enable = true;
                autoMount = b.startOn == "login";
                inherit (b) mountPoint;
                logLevel = "INFO";
                options =
                  {
                    vfs-cache-mode = "full";
                    vfs-cache-max-size = b.vfs.cacheMaxSize;
                    vfs-cache-max-age = b.vfs.cacheMaxAge;
                    dir-cache-time = b.vfs.dirCacheTime;
                    inherit (b) checkers;
                    links = true;
                  }
                  // b.extraOptions;
              };
            })
          active;
        };

        ssh.matchBlocks = lib.mapAttrs' (name: b:
          lib.nameValuePair "storagebox-${name}" {
            hostname = b.host;
            inherit (b) user port;
            identityFile = b.keyFile;
            identitiesOnly = true;
          })
        active;
      };

      home.packages = [pkgs.rclone];
    };
  };
}
