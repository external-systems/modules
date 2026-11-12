_: {
  # ------ NixOS Modules ------ #
  # Local Odoo instances for testing: 0..n independent Odoo servers on one
  # machine, each with its own PostgreSQL database and state, behind nginx
  # with trusted HTTPS at https://<name>.<baseDomain> (default
  # https://<name>.odoo.localhost), reachable from this machine only.
  # https://<baseDomain> is an index page linking every instance.
  #
  # Local only: every Odoo binds 127.0.0.1 (HTTP port and gevent websocket
  # port = port + 1), nginx listens on loopback only, no firewall port is
  # opened and PostgreSQL keeps its default (unix socket, peer auth, no
  # TCP listener, no database password).
  #
  # Not the nixpkgs services.odoo: that module runs exactly one instance
  # (one unit, one database named odoo, ports 8069/8072 fixed in its nginx
  # upstreams). The units here follow it (static system user plus
  # DynamicUser sandboxing, state under /var/lib/private, first-start
  # init behind a marker file) once per instance.
  #
  # Per instance <name>:
  #   unit, system user, PostgreSQL role and database   odoo-<name>
  #   state (data_dir: filestore, sessions, markers)     /var/lib/private/odoo-<name>
  #   runtime config (0600, holds the master password)   /run/odoo-<name>/odoo.cfg
  #
  # odoo-reset NAME... | --all   back to a freshly created database (with
  #                              or without demo data, per instance)
  # odoo-purge [NAME...]         list or delete the database, role and
  #                              state of instances no longer configured
  #
  # Package: pkgs.odoo19 as fixed by external-systems/pkgs overlays.odoo
  # (part of overlays.default). Plain nixpkgs' odoo19 refuses to evaluate
  # (insecure pypdf2), so consumers apply the org overlay or set package.
  #
  # Secrets (clan vars generators, provisionSecrets = true), shared by
  # every instance so adding one never needs `clan vars generate`:
  #   odoo-local-ca   CA for HTTPS; name-constrained to baseDomain and its
  #                   subdomains, ca.key never deployed, ca.crt trusted
  #                   system wide and by Firefox
  #   odoo-tls        one nginx certificate for baseDomain and *.baseDomain
  #   odoo-passwords  admin-password (web login of user "admin") and
  #                   master-password (Odoo's admin_passwd)
  # Run `clan vars generate <machine>` after enabling. The web login is
  # `admin` / `clan vars get <machine> odoo-passwords/admin-password`.
  #
  # Neither password can live in the Odoo config in the store (world
  # readable). Both reach the units as systemd credentials: the master
  # password is merged into a 0600 copy of the config under /run (ODOO_RC
  # points there); the admin password is written into the database once
  # after init and again only when the secret changes, so a password
  # changed in the UI survives restarts.
  flake.nixosModules.odoo = {
    config,
    lib,
    pkgs,
    ...
  }: let
    cfg = config.hostSpec.services.odoo;
    iniFormat = pkgs.formats.ini {};
    postgresql = config.services.postgresql.package;

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
    tlsCertFile = fileFor "tlsCertFile" "odoo-tls" "tls.crt";
    tlsKeyCredential = "/run/credentials/nginx.service/odoo-tls.key";
    credentials = [
      "admin-password:${fileFor "adminPasswordFile" "odoo-passwords" "admin-password"}"
      "master-password:${fileFor "masterPasswordFile" "odoo-passwords" "master-password"}"
    ];

    loopback = ["127.0.0.1"] ++ lib.optional config.networking.enableIPv6 "[::1]";

    # Instances in name order; the index fixes the automatic port.
    instances = lib.imap0 mkInstance (lib.attrNames cfg.instances);
    hasInstances = instances != [];

    mkInstance = index: name: let
      icfg = cfg.instances.${name};
      unit = "odoo-${name}";
      stateDir = "/var/lib/private/${unit}";
      dataDir = "${stateDir}/data";
      httpPort =
        if icfg.port != null
        then icfg.port
        else cfg.basePort + 2 * index;
      geventPort = httpPort + 1;
      host = "${name}.${cfg.baseDomain}";

      storeConfig = iniFormat.generate "${unit}.cfg" {
        options =
          {
            inherit (icfg) workers;
            data_dir = dataDir;
            http_interface = "127.0.0.1";
            http_port = httpPort;
            gevent_port = geventPort;
            db_user = unit;
            # One database per instance, always the one created for it.
            db_name = unit;
            dbfilter = "^${unit}$";
            # The database manager stays off (as in nixpkgs).
            list_db = false;
            # Behind nginx: honour X-Forwarded-*.
            proxy_mode = true;
          }
          // lib.optionalAttrs (icfg.addons != []) {
            addons_path = lib.concatMapStringsSep "," toString icfg.addons;
          };
      };
      runtimeConfig = "/run/${unit}/odoo.cfg";

      # Copy the store config to /run and add admin_passwd under
      # [options]. awk reads the password from the environment, so no
      # character in it is interpreted.
      writeRuntimeConfig = pkgs.writeShellScript "${unit}-runtime-config" ''
        set -euo pipefail
        umask 077
        ODOO_MASTER_PASSWORD=$(< "$CREDENTIALS_DIRECTORY/master-password") \
          ${lib.getExe pkgs.gawk} '{print} /^\[options\]$/ {print "admin_passwd = " ENVIRON["ODOO_MASTER_PASSWORD"]}' \
          ${storeConfig} > ${runtimeConfig}
      '';

      # First start, and the first start after odoo-reset: the marker is
      # gone, so the (empty) database gets base and, if asked, demo data.
      initDatabase = pkgs.writeShellScript "${unit}-init" ''
        set -euo pipefail
        mkdir -p ${dataDir}
        marker=${dataDir}/.odoo.initialized
        if [ ! -e "$marker" ]; then
          echo "pre-start: creating database ${unit} (demo data: ${lib.boolToYesNo icfg.demoData})"
          ${icfg.package}/bin/odoo --init=base --database=${unit} --stop-after-init ${lib.optionalString icfg.demoData "--with-demo"}
          touch "$marker"
        fi
      '';

      setAdminPassword = pkgs.writeText "${unit}-set-admin-password.py" ''
        import os

        with open(os.path.join(os.environ["CREDENTIALS_DIRECTORY"], "admin-password")) as f:
            password = f.read().strip()
        env.ref("base.user_admin").password = password
        env.cr.commit()
      '';

      # After the init. The marker holds the hash of the password last
      # applied; odoo-reset deletes it with the rest of the state.
      applyAdminPassword = pkgs.writeShellScript "${unit}-admin-password" ''
        set -euo pipefail
        marker=${dataDir}/.admin-password.sha256
        want=$(${pkgs.coreutils}/bin/sha256sum < "$CREDENTIALS_DIRECTORY/admin-password" | ${pkgs.coreutils}/bin/cut -d' ' -f1)
        if [ "$(cat "$marker" 2>/dev/null || true)" != "$want" ]; then
          echo "pre-start: setting the admin password"
          ${icfg.package}/bin/odoo shell --database=${unit} --no-http < ${setAdminPassword}
          echo "$want" > "$marker"
        fi
      '';
    in {
      inherit name unit stateDir dataDir httpPort geventPort host;
      inherit (icfg) demoData;
      url = "https://${host}";

      service = {
        description = "Odoo instance ${name} (https://${host})";
        wantedBy = ["multi-user.target"];
        after = ["network.target" "postgresql.target"];
        requires = ["postgresql.target"];
        # pg_dump for Odoo's backups.
        path = [postgresql];
        environment.ODOO_RC = runtimeConfig;
        serviceConfig = {
          ExecStart = "${icfg.package}/bin/odoo";
          ExecStartPre = ["${writeRuntimeConfig}" "${initDatabase}" "${applyAdminPassword}"];
          # A static user (users.users below) with DynamicUser's sandbox,
          # as nixpkgs services.odoo does: state lands in /var/lib/private.
          DynamicUser = true;
          User = unit;
          Group = unit;
          StateDirectory = unit;
          RuntimeDirectory = unit;
          RuntimeDirectoryMode = "0700";
          LoadCredential = credentials;
          # The first start creates the database (with demo data,
          # minutes); systemd's 90 s default would kill it.
          TimeoutStartSec = "15min";
        };
      };

      virtualHost = {
        forceSSL = true;
        listenAddresses = loopback;
        sslCertificate = tlsCertFile;
        sslCertificateKey = tlsKeyCredential;
        extraConfig = ''
          proxy_read_timeout 720s;
          proxy_connect_timeout 720s;
          proxy_send_timeout 720s;
        '';
        locations = {
          "/" = {
            proxyPass = "http://127.0.0.1:${toString httpPort}";
            recommendedProxySettings = true;
            extraConfig = "proxy_redirect off;";
          };
          "/websocket" = {
            proxyPass = "http://127.0.0.1:${toString geventPort}";
            proxyWebsockets = true;
            recommendedProxySettings = true;
          };
        };
      };
    };

    # What odoo-reset and odoo-purge know about the configured instances.
    instancesJson = pkgs.writeText "odoo-instances.json" (builtins.toJSON (map (i: {
        inherit (i) name unit stateDir httpPort url demoData;
      })
      instances));

    indexPage = pkgs.writeTextDir "index.html" ''
      <!doctype html>
      <html lang="en">
        <head>
          <meta charset="utf-8">
          <title>Odoo instances</title>
          <style>
            body { font-family: Georgia, serif; background: #1f1e1d; color: #faf9f5; max-width: 40rem; margin: 3rem auto; padding: 0 1rem; }
            a { color: #e8a48a; }
            li { margin: 0.5rem 0; }
            .muted { color: #b0aea5; }
          </style>
        </head>
        <body>
          <h1>Odoo instances</h1>
          ${
        if hasInstances
        then ''
          <ul>
            ${lib.concatMapStringsSep "\n" (i: ''<li><a href="${i.url}/">${i.name}</a> <span class="muted">${
              if i.demoData
              then "demo data"
              else "no demo data"
            }</span></li>'')
          instances}
          </ul>''
        else "<p>No instances configured.</p>"
      }
          <p class="muted">Reset one: <code>sudo odoo-reset NAME</code>. List: <code>odoo-reset --list</code>.</p>
        </body>
      </html>
    '';

    commonTools = [pkgs.coreutils pkgs.findutils pkgs.gnused pkgs.jq pkgs.util-linux postgresql];

    odooReset = pkgs.writeShellApplication {
      name = "odoo-reset";
      runtimeInputs = commonTools ++ [pkgs.curl pkgs.systemd];
      text = ''
        instances=${instancesJson}

        usage() {
          cat <<'EOF'
        Usage: odoo-reset --list
               odoo-reset [--yes] NAME...
               odoo-reset [--yes] --all

        Resets Odoo instances to how they were when first enabled: stops the
        instance, drops and recreates its PostgreSQL database, empties its state
        (filestore, sessions, markers) and starts it again, which creates the
        database afresh with demo data or without it, as the instance is
        configured, and sets the provisioned admin password. Runs as root.

          --list   show the configured instances
          --all    reset every configured instance
          --yes    do not ask for confirmation (needed without a terminal)
        EOF
        }

        die() {
          echo "odoo-reset: $*" >&2
          exit 1
        }

        list() {
          if [ "$(jq length "$instances")" -eq 0 ]; then
            echo "No Odoo instances configured."
            return
          fi
          printf '%-16s %-40s %-14s %s\n' NAME URL DATA STATE
          jq -r '.[] | [.name, .url, (if .demoData then "demo" else "no-demo" end), .unit] | @tsv' "$instances" |
            while IFS=$'\t' read -r name url data unit; do
              state=$(systemctl is-active "$unit.service" || true)
              printf '%-16s %-40s %-14s %s\n' "$name" "$url" "$data" "$state"
            done
        }

        all=false
        yes=false
        selected=()
        while [ $# -gt 0 ]; do
          case "$1" in
            --list) list; exit 0 ;;
            --all) all=true ;;
            --yes | -y) yes=true ;;
            -h | --help) usage; exit 0 ;;
            -*) usage >&2; die "unknown option $1" ;;
            *) selected+=("$1") ;;
          esac
          shift
        done

        if $all; then
          [ ''${#selected[@]} -eq 0 ] || die "--all takes no names"
          mapfile -t selected < <(jq -r '.[].name' "$instances")
          if [ ''${#selected[@]} -eq 0 ]; then
            echo "No Odoo instances configured."
            exit 0
          fi
        fi
        if [ ''${#selected[@]} -eq 0 ]; then
          usage >&2
          exit 1
        fi
        for name in "''${selected[@]}"; do
          jq -e --arg n "$name" 'any(.[]; .name == $n)' "$instances" >/dev/null ||
            die "no instance named '$name' (odoo-reset --list shows them)"
        done
        [ "$(id -u)" -eq 0 ] || die "run as root (sudo odoo-reset ...)"

        if ! $yes; then
          [ -t 0 ] || die "not a terminal: pass --yes to reset without asking"
          echo "This deletes every record and file of: ''${selected[*]}"
          read -r -p "Type yes to reset: " answer
          [ "$answer" = yes ] || die "aborted, nothing changed"
        fi

        for name in "''${selected[@]}"; do
          info=$(jq -c --arg n "$name" '.[] | select(.name == $n)' "$instances")
          unit=$(jq -r .unit <<<"$info")
          stateDir=$(jq -r .stateDir <<<"$info")
          port=$(jq -r .httpPort <<<"$info")
          url=$(jq -r .url <<<"$info")
          demo=$(jq -r 'if .demoData then "with demo data" else "without demo data" end' <<<"$info")

          echo "==> $name: stopping $unit"
          systemctl stop "$unit.service"
          echo "==> $name: recreating database $unit"
          runuser -u postgres -- psql -v ON_ERROR_STOP=1 -q -d postgres \
            -c "DROP DATABASE IF EXISTS \"$unit\" WITH (FORCE)" \
            -c "CREATE DATABASE \"$unit\" OWNER \"$unit\""
          echo "==> $name: emptying $stateDir"
          if [ -d "$stateDir" ]; then
            find "$stateDir" -mindepth 1 -delete
          fi
          echo "==> $name: starting, creating the database $demo (takes minutes)"
          systemctl start "$unit.service"
          ready=false
          for _ in $(seq 300); do
            if curl -sf -o /dev/null "http://127.0.0.1:$port/web/login"; then
              ready=true
              break
            fi
            sleep 1
          done
          $ready || die "$name did not answer on port $port; see journalctl -u $unit"
          echo "==> $name: fresh at $url"
        done
      '';
    };

    odooPurge = pkgs.writeShellApplication {
      name = "odoo-purge";
      runtimeInputs = commonTools;
      text = ''
        instances=${instancesJson}

        usage() {
          cat <<'EOF'
        Usage: odoo-purge
               odoo-purge [--yes] NAME...

        Without names: lists what removed Odoo instances left behind (a
        database or role odoo-NAME, or a state folder /var/lib/private/odoo-NAME,
        for a NAME no longer configured). With names: deletes it. A configured
        instance is refused: odoo-reset empties those. Runs as root.

          --yes    do not ask for confirmation (needed without a terminal)
        EOF
        }

        die() {
          echo "odoo-purge: $*" >&2
          exit 1
        }

        sql() {
          runuser -u postgres -- psql -v ON_ERROR_STOP=1 -qtA -d postgres "$@"
        }

        configured() {
          jq -e --arg n "$1" 'any(.[]; .name == $n)' "$instances" >/dev/null
        }

        leftovers() {
          {
            sql -c "SELECT datname FROM pg_database WHERE datname LIKE 'odoo-%'"
            sql -c "SELECT rolname FROM pg_roles WHERE rolname LIKE 'odoo-%'"
            for dir in /var/lib/private/odoo-*; do
              if [ -e "$dir" ]; then basename "$dir"; fi
            done
          } | sed -n 's/^odoo-//p' | sort -u | while read -r name; do
            configured "$name" || echo "$name"
          done
        }

        yes=false
        selected=()
        while [ $# -gt 0 ]; do
          case "$1" in
            --yes | -y) yes=true ;;
            -h | --help) usage; exit 0 ;;
            -*) usage >&2; die "unknown option $1" ;;
            *) selected+=("$1") ;;
          esac
          shift
        done

        [ "$(id -u)" -eq 0 ] || die "run as root (sudo odoo-purge ...)"
        sql -c "SELECT 1" >/dev/null || die "PostgreSQL is not reachable"

        if [ ''${#selected[@]} -eq 0 ]; then
          found=$(leftovers)
          if [ -z "$found" ]; then
            echo "Nothing left behind by removed Odoo instances."
          else
            echo "Left behind by removed instances (odoo-purge NAME deletes it):"
            echo "$found"
          fi
          exit 0
        fi

        for name in "''${selected[@]}"; do
          [[ "$name" =~ ^[a-z][a-z0-9-]*$ ]] || die "'$name' is not an instance name"
          if configured "$name"; then
            die "'$name' is still configured; remove it from hostSpec.services.odoo.instances and deploy first, or use odoo-reset"
          fi
        done

        if ! $yes; then
          [ -t 0 ] || die "not a terminal: pass --yes to purge without asking"
          echo "This deletes the database, role and state of: ''${selected[*]}"
          read -r -p "Type yes to purge: " answer
          [ "$answer" = yes ] || die "aborted, nothing changed"
        fi

        for name in "''${selected[@]}"; do
          unit="odoo-$name"
          echo "==> $name: dropping database and role $unit"
          sql -c "DROP DATABASE IF EXISTS \"$unit\" WITH (FORCE)" -c "DROP ROLE IF EXISTS \"$unit\""
          echo "==> $name: deleting /var/lib/private/$unit"
          rm -rf "/var/lib/private/$unit" "/var/lib/$unit"
        done
      '';
    };
  in {
    options.hostSpec.services.odoo = {
      enable = lib.mkEnableOption ''
        local Odoo instances for testing: PostgreSQL, the HTTPS CA and
        certificate, odoo-reset and odoo-purge. The instances themselves
        come from `instances`; with none, only PostgreSQL runs (so
        odoo-purge can still clean up)'';

      package = lib.mkOption {
        type = lib.types.package;
        default = pkgs.odoo19;
        defaultText = lib.literalExpression "pkgs.odoo19";
        description = ''
          Default Odoo package for every instance. The default needs
          external-systems/pkgs overlays.odoo (in overlays.default):
          nixpkgs' own odoo19 does not evaluate.
        '';
      };

      baseDomain = lib.mkOption {
        type = lib.types.str;
        default = "odoo.localhost";
        description = ''
          Instance NAME is served at https://NAME.<baseDomain>;
          https://<baseDomain> lists the instances. Every name resolves to
          loopback through networking.hosts (Firefox resolves *.localhost
          itself). The CA is name-constrained to this domain and its
          subdomains.
        '';
      };

      basePort = lib.mkOption {
        type = lib.types.port;
        default = 18069;
        description = ''
          First automatic HTTP port. Instances without a port of their own
          get basePort + 2 * (position in name order), the websocket port
          the one above it. Adding an instance can move the others' ports,
          which only matters to things that bypass nginx.
        '';
      };

      instances = lib.mkOption {
        default = {};
        example = lib.literalExpression ''
          {
            demo = {};                     # https://demo.odoo.localhost, demo data
            blank.demoData = false;        # https://blank.odoo.localhost, empty
          }
        '';
        description = ''
          Odoo instances, by name (a DNS label: lowercase letters, digits
          and hyphens, starting with a letter). Each gets its own unit,
          user, database and state, all named odoo-NAME. Removing one
          leaves its database and state behind: odoo-purge deletes them.
        '';
        type = lib.types.attrsOf (lib.types.submodule {
          options = {
            demoData = lib.mkOption {
              type = lib.types.bool;
              default = true;
              description = ''
                Load Odoo's demo data when the database is created: at the
                first start and after every odoo-reset.
              '';
            };

            package = lib.mkOption {
              type = lib.types.package;
              default = cfg.package;
              defaultText = lib.literalExpression "config.hostSpec.services.odoo.package";
              description = "Odoo package of this instance.";
            };

            workers = lib.mkOption {
              type = lib.types.ints.positive;
              default = 2;
              description = ''
                Odoo HTTP worker processes. At least 1: the multi-process
                server is what starts the gevent websocket service that
                Discuss and live updates need.
              '';
            };

            addons = lib.mkOption {
              type = lib.types.listOf lib.types.package;
              default = [];
              description = "Extra Odoo addon packages (addons_path).";
            };

            port = lib.mkOption {
              type = lib.types.nullOr lib.types.port;
              default = null;
              description = ''
                HTTP port on 127.0.0.1; the websocket port is port + 1.
                null picks one from basePort.
              '';
            };
          };
        });
      };

      trustCertificate = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Trust the CA system wide (security.pki) and in Firefox (enterprise
          policy Certificates.Install), so every instance opens without a
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
        description = "External certificate PEM for baseDomain and *.baseDomain. Required when provisionSecrets = false.";
      };
      tlsKeyFile = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "External private key PEM for tlsCertFile. Required when provisionSecrets = false.";
      };
      adminPasswordFile = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "External file holding the web login password of user admin (every instance). Required when provisionSecrets = false.";
      };
      masterPasswordFile = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "External file holding Odoo's master password (admin_passwd, every instance). Required when provisionSecrets = false.";
      };
    };

    config = lib.mkIf cfg.enable (lib.mkMerge [
      {
        assertions = let
          ports = lib.concatMap (i: [i.httpPort i.geventPort]) instances;
        in [
          {
            assertion = lib.all (name: builtins.match "[a-z][a-z0-9-]*" name != null) (lib.attrNames cfg.instances);
            message = "hostSpec.services.odoo.instances: names must be DNS labels (lowercase letters, digits, hyphens, starting with a letter)";
          }
          {
            assertion = lib.length ports == lib.length (lib.unique ports);
            message = "hostSpec.services.odoo.instances: two instances share a port (each uses port and port + 1)";
          }
          {
            assertion = lib.all (i: i.geventPort <= 65535) instances;
            message = "hostSpec.services.odoo.instances: port + 1 must be a valid port";
          }
        ];

        clan.core.vars.generators = lib.mkIf cfg.provisionSecrets {
          # ca.key is never deployed (deploy = false): it only signs the
          # server certificate during `clan vars generate`. The name
          # constraint limits the trust security.pki grants this CA to
          # baseDomain and its subdomains, even if the key leaked.
          odoo-local-ca = {
            files = {
              "ca.crt".secret = false;
              "ca.key".deploy = false;
            };
            validation.domain = cfg.baseDomain;
            runtimeInputs = [pkgs.openssl];
            script = ''
              openssl req -x509 -newkey rsa:3072 -nodes \
                -keyout "$out"/ca.key -out "$out"/ca.crt \
                -days 3650 -subj "/CN=odoo-local-ca" \
                -addext "basicConstraints=critical,CA:TRUE,pathlen:0" \
                -addext "keyUsage=critical,keyCertSign,cRLSign" \
                -addext "nameConstraints=critical,permitted;DNS:${cfg.baseDomain}"
            '';
          };

          # One certificate for the index and every instance, so adding an
          # instance needs no new certificate. nginx reads the key as a
          # systemd credential, so it stays root-only.
          odoo-tls = {
            files = {
              "tls.crt".secret = false;
              "tls.key".restartUnits = ["nginx.service"];
            };
            dependencies = ["odoo-local-ca"];
            validation.names = "${cfg.baseDomain} *.${cfg.baseDomain}";
            runtimeInputs = [pkgs.openssl];
            script = ''
              work=$(mktemp -d)
              openssl req -newkey rsa:2048 -nodes \
                -keyout "$out"/tls.key -out "$work/tls.csr" \
                -subj "/CN=${cfg.baseDomain}"
              printf 'subjectAltName=DNS:%s,DNS:*.%s\nextendedKeyUsage=serverAuth\nbasicConstraints=critical,CA:FALSE\n' '${cfg.baseDomain}' '${cfg.baseDomain}' > "$work/ext"
              openssl x509 -req -in "$work/tls.csr" \
                -CA "$in"/odoo-local-ca/ca.crt -CAkey "$in"/odoo-local-ca/ca.key \
                -CAcreateserial -out "$out"/tls.crt \
                -days 825 -sha256 -extfile "$work/ext"
            '';
          };

          odoo-passwords = {
            files = {
              admin-password.restartUnits = map (i: "${i.unit}.service") instances;
              master-password.restartUnits = map (i: "${i.unit}.service") instances;
            };
            runtimeInputs = [pkgs.openssl];
            script = ''
              openssl rand -hex 16 | tr -d '\n' > "$out"/admin-password
              openssl rand -hex 32 | tr -d '\n' > "$out"/master-password
            '';
          };
        };

        environment.systemPackages = [odooReset odooPurge];

        # On even with no instances, so odoo-purge can drop what removed
        # instances left behind.
        services.postgresql = {
          enable = true;
          ensureDatabases = map (i: i.unit) instances;
          ensureUsers =
            map (i: {
              name = i.unit;
              ensureDBOwnership = true;
            })
            instances;
        };

        security.pki.certificateFiles = lib.mkIf cfg.trustCertificate [caFile];

        # Firefox reads /etc/firefox/policies/policies.json. Through
        # programs.firefox when the machine uses it, otherwise written here.
        programs.firefox.policies = lib.mkIf (cfg.trustCertificate && config.programs.firefox.enable) {
          Certificates.Install = [caFile];
        };
        environment.etc."firefox/policies/policies.json" = lib.mkIf (cfg.trustCertificate && !config.programs.firefox.enable) {
          text = builtins.toJSON {policies.Certificates.Install = [caFile];};
        };
      }

      (lib.mkIf hasInstances {
        users = {
          users = lib.listToAttrs (map (i:
            lib.nameValuePair i.unit {
              isSystemUser = true;
              group = i.unit;
            })
          instances);
          groups = lib.genAttrs (map (i: i.unit) instances) (_: {});
        };

        systemd.services =
          lib.listToAttrs (map (i: lib.nameValuePair i.unit i.service) instances)
          // {
            nginx.serviceConfig.LoadCredential = [
              "odoo-tls.key:${fileFor "tlsKeyFile" "odoo-tls" "tls.key"}"
            ];
          };

        services.nginx = {
          enable = true;
          recommendedTlsSettings = lib.mkDefault true;
          virtualHosts =
            lib.listToAttrs (map (i: lib.nameValuePair i.host i.virtualHost) instances)
            // {
              ${cfg.baseDomain} = {
                forceSSL = true;
                listenAddresses = loopback;
                sslCertificate = tlsCertFile;
                sslCertificateKey = tlsKeyCredential;
                root = indexPage;
              };
            };
        };

        networking.hosts = let
          names = [cfg.baseDomain] ++ map (i: i.host) instances;
        in
          {"127.0.0.1" = names;}
          // lib.optionalAttrs config.networking.enableIPv6 {"::1" = names;};
      })
    ]);
  };
}
