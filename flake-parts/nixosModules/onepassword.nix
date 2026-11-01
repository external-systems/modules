{lib, ...}: {
  # ------ NixOS Modules ------ #
  # 1Password through the NixOS modules, never as a plain package. The
  # desktop app only talks to an `op` that is setgid to the
  # onepassword-cli group; programs._1password installs exactly that at
  # /run/wrappers/bin/op. Do NOT also add pkgs._1password-cli to system or
  # home packages: a Nix-store `op` earlier on PATH fails with
  # "connecting to desktop app" errors.
  #
  # After the rebuild, in the app: sign in, then Settings > Security >
  # "Unlock using system authentication" (fingerprint also needs
  # services.fprintd.enable and an enrolled finger) and Settings >
  # Developer > "Integrate with 1Password CLI". `op vault list` should
  # then prompt for authorization.
  flake.nixosModules.onepassword = {config, ...}: let
    cfg = config.hostSpec.services.onepassword;
  in {
    options.hostSpec.services.onepassword = {
      enable = lib.mkEnableOption "1Password desktop app and the setgid op CLI wrapper";

      polkitPolicyOwners = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = ["andrew"];
        description = "Users allowed to unlock 1Password with system authentication (polkit) and to use the CLI integration.";
      };
    };

    config = lib.mkIf cfg.enable {
      # Both packages are unfree. mkDefault: a consumer's own predicate
      # (or nixpkgs.config.allowUnfree, which nixosModules.default sets)
      # takes over, so it must cover 1password and 1password-cli too.
      nixpkgs.config.allowUnfreePredicate = lib.mkDefault (
        pkg: builtins.elem (lib.getName pkg) ["1password" "1password-cli"]
      );

      programs = {
        _1password.enable = true;
        _1password-gui = {
          enable = true;
          inherit (cfg) polkitPolicyOwners;
        };
      };
    };
  };
}
