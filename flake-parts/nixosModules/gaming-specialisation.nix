# Boot entries for a machine that games and develops:
#
# - default: the everyday desktop. The jovian module is on (Valve kernel
#   unless the machine pins one, Steam on the KDE desktop, zram, scx,
#   ntsync, the boot power profile), and the machine boots to the normal
#   login screen.
# - "gaming" specialisation: the same system, booting straight into
#   Steam Gaming Mode (hostSpec.system.jovian.gamingMode) for couch play.
# - "developer" specialisation (developer-specialisation.nix): jovian
#   off, so the machine's normal kernel and no Steam.
#
# Anything else the gaming entry needs goes in `configuration`. Pick the
# entry in the boot menu (a kernel change needs a reboot). A machine that
# enables this must not set hostSpec.system.jovian.enable itself: this
# module owns it. Nested specialisations are ignored by NixOS, so
# specialisations the machine defines exist only in the default entry.
{
  flake.nixosModules.gaming-specialisation = {
    config,
    lib,
    ...
  }: let
    cfg = config.hostSpec.system.gamingSpecialisation;
    # `or`: works without nixosModules.developer-specialisation too.
    developer = config.hostSpec.system.developerSpecialisation.active or false;
  in {
    options.hostSpec.system.gamingSpecialisation = {
      enable = lib.mkEnableOption ''
        jovian in the default entry and a "gaming" boot entry (NixOS
        specialisation) that boots into Steam Gaming Mode; see this
        file's header
      '';
      configuration = lib.mkOption {
        type = lib.types.deferredModule;
        default = {};
        example = lib.literalExpression ''
          {
            services.flatpak.enable = false;
          }
        '';
        description = ''
          NixOS module merged into the gaming entry only, on top of the
          machine's own configuration.
        '';
      };
      active = lib.mkOption {
        type = lib.types.bool;
        default = false;
        internal = true;
        description = "True inside the gaming specialisation; set by this module, never by a machine.";
      };
    };

    config = lib.mkIf cfg.enable {
      specialisation.gaming.configuration = {
        imports = [cfg.configuration];
        hostSpec.system.gamingSpecialisation.active = true;
      };
      hostSpec.system.jovian.enable = !developer;
    };
  };
}
