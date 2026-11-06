_: {
  # ------ NixOS Modules ------ #
  flake.nixosModules.amd = {
    config,
    pkgs,
    lib,
    ...
  }: let
    cfg = config.hostSpec.hardware.gpu.amd;
    cards = config.hardware.facter.report.hardware.graphics_card or [];
  in {
    options.hostSpec.hardware.gpu.amd = {
      enable =
        lib.mkEnableOption "AMD GPU support (amdgpu in initrd, LACT, GPU tools)"
        // {
          # 0x1002: an AMD/ATI GPU in the machine's nixos-facter report.
          default = lib.any (card: (card.vendor.value or null) == 4098) cards;
          defaultText = lib.literalMD "an AMD graphics card in `hardware.facter.report`";
        };
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

      # LACT: GUI for AMD fan curves, power limits and undervolting.
      services.lact.enable = true;
    };
  };
}
