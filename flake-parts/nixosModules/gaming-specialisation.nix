# Boot entries for a machine that games and develops:
#
# - desktop: the everyday desktop. The jovian module is on (Valve kernel
#   unless the machine pins one, Steam on the KDE desktop, zram, scx,
#   ntsync, the boot power profile), and the machine boots to the normal
#   login screen.
# - gaming: the same system, booting straight into Steam Gaming Mode
#   (hostSpec.system.jovian.gamingMode) for couch play.
# - "developer" specialisation (developer-specialisation.nix): jovian
#   off, so the machine's normal kernel and no Steam.
#
# `gamingEntry = false` drops the gaming entry: the desktop and developer
# entries only, one Steam client and no Gaming Mode (a desktop several
# people use). `defaultEntry` picks which of desktop and gaming is the machine's
# default boot entry; the other one becomes a specialisation named after
# it ("gaming" or "desktop"). A Steam Deck sets defaultEntry = "gaming".
#
# Anything else the gaming entry needs goes in `configuration`, which
# only works while gaming is the specialisation: with defaultEntry =
# "gaming" the machine's own configuration is the gaming entry. Pick the
# entry in the boot menu (a kernel change needs a reboot). A machine that
# enables this must not set hostSpec.system.jovian.enable itself: this
# module owns it. Nested specialisations are ignored by NixOS, so
# specialisations the machine defines exist only in the default entry.
{
  flake.nixosModules.gaming-specialisation = {
    config,
    lib,
    options,
    ...
  }: let
    cfg = config.hostSpec.system.gamingSpecialisation;
    # `or`: works without nixosModules.developer-specialisation too.
    developer = config.hostSpec.system.developerSpecialisation.active or false;
    gamingDefault = cfg.defaultEntry == "gaming";
    other =
      if gamingDefault
      then "desktop"
      else "gaming";
  in {
    options.hostSpec.system.gamingSpecialisation = {
      enable = lib.mkEnableOption ''
        jovian in the desktop and gaming entries, with the gaming entry
        booting into Steam Gaming Mode; see this file's header
      '';
      defaultEntry = lib.mkOption {
        type = lib.types.enum ["desktop" "gaming"];
        default = "desktop";
        example = "gaming";
        description = ''
          Which entry the machine boots by default. "desktop" boots the
          KDE login screen and adds a "gaming" specialisation; "gaming"
          boots Gaming Mode and adds a "desktop" specialisation (a Steam
          Deck).
        '';
      };
      gamingEntry = lib.mkOption {
        type = lib.types.bool;
        default = true;
        example = false;
        description = ''
          Whether the machine has the gaming entry. false leaves the
          desktop entry (jovian, Steam on the KDE desktop) and the
          developer entry: one Steam client and no Gaming Mode, for a
          desktop several people use. Needs defaultEntry = "desktop".
        '';
      };
      configuration = lib.mkOption {
        type = lib.types.deferredModule;
        default = {};
        example = lib.literalExpression ''
          {
            services.flatpak.enable = false;
          }
        '';
        description = ''
          NixOS module merged into the gaming specialisation only, on top
          of the machine's own configuration. Only for defaultEntry =
          "desktop"; with "gaming", put it in the machine's configuration.
        '';
      };
      alternate = lib.mkOption {
        type = lib.types.bool;
        default = false;
        internal = true;
        description = "True inside the desktop or gaming specialisation; set by this module, never by a machine.";
      };
      active = lib.mkOption {
        type = lib.types.bool;
        default = false;
        internal = true;
        description = "True in the gaming entry, default or specialisation; set by this module, never by a machine.";
      };
    };

    config = lib.mkIf cfg.enable {
      assertions = [
        {
          assertion = cfg.gamingEntry || !gamingDefault;
          message = "hostSpec.system.gamingSpecialisation.gamingEntry = false needs defaultEntry = \"desktop\": the default entry is the gaming entry.";
        }
        {
          assertion = gamingDefault -> options.hostSpec.system.gamingSpecialisation.configuration.highestPrio >= 1500;
          message = ''
            hostSpec.system.gamingSpecialisation.configuration only applies
            to a gaming specialisation; with defaultEntry = "gaming" the
            machine's own configuration is the gaming entry.
          '';
        }
      ];
      specialisation.${other} = lib.mkIf (cfg.gamingEntry || gamingDefault) {
        configuration = {
          imports = lib.optional (!gamingDefault) cfg.configuration;
          hostSpec.system.gamingSpecialisation.alternate = true;
        };
      };
      hostSpec.system = {
        gamingSpecialisation.active = !developer && (gamingDefault != cfg.alternate);
        jovian.enable = !developer;
      };
    };
  };
}
