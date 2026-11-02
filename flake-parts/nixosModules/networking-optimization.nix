{lib, ...}: {
  flake.nixosModules.networking-optimization = {config, ...}: let
    cfg = config.hostSpec.networking.optimization;
    inherit (lib) mkOption types;
    max = toString cfg.bufferMax;
  in {
    options.hostSpec.networking.optimization = {
      enable = lib.mkEnableOption "generic network performance optimizations";

      bufferMax = mkOption {
        type = types.ints.positive;
        default = 16777216;
        example = 67108864;
        description = ''
          Per-socket TCP/UDP buffer ceiling in bytes (net.core.{r,w}mem_max
          and the max field of net.ipv4.tcp_{r,w}mem). Size it to the
          bandwidth-delay product of the host's longest fast path: 1 Gbit/s
          at 160 ms RTT needs about 20 MB. A ceiling, not a preallocation:
          sockets only grow to it under load.
        '';
      };

      wifi.powerSave = mkOption {
        type = types.bool;
        default = false;
        description = "Whether NetworkManager may enable Wi-Fi power saving. Disable it to avoid power-management latency and throughput regressions.";
      };
    };

    config = lib.mkIf cfg.enable {
      boot = {
        kernelModules = ["tcp_bbr"];
        kernel.sysctl = lib.mapAttrs (_: lib.mkDefault) {
          # BBR with packet pacing sustains throughput on lossy and long-RTT
          # paths without CUBIC's loss-driven congestion-window collapse.
          "net.ipv4.tcp_congestion_control" = "bbr";
          "net.core.default_qdisc" = "fq";

          # These are per-socket ceilings, not memory preallocations.
          "net.core.rmem_max" = cfg.bufferMax;
          "net.core.wmem_max" = cfg.bufferMax;
          "net.ipv4.tcp_rmem" = "4096 131072 ${max}";
          "net.ipv4.tcp_wmem" = "4096 65536 ${max}";

          # Keep only ~128 KiB of not-yet-sent data queued per socket, so
          # large send buffers do not add latency (pairs with BBR + fq).
          "net.ipv4.tcp_notsent_lowat" = 131072;

          # TCP Fast Open for outgoing and incoming connections: one RTT
          # saved on repeat connections; falls back cleanly when refused.
          "net.ipv4.tcp_fastopen" = 3;

          "net.core.netdev_max_backlog" = 16384;
          "net.ipv4.tcp_mtu_probing" = 1;
          "net.ipv4.tcp_slow_start_after_idle" = 0;
        };
      };

      # Spread NIC (and other) interrupts across cores instead of letting
      # them pile onto CPU0. A no-op on single-core hosts.
      services.irqbalance.enable = lib.mkDefault true;

      networking.networkmanager.wifi.powersave = lib.mkDefault cfg.wifi.powerSave;
    };
  };
}
