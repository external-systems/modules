# Minimal stand-in for clan-core's clan.core and sops-nix's sops options,
# so the eval checks cover the clan-aware modules without pulling
# clan-core into the dev partition. Only the attributes the modules read
# are typed; everything else is freeform. Vars never exist here, which is
# the same state a machine is in before its first `clan vars generate`.
{lib, ...}: let
  inherit (lib) mkOption types;
  freeform = types.lazyAttrsOf types.raw;

  file = generator:
    types.submodule ({name, ...}: {
      freeformType = freeform;
      options = {
        path = mkOption {
          type = types.str;
          default = "/run/secrets/vars/${generator}/${name}";
        };
        exists = mkOption {
          type = types.bool;
          default = false;
        };
        value = mkOption {
          type = types.str;
          default = "";
        };
      };
    });

  generator = types.submodule ({name, ...}: {
    freeformType = freeform;
    options.files = mkOption {
      type = types.attrsOf (file name);
      default = {};
    };
  });
in {
  options = {
    clan.core = mkOption {
      type = types.submodule {
        freeformType = freeform;
        options = {
          settings = mkOption {
            type = types.submodule {
              freeformType = freeform;
              options = {
                directory = mkOption {
                  type = types.str;
                  default = "/var/empty";
                };
                machine.name = mkOption {
                  type = types.str;
                  default = "eval";
                };
              };
            };
            default = {};
          };
          vars.generators = mkOption {
            type = types.attrsOf generator;
            default = {};
          };
        };
      };
      default = {};
    };

    sops.secrets = mkOption {
      type = types.attrsOf freeform;
      default = {};
    };
  };
}
