{lib, ...}: {
  # ------ Home-manager Modules ------ #
  flake.homeModules.git = {
    config,
    pkgs,
    ...
  }: let
    cfg = config.homeSpec.programs.git;
    # git runs helper strings through the shell; a store-path script keeps
    # shell quoting out of the ini file. Missing/unreadable PAT -> exit 1 so
    # git falls through to the next helper instead of auth-failing on "".
    githubCredentialHelper = pkgs.writeShellScript "git-credential-github-pat" ''
      test "$1" = get || exit 0
      test -r "${cfg.githubAuth.patFile}" || exit 1
      echo username=x-access-token
      echo "password=$(cat "${cfg.githubAuth.patFile}")"
    '';
  in {
    options.homeSpec.programs.git = {
      enable = lib.mkEnableOption "default git configuration";

      userName = lib.mkOption {
        type = lib.types.str;
        description = "git user.name for this profile.";
      };

      userEmail = lib.mkOption {
        type = lib.types.str;
        description = "git user.email for this profile.";
      };

      signingKey = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        # Default: the clan-generated keypair's private half (ssh.clanKey),
        # which nixosModules/ssh.nix nulls until the var exists — signing
        # stays off rather than broken pre-generation. Must be the PRIVATE
        # key: git's ssh signer (ssh-keygen -Y sign) needs the private half,
        # and a store-path .pub has none beside it. Profiles only set this
        # to override with a static key.
        default = config.homeSpec.programs.ssh.clanKey.privateKeyFile;
        description = "SSH private key used to sign commits; null disables commit signing.";
      };

      # One GitHub PAT per user (clan vars generator "github-<user>",
      # declared by nixosModules/git.nix) drives github.com HTTPS git
      # operations, GH_TOKEN for the gh CLI, and the github MCP wrapper.
      githubAuth = {
        enabled = lib.mkEnableOption "declarative github.com auth via the per-user clan-var PAT";
        patFile = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          description = "Deployed path of the user's GitHub PAT. Internal: set by nixosModules/git.nix from the clan vars generator — never hardcode it in a profile.";
        };
      };
    };

    config = lib.mkIf cfg.enable {
      home.packages = with pkgs; [
        gh
      ];

      programs = {
        lazygit.enable = true;

        bash.initExtra = lib.mkIf (cfg.githubAuth.patFile != null) ''
          if [ -r "${cfg.githubAuth.patFile}" ]; then
            export GH_TOKEN="$(cat "${cfg.githubAuth.patFile}")"
          fi
        '';

        git = {
          enable = true;
          package = pkgs.unstable.gitFull;
          lfs.enable = true;

          ignores = [
            ".secrets"
            "result*"
            "result-*"
            ".direnv"
            ".devenv"
            ".env"
            ".env.*"
            "!.env.schema"
            ".venv"
            ".terraform*"
            "terraform.tfstate*"
            "config.tf.json"
            "*.tfbackend"
            "backend.tfbackend"
            ".baton-pass/"
          ];

          # programs.git.settings is freeform: keys render verbatim into git
          # config, so git's real section names belong here ([alias]
          # singular, [gpg]/[commit]/[user] for signing — the previous
          # extraConfig/aliases/signing nesting rendered as literal inert
          # sections and none of it applied).
          settings = {
            init.defaultBranch = "main";

            pull = {
              rebase = true;
              autostash = true;
              twohead = "ort";
            };

            push = {
              default = "simple";
              autoSetupRemote = true;
            };

            branch = {
              autoSetupRebase = "always";
              autoSetupMerge = "always";
            };

            rebase = {
              stat = true;
              autoStash = true;
              autoSquash = true;
              updateRefs = true;
            };

            help.autocorrect = 10;

            commit.gpgsign = cfg.signingKey != null;
            gpg.format = lib.mkIf (cfg.signingKey != null) "ssh";

            credential = lib.mkIf (cfg.githubAuth.patFile != null) {
              "https://github.com".helper = "!${githubCredentialHelper}";
            };

            alias = {
              s = "status";
              d = "diff";
              a = "add";
              c = "commit";
              p = "push";
              o = "checkout";
              co = "checkout";
              uncommit = "reset --soft HEAD^";
              comma = "commit --amend";
              reset-pr = "reset --hard FETCH_HEAD";
              force-push = "push --force-with-lease";
            };

            user =
              {
                name = cfg.userName;
                email = cfg.userEmail;
              }
              // lib.optionalAttrs (cfg.signingKey != null) {
                inherit (cfg) signingKey;
              };
          };
        };
      };
    };
  };
}
