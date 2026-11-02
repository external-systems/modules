{lib, ...}: {
  flake.nixosModules.networking-optimization = {config, ...}: let
    cfg = config.hostSpec.networking.optimization;
    inherit (lib) mkOption types;
  in {
    options.hostSpec.networking.optimization = {
      enabled = lib.mkEnableOption "generic network performance optimizations";

      wifi.powerSave = mkOption {
        type = types.bool;
        default = false;
        description = "Whether NetworkManager may enable Wi-Fi power saving. Disable it to avoid power-management latency and throughput regressions.";
      };
    };

    config = lib.mkIf cfg.enabled {
      boot = {
        kernelModules = ["tcp_bbr"];
        kernel.sysctl = lib.mapAttrs (_: lib.mkDefault) {
          # BBR with packet pacing sustains throughput on lossy and long-RTT
          # paths without CUBIC's loss-driven congestion-window collapse.
          "net.ipv4.tcp_congestion_control" = "bbr";
          "net.core.default_qdisc" = "fq";

          # These are per-socket ceilings, not memory preallocations.
          "net.core.rmem_max" = 16777216;
          "net.core.wmem_max" = 16777216;
          "net.ipv4.tcp_rmem" = "4096 131072 16777216";
          "net.ipv4.tcp_wmem" = "4096 65536 16777216";

          "net.core.netdev_max_backlog" = 16384;
          "net.ipv4.tcp_mtu_probing" = 1;
          "net.ipv4.tcp_slow_start_after_idle" = 0;
        };
      };

      networking.networkmanager.wifi.powersave = lib.mkDefault cfg.wifi.powerSave;
    };
  };
}
