# hostSpec.system.crashDiagnostics: the kernel, journald and the
# watchdog are set up to leave evidence, crash-sampler writes health
# lines, and crash-report tells a clean shutdown from a crash at the next
# boot. The crash is a hard VM reset (machine.crash()), the closest to a
# machine killed without a shutdown.
_: {
  nodes.machine = {
    virtualisation.qemu.options = ["-device" "i6300esb"];
    hostSpec.system.crashDiagnostics = {
      enable = true;
      sampler.interval = "5s";
    };
  };

  testScript = ''
    machine.wait_for_unit("multi-user.target")

    with subtest("kernel, journald and watchdog settings"):
        cmdline = machine.succeed("cat /proc/cmdline")
        for param in ["printk.always_kmsg_dump=1", "nmi_watchdog=panic", "softlockup_panic=1"]:
            assert param in cmdline, cmdline
        assert machine.succeed("sysctl -n kernel.panic").strip() == "10"
        assert machine.succeed("sysctl -n kernel.panic_on_oops").strip() == "0"
        machine.succeed("grep -qx 'SyncIntervalSec=10s' /etc/systemd/journald.conf")
        assert machine.succeed("systemctl show -P RuntimeWatchdogUSec").strip() == "1min"

    with subtest("first boot: nothing to report"):
        machine.wait_for_unit("crash-diagnostics-report.service")
        machine.succeed("test -z \"$(ls -A /var/log/crash-diagnostics 2>/dev/null)\"")

    with subtest("crash-sampler writes health lines"):
        machine.wait_until_succeeds("journalctl -t crash-sampler -o cat | grep -q '^load=.*mem_avail=.*temp_max='", timeout=60)

    with subtest("a clean shutdown is reported clean"):
        machine.shutdown()
        machine.start()
        machine.wait_for_unit("crash-diagnostics-report.service")
        report = machine.succeed("cat /var/log/crash-diagnostics/*.txt")
        assert "verdict   clean" in report, report
        machine.succeed("journalctl -b -t crash-report -o cat | grep -q 'ended cleanly'")

    with subtest("a hard reset is reported unclean"):
        machine.wait_until_succeeds("journalctl -b -t crash-sampler -o cat | grep -q '^load='", timeout=60)
        # Only what reached the disk survives a reset; sync, as the
        # interval would within 10 seconds.
        machine.succeed("journalctl --sync")
        machine.crash()
        machine.start()
        machine.wait_for_unit("crash-diagnostics-report.service")
        machine.succeed("journalctl -b -t crash-report -o cat | grep -q 'ended uncleanly'")
        latest = machine.succeed("ls -1t /var/log/crash-diagnostics | head -n 1").strip()
        report = machine.succeed(f"cat /var/log/crash-diagnostics/{latest}")
        assert "verdict   UNCLEAN" in report, report
        assert "crash-sampler" in report, report
        # crash-report reads any boot on demand.
        assert "verdict   UNCLEAN" in machine.succeed("crash-report -1")
        assert "verdict   clean" in machine.succeed("crash-report -2")
        assert machine.succeed("crash-report --list").count(".txt") == 2
  '';
}
