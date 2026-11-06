# Gaming as a second boot entry. The default entry is the machine's own
# system with the jovian module off; the "gaming" specialisation turns it
# on (Valve kernel unless the machine pins one, Steam, gamescope, zram,
# scx, ntsync, the boot power profile, Gaming Mode when
# hostSpec.system.jovian.gamingMode is on). Anything else the gaming entry
# needs, such as stopping services a developer system runs, goes in
# `configuration`. Pick the entry in the boot menu (a kernel change needs
# a reboot).
#
# A machine that enables this must not set hostSpec.system.jovian.enable
# itself: this module owns it. Nested specialisations are ignored by
# NixOS, so specialisations the machine defines exist only in the default
# entry.
{
  flake.nixosModules.gaming-specialisation = {
    config,
    lib,
    ...
  }: let
    cfg = config.hostSpec.system.gamingSpecialisation;
  in {
    options.hostSpec.system.gamingSpecialisation = {
      enable = lib.mkEnableOption ''
        a "gaming" boot entry (NixOS specialisation) next to the default
        system; see this file's header
      '';
      diskSwap = lib.mkOption {
        type = lib.types.bool;
        default = false;
        example = true;
        description = ''
          Whether disk swap (swapDevices) is used only in the gaming
          entry, so the default entry runs without it as kubelet wants.
          Off keeps swap as the machine defines it in both entries.
        '';
      };
      configuration = lib.mkOption {
        type = lib.types.deferredModule;
        default = {};
        example = lib.literalExpression ''
          {lib, ...}: {
            services.k3s.enable = lib.mkForce false;
          }
        '';
        description = ''
          NixOS module merged into the gaming entry only, on top of the
          machine's own configuration: stop services the default entry
          runs, change settings for gaming.
        '';
      };
      active = lib.mkOption {
        type = lib.types.bool;
        default = false;
        internal = true;
        description = "True inside the gaming specialisation; set by this module, never by a machine.";
      };
    };

    config = lib.mkIf cfg.enable (lib.mkMerge [
      {
        specialisation.gaming.configuration = {
          imports = [cfg.configuration];
          hostSpec.system.gamingSpecialisation.active = true;
        };
        hostSpec.system.jovian.enable = cfg.active;
      }
      # The parent's definitions are re-evaluated inside the specialisation
      # with active = true, so this drops out there without a mkForce fight.
      (lib.mkIf (!cfg.active && cfg.diskSwap) {
        swapDevices = lib.mkForce [];
      })
    ]);
  };
}
