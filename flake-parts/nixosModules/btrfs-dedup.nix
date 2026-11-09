# Block-level deduplication of btrfs filesystems with bees
# (services.beesd): identical data, such as the same game installed by
# two users or two copies of a shader cache, is stored once whoever owns
# the files. Programs see ordinary files; nothing about ownership or
# permissions changes.
#
# bees runs all the time in the background and keeps a hash table in
# locked memory (hashTableSizeMB). It works at idle CPU and I/O priority
# and backs off while the machine is busy (a game running), so it never
# competes with the desktop.
{
  flake.nixosModules.btrfs-dedup = {
    config,
    lib,
    ...
  }: let
    cfg = config.hostSpec.system.btrfsDedup;
  in {
    options.hostSpec.system.btrfsDedup = {
      enable = lib.mkEnableOption ''
        block-level deduplication of btrfs filesystems with bees; see this
        file's header
      '';
      filesystems = lib.mkOption {
        type = lib.types.attrsOf (lib.types.submodule {
          options = {
            spec = lib.mkOption {
              type = lib.types.str;
              example = "LABEL=root";
              description = ''
                The btrfs filesystem: LABEL=, UUID= or a mounted path. bees
                works on the whole filesystem, every subvolume included.
              '';
            };
            hashTableSizeMB = lib.mkOption {
              type = lib.types.addCheck lib.types.int (n: lib.mod n 16 == 0);
              default = 512;
              example = 1024;
              description = ''
                Memory for bees' hash table, a multiple of 16. About 512 MB
                suits a 1 TB disk of mostly games; more finds more duplicates
                on a bigger disk.
              '';
            };
            loadAverageTarget = lib.mkOption {
              type = lib.types.ints.positive;
              default = 4;
              example = 8;
              description = ''
                bees pauses work while the load average is above this
                (--loadavg-target), so a running game keeps the CPU.
              '';
            };
          };
        });
        default = {};
        example = lib.literalExpression ''
          {
            root.spec = "LABEL=root";
          }
        '';
        description = "btrfs filesystems to deduplicate, by name (beesd@<name>.service).";
      };
    };

    config = lib.mkIf cfg.enable {
      assertions = [
        {
          assertion = cfg.filesystems != {};
          message = "hostSpec.system.btrfsDedup: no filesystems to deduplicate.";
        }
      ];

      services.beesd.filesystems =
        lib.mapAttrs (_: fs: {
          inherit (fs) spec hashTableSizeMB;
          verbosity = "warning";
          extraOptions = ["--loadavg-target" (toString fs.loadAverageTarget)];
        })
        cfg.filesystems;

      systemd.services = lib.mapAttrs' (name: _:
        lib.nameValuePair "beesd@${name}" {
          serviceConfig = {
            Nice = 19;
            CPUSchedulingPolicy = "idle";
            IOSchedulingClass = "idle";
          };
        })
      cfg.filesystems;
    };
  };
}
