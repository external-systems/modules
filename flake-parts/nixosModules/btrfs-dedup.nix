# Block-level deduplication of btrfs filesystems with bees
# (services.beesd): identical data, such as the same game installed by
# two users or two copies of a shader cache, is stored once whoever owns
# the files. Programs see ordinary files; nothing about ownership or
# permissions changes.
#
# bees runs all the time in the background and keeps a hash table in
# locked memory (hashTableSizeMB). It works at idle CPU and I/O priority
# and backs off while the load average is high. The idle I/O class only
# works with the BFQ scheduler (NVMe disks default to "none"), so
# gaming.nix also freezes bees while a game runs. bees reads the whole
# filesystem through the page cache: memoryHighMB makes it give back its
# own cache instead of pushing other programs into swap.
#
# Deduplicated data is stored once, so one bad block now hits every
# copy: a monthly scrub (services.btrfs.autoScrub, every btrfs
# filesystem) finds it while the data can still be downloaded again.
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
            memoryHighMB = lib.mkOption {
              type = lib.types.ints.positive;
              default = 3072;
              example = 4096;
              description = ''
                Memory, page cache included, above which bees is made to
                reclaim its own (systemd MemoryHigh): it reads the whole
                filesystem, and without a ceiling its cache pushes games
                and the desktop into swap. Leave room for the hash table
                (hashTableSizeMB) and about 1 GB more.
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
      assertions =
        [
          {
            assertion = cfg.filesystems != {};
            message = "hostSpec.system.btrfsDedup: no filesystems to deduplicate.";
          }
        ]
        ++ lib.mapAttrsToList (name: fs: {
          assertion = fs.memoryHighMB >= fs.hashTableSizeMB + 512;
          message = "hostSpec.system.btrfsDedup.filesystems.${name}: memoryHighMB must leave room for the hash table (hashTableSizeMB + 512 at least).";
        })
        cfg.filesystems;

      # Only with a btrfs filesystem in fileSystems: autoScrub scrubs
      # those (each device once) and asserts there is one.
      services.btrfs.autoScrub.enable = lib.mkDefault (lib.any (fs: fs.fsType == "btrfs") (lib.attrValues config.fileSystems));

      services.beesd.filesystems =
        lib.mapAttrs (_: fs: {
          inherit (fs) spec hashTableSizeMB;
          verbosity = "warning";
          extraOptions = ["--loadavg-target" (toString fs.loadAverageTarget)];
        })
        cfg.filesystems;

      systemd.services = lib.mapAttrs' (name: fs:
        lib.nameValuePair "beesd@${name}" {
          serviceConfig = {
            Nice = 19;
            CPUSchedulingPolicy = "idle";
            IOSchedulingClass = "idle";
            MemoryHigh = "${toString fs.memoryHighMB}M";
          };
        })
      cfg.filesystems;
    };
  };
}
