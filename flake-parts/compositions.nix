{
  inputs,
  self,
  lib,
  ...
}: let
  # Every module this flake exports under `kind`, minus the composition
  # itself — the default modules import all of them, each gated behind its
  # own hostSpec/homeSpec enable option.
  allModules = kind: lib.attrValues (lib.filterAttrs (n: _: n != "default") self.${kind});
in {
  flake = {
    # ------ NixOS Modules ------ #
    # Consumers provide pkgs: these modules read the repo-built packages
    # (pkgs.openshell*, pkgs.code-sandbox, pkgs.devenv, pkgs.headroom-lean,
    # ...) from the consumer's overlay, so the overlay is applied by the
    # consuming flake, not here. Package choice (stable vs unstable) is the
    # consumer's: override the package options instead.
    nixosModules.default = {
      nixpkgs = {
        config.allowUnfree = lib.mkDefault true;
        hostPlatform = lib.mkDefault "x86_64-linux";
      };

      imports =
        [inputs.home-manager.nixosModules.home-manager]
        ++ allModules "nixosModules";

      # Boot
      boot = {
        tmp = {
          useTmpfs = lib.mkDefault false;
          cleanOnBoot = lib.mkDefault true;
        };
        loader.grub = {
          enable = lib.mkDefault true;
          efiSupport = lib.mkDefault true;
          efiInstallAsRemovable = lib.mkDefault true;
        };
      };
    };

    # ------ Home-manager Default Module ------ #
    # Default home-manager module for all users. homeModules.plasma-manager
    # needs plasma-manager's own module; consumers add
    # inputs.plasma-manager.homeModules.plasma-manager (e.g. through
    # home-manager.sharedModules), as external-systems/home already does.
    homeModules.default = {osConfig ? null, ...}: {
      # Only when the user evaluates its own nixpkgs: under
      # home-manager.useGlobalPkgs the NixOS pkgs are used, home-manager
      # warns about any nixpkgs.* definition, and fails once both
      # nixpkgs.config and nixpkgs.overlays are set.
      # The mkIf sits on nixpkgs.config itself: the option's type is
      # opaque, so a condition inside the attrset would still define it.
      nixpkgs.config = lib.mkIf (!(osConfig.home-manager.useGlobalPkgs or false)) {
        allowUnfree = lib.mkDefault true;
      };
      home = {
        stateVersion = "26.11";
        keyboard.layout = "us";
      };
      programs.home-manager.enable = true;

      imports = allModules "homeModules";
    };
  };
}
