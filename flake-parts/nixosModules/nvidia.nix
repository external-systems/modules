_: {
  # ------ NixOS Modules ------ #
  # The proprietary NVIDIA driver, set up from the machine's nixos-facter
  # report: on when the report has an NVIDIA card, with the kernel module
  # and driver branch that card's generation needs. What else depends on
  # the machine stays there: a kernel pin, CUDA capabilities.
  flake.nixosModules.nvidia = {
    config,
    pkgs,
    lib,
    ...
  }: let
    cfg = config.hostSpec.hardware.gpu.nvidia;

    # PCI device ids of the NVIDIA (0x10de) cards in the report. The
    # oldest card decides, so every card in the machine is supported.
    devices = map (card: card.device.value or 0) (lib.filter (card: (card.vendor.value or null) == 4318) (config.hardware.facter.report.hardware.graphics_card or []));
    detected = devices != [];
    oldest = lib.foldl' lib.min (lib.head devices) devices;

    # Device ids by generation: Turing starts at 0x1e00 (the open kernel
    # module needs Turing or newer); Maxwell, Pascal and Volta (0x1340 up
    # to 0x1e00) stop at the 580 branch; Kepler and older at 470.
    turingOrNewer = oldest >= 7680; # 0x1e00
    maxwellOrNewer = oldest >= 4928; # 0x1340
  in {
    options.hostSpec.hardware.gpu.nvidia = {
      enable =
        lib.mkEnableOption "the proprietary NVIDIA driver (X11 and Wayland)"
        // {
          default = detected;
          defaultText = lib.literalMD "an NVIDIA graphics card in `hardware.facter.report`";
        };
      open = lib.mkOption {
        type = lib.types.bool;
        default = !detected || turingOrNewer;
        defaultText = lib.literalMD "true for Turing (RTX 20, GTX 16) and newer in `hardware.facter.report`, false for older cards";
        description = "Use NVIDIA's open kernel module (hardware.nvidia.open). It needs Turing or newer.";
      };
      branch = lib.mkOption {
        type = lib.types.str;
        default =
          if !detected || turingOrNewer
          then "stable"
          else if maxwellOrNewer
          then "legacy_580"
          else "legacy_470";
        defaultText = lib.literalMD ''"stable" for Turing and newer, "legacy_580" for Maxwell to Volta, "legacy_470" for Kepler, from `hardware.facter.report`'';
        description = "Driver branch (hardware.nvidia.branch).";
      };
      containerToolkit.enable = lib.mkOption {
        type = lib.types.bool;
        default = config.virtualisation.docker.enable || config.virtualisation.podman.enable;
        defaultText = lib.literalExpression "config.virtualisation.docker.enable || config.virtualisation.podman.enable";
        description = "The NVIDIA container toolkit (CDI), so containers can use the GPU. On by default wherever Docker or Podman runs.";
      };
      packages = lib.mkOption {
        type = lib.types.listOf lib.types.package;
        default = [pkgs.nvtopPackages.nvidia];
        defaultText = lib.literalExpression "[pkgs.nvtopPackages.nvidia]";
        description = "GPU tools to install.";
      };
    };

    config = lib.mkIf cfg.enable {
      environment.systemPackages = cfg.packages;

      services.xserver.videoDrivers = ["nvidia"];
      hardware = {
        graphics.enable = true;
        nvidia-container-toolkit.enable = cfg.containerToolkit.enable;
        nvidia = {
          inherit (cfg) open branch;
          modesetting.enable = lib.mkDefault true;
          # Save and restore video memory across suspend, so the desktop
          # comes back intact. finegrained (laptop PRIME offload) stays off.
          powerManagement.enable = lib.mkDefault true;
        };
      };
    };
  };
}
