_: {
  # ------ NixOS Modules ------ #
  flake.nixosModules.intel = {
    config,
    pkgs,
    lib,
    ...
  }: let
    cfg = config.hostSpec.hardware.gpu.intel;
  in {
    # It only ever set up the Intel GPU (VA-API and OpenCL); CPU microcode
    # comes from nixos-facter (hardware.facter, firmware.nix).
    imports = [
      (lib.mkRenamedOptionModule
        ["hostSpec" "hardware" "cpu" "intel" "enable"]
        ["hostSpec" "hardware" "gpu" "intel" "enable"])
    ];

    options.hostSpec.hardware.gpu.intel.enable = lib.mkEnableOption "Intel GPU media (VA-API) and compute (OpenCL) drivers";

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
