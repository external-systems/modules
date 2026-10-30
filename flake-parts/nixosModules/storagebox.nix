{
  # inputs,
  # self,
  lib,
  ...
}: {
  # ------ NixOS Modules ------ #
  flake.nixosModules.storagebox = {
    pkgs,
    config,
    ...
  }: let
    cfg = config.hostSpec.services.storagebox;
  in {
    options.hostSpec.services.storagebox = {
      enable = lib.mkEnableOption "default storagebox configuration";
      mountOnAccess = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Whether to mount on access, instead of permanently";
        example = true;
      };
      mountPoint = lib.mkOption {
        type = lib.types.str;
        default = "/mnt/storagebox";
        description = "Where to mount the storage";
        example = "/mnt/music";
      };
      boxUser = lib.mkOption {
        type = lib.types.str;
        # No default: the account id is a fleet value. Take it from the
        # values flake (external-systems/secrets, or the not-secrets
        # placeholder) in the machine config.
        description = "The Hetzner Storage Box User";
        example = "u000000-sub1";
      };
      concurrency = lib.mkOption {
        type = lib.types.int;
        default = 2;
        description = "The number of concurrent checkers (max 10)";
        example = 10;
      };
    };

    config = lib.mkIf cfg.enable {
      # Hard-code an unsused gid for the group
      users.groups.storage-users.gid = 982;

      # SSH keypair generator for Hetzner Storage Box
      # To add SSH keys to storagebox use the below command, this will ask for the password
      # clan vars get [MACHINE] storagebox-ssh-[USER]/ssh-public-key | ssh -p23 [USER]@[USER].your-storagebox.de install-ssh-key
      clan.core.vars.generators."storagebox-ssh-${cfg.boxUser}" = {
        share = true;
        files.ssh-private-key = {};
        files.ssh-public-key.secret = false;
        runtimeInputs = with pkgs; [openssh];
        script = ''
          mkdir -p $out
          ssh-keygen -t ed25519 -f $out/ssh-private-key -N "" -C "${cfg.boxUser}-storagebox"
          mv $out/ssh-private-key.pub $out/ssh-public-key
        '';
      };

      # Add rclone to system packages for mount helper support
      environment.systemPackages = [pkgs.rclone];

      # Hetzner Storage Box mount with rclone - using proper mount helper
      # Create cache directory for rclone
      systemd.tmpfiles.rules = [
        "d /var/cache/rclone-storagebox-${cfg.boxUser} 0750 root storage-users -"
      ];

      fileSystems."${cfg.mountPoint}" = {
        device = ":sftp:";
        fsType = "rclone";
        options =
          [
            "rw"
            "nofail"
            "_netdev"
            "x-systemd.mount-timeout=360s"
            "x-systemd.wants=network-online.target"
            "args2env"
            "config=/dev/null"
            "vfs_cache_mode=full"
            "cache_dir=/var/cache/rclone-storagebox-${cfg.boxUser}"
            "checkers=${toString cfg.concurrency}"
            "gid=${toString config.users.groups.storage-users.gid}"
            "umask=007"
            "allow_other"
            "allow_non_empty"
            "links"
            "sftp_host=${cfg.boxUser}.your-storagebox.de"
            "sftp_user=${cfg.boxUser}"
            "sftp_port=23"
            "sftp_key_file=${config.clan.core.vars.generators."storagebox-ssh-${cfg.boxUser}".files."ssh-private-key".path}"
            "vfs_cache_max_size=5G"
            "vfs_cache_max_age=10m"
            "vfs_read_ahead=256M"
            "buffer_size=500M"
            "dir_cache_time=1m"
            "log_level=INFO"
            "log_systemd=true"
          ]
          ++ lib.optionals cfg.mountOnAccess [
            "noauto"
            "x-systemd.automount"
            "x-systemd.idle-timeout=900s"
          ];
      };
    };
  };
}
