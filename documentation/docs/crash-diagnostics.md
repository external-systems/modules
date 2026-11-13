# Crash diagnostics

`hostSpec.system.crashDiagnostics` makes a machine that crashes, resets
or is killed without a shutdown leave enough evidence to say why. It
was written after a desktop reset itself with a journal that just
stopped: no shutdown, no panic, nothing in pstore, only the AMD
firmware's `software wrote 0x6 to reset control register 0xCF9` at the
next boot.

```nix
hostSpec.system.crashDiagnostics.enable = true;
```

## What it changes

| Setting | Default | Effect |
|---|---|---|
| `dmesgOnReboot` | `true` | `printk.always_kmsg_dump=1`: the kernel log tail goes to pstore (EFI variables) on every reboot and power-off the kernel performs, not only on a panic. systemd-pstore moves it to `/var/lib/systemd/pstore` at the next boot. |
| `panicOnHang` | `true` | `nmi_watchdog=panic softlockup_panic=1`: a hung kernel panics, so its log reaches pstore. |
| `panicRebootSeconds` | `10` | `kernel.panic`: a panic reboots after 10 s instead of freezing. |
| `panicOnOops` | `false` | `kernel.panic_on_oops`. |
| `watchdogTimeout` | `"60s"` | systemd feeds the hardware watchdog; if it stops for this long, the watchdog resets the machine (AMD firmware then reports a watchdog reset). `null` leaves the watchdog alone. |
| `journalSyncInterval` | `"10s"` | journald `SyncIntervalSec` (5 min by default): less of the journal is lost in a hard reset. |
| `sampler.enable`, `sampler.interval` | `true`, `"30s"` | `crash-sampler` writes load, pressure (PSI), free memory, swap, the hottest sensor and the biggest process to the journal. |
| `keepReports` | `50` | Boot reports kept in `/var/log/crash-diagnostics`. |

All kernel and journald values are `mkDefault`, so a machine can still
set them itself.

## Reading the evidence

At every boot `crash-diagnostics-report.service` writes how the previous
boot ended to `/var/log/crash-diagnostics/<time>-<boot id>.txt` and logs
one line (a warning if it ended uncleanly):

```console
$ journalctl -b -t crash-report
previous boot ended uncleanly; report: /var/log/crash-diagnostics/...; reset    x86/amd: Previous system reset reason [0x00080800]: ...
$ crash-report          # the previous boot, on demand
$ crash-report -3       # any boot still in the journal
$ crash-report --list   # saved reports
```

A report has the boot's times and the gap to the next boot, a verdict
(clean if logind or systemd logged a requested shutdown), the firmware's
reset reason (AMD CPUs only), kernel messages counted by class (panic,
lockup, hardware, OOM, thermal, GPU, storage, filesystem, ACPI,
watchdog), the last samples, the last journal lines, and the pstore
tail.

## Reading a verdict

- **Clean, nothing else:** someone or something asked for the shutdown;
  the journal line before it says who. On AMD the reset reason of a
  normal power-off reads `ACPI power state transition occurred`.
- **Unclean, pstore has a panic:** a kernel crash; the trace is there.
- **Unclean, pstore ends in `reboot: Restarting system`:** the kernel
  rebooted on purpose without systemd (`reboot -ff`, a kernel restart
  path); the lines before it show what ran last.
- **Unclean, a watchdog reset reason:** userspace or the kernel hung for
  longer than `watchdogTimeout`.
- **Unclean, nothing in pstore, no watchdog:** the kernel never got to
  write anything: firmware, power or a hardware fault. Check the last
  samples for temperature and load.

## Not included

kdump (`boot.crashDump`) boots a second kernel that waits in a rescue
shell, which an unattended desktop cannot use.
