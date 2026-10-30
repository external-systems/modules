_: {
  # ------ NixOS Modules ------ #
  flake.nixosModules.amd = {
    config,
    pkgs,
    lib,
    ...
  }: let
    cfg = config.hostSpec.hardware.gpu.amd;
  in {
    options.hostSpec.hardware.gpu.amd.enable = lib.mkEnableOption "default amd configuration";

    config = lib.mkIf cfg.enable {
      environment.systemPackages = with pkgs.unstable; [
        amdgpu_top # GPU monitoring
        vulkan-tools # vulkaninfo
      ];

      hardware = {
        amdgpu.initrd.enable = true;
        graphics.enable = true;
      };
    };
  };
}
