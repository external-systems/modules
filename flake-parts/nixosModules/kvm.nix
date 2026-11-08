{lib, ...}: {
  # ------ NixOS Modules ------ #
  # Whether this machine can run KVM guests: a capability flag, not a
  # service. Modules that need hardware virtualisation read it (Claude
  # Desktop's Cowork, through homeSpec.agents.claude.desktop.cowork);
  # nixos-facter already loads kvm-amd / kvm-intel itself.
  flake.nixosModules.kvm = {config, ...}: {
    options.hostSpec.hardware.kvm.enable =
      lib.mkEnableOption "KVM hardware virtualisation for user VMs"
      // {
        # AMD-V (svm) or VT-x (vmx) in the machine's nixos-facter report,
        # the same CPU flags facter loads kvm-amd / kvm-intel from.
        default = lib.any (cpu: lib.any (f: lib.elem f (cpu.features or [])) ["svm" "vmx"]) (config.hardware.facter.report.hardware.cpu or []);
        defaultText = lib.literalMD "an `svm` or `vmx` CPU feature in `hardware.facter.report`";
      };
  };
}
