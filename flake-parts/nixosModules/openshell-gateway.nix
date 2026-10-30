_: {
  # ------ NixOS Modules ------ #
  # Single-machine OpenShell gateway with TLS + mTLS, backed by clan vars
  # generators, plus the CLI configured to use the local gateway.
  #
  # Exported as flake.nixosModules.openshell-gateway so other flakes can
  # consume it; it assumes the consuming machines provide pkgs.openshell,
  # pkgs.openshell-gateway and (for computeDriver "vm") pkgs.openshell-driver-vm
  # via an overlay (reference packaging: external-systems/home).
  #
  # Topology: openshell-gateway (systemd, dedicated `openshell` user) spawns
  # the compute driver subprocess (VM/libkrun by default), which boots
  # per-sandbox microVMs whose host-side supervisor dials back over
  # https://127.0.0.1:<port>. The gateway requires client certificates
  # (mTLS) and mints gateway/sandbox JWTs from generated Ed25519 keys — the
  # VM driver refuses to launch sandboxes without launch authentication.
  #
  # Secrets (clan vars generators, provisionSecrets = true):
  #   openshell-local-ca            (shared) instance CA; ca.key never deployed
  #   openshell-local-gateway-tls   gateway server cert/key (SANs below)
  #   openshell-local-jwt           Ed25519 gateway JWT keys
  #   openshell-local-client-tls    machine-wide CLI + supervisor identity
  # Run `clan vars generate <machine>` after enabling. Set provisionCerts =
  # false and the *File options to bring external material instead.
  #
  # Ownership (hard-won — clan vars deployment model): sops-nix deploys
  # secret files root:root 0400 under /run/secrets.d/<gen>/vars/... whose
  # directories are root:keys 0710. A service user therefore needs (a)
  # membership in the `keys` group for directory traversal and (b) ownership
  # (or group+mode) on the files it reads — both declared per generator
  # file via owner/group/mode, which clan maps onto sops.secrets. The
  # machine-wide client key additionally has to be readable by every CLI
  # user; it is deployed world-readable (0644 — the documented machine-wide
  # identity threat model) to /etc/openshell/.../tls.key by overriding the
  # path on the clan-mapped sops secret, so the gateway's guest identity
  # and all CLI users share a single deployment (no diverging copies).
  flake.nixosModules.openshell-gateway = {
    config,
    options,
    lib,
    pkgs,
    ...
  }: let
    cfg = config.hostSpec.services.openshell.gateway;

    tomlFormat = pkgs.formats.toml {};

    hostName = config.networking.hostName;
    fqdn =
      if config.networking.domain != null
      then "${hostName}.${config.networking.domain}"
      else null;

    # TLS SANs for the gateway certificate: the loopback names the gateway,
    # supervisor and CLI actually dial.
    sanList = lib.concatStringsSep "," (
      ["DNS:localhost" "DNS:${hostName}" "IP:127.0.0.1"]
      ++ lib.optional (fqdn != null) "DNS:${fqdn}"
    );

    # Resolve a secret file: explicit setting wins; otherwise the clan vars
    # generator output (only touched when provisionSecrets = true, so
    # machines/tests with external material never reference clan).
    fileFor = settingName: generator: file:
      if cfg.${settingName} != null
      then cfg.${settingName}
      else if cfg.provisionSecrets
      then config.clan.core.vars.generators.${generator}.files.${file}.path
      else throw "hostSpec.services.openshell.gateway: ${settingName} must be set when provisionSecrets = false";

    gatewayConfigFile = tomlFormat.generate "openshell-gateway.toml" {
      openshell = {
        version = 2;

        gateway = {
          inherit (cfg) name;
          log_level = cfg.logLevel;
          bind_address = "${cfg.bindAddress}:${toString cfg.port}";
          health_bind_address = "127.0.0.1:${toString cfg.healthPort}";
          compute_driver = cfg.computeDriver;

          tls = {
            cert_path = fileFor "gatewayCertFile" "openshell-local-gateway-tls" "gateway.crt";
            key_path = fileFor "gatewayKeyFile" "openshell-local-gateway-tls" "gateway.key";
            client_ca_path = fileFor "caFile" "openshell-local-ca" "ca.crt";
          };
          # Map verified client certificates to local user principals: the
          # machine-wide client cert is the only identity this gateway serves.
          mtls_auth.enabled = true;

          # The compute driver's supervisor side authenticates to the
          # gateway with the machine's client identity (required when TLS
          # is enabled).
          guest_tls_ca = fileFor "caFile" "openshell-local-ca" "ca.crt";
          guest_tls_cert = fileFor "clientCertFile" "openshell-local-client-tls" "client.crt";
          guest_tls_key = fileFor "clientKeyFile" "openshell-local-client-tls" "client.key";

          gateway_jwt = {
            signing_key_path = fileFor "jwtSigningKeyFile" "openshell-local-jwt" "signing.pem";
            public_key_path = fileFor "jwtPublicKeyFile" "openshell-local-jwt" "public.pem";
            kid_path = fileFor "jwtKidFile" "openshell-local-jwt" "kid";
            gateway_id = cfg.name;
          };

          auth.allow_unauthenticated_users = false;
        };

        drivers =
          if cfg.computeDriver == "vm"
          then {
            vm = {
              grpc_endpoint = "https://127.0.0.1:${toString cfg.port}";
              state_dir = "/var/lib/openshell/vm";
              driver_dir = "${pkgs.openshell-driver-vm}/libexec/openshell";
              default_image = cfg.vm.defaultImage;
              bootstrap_image = cfg.vm.bootstrapImage;
              inherit (cfg.vm) vcpus;
              mem_mib = cfg.vm.memMiB;
              overlay_disk_mib = cfg.vm.overlayDiskMiB;
              krun_log_level = cfg.vm.krunLogLevel;
            };
          }
          else {
            docker = {
              grpc_endpoint = "https://127.0.0.1:${toString cfg.port}";
              socket_path = "/var/run/docker.sock";
              default_image = cfg.vm.defaultImage;
              image_pull_policy = "if_not_present";
              sandbox_label = "openshell";
            };
          };
      };
    };

    clientCa = fileFor "caFile" "openshell-local-ca" "ca.crt";
    clientCert = fileFor "clientCertFile" "openshell-local-client-tls" "client.crt";
    clientKey = fileFor "clientKeyFile" "openshell-local-client-tls" "client.key";
  in {
    options.hostSpec.services.openshell.gateway = {
      enable = lib.mkEnableOption "a local OpenShell gateway (TLS + mTLS) with the CLI configured to use it";

      name = lib.mkOption {
        type = lib.types.str;
        default = "local";
        description = "Gateway installation name and system CLI registration name.";
      };

      port = lib.mkOption {
        type = lib.types.port;
        default = 17670;
        description = "Gateway listener port.";
      };

      healthPort = lib.mkOption {
        type = lib.types.port;
        default = 17671;
        description = "Health endpoint port (loopback only).";
      };

      logLevel = lib.mkOption {
        type = lib.types.str;
        default = "info";
        description = "Gateway log level.";
      };

      computeDriver = lib.mkOption {
        type = lib.types.enum ["vm" "docker"];
        default = "vm";
        description = ''
          Compute driver backing the gateway. "vm" runs each sandbox in its
          own libkrun microVM (requires /dev/kvm); "docker" runs sandbox
          containers on the host.
        '';
      };

      bindAddress = lib.mkOption {
        type = lib.types.str;
        default = "127.0.0.1";
        description = ''
          Bind address of the gateway listener. Defaults to loopback: the
          gateway is local-only by design: any remote client should reach it
          through an operator-managed reverse proxy instead.
        '';
      };

      provisionSecrets = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Create the CA, gateway certificate, machine client certificate and
          JWT keys with clan vars generators (requires `clan vars generate
          <machine>` after enabling). Disable to supply external material via
          the *File options below (used by vm tests).
        '';
      };

      gatewayCertFile = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "External gateway certificate (chain) PEM. Required when provisionSecrets = false.";
      };
      gatewayKeyFile = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "External gateway private key PEM. Required when provisionSecrets = false.";
      };
      caFile = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "External CA certificate PEM (also the client-cert CA). Required when provisionSecrets = false.";
      };
      clientCertFile = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "External machine client certificate PEM (also the supervisor guest identity). Required when provisionSecrets = false.";
      };
      clientKeyFile = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "External machine client key PEM. Required when provisionSecrets = false.";
      };
      jwtSigningKeyFile = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "External Ed25519 JWT signing key PEM. Required when provisionSecrets = false.";
      };
      jwtPublicKeyFile = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "External Ed25519 JWT public key PEM. Required when provisionSecrets = false.";
      };
      jwtKidFile = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "External JWT key-id file. Required when provisionSecrets = false.";
      };

      vm = {
        vcpus = lib.mkOption {
          type = lib.types.ints.positive;
          default = 4;
          description = ''
            vCPUs per sandbox microVM. Driver-wide default: the VM driver
            ignores per-sandbox CPU requests (`openshell sandbox create
            --cpu` is accepted but has no effect), so this is the only knob.
            GPU sandboxes use the driver's gpu_vcpus default (4) instead.
          '';
        };
        memMiB = lib.mkOption {
          type = lib.types.ints.positive;
          default = 8192;
          description = ''
            Memory per sandbox microVM, in MiB. Driver-wide default: the VM
            driver ignores per-sandbox memory requests (`--memory` is
            accepted but has no effect), so this is the only knob. GPU
            sandboxes use the driver's gpu_mem_mib default (8192) instead.
          '';
        };
        overlayDiskMiB = lib.mkOption {
          type = lib.types.ints.positive;
          default = 32768;
          description = ''
            Sparse writable overlay disk per sandbox, in MiB. This is the
            sandbox's entire writable filesystem (everything outside tmpfs
            mounts like /tmp and /dev/shm), so it caps /, /sandbox, /home
            and /nix growth. 32 GiB gives ample room for image-adjacent
            fetches (nix store additions, uv/python environments, clone
            worktrees) before the overlay fills. Sparse: only consumed
            blocks use host disk.
            Driver-wide default — there is no per-sandbox disk flag, and
            sandboxes created before a size change keep their existing
            overlay (new sizes apply to newly created sandboxes; the driver
            caches one sparse template per size under state_dir).
          '';
        };
        krunLogLevel = lib.mkOption {
          type = lib.types.ints.between 0 5;
          default = 1;
          description = "libkrun verbosity (0-5).";
        };
        defaultImage = lib.mkOption {
          type = lib.types.str;
          default = "nvcr.io/nvidia/base/ubuntu:24.04";
          description = "Sandbox image used when a create request omits one.";
        };
        bootstrapImage = lib.mkOption {
          type = lib.types.str;
          default = "nvcr.io/nvidia/base/ubuntu:24.04";
          description = "Immutable bootstrap root disk image for the VM runtime.";
        };
      };
    };

    config = lib.mkIf cfg.enable (lib.mkMerge [
      {
        assertions = [
          {
            assertion = cfg.computeDriver == "docker" || config.programs.nix-ld.enable;
            message = "hostSpec.services.openshell.gateway: programs.nix-ld must be enabled for computeDriver \"vm\" — the driver extracts its embedded (dynamically linked gnu) host supervisor into the state dir and executes it on the host.";
          }
          {
            assertion = cfg.computeDriver == "vm" || config.virtualisation.docker.enable;
            message = "hostSpec.services.openshell.gateway: computeDriver \"docker\" requires virtualisation.docker.enable on the machine.";
          }
        ];

        # Both vendor lines; the wrong-vendor one is inert. /dev/kvm access
        # comes via the kvm group.
        boot.kernelModules = lib.mkIf (cfg.computeDriver == "vm") (lib.mkDefault ["kvm-amd" "kvm-intel"]);

        clan.core.vars.generators = lib.mkIf cfg.provisionSecrets {
          # mTLS CA. ca.key is never deployed to any machine (deploy = false):
          # it only exists to sign the leaf certs during `clan vars generate`
          # on the operator machine. Shared so every machine's local gateway
          # trusts the same client CA.
          openshell-local-ca = {
            share = true;
            files."ca.crt".secret = false;
            files."ca.key" = {deploy = false;};
            runtimeInputs = [pkgs.openssl];
            script = ''
              openssl req -x509 -newkey rsa:3072 -nodes \
                -keyout "$out"/ca.key -out "$out"/ca.crt \
                -days 3650 -subj "/CN=openshell-local-ca" \
                -addext "basicConstraints=critical,CA:TRUE,pathlen:1" \
                -addext "keyUsage=critical,keyCertSign,cRLSign"
            '';
          };

          # Gateway server identity.
          openshell-local-gateway-tls = {
            files."gateway.crt".secret = false;
            # Owned outright by the service user: `keys` group membership
            # (users.users.openshell) grants traversal of the 0710
            # /run/secrets directories, ownership the read.
            files."gateway.key" = {
              owner = "openshell";
              group = "openshell";
              mode = "0400";
              restartUnits = ["openshell-gateway.service"];
            };
            dependencies = ["openshell-local-ca"];
            runtimeInputs = [pkgs.openssl];
            script = ''
              work=$(mktemp -d)
              openssl req -newkey rsa:2048 -nodes \
                -keyout "$out"/gateway.key -out "$work/gateway.csr" \
                -subj "/CN=openshell-gateway-${hostName}"
              printf 'subjectAltName=%s\nextendedKeyUsage=serverAuth,clientAuth\n' '${sanList}' > "$work/ext"
              openssl x509 -req -in "$work/gateway.csr" \
                -CA "$in"/openshell-local-ca/ca.crt -CAkey "$in"/openshell-local-ca/ca.key \
                -CAcreateserial -out "$out"/gateway.crt \
                -days 825 -sha256 -extfile "$work/ext"
            '';
          };

          # Machine-wide CLI identity and the gateway's guest (supervisor)
          # identity. Deployed world-readable by sops-nix at /etc/openshell/
          # .../tls.key via the sops.secrets path override below — both
          # consumers read that one file.
          openshell-local-client-tls = {
            files."client.crt".secret = false;
            files."client.key" = {
              mode = "0644";
              restartUnits = ["openshell-gateway.service"];
            };
            dependencies = ["openshell-local-ca"];
            runtimeInputs = [pkgs.openssl];
            script = ''
              work=$(mktemp -d)
              openssl req -newkey rsa:2048 -nodes \
                -keyout "$out"/client.key -out "$work/client.csr" \
                -subj "/CN=openshell-client-${hostName}"
              printf 'extendedKeyUsage=clientAuth\n' > "$work/ext"
              openssl x509 -req -in "$work/client.csr" \
                -CA "$in"/openshell-local-ca/ca.crt -CAkey "$in"/openshell-local-ca/ca.key \
                -CAcreateserial -out "$out"/client.crt \
                -days 825 -sha256 -extfile "$work/ext"
            '';
          };

          # Ed25519 gateway JWT keys: the VM driver requires launch-scoped
          # authentication minted from these.
          openshell-local-jwt = {
            files = {
              # Same ownership model as gateway.key above.
              "signing.pem" = {
                owner = "openshell";
                group = "openshell";
                mode = "0400";
                restartUnits = ["openshell-gateway.service"];
              };
              "public.pem".secret = false;
              "kid".secret = false;
            };
            runtimeInputs = [pkgs.openssl];
            script = ''
              openssl genpkey -algorithm Ed25519 -out "$out"/signing.pem
              openssl pkey -in "$out"/signing.pem -pubout -out "$out"/public.pem
              openssl rand -hex 8 > "$out"/kid
            '';
          };
        };

        # Materialize the machine-wide client key as a real file in the
        # system registry by overriding the path on the sops secret clan
        # vars already maps. A single deployment serves the gateway's
        # guest identity (the generator file's .path follows this
        # override, so the TOML picks it up through fileFor) and every CLI
        # user (via /etc/openshell directly or the home-manager mirror).
        # environment.etc cannot do this: it would only symlink the
        # root:root 0400 /run/secrets target, which non-root users cannot
        # read, and its mode is ignored on symlinks.
        # The guard mirrors the filter in clan-core's generators-to-sops
        # (the secret only exists once the var has been generated and
        # committed); defining it early would create a bogus entry
        # pointing at the dummy sopsFile. Lazy `&&` keeps the clan option
        # access inside the condition unevaluated for provisionSecrets =
        # false consumers (vm test, external flakes).
        sops.secrets = let
          clientKeySecret = "vars/per-machine/${config.clan.core.settings.machine.name}/openshell-local-client-tls/client.key";
        in
          lib.mkIf (
            cfg.provisionSecrets
            && builtins.pathExists "${config.clan.core.settings.directory}/${clientKeySecret}/secret"
          ) {
            ${clientKeySecret} = {
              path = "/etc/openshell/gateways/${cfg.name}/mtls/tls.key";
            };
          };

        users.users.openshell = {
          isSystemUser = true;
          group = "openshell";
          # kvm: /dev/kvm for the libkrun driver. keys: sops-nix creates the
          # /run/secrets.d directory chain root:keys 0710, so this is what
          # lets the service reach its owner-tagged secret files.
          # docker: lets the VM driver resolve sandbox images from the host
          # container engine's local image store (e.g. dockerTools images
          # loaded with `docker load`) before falling back to a registry
          # pull.
          extraGroups = ["kvm" "keys" "docker"];
          home = "/var/lib/openshell";
          description = "OpenShell gateway / compute driver service user";
        };
        users.groups.openshell = {};

        systemd.services.openshell-gateway = {
          description = "OpenShell gateway (${cfg.computeDriver} compute driver)";
          documentation = ["https://docs.nvidia.com/openshell/"];
          wantedBy = ["multi-user.target"];
          after = ["network.target"];

          path = [pkgs.e2fsprogs];

          environment = {
            # database_url is env-only and must not appear in the TOML file.
            OPENSHELL_DB_URL = "sqlite:/var/lib/openshell/gateway.db?mode=rwc";
            XDG_STATE_HOME = "/var/lib/openshell";
            HOME = "/var/lib/openshell";
          };

          serviceConfig = {
            Type = "simple";
            User = "openshell";
            Group = "openshell";
            StateDirectory = "openshell";
            StateDirectoryMode = "0750";
            ExecStart = "${pkgs.openshell-gateway}/bin/openshell-gateway --config ${gatewayConfigFile}";
            Restart = "on-failure";
            RestartSec = 5;
            # Image pulls and rootfs preparations can be slow.
            TimeoutStartSec = 300;
            NoNewPrivileges = true;
            ProtectSystem = "strict";
            ProtectHome = true;
            PrivateTmp = true;
            ReadWritePaths = ["/var/lib/openshell"];
          };
        };

        # CLI for all users, configured to default to the local gateway via
        # the system registry (/etc/openshell; per-user registrations shadow
        # it).
        environment.systemPackages = [pkgs.openshell];
        environment.etc = {
          "openshell/active_gateway".text = cfg.name;
          "openshell/gateways/${cfg.name}/metadata.json".text = builtins.toJSON {
            inherit (cfg) name;
            gateway_endpoint = "https://127.0.0.1:${toString cfg.port}";
            is_remote = false;
            gateway_port = cfg.port;
            auth_mode = "mtls";
          };
          "openshell/gateways/${cfg.name}/mtls/ca.crt".source = clientCa;
          "openshell/gateways/${cfg.name}/mtls/tls.crt".source = clientCert;
          # Machine-wide identity by design (no per-user identities). With
          # provisionSecrets, sops-nix materializes this file (sops.secrets
          # override above); only external material (provisionSecrets =
          # false, e.g. the vm test) needs the etc link.
          "openshell/gateways/${cfg.name}/mtls/tls.key" = lib.mkIf (!cfg.provisionSecrets) {
            source = clientKey;
            mode = "0644";
          };
        };
      }
      # Propagate the system gateway into every home-manager user that
      # enables the openshell CLI: they need no openshell settings at all —
      # `homeSpec.programs.openshell.enable = true` is enough to get the
      # mTLS mirror (systemGateway) and the matching name/endpoint. All
      # values are mkDefault, so per-user configuration still wins. Guarded
      # so the module also evaluates on machines without home-manager.
      (lib.optionalAttrs (options ? home-manager.sharedModules) {
        home-manager.sharedModules = [
          ({config, ...}: {
            homeSpec.programs.openshell = lib.mkIf config.homeSpec.programs.openshell.enable {
              systemGateway = lib.mkDefault cfg.name;
              gateway = {
                name = lib.mkDefault cfg.name;
                endpoint = lib.mkDefault "https://127.0.0.1:${toString cfg.port}";
              };
            };
          })
        ];
      })
    ]);
  };
}
