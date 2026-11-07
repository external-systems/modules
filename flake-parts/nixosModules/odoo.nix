_: {
  # ------ NixOS Modules ------ #
  # Odoo for local evaluation: the nixpkgs services.odoo (PostgreSQL over
  # the unix socket, peer auth, so no database password exists) behind
  # nginx with HTTPS at https://odoo.localhost, reachable from this
  # machine only.
  #
  # Local only: Odoo binds 127.0.0.1 (HTTP 8069 and the gevent websocket
  # port 8072), nginx listens on loopback only, no firewall port is opened
  # and PostgreSQL keeps its default (no TCP listener).
  #
  # Package: pkgs.odoo19 as fixed by external-systems/pkgs overlays.odoo
  # (part of overlays.default). Plain nixpkgs' odoo19 refuses to evaluate
  # (insecure pypdf2), so consumers apply the org overlay or set package.
  #
  # Secrets (clan vars generators, provisionSecrets = true):
  #   odoo-local-ca   CA for the HTTPS certificate; name-constrained to the
  #                   domain, ca.key never deployed, ca.crt trusted system
  #                   wide and by Firefox
  #   odoo-tls        nginx server certificate/key for the domain
  #   odoo-passwords  admin-password (web login of user "admin") and
  #                   master-password (Odoo's admin_passwd)
  # Run `clan vars generate <machine>` after enabling. The web login is
  # `admin` / `clan vars get <machine> odoo-passwords/admin-password`.
  #
  # Neither password can live in services.odoo.settings: that ini is
  # generated into the world-readable store. Both reach the service as
  # systemd credentials instead: the master password is merged into a
  # 0600 copy of the ini under /run/odoo (ODOO_RC points there); the admin
  # password is written into the database once after init and again only
  # when the secret changes, so a password changed in the UI survives
  # restarts.
  flake.nixosModules.odoo = {
    config,
    lib,
    pkgs,
    ...
  }: let
    cfg = config.hostSpec.services.odoo;
    odooCfg = config.services.odoo;

    # Resolve a secret file: explicit setting wins; otherwise the clan vars
    # generator output (only touched when provisionSecrets = true, so
    # machines/tests with external material never reference clan).
    fileFor = settingName: generator: file:
      if cfg.${settingName} != null
      then cfg.${settingName}
      else if cfg.provisionSecrets
      then config.clan.core.vars.generators.${generator}.files.${file}.path
      else throw "hostSpec.services.odoo: ${settingName} must be set when provisionSecrets = false";

    caFile = fileFor "caFile" "odoo-local-ca" "ca.crt";

    # The same ini the nixpkgs module generates; services.odoo does not
    # expose its file.
    storeConfig = (pkgs.formats.ini {}).generate "odoo.cfg" odooCfg.settings;
    runtimeConfig = "/run/odoo/odoo.cfg";
    dataDir = odooCfg.settings.options.data_dir;

    # Copy the store ini to /run and add admin_passwd under [options].
    # awk reads the password from the environment, so no character in it
    # is interpreted.
    writeRuntimeConfig = pkgs.writeShellScript "odoo-runtime-config" ''
      set -euo pipefail
      umask 077
      ODOO_MASTER_PASSWORD=$(< "$CREDENTIALS_DIRECTORY/master-password") \
        ${lib.getExe pkgs.gawk} '{print} /^\[options\]$/ {print "admin_passwd = " ENVIRON["ODOO_MASTER_PASSWORD"]}' \
        ${storeConfig} > ${runtimeConfig}
    '';

    setAdminPassword = pkgs.writeText "odoo-set-admin-password.py" ''
      import os

      with open(os.path.join(os.environ["CREDENTIALS_DIRECTORY"], "admin-password")) as f:
          password = f.read().strip()
      env.ref("base.user_admin").password = password
      env.cr.commit()
    '';

    # Runs after the nixpkgs auto-init, as the odoo user. The marker holds
    # the hash of the password last applied.
    applyAdminPassword = pkgs.writeShellScript "odoo-admin-password" ''
      set -euo pipefail
      marker=${dataDir}/.admin-password.sha256
      want=$(${pkgs.coreutils}/bin/sha256sum < "$CREDENTIALS_DIRECTORY/admin-password" | ${pkgs.coreutils}/bin/cut -d' ' -f1)
      if [ "$(cat "$marker" 2>/dev/null || true)" != "$want" ]; then
        echo "pre-start: setting the admin password"
        ${odooCfg.package}/bin/odoo shell --database=odoo --no-http < ${setAdminPassword}
        echo "$want" > "$marker"
      fi
    '';

    loopback = ["127.0.0.1"] ++ lib.optional config.networking.enableIPv6 "[::1]";
  in {
    options.hostSpec.services.odoo = {
      enable = lib.mkEnableOption "Odoo for local evaluation: PostgreSQL, nginx with HTTPS, reachable from this machine only";

      package = lib.mkOption {
        type = lib.types.package;
        default = pkgs.odoo19;
        defaultText = lib.literalExpression "pkgs.odoo19";
        description = ''
          Odoo package. The default needs external-systems/pkgs
          overlays.odoo (in overlays.default): nixpkgs' own odoo19 does not
          evaluate.
        '';
      };

      domain = lib.mkOption {
        type = lib.types.str;
        default = "odoo.localhost";
        description = ''
          Hostname Odoo is served at over HTTPS. It resolves to loopback
          through networking.hosts and is the only name the certificate
          (and the name-constrained CA) is valid for.
        '';
      };

      demoData = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Load Odoo's demo data when the database is first created. Only
          applies to the first start: the database is never re-initialised.
        '';
      };

      workers = lib.mkOption {
        type = lib.types.ints.positive;
        default = 2;
        description = ''
          Odoo HTTP worker processes. At least 1: the multi-process server
          is what starts the gevent websocket service (port 8072) that
          Discuss and live updates need.
        '';
      };

      addons = lib.mkOption {
        type = lib.types.listOf lib.types.package;
        default = [];
        description = "Extra Odoo addon packages (services.odoo.addons).";
      };

      trustCertificate = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Trust the CA system wide (security.pki) and in Firefox (enterprise
          policy Certificates.Install), so https://<domain> opens without a
          warning. Other browsers need the CA imported by hand.
        '';
      };

      provisionSecrets = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Create the CA, the HTTPS certificate and both passwords with clan
          vars generators (requires `clan vars generate <machine>` after
          enabling). Disable to supply external material via the *File
          options below (used by VM tests).
        '';
      };

      caFile = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "External CA certificate PEM. Required when provisionSecrets = false.";
      };
      tlsCertFile = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "External certificate PEM for the domain. Required when provisionSecrets = false.";
      };
      tlsKeyFile = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "External private key PEM for the domain. Required when provisionSecrets = false.";
      };
      adminPasswordFile = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "External file holding the web login password of user admin. Required when provisionSecrets = false.";
      };
      masterPasswordFile = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "External file holding Odoo's master password (admin_passwd). Required when provisionSecrets = false.";
      };
    };

    config = lib.mkIf cfg.enable {
      clan.core.vars.generators = lib.mkIf cfg.provisionSecrets {
        # ca.key is never deployed (deploy = false): it only signs the
        # server certificate during `clan vars generate`. The name
        # constraint limits the trust security.pki grants this CA to the
        # one domain, even if the key leaked.
        odoo-local-ca = {
          files = {
            "ca.crt".secret = false;
            "ca.key".deploy = false;
          };
          validation.domain = cfg.domain;
          runtimeInputs = [pkgs.openssl];
          script = ''
            openssl req -x509 -newkey rsa:3072 -nodes \
              -keyout "$out"/ca.key -out "$out"/ca.crt \
              -days 3650 -subj "/CN=odoo-local-ca" \
              -addext "basicConstraints=critical,CA:TRUE,pathlen:0" \
              -addext "keyUsage=critical,keyCertSign,cRLSign" \
              -addext "nameConstraints=critical,permitted;DNS:${cfg.domain}"
          '';
        };

        # nginx reads the key as a systemd credential, so it stays root-only.
        odoo-tls = {
          files = {
            "tls.crt".secret = false;
            "tls.key".restartUnits = ["nginx.service"];
          };
          dependencies = ["odoo-local-ca"];
          validation.domain = cfg.domain;
          runtimeInputs = [pkgs.openssl];
          script = ''
            work=$(mktemp -d)
            openssl req -newkey rsa:2048 -nodes \
              -keyout "$out"/tls.key -out "$work/tls.csr" \
              -subj "/CN=${cfg.domain}"
            printf 'subjectAltName=DNS:%s\nextendedKeyUsage=serverAuth\nbasicConstraints=critical,CA:FALSE\n' '${cfg.domain}' > "$work/ext"
            openssl x509 -req -in "$work/tls.csr" \
              -CA "$in"/odoo-local-ca/ca.crt -CAkey "$in"/odoo-local-ca/ca.key \
              -CAcreateserial -out "$out"/tls.crt \
              -days 825 -sha256 -extfile "$work/ext"
          '';
        };

        odoo-passwords = {
          files = {
            admin-password.restartUnits = ["odoo.service"];
            master-password.restartUnits = ["odoo.service"];
          };
          runtimeInputs = [pkgs.openssl];
          script = ''
            openssl rand -hex 16 | tr -d '\n' > "$out"/admin-password
            openssl rand -hex 32 | tr -d '\n' > "$out"/master-password
          '';
        };
      };

      services.odoo = {
        enable = true;
        inherit (cfg) package addons domain;
        autoInit = true;
        autoInitExtraFlags = lib.optional cfg.demoData "--with-demo";
        settings.options = {
          inherit (cfg) workers;
          http_interface = "127.0.0.1";
          # One database, always the one the module created.
          db_name = "odoo";
          dbfilter = "^odoo$";
        };
      };

      systemd.services.odoo.serviceConfig = {
        LoadCredential = [
          "admin-password:${fileFor "adminPasswordFile" "odoo-passwords" "admin-password"}"
          "master-password:${fileFor "masterPasswordFile" "odoo-passwords" "master-password"}"
        ];
        RuntimeDirectory = "odoo";
        RuntimeDirectoryMode = "0700";
        # After the nixpkgs Environment entry: the later ODOO_RC wins.
        Environment = lib.mkAfter ["ODOO_RC=${runtimeConfig}"];
        # The runtime config before the nixpkgs pre-start (auto-init reads
        # it too), the admin password after it.
        ExecStartPre = lib.mkMerge [
          (lib.mkBefore ["${writeRuntimeConfig}"])
          (lib.mkAfter ["${applyAdminPassword}"])
        ];
        # The first start creates the database (with demo data, minutes);
        # systemd's 90 s default would kill it.
        TimeoutStartSec = lib.mkDefault "15min";
      };

      services.nginx = {
        enable = true;
        recommendedTlsSettings = lib.mkDefault true;
        virtualHosts.${cfg.domain} = {
          forceSSL = true;
          listenAddresses = loopback;
          sslCertificate = fileFor "tlsCertFile" "odoo-tls" "tls.crt";
          sslCertificateKey = "/run/credentials/nginx.service/odoo-tls.key";
          # The nixpkgs vhost proxies /websocket without the upgrade
          # headers. Any proxy_set_header in a location drops the
          # server-level X-Forwarded-* the nixpkgs vhost sets, so both
          # locations carry the full header set themselves.
          locations = {
            "/".recommendedProxySettings = true;
            "/websocket" = {
              proxyWebsockets = true;
              recommendedProxySettings = true;
            };
          };
        };
      };
      systemd.services.nginx.serviceConfig.LoadCredential = [
        "odoo-tls.key:${fileFor "tlsKeyFile" "odoo-tls" "tls.key"}"
      ];

      networking.hosts =
        {"127.0.0.1" = [cfg.domain];}
        // lib.optionalAttrs config.networking.enableIPv6 {"::1" = [cfg.domain];};

      security.pki.certificateFiles = lib.mkIf cfg.trustCertificate [caFile];

      # Firefox reads /etc/firefox/policies/policies.json. Through
      # programs.firefox when the machine uses it, otherwise written here.
      # This file replaces a policies.json bundled in a wrapped Firefox
      # (home-manager programs.firefox.policies).
      programs.firefox.policies = lib.mkIf (cfg.trustCertificate && config.programs.firefox.enable) {
        Certificates.Install = [caFile];
      };
      environment.etc."firefox/policies/policies.json" = lib.mkIf (cfg.trustCertificate && !config.programs.firefox.enable) {
        text = builtins.toJSON {policies.Certificates.Install = [caFile];};
      };
    };
  };
}
