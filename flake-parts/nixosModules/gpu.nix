_: {
  # ------ NixOS Modules ------ #
  # Turns on the GPU modules (amd.nix, intel.nix, nvidia.nix) from the
  # machine's nixos-facter report, so a fleet does not repeat per-vendor
  # tags that the hardware already answers. Each enable is mkDefault: a
  # machine can still switch one off.
  flake.nixosModules.gpu = {
    config,
    lib,
    ...
  }: let
    cfg = config.hostSpec.hardware.gpu;

    # PCI vendor ids of the graphics cards in the report.
    vendors = map (card: card.vendor.value or null) (config.hardware.facter.report.hardware.graphics_card or []);
    has = vendor: lib.elem vendor vendors;
  in {
    options.hostSpec.hardware.gpu.fromFacter = lib.mkEnableOption ''
      hostSpec.hardware.gpu.{amd,intel,nvidia} for every graphics card in the
      nixos-facter report (hardware.facter.report). A GPU the firmware hides,
      like a disabled iGPU, is not in the report and stays off
    '';

    config = lib.mkIf cfg.fromFacter {
      hostSpec.hardware.gpu = {
        amd.enable = lib.mkDefault (has 4098); # 0x1002 AMD/ATI
        intel.enable = lib.mkDefault (has 32902); # 0x8086 Intel
        nvidia.enable = lib.mkDefault (has 4318); # 0x10de NVIDIA
      };
    };
  };
}
