_: {
  # ------ NixOS Modules ------ #
  flake.nixosModules.virtualization = {
    config,
    lib,
    ...
  }: let
    cfg = config.hostSpec.hardware.virtualization;
  in {
    options.hostSpec.hardware.virtualization.nested.enable =
      lib.mkEnableOption "nested KVM (kvm_amd/kvm_intel nested=1) so KVM guests can run their own KVM VMs, e.g. KubeVirt";

    config = lib.mkIf cfg.nested.enable {
      # Both vendor lines; the wrong-vendor one is inert. Explicit beats
      # relying on defaults (kvm_amd already nests by default, kvm_intel
      # historically does not). facter already loads kvm-amd/kvm-intel via
      # boot.kernelModules on the machines that use this.
      boot.extraModprobeConfig = ''
        options kvm_amd nested=1
        options kvm_intel nested=1
      '';
    };
  };
}
