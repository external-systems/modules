{inputs, ...}: {
  # ------ NixOS Modules ------ #
  flake.nixosModules.jovian = {
    config,
    pkgs,
    lib,
    ...
  }: let
    cfg = config.hostSpec.system.jovian;

    pureGamescope =
      (import pkgs.path {
        inherit (pkgs.stdenv.hostPlatform) system;
        config.allowUnfree = true;
      }).gamescope;
  in {
    options.hostSpec.system.jovian = {
      enable = lib.mkEnableOption "default jovian configuration";
      gamingMode = lib.mkEnableOption ''
        Steam Gaming Mode (Jovian's gamescope session, jovian.steam). The
        machine boots straight into it as `user`; Switch to Desktop opens
        `desktopSession`
      '';
      user = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = "alice";
        description = "User that Gaming Mode logs in as. Required when gamingMode is on.";
      };
      desktopSession = lib.mkOption {
        type = lib.types.str;
        default =
          if config.hostSpec.services.kde.enable or false
          then "plasma"
          else "gamescope-wayland";
        defaultText = lib.literalExpression ''if hostSpec.services.kde.enable then "plasma" else "gamescope-wayland"'';
        example = "plasma";
        description = ''
          Session that Gaming Mode's Switch to Desktop opens. Defaults to
          Plasma (Wayland) when the kde module is on; "gamescope-wayland"
          relaunches Gaming Mode instead.
        '';
      };
      steamdeck = lib.mkEnableOption ''
        Steam Deck hardware support (jovian.devices.steamdeck: controls,
        fan, display, firmware)
      '';
      amd = lib.mkOption {
        type = lib.types.bool;
        default = config.hostSpec.hardware.gpu.amd.enable or false;
        description = "has amd";
        example = true;
      };
    };

    imports = [
      inputs.jovian.nixosModules.default
    ];

    config = lib.mkIf cfg.enable {
      assertions = [
        {
          assertion = cfg.gamingMode -> cfg.user != null;
          message = "hostSpec.system.jovian.gamingMode needs hostSpec.system.jovian.user: the user Gaming Mode logs in as.";
        }
      ];

      # Valve vendor kernel by default for every jovian machine. mkDefault so
      # a host whose GPU Valve does not test on (NVIDIA) can pick its own.
      # On a Steam Deck, jovian.devices.steamdeck sets the same kernel at
      # the same priority, which the unique option would reject.
      boot.kernelPackages = lib.mkIf (!cfg.steamdeck) (lib.mkDefault pkgs.linuxPackages_jovian);

      boot = {
        # Wine/Proton's sync driver (/dev/ntsync, mode 0666 upstream): Proton
        # 10 and GE use it when present; cuts CPU overhead in Windows games.
        kernelModules = ["ntsync"];
        kernel.sysctl."vm.swappiness" = lib.mkDefault 180; # zram, not disk
      };

      # Start desktop gaming PCs on the Performance power profile (Plasma's
      # slider is power-profiles-daemon). The daemon only remembers the last
      # choice, so set it at every boot. Not on the Deck: battery.
      systemd.services.power-profile-performance = lib.mkIf (!cfg.steamdeck && config.services.power-profiles-daemon.enable) {
        description = "Set the Performance power profile";
        after = ["power-profiles-daemon.service"];
        requires = ["power-profiles-daemon.service"];
        wantedBy = ["multi-user.target"];
        serviceConfig = {
          Type = "oneshot";
          ExecStart = "${lib.getExe' config.services.power-profiles-daemon.package "powerprofilesctl"} set performance";
        };
      };

      # Compressed RAM swap: big modpacks or a browser beside a game stop
      # paging to disk.
      zramSwap.enable = true;

      # sched_ext scheduler tuned for interactive and gaming latency. The
      # Valve kernel and nixpkgs kernels both build SCHED_CLASS_EXT.
      services.scx = {
        enable = true;
        scheduler = "scx_lavd";
      };

      jovian = {
        hardware.has.amd.gpu = cfg.amd;
        # Plugin loader for Gaming Mode's Quick Access Menu. Deck only: its
        # useful plugins (TDP, fan, battery) target handheld hardware, and it
        # opens Steam's CEF debugger, so PCs stay without it.
        decky-loader.enable = cfg.steamdeck && cfg.gamingMode;
        devices.steamdeck.enable = cfg.steamdeck;
        # autoStart reuses SDDM (autologin, gamescope-wayland as default
        # session), so it composes with the kde module. Without a user the
        # assertion above reports it instead of a type error.
        steam = lib.mkIf (cfg.gamingMode && cfg.user != null) {
          enable = true;
          autoStart = true;
          inherit (cfg) user desktopSession;
        };
      };
      services.orca.enable = false; # Disable screen reader
      networking.networkmanager.enable = lib.mkForce true; # Steam UI needs networkmanager

      hardware = {
        graphics.enable32Bit = true;
        xone.enable = true;
      };
      environment.systemPackages = with pkgs; [
        steam-rom-manager # App for adding 3rd party games/ROMs as Steam launch items
        steam-run
        (pkgs.heroic.override {
          extraPkgs = p:
            with p; [
              pureGamescope
              gamemode
              mangohud
              winetricks
              cabextract
            ];
        })
      ];

      # Steam
      #
      # Set game launcher: gamemoderun %command%
      #   Set this for each game in Steam, if the game could benefit from a minor
      #   performance tweak: YOUR_GAME > Properties > General > Launch > Options
      #   It's a modest tweak that may not be needed. Jovian is optimized for
      #   high performance by default.
      programs = {
        steam = {
          enable = true;
          # Steam Input sends X11 events; extest turns them into uinput so
          # a controller's desktop layout (stick/touchpad as mouse, buttons
          # as keys) also drives native Wayland (Plasma) windows.
          extest.enable = true;
          # Winetricks for Proton prefixes (fonts, runtimes, EA app fixes).
          protontricks.enable = true;
          remotePlay.openFirewall = true;
          dedicatedServer.openFirewall = true;
          localNetworkGameTransfers.openFirewall = true;
          extraCompatPackages = with pkgs; [
            proton-ge-bin
          ];
        };
        gamescope = {
          enable = true;
          package = pureGamescope;
        };
        gamemode = {
          enable = true;
          settings = lib.optionalAttrs cfg.amd {
            general.renice = 10;
            gpu = {
              apply_gpu_optimisations = "accept-responsibility"; # For systems with AMD GPUs
              gpu_device = 0;
              amd_performance_level = "high";
            };
          };
        };
        appimage = {
          enable = true;
          binfmt = true;
        };
      };
    };
  };
}
