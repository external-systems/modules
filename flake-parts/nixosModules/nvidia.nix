_: {
  # ------ NixOS Modules ------ #
  # The parts every NVIDIA machine shares. What depends on the card stays
  # on the machine: hardware.nvidia.branch (e.g. legacy_580 for Pascal),
  # hardware.nvidia.open = false before Turing, power management, a kernel
  # pin and CUDA capabilities.
  flake.nixosModules.nvidia = {
    config,
    pkgs,
    lib,
    ...
  }: let
    cfg = config.hostSpec.hardware.gpu.nvidia;
  in {
    options.hostSpec.hardware.gpu.nvidia = {
      enable = lib.mkEnableOption "the proprietary NVIDIA driver (X11 and Wayland)";
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
          modesetting.enable = lib.mkDefault true;
          # NVIDIA recommends the open kernel module from Turing (RTX 20,
          # GTX 16) on; older cards set it to false.
          open = lib.mkDefault true;
        };
      };
    };
  };
}
