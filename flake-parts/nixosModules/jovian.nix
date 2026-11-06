{inputs, ...}: {
  # ------ NixOS Modules ------ #
  flake.nixosModules.jovian = {
    config,
    pkgs,
    lib,
    ...
  }: let
    cfg = config.hostSpec.system.jovian;
    # Gaming Mode is on exactly when it has a user to log in as.
    gamingMode = cfg.user != null;

    pureGamescope =
      (import pkgs.path {
        inherit (pkgs.stdenv.hostPlatform) system;
        config.allowUnfree = true;
      }).gamescope;
  in {
    options.hostSpec.system.jovian = {
      enable = lib.mkEnableOption "default jovian configuration";
      user = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = "alice";
        description = ''
          Steam Gaming Mode (Jovian's gamescope session, jovian.steam): the
          machine boots straight into it, logged in as this user, and Switch
          to Desktop opens `desktopSession`. null boots to the normal login
          screen (SDDM) instead. The user must exist on the machine.
        '';
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
      powerProfile = {
        enable = lib.mkOption {
          type = lib.types.bool;
          default = true;
          example = false;
          description = ''
            Whether to set `profile` at every boot through power-profiles-daemon
            (Plasma's Power Profile slider). Off leaves the daemon's last
            choice in place. The slider still changes it until the next boot.
          '';
        };
        profile = lib.mkOption {
          type = lib.types.enum ["power-saver" "balanced" "performance"];
          default =
            if cfg.steamdeck
            then "balanced"
            else "performance";
          defaultText = lib.literalExpression ''if steamdeck then "balanced" else "performance"'';
          example = "power-saver";
          description = ''
            Power profile set at boot: "power-saver" (Power Save), "balanced"
            (Balanced) or "performance" (Performance). Defaults to balanced on
            a Steam Deck for battery life; set "performance" on a docked Deck.
          '';
        };
      };
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
          assertion = gamingMode -> (config.users.users.${cfg.user}.isNormalUser or false);
          message = "hostSpec.system.jovian.user: Gaming Mode logs in as \"${toString cfg.user}\", which is not a normal user on this machine.";
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

      # Plasma's power slider is power-profiles-daemon, which only remembers
      # the last choice; set the chosen profile at every boot.
      systemd.services.power-profile = lib.mkIf (cfg.powerProfile.enable && config.services.power-profiles-daemon.enable) {
        description = "Set the ${cfg.powerProfile.profile} power profile";
        after = ["power-profiles-daemon.service"];
        requires = ["power-profiles-daemon.service"];
        wantedBy = ["multi-user.target"];
        serviceConfig = {
          Type = "oneshot";
          ExecStart = "${lib.getExe' config.services.power-profiles-daemon.package "powerprofilesctl"} set ${cfg.powerProfile.profile}";
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
        decky-loader.enable = cfg.steamdeck && gamingMode;
        devices.steamdeck.enable = cfg.steamdeck;
        # autoStart reuses SDDM (autologin, gamescope-wayland as default
        # session), so it composes with the kde module.
        steam = lib.mkIf gamingMode {
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
