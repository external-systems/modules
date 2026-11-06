# The module eval checks: every hostSpec/homeSpec toggle on, evaluated
# against the fixtures here. Formatting, docs and lock-sync come from
# org-pkgs flakeModules.default (flake.nix). Checks are evaluated only on
# demand, so a consumer of nixosModules/homeModules never touches them.
{
  inputs,
  lib,
  self,
  ...
}: {
  perSystem = {
    pkgs,
    system,
    ...
  }: let
    # Every hostSpec/homeSpec toggle on, evaluated down to the system
    # derivation. Only instantiated, never built: the check fails when a
    # module stops evaluating, not when a package fails to build.
    machine = inputs.nixpkgs.lib.nixosSystem {
      modules = [
        (import ./fixtures/nixos.nix {inherit inputs self;})
        {nixpkgs.hostPlatform = system;}
      ];
    };
  in {
    # Formatting and lint: checks.treefmt (pkgs flakeModules.default).
    # The fleet is x86_64-linux; jovian and the GPU modules are not meant
    # for aarch64.
    checks = lib.optionalAttrs (system == "x86_64-linux") {
      eval-all-enabled = pkgs.writeText "eval-all-enabled" (
        builtins.unsafeDiscardStringContext machine.config.system.build.toplevel.drvPath
      );

      # Per-user Storage Box wiring: the NixOS companion declares alice's
      # key, feeds its path back, and the user units come out right.
      storagebox-per-user = let
        inherit (machine.config.clan.core.vars) generators;
        hm = machine.config.home-manager.users.alice;
        units = hm.systemd.user.services;
        key = generators.storagebox-ssh-alice.files.ssh-private-key;
        mainUnit = units."rclone-mount:@storagebox-main";
        archiveUnit = units."rclone-mount:BACKUPS@storagebox-archive";
        expect = cond: msg: lib.assertMsg cond "storagebox-per-user: ${msg}";
      in
        assert expect (generators ? storagebox-ssh-alice) "no storagebox-ssh-alice generator";
        assert expect (key.owner == "alice" && key.mode == "0400") "key not owned by alice with mode 0400";
        assert expect (hm.homeSpec.programs.storagebox.keyFile == key.path) "keyFile not fed back";
        assert expect (mainUnit.Install.WantedBy == ["default.target"]) "main box does not start on login";
        assert expect (archiveUnit.Install.WantedBy == []) "manual box starts on login";
        assert expect (lib.hasInfix "storagebox-archive:BACKUPS" (toString archiveUnit.Service.ExecStart)) "remotePath not mounted";
        assert expect (hm.programs.ssh.settings.storagebox-main.data.Port == 23) "ssh alias missing";
          pkgs.writeText "storagebox-per-user" "ok";

      # Hardware modules configure themselves from the nixos-facter report:
      # a Pascal card (GTX 1070 Ti) gets the closed module and legacy_580, a
      # Turing card the open module, an Intel iGPU and Bluetooth come on,
      # AMD stays off, and a machine can still opt out.
      hardware-from-facter = let
        configOf = nvidiaDevice: extra:
          (inputs.nixpkgs.lib.nixosSystem {
            modules = [
              self.nixosModules.amd
              self.nixosModules.bluetooth
              self.nixosModules.intel
              self.nixosModules.nvidia
              {
                nixpkgs.hostPlatform = system;
                hardware.facter.report.hardware.bluetooth = [{driver_modules = ["btusb"];}];
                hardware.facter.report.hardware.graphics_card = [
                  {
                    vendor.value = 4318; # 0x10de NVIDIA
                    device.value = nvidiaDevice;
                    driver_modules = [];
                  }
                  {
                    vendor.value = 32902; # 0x8086 Intel
                    device.value = 39497;
                    driver_modules = ["i915"];
                  }
                ];
              }
              extra
            ];
          }).config;
        pascal = configOf 7042 {}; # 0x1b82 GTX 1070 Ti
        turing = configOf 7810 {}; # 0x1e82 RTX 2080
        optedOut = configOf 7042 {hostSpec.hardware.gpu.intel.enable = false;};
        expect = cond: msg: lib.assertMsg cond "hardware-from-facter: ${msg}";
      in
        assert expect pascal.hostSpec.hardware.gpu.nvidia.enable "NVIDIA card not detected";
        assert expect pascal.hostSpec.hardware.bluetooth.enable "Bluetooth not detected";
        assert expect pascal.hostSpec.hardware.gpu.intel.enable "Intel GPU not detected";
        assert expect (!pascal.hostSpec.hardware.gpu.amd.enable) "AMD on without an AMD card";
        assert expect (!pascal.hardware.nvidia.open && pascal.hardware.nvidia.branch == "legacy_580") "Pascal not on the closed module and legacy_580";
        assert expect pascal.hardware.nvidia.powerManagement.enable "NVIDIA power management off";
        assert expect (turing.hardware.nvidia.open && turing.hardware.nvidia.branch == "stable") "Turing not on the open module and stable";
        assert expect (!optedOut.hostSpec.hardware.gpu.intel.enable) "a machine cannot switch a detected GPU off";
          pkgs.writeText "hardware-from-facter" "ok";
    };
  };
}
