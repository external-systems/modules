_: {
  # ------ NixOS Modules ------ #
  flake.nixosModules.intel = {
    config,
    pkgs,
    lib,
    ...
  }: let
    cfg = config.hostSpec.hardware.gpu.intel;
    cards = config.hardware.facter.report.hardware.graphics_card or [];
  in {
    options.hostSpec.hardware.gpu.intel.enable =
      lib.mkEnableOption "Intel GPU media (VA-API) and compute (OpenCL) drivers"
      // {
        # 0x8086: an Intel GPU in the machine's nixos-facter report. A
        # disabled iGPU is not in the report and stays off.
        default = lib.any (card: (card.vendor.value or null) == 32902) cards;
        defaultText = lib.literalMD "an Intel graphics card in `hardware.facter.report`";
      };

    config = lib.mkIf cfg.enable {
      hardware.graphics = {
        enable = true;
        extraPackages = with pkgs; [
          intel-media-driver
          intel-compute-runtime
        ];
      };
    };
  };
}
