# A "developer" boot entry (NixOS specialisation) next to the default
# system: the place for what only a developer session needs, such as
# Kubernetes and VPNs, passed in through `configuration`. With
# gaming-specialisation.nix on, the jovian module is off here: the
# machine's normal kernel and no Steam.
{
  flake.nixosModules.developer-specialisation = {
    config,
    lib,
    ...
  }: let
    cfg = config.hostSpec.system.developerSpecialisation;
  in {
    options.hostSpec.system.developerSpecialisation = {
      enable = lib.mkEnableOption ''
        a "developer" boot entry (NixOS specialisation); see this file's
        header
      '';
      diskSwap = lib.mkOption {
        type = lib.types.bool;
        default = true;
        example = false;
        description = ''
          Whether the developer entry keeps disk swap (swapDevices).
          false drops it there only, as kubelet wants; the other entries
          keep the machine's swap.
        '';
      };
      configuration = lib.mkOption {
        type = lib.types.deferredModule;
        default = {};
        example = lib.literalExpression ''
          {
            services.k3s.enable = true;
          }
        '';
        description = ''
          NixOS module merged into the developer entry only, on top of
          the machine's own configuration.
        '';
      };
      active = lib.mkOption {
        type = lib.types.bool;
        default = false;
        internal = true;
        description = "True inside the developer specialisation; set by this module, never by a machine.";
      };
    };

    config = lib.mkIf cfg.enable (lib.mkMerge [
      {
        specialisation.developer.configuration = {
          imports = [cfg.configuration];
          hostSpec.system.developerSpecialisation.active = true;
        };
      }
      # The parent's definitions are re-evaluated inside the specialisation
      # with active = true, so this only applies there.
      (lib.mkIf (cfg.active && !cfg.diskSwap) {
        swapDevices = lib.mkForce [];
      })
    ]);
  };
}
