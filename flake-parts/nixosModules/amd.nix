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
    options.hostSpec.hardware.gpu.amd = {
      enable = lib.mkEnableOption "default amd configuration";
      packages = lib.mkOption {
        type = lib.types.listOf lib.types.package;
        default = with pkgs; [
          amdgpu_top # GPU monitoring
          vulkan-tools # vulkaninfo
        ];
        defaultText = lib.literalExpression "with pkgs; [amdgpu_top vulkan-tools]";
        description = "GPU tools to install.";
      };
    };

    config = lib.mkIf cfg.enable {
      environment.systemPackages = cfg.packages;

      hardware = {
        amdgpu.initrd.enable = true;
        graphics.enable = true;
      };
    };
  };
}
