# The module eval checks: every hostSpec/homeSpec toggle on, evaluated
# against the fixtures here. Formatting, docs and lock-sync come from
# org-pkgs flakeModules.dev (flake.nix). Checks are evaluated only on
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
    # Formatting and lint: checks.treefmt (pkgs flakeModules.dev).
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
    };
  };
}
