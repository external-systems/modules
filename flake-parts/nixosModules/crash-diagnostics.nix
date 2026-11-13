# Evidence for unexpected crashes, resets and machine kills. A desktop
# that resets on its own usually leaves a journal that just stops: no
# shutdown, no panic, nothing in pstore. This module makes the next one
# explain itself:
#
# - The kernel log tail goes to pstore (EFI variables) on every panic
#   and, with dmesgOnReboot, on every reboot the kernel performs, so a
#   reset that never reached the journal still leaves its last kernel
#   lines. systemd-pstore moves them to /var/lib/systemd/pstore at the
#   next boot.
# - A hung kernel panics instead of freezing (panicOnHang), and a panic
#   reboots after panicRebootSeconds, so the hang reaches pstore and the
#   machine comes back.
# - systemd feeds the hardware watchdog (watchdogTimeout): a machine
#   whose userspace stops is reset by it, and AMD firmware reports that
#   as a watchdog reset at the next boot.
# - journald syncs every journalSyncInterval instead of every 5 minutes,
#   so the minutes before a hard reset are on disk.
# - crash-sampler writes one line of load, pressure, memory and
#   temperature to the journal every sampler.interval.
# - At every boot, crash-report writes how the previous boot ended to
#   /var/log/crash-diagnostics: clean or not, the firmware's reset
#   reason, kernel errors by class, the last samples and log lines and
#   the pstore tail. `crash-report [OFFSET]` reads any earlier boot.
#
# Not used: boot.crashDump (kdump) boots a second kernel that waits in a
# rescue shell, which is wrong for an unattended desktop.
{
  flake.nixosModules.crash-diagnostics = {
    config,
    lib,
    pkgs,
    ...
  }: let
    cfg = config.hostSpec.system.crashDiagnostics;
    reportDir = "/var/log/crash-diagnostics";

    crashApp = name: main:
      pkgs.writeShellApplication {
        inherit name;
        runtimeInputs = with pkgs; [coreutils findutils gawk gnugrep jq procps systemd];
        text = builtins.readFile ./_crash-diagnostics.sh + "\n${main}\n";
      };

    crashReport = crashApp "crash-report" ''
      case "''${1:--1}" in
        -h | --help) usage ;;
        --list) ls -1t ${reportDir} 2>/dev/null || true ;;
        --boot) boot_report ${reportDir} ${toString cfg.keepReports} ;;
        -[0-9]* | 0) report "''${1:--1}" ;;
        *) usage >&2; exit 2 ;;
      esac
    '';
    crashSampler = crashApp "crash-sampler" "sample";
  in {
    options.hostSpec.system.crashDiagnostics = {
      enable = lib.mkEnableOption ''
        evidence for unexpected crashes and resets (pstore, panic on hang,
        hardware watchdog, a boot report of how the previous boot ended);
        see this file's header
      '';
      panicRebootSeconds = lib.mkOption {
        type = lib.types.ints.unsigned;
        default = 10;
        description = ''
          Seconds a panicked kernel waits before rebooting (kernel.panic).
          0 leaves it frozen on screen, as the kernel default does.
        '';
      };
      panicOnHang = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Panic on a hard lockup (NMI watchdog) or soft lockup, so a hung
          kernel writes its log to pstore and reboots instead of freezing
          with nothing on disk.
        '';
      };
      panicOnOops = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Panic on any kernel oops (kernel.panic_on_oops). Off by default:
          after most oopses the machine keeps running and the journal
          already has the trace.
        '';
      };
      dmesgOnReboot = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Save the kernel log tail to pstore on every reboot and power-off
          the kernel performs, not just on panics
          (printk.always_kmsg_dump). This is what explains a reboot that
          no log saw. Each one writes a few EFI variables, which
          systemd-pstore deletes again at the next boot.
        '';
      };
      watchdogTimeout = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = "60s";
        example = "2min";
        description = ''
          Hardware watchdog timeout systemd keeps fed
          (systemd.watchdog.runtimeTime). If systemd stops responding for
          this long, the watchdog resets the machine. null leaves the
          watchdog alone.
        '';
      };
      journalSyncInterval = lib.mkOption {
        type = lib.types.str;
        default = "10s";
        description = ''
          How often journald syncs the journal to disk (SyncIntervalSec,
          5min by default). Lines not synced are lost in a hard reset.
        '';
      };
      sampler = {
        enable =
          lib.mkEnableOption "a periodic health line in the journal (crash-sampler)"
          // {default = true;};
        interval = lib.mkOption {
          type = lib.types.str;
          default = "30s";
          description = "How often crash-sampler writes a line.";
        };
      };
      keepReports = lib.mkOption {
        type = lib.types.ints.positive;
        default = 50;
        description = "Boot reports to keep in ${reportDir}.";
      };
    };

    config = lib.mkIf cfg.enable {
      environment.systemPackages = [crashReport];

      boot = {
        kernelParams =
          lib.optional cfg.dmesgOnReboot "printk.always_kmsg_dump=1"
          ++ lib.optionals cfg.panicOnHang ["nmi_watchdog=panic" "softlockup_panic=1"];
        kernel.sysctl = {
          "kernel.panic" = lib.mkDefault cfg.panicRebootSeconds;
          "kernel.panic_on_oops" = lib.mkDefault (
            if cfg.panicOnOops
            then 1
            else 0
          );
        };
      };

      services.journald.settings.Journal.SyncIntervalSec = lib.mkDefault cfg.journalSyncInterval;

      systemd = {
        watchdog.runtimeTime = lib.mkIf (cfg.watchdogTimeout != null) (lib.mkDefault cfg.watchdogTimeout);

        services = {
          crash-diagnostics-report = {
            description = "Report how the previous boot ended";
            wantedBy = ["multi-user.target"];
            after = ["systemd-journal-flush.service" "systemd-pstore.service"];
            wants = ["systemd-pstore.service"];
            serviceConfig = {
              Type = "oneshot";
              # Stays active, so `systemctl status` shows it ran this boot.
              RemainAfterExit = true;
              ExecStart = "${lib.getExe crashReport} --boot";
              SyslogIdentifier = "crash-report";
            };
          };

          crash-sampler = lib.mkIf cfg.sampler.enable {
            description = "Write one line of machine health to the journal";
            serviceConfig = {
              Type = "oneshot";
              ExecStart = lib.getExe crashSampler;
              SyslogIdentifier = "crash-sampler";
              Nice = 19;
              IOSchedulingClass = "idle";
            };
          };
        };

        timers.crash-sampler = lib.mkIf cfg.sampler.enable {
          wantedBy = ["timers.target"];
          timerConfig = {
            OnBootSec = cfg.sampler.interval;
            OnUnitActiveSec = cfg.sampler.interval;
            AccuracySec = "1s";
          };
        };
      };
    };
  };
}
