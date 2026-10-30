{lib, ...}: {
  # ------ Home-manager Modules ------ #
  flake.homeModules.ssh = {config, ...}: let
    cfg = config.homeSpec.programs.ssh;
  in {
    options.homeSpec.programs.ssh = {
      enable = lib.mkEnableOption "default ssh configuration";

      # Clan-vars-managed per-user keypair ("user-ssh-<user>", declared by
      # nixosModules/ssh.nix). Non-destructive: the default
      # ~/.ssh/id_ed25519 is never touched. git picks the private half up
      # as its default signing key (homeModules/git.nix); per-host ssh
      # IdentityFile stanzas were removed for now.
      clanKey = {
        enabled = lib.mkEnableOption "clan-vars-managed per-user SSH keypair";

        privateKeyFile = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          description = "Deployed path of the user's clan-generated SSH private key; doubles as git's default signing key. Internal: set by nixosModules/ssh.nix via home-manager.sharedModules — never hardcode it in a profile.";
        };

        publicKeyFile = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          description = "Deployed path of the user's clan-generated SSH public key. Internal: set by nixosModules/ssh.nix — never hardcode it in a profile.";
        };
      };
    };

    config = lib.mkIf cfg.enable {
      # for DevPod
      home.sessionVariables.SSH_CONFIG_PATH = "~/.ssh/config.local";

      programs.ssh = {
        enable = true;
        enableDefaultConfig = false;
        includes = lib.mkDefault ["~/.ssh/config.local"];
      };
    };
  };
}
