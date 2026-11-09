# hostSpec.system.btrfsDedup: bees merges identical data on a btrfs
# filesystem in the background, at idle priority. Two users each write
# the same 64 MiB file (no reflink); bees ends up storing it once.
_: {
  nodes.machine = {pkgs, ...}: {
    virtualisation = {
      emptyDiskImages = [1024];
      fileSystems."/mnt/dedup" = {
        device = "/dev/vdb";
        fsType = "btrfs";
        autoFormat = true;
      };
      memorySize = 2048;
      cores = 2;
    };
    hostSpec.system.btrfsDedup = {
      enable = true;
      filesystems.dedup = {
        spec = "/mnt/dedup";
        hashTableSizeMB = 64;
      };
    };
    users.users = {
      alice.isNormalUser = true;
      bob.isNormalUser = true;
    };
    environment.systemPackages = [pkgs.btrfs-progs];
  };

  testScript = ''
    machine.wait_for_unit("multi-user.target")
    machine.wait_for_unit("beesd@dedup.service", timeout=120)

    with subtest("bees runs at idle priority"):
        def prop(name):
            return machine.succeed(f"systemctl show -P {name} beesd@dedup.service").strip()

        # 5 is SCHED_IDLE, 3 the idle I/O class.
        props = [prop("Nice"), prop("CPUSchedulingPolicy"), prop("IOSchedulingClass")]
        assert props == ["19", "5", "3"], props

    with subtest("two users' copies of one file end up stored once"):
        machine.succeed("install -d -m 0777 /mnt/dedup/alice /mnt/dedup/bob")
        machine.succeed("head -c 64M /dev/urandom > /tmp/game.bin")
        machine.succeed("su alice -c 'cp --reflink=never /tmp/game.bin /mnt/dedup/alice/game.bin'")
        machine.succeed("su bob -c 'cp --reflink=never /tmp/game.bin /mnt/dedup/bob/game.bin'")
        machine.succeed("sync")

        # btrfs filesystem du: Total, Exclusive, Set shared, Filename.
        shared = "btrfs filesystem du -s --raw /mnt/dedup/alice/game.bin | awk 'NR == 2 { print $3 }'"
        assert int(machine.succeed(shared)) == 0, machine.succeed(shared)
        machine.wait_until_succeeds(f"test $({shared}) -gt 33554432", timeout=600)
        # The files are unchanged and still each user's own.
        machine.succeed("cmp /mnt/dedup/alice/game.bin /mnt/dedup/bob/game.bin")
        assert machine.succeed("stat -c %U /mnt/dedup/bob/game.bin").strip() == "bob"
  '';
}
