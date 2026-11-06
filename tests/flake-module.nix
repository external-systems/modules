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

      # VSCodium gets GH_TOKEN from alice's PAT: the wrapper reads the
      # deployed clan-var path at launch (never the token itself).
      vscodium-gh-token = let
        hm = machine.config.home-manager.users.alice;
        inherit (hm.homeSpec.programs.git.githubAuth) patFile;
        inherit (hm.programs.vscodium) package;
        expect = cond: msg: lib.assertMsg cond "vscodium-gh-token: ${msg}";
      in
        assert expect (patFile != null) "no patFile fed back";
        assert expect (lib.hasInfix patFile (package.buildCommand or "")) "codium not wrapped with the PAT file";
        assert expect (lib.getExe package == "${package}/bin/codium") "wrapper lost bin/codium";
          pkgs.writeText "vscodium-gh-token" "ok";

      # Gaming Mode as the dedicated user, shared Steam libraries, and the
      # gaming boot entry: the user and libraries exist in both entries,
      # jovian and the configuration hook only in the gaming one.
      gaming = let
        cfg = machine.config;
        gamer = cfg.users.users.gamer;
        entry = (inputs.nixpkgs.lib.nixosSystem {
          modules = [
            self.nixosModules.default
            ./clan-stub.nix
            {
              nixpkgs.hostPlatform = system;
              fileSystems = {
                "/".device = "/dev/disk/by-label/nixos";
                "/mnt/steam" = {
                  device = "/dev/disk/by-label/root";
                  fsType = "btrfs";
                };
              };
              boot.loader.grub.devices = ["nodev"];
              system.stateVersion = "26.11";
              swapDevices = [{device = "/dev/disk/by-label/swap";}];
              users.users.alice.isNormalUser = true;
              hostSpec.system = {
                gamingSpecialisation = {
                  enable = true;
                  diskSwap = true;
                  configuration.environment.etc.gaming-hook.text = "on";
                };
                jovian.gamingMode = true;
                gaming.sharedLibraries = {
                  enable = true;
                  paths = ["/mnt/steam"];
                };
              };
            }
          ];
        });
        parent = entry.config;
        gaming = (entry.extendModules {modules = [parent.specialisation.gaming.configuration];}).config;
        expect = c: msg: lib.assertMsg c "gaming: ${msg}";
      in
        assert expect (gamer.isNormalUser && gamer.uid == 1500 && gamer.hashedPassword == "!") "gamer not a locked normal user with uid 1500";
        assert expect (!(lib.elem "wheel" gamer.extraGroups) && gamer.openssh.authorizedKeys.keys == []) "gamer has wheel or SSH keys";
        assert expect (cfg.services.displayManager.sddm.settings.Users.HideUsers == "gamer") "gamer not hidden from SDDM";
        assert expect (cfg.jovian.steam.user == "gamer") "Gaming Mode does not log in as gamer";
        assert expect (lib.sort lib.lessThan cfg.users.groups.gamers.members == ["alice" "gamer"]) "gamers group is not alice and gamer";
        assert expect (cfg.systemd.services.steam-library-mnt-games2.unitConfig.RequiresMountsFor == "/mnt/games2") "library service not tied to its mount";
        assert expect (lib.hasInfix "/srv/games/users/alice/steamapps/common" cfg.systemd.services.steam-library-srv-games.script) "alice has no common link";
        assert expect (!parent.hostSpec.system.jovian.enable && gaming.hostSpec.system.jovian.enable) "jovian not only in the gaming entry";
        assert expect (parent.users.users ? gamer && gaming.users.users ? gamer) "gamer missing from an entry";
        assert expect (!(parent.environment.etc ? gaming-hook) && gaming.environment.etc.gaming-hook.text == "on") "configuration hook not only in the gaming entry";
        assert expect (parent.swapDevices == [] && gaming.swapDevices != []) "diskSwap not only in the gaming entry";
        assert expect (gaming.jovian.steam.user == "gamer" && gaming.jovian.steam.autoStart) "gaming entry does not autostart Gaming Mode as gamer";
          pkgs.writeText "gaming" "ok";

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
