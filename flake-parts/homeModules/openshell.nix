_: {
  # ------ Home-manager Modules ------ #
  # NVIDIA OpenShell CLI user environment: installs the CLI, wires the
  # gateway endpoint/policy into the shell session, and renders the pure
  # config files the CLI (and a user-run gateway) reads from XDG config.
  #
  # OpenShell v0.1.2 layout (crates/openshell-bootstrap/src/paths.rs):
  #   $XDG_CONFIG_HOME/openshell/gateway.toml     gateway server config
  #   $XDG_CONFIG_HOME/openshell/active_gateway   active gateway name
  #   $XDG_CONFIG_HOME/openshell/gateways/<name>/ gateway registry (CLI-managed)
  # Only pure files are written declaratively. The registry, mTLS material
  # and OIDC tokens are mutable CLI state (plain fs::write, 0600) and are
  # deliberately left to `openshell gateway add`/`login`.
  # `lib` is taken from the home-manager module eval (extended with
  # `lib.hm.dag`) rather than the outer flake-parts scope.
  flake.homeModules.openshell = {
    config,
    lib,
    pkgs,
    ...
  }: let
    cfg = config.homeSpec.programs.openshell;

    tomlFormat = pkgs.formats.toml {};
    yamlFormat = pkgs.formats.yaml {};

    # gateway.toml is read by the gateway when --config /
    # OPENSHELL_GATEWAY_CONFIG are unset. Schema v2 requires an
    # [openshell] version; an empty file is rejected, so the minimum is
    # merged with whatever the user sets under settings.
    gatewayConfig =
      tomlFormat.generate "openshell-gateway.toml"
      (lib.recursiveUpdate {openshell.version = 2;} cfg.settings);

    # Sandbox policy is passed with --policy or, when unset, taken from
    # OPENSHELL_SANDBOX_POLICY (openshell-cli --policy help). The env var
    # carries an absolute path because home-manager shell-escapes session
    # variable values (lib.escapeShellArg), so "$HOME/..." would not expand.
    policyFile =
      if cfg.sandboxPolicy == null
      then null
      else yamlFormat.generate "openshell-policy.yaml" cfg.sandboxPolicy;
    policyPath =
      if policyFile == null
      then null
      else "${config.xdg.configHome}/openshell/policy.yaml";

    # `gateway add` errors when the gateway already exists (User source),
    # so the activation is gated on the metadata file the command writes.
    # Skipped entirely when a system gateway is mirrored: the symlinked
    # metadata.json already satisfies the check.
    register = cfg.gateway.register && cfg.enable && cfg.systemGateway == null;
  in {
    options.homeSpec.programs.openshell = {
      enable = lib.mkEnableOption "the NVIDIA OpenShell CLI user environment";

      package = lib.mkOption {
        type = lib.types.package;
        default = pkgs.openshell;
        description = "OpenShell CLI package to install (pkgs.openshell, from the consumer's overlay).";
      };

      codeSandbox = {
        enable = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = ''
            Install the code-sandbox wrapper (pkgs.code-sandbox, from the
            consumer's overlay): the code-agent sandbox lifecycle CLI —
            create/delete/connect/exec/ssh-config/sync/doctor. Baked
            against the flake that builds it, so it runs from ANY
            directory and always builds the image/policy/provider-profile
            from that flake's pins (`--flake REF` overrides per
            invocation). Its bash completion ships inside the package (a
            static file — the wrapper has no clap), so every install path
            gets it. Requires an overlay providing pkgs.code-sandbox.
          '';
        };
      };

      completions = {
        enable = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = ''
            Install bash/fish/zsh completions for the CLI, generated from
            the installed package at build time (no gateway contact).
            Requires the shell's completion loader (e.g.
            programs.bash.enableCompletion) — enable that in your profile.
          '';
        };
      };

      gateway = {
        name = lib.mkOption {
          type = lib.types.str;
          default = "openshell";
          description = "Gateway alias, written to OPENSHELL_GATEWAY and used as the registration name.";
        };
        endpoint = lib.mkOption {
          type = lib.types.str;
          default = "http://127.0.0.1:17670";
          description = "Gateway endpoint URL, written to OPENSHELL_GATEWAY_ENDPOINT. 17670 is the gateway's built-in default listener (DEFAULT_SERVER_PORT).";
        };
        insecure = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = "Skip TLS certificate verification (OPENSHELL_GATEWAY_INSECURE).";
        };
        register = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = "Register the gateway via home.activation on activation. Idempotent: skipped once gateway metadata exists. The command also selects the gateway as active.";
        };
      };

      systemGateway = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = "local";
        description = ''
          Name of a gateway registration seeded system-wide by the NixOS
          module (hostSpec.services.openshell.gateway) to mirror into this
          user's ~/.config/openshell. The registration metadata and the mTLS
          bundle are symlinked from /etc/openshell — necessary because the
          CLI reads the mtls bundle only from the per-user config, never
          from the system registry — and the registration is made the user's
          active gateway declaratively. null disables the mirror (use
          gateway.register for a plaintext self-registered gateway instead).
          Mutually exclusive with gateway.register: the symlinked
          metadata.json satisfies register's idempotency check, and the
          active gateway is managed declaratively while this is set.
        '';
      };

      settings = lib.mkOption {
        type = lib.types.submodule {freeformType = tomlFormat.type;};
        default = {};
        description = ''
          Gateway configuration rendered to $XDG_CONFIG_HOME/openshell/gateway.toml.
          Free-form: any key is accepted and merged under the schema-v2 default
          ([openshell] version = 2). Only affects a gateway that reads this file
          (--config / OPENSHELL_GATEWAY_CONFIG unset); NixOS-managed gateways use
          their own /etc/openshell/gateway.toml.
        '';
      };

      sandboxPolicy = lib.mkOption {
        type = with lib.types; nullOr (submodule {freeformType = yamlFormat.type;});
        default = {
          version = 1;
          filesystem_policy = {
            include_workdir = true;
            # Nix puts every runtime dependency in /nix/store; without it a
            # sandboxed agent cannot execute anything.
            read_only = [
              "/bin"
              "/usr"
              "/lib"
              "/lib64"
              "/etc"
              "/proc"
              "/nix"
              "/nix/store"
              "/dev/urandom"
            ];
            read_write = [
              "/sandbox"
              "/tmp"
              "/home"
              "/env"
              "/dev/null"
            ];
          };
          landlock.compatibility = "best_effort";
        };
        description = ''
          Sandbox policy rendered to $XDG_CONFIG_HOME/openshell/policy.yaml and
          exported as OPENSHELL_SANDBOX_POLICY (the default for
          `openshell sandbox create --policy`). Set to null to write no policy
          and export no variable.
        '';
      };

      environment = lib.mkOption {
        type = lib.types.attrsOf lib.types.str;
        default = {};
        description = "Extra environment variables for the shell session.";
      };
    };

    config = lib.mkIf cfg.enable {
      home = {
        packages =
          [cfg.package]
          ++ lib.optional cfg.codeSandbox.enable pkgs.code-sandbox
          ++ lib.optionals cfg.completions.enable [
            # Completions are generated by the CLI at package build time
            # (pure clap output, no gateway contact) and picked up from
            # home.packages by the standard bash/fish/zsh completion
            # loaders. code-sandbox's bash completion ships inside
            # pkgs.code-sandbox itself (a static file — the wrapper has
            # no clap), so it needs no entry here.
            (pkgs.runCommand "openshell-completions" {} ''
              mkdir -p \
                $out/share/bash-completion/completions \
                $out/share/fish/vendor_completions.d \
                $out/share/zsh/site-functions
              ${lib.getExe cfg.package} completions bash \
                > $out/share/bash-completion/completions/openshell
              ${lib.getExe cfg.package} completions fish \
                > $out/share/fish/vendor_completions.d/openshell.fish
              ${lib.getExe cfg.package} completions zsh \
                > $out/share/zsh/site-functions/_openshell
            '')
          ];

        sessionVariables = lib.mkMerge [
          {
            OPENSHELL_GATEWAY = cfg.gateway.name;
            OPENSHELL_GATEWAY_ENDPOINT = cfg.gateway.endpoint;
          }
          (lib.mkIf cfg.gateway.insecure {OPENSHELL_GATEWAY_INSECURE = "1";})
          (lib.mkIf (policyPath != null) {OPENSHELL_SANDBOX_POLICY = policyPath;})
          cfg.environment
        ];

        # Declarative local plaintext registration. `gateway add` is the only
        # supported writer of active_gateway/metadata.json; it also selects the
        # gateway as active, so no separate `gateway select` is needed.
        activation.openshellGateway = lib.mkIf register (lib.hm.dag.entryAfter ["writeBoundary"] ''
          if [ ! -e "${config.xdg.configHome}/openshell/gateways/${cfg.gateway.name}/metadata.json" ]; then
            $DRY_RUN_CMD ${lib.getExe cfg.package} gateway add ${lib.escapeShellArg cfg.gateway.endpoint} \
              --local \
              --name ${lib.escapeShellArg cfg.gateway.name} \
              ${lib.optionalString cfg.gateway.insecure "--gateway-insecure"}
          fi
        '');
      };

      xdg.configFile =
        {
          "openshell/gateway.toml".source = gatewayConfig;
          "openshell/policy.yaml" = lib.mkIf (policyFile != null) {source = policyFile;};
        }
        # Mirror of the NixOS module's system-seeded registration: the CLI
        # reads the mTLS bundle only from the per-user config, so link the
        # metadata + bundle from /etc/openshell (out-of-store symlinks — the
        # targets are root-owned /etc files, and the CLI never rewrites them;
        # mutable per-user state like last_sandbox still lives in the real
        # directory next to these links).
        // lib.optionalAttrs (cfg.systemGateway != null) {
          "openshell/gateways/${cfg.systemGateway}/metadata.json".source =
            config.lib.file.mkOutOfStoreSymlink "/etc/openshell/gateways/${cfg.systemGateway}/metadata.json";
          "openshell/gateways/${cfg.systemGateway}/mtls/ca.crt".source =
            config.lib.file.mkOutOfStoreSymlink "/etc/openshell/gateways/${cfg.systemGateway}/mtls/ca.crt";
          "openshell/gateways/${cfg.systemGateway}/mtls/tls.crt".source =
            config.lib.file.mkOutOfStoreSymlink "/etc/openshell/gateways/${cfg.systemGateway}/mtls/tls.crt";
          "openshell/gateways/${cfg.systemGateway}/mtls/tls.key".source =
            config.lib.file.mkOutOfStoreSymlink "/etc/openshell/gateways/${cfg.systemGateway}/mtls/tls.key";
          # A real file (not a symlink into root-owned /etc) so
          # `openshell gateway select` keeps working for the user; it is
          # reset to the system gateway on each home activation.
          "openshell/active_gateway".text = cfg.systemGateway;
        };
    };
  };
}
