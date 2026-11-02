{
  # inputs,
  # self,
  lib,
  ...
}: {
  # ------ NixOS Modules ------ #
  flake.nixosModules.tailscale = {
    pkgs,
    config,
    ...
  }: let
    cfg = config.hostSpec.networking.tailscale;
    tailscaleGro = ''
      NETDEV=$(${pkgs.iproute2}/bin/ip -o route get 8.8.8.8 | cut -f 5 -d " ")
      ${pkgs.ethtool}/bin/ethtool -K "$NETDEV" rx-udp-gro-forwarding on rx-gro-list off
    '';
  in {
    options.hostSpec.networking.tailscale = {
      enable = lib.mkEnableOption "default tailscale configuration";
      systray = lib.mkEnableOption "systray";
    };

    config = lib.mkIf cfg.enable {
      services.tailscale = {
        inherit (cfg) enable;
        openFirewall = true;
      };
      networking = {
        networkmanager.unmanaged = ["tailscale0"];
        firewall = {
          trustedInterfaces = ["tailscale0"];
          checkReversePath = "loose";
        };
      };
      # UDP GRO forwarding on the default-route interface (Tailscale's
      # exit-node/subnet-router throughput tuning), re-applied when a link
      # comes up. Runs from whichever network manager the machine uses:
      # networkd-dispatcher only fires under systemd-networkd, so
      # NetworkManager machines get an NM dispatcher script instead.
      networking.networkmanager.dispatcherScripts = lib.mkIf config.networking.networkmanager.enable [
        {
          type = "basic";
          source = pkgs.writeShellScript "50-tailscale-gro" ''
            [ "$2" = up ] || exit 0
            ${tailscaleGro}
          '';
        }
      ];
      services.networkd-dispatcher = lib.mkIf (config.networking.useNetworkd || config.systemd.network.enable) {
        enable = true;
        rules."50-tailscale" = {
          onState = ["routable"];
          script = ''
            #!${pkgs.runtimeShell}
            ${tailscaleGro}
          '';
        };
      };

      systemd.services.tailscaled-autoconnect = {
        serviceConfig = {
          Restart = "on-failure";
          RestartSec = "5s";
          StartLimitIntervalSec = 0;
        };
        unitConfig = {
          StartLimitIntervalSec = 0; # Unlimited retries
        };
      };

      systemd.user.services.tailscale-systray = lib.mkIf cfg.systray {
        enable = true;
        description = "Tailscale Systray GUI";
        after = [
          "graphical-session.target"
          "tailscaled.service"
        ];
        wants = ["tailscaled.service"];
        wantedBy = ["graphical-session.target"];
        serviceConfig = {
          Type = "simple";
          Restart = "on-failure";
          RestartSec = "5s";
          ExecStart = "${lib.getExe' config.services.tailscale.package "tailscale"} systray";
        };
      };
    };
  };
}
