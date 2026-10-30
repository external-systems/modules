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
      steamui = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Whether to enable steam big picture mode";
        example = true;
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
      # Valve vendor kernel for every jovian machine; steam is assumed with
      # jovian, so this is the only kernelPackages definition in the tree.
      boot.kernelPackages = pkgs.linuxPackages_jovian;

      jovian = {
        hardware.has.amd.gpu = cfg.amd;
        steam.enable = cfg.steamui;
      };
      services.orca.enable = false; # Disable screen reader
      networking.networkmanager.enable = lib.mkForce true; # Steam UI needs networkmanager

      hardware = {
        graphics.enable32Bit = true;
        xone.enable = true;
      };
      environment.systemPackages = with pkgs; [
        cmake # Cross-platform, open-source build system generator
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
