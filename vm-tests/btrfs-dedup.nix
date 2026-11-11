# hostSpec.system.btrfsDedup: bees merges identical data on a btrfs
# filesystem in the background, at idle priority, with a memory
# ceiling. Two users each write the same 64 MiB file (no reflink); bees
# ends up storing it once. With hostSpec.system.gaming.dedup, bees is
# frozen while a Steam game (its `reaper SteamLaunch` process) runs.
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
      filesystems.root = {
        spec = "/mnt/dedup";
        hashTableSizeMB = 64;
      };
    };
    hostSpec.system.gaming.dedup.enable = true;
    users.users = {
      alice.isNormalUser = true;
      bob.isNormalUser = true;
    };
    environment.systemPackages = [pkgs.btrfs-progs];
  };

  testScript = ''
    machine.wait_for_unit("multi-user.target")
    machine.wait_for_unit("beesd@root.service", timeout=120)

    with subtest("bees runs at idle priority"):
        def prop(name):
            return machine.succeed(f"systemctl show -P {name} beesd@root.service").strip()

        # 5 is SCHED_IDLE, 3 the idle I/O class.
        props = [prop("Nice"), prop("CPUSchedulingPolicy"), prop("IOSchedulingClass")]
        assert props == ["19", "5", "3"], props
        assert prop("MemoryHigh") == str(3072 * 1024 * 1024), prop("MemoryHigh")

    with subtest("the filesystem is scrubbed monthly"):
        machine.succeed("systemctl is-enabled btrfs-scrub@mnt-dedup.timer")

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

    with subtest("bees is frozen while a Steam game runs"):
        def freezer():
            return machine.succeed("systemctl show -P FreezerState beesd@root.service").strip()

        machine.wait_for_unit("bees-pause-while-playing.service")
        assert freezer() == "running", freezer()
        # Steam starts every game under `reaper SteamLaunch AppId=<id>`.
        machine.succeed("systemd-run --uid=alice --unit=fake-game bash -c '/run/current-system/sw/bin/sleep 600; :' reaper SteamLaunch AppId=100")
        machine.wait_until_succeeds("test $(systemctl show -P FreezerState beesd@root.service) = frozen", timeout=60)
        machine.succeed("systemctl stop fake-game")
        machine.wait_until_succeeds("test $(systemctl show -P FreezerState beesd@root.service) = running", timeout=60)

    with subtest("stopping the pause service never leaves bees frozen"):
        machine.succeed("systemd-run --uid=alice --unit=fake-game bash -c '/run/current-system/sw/bin/sleep 600; :' reaper SteamLaunch AppId=100")
        machine.wait_until_succeeds("test $(systemctl show -P FreezerState beesd@root.service) = frozen", timeout=60)
        machine.succeed("systemctl stop bees-pause-while-playing.service")
        assert freezer() == "running", freezer()
        machine.succeed("systemctl stop fake-game")
  '';
}
