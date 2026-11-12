_: {
  # ------ NixOS Modules ------ #
  # Odoo instances for testing (never production): 0..n independent Odoo
  # servers on one machine, each with its own PostgreSQL database and
  # state, behind nginx with trusted HTTPS at https://<name>.<baseDomain>
  # (default https://<name>.odoo.localhost). https://<baseDomain> is an
  # index page; https://mail.<baseDomain> is Mailpit, which catches every
  # mail the instances send.
  #
  # Local by default: every Odoo binds 127.0.0.1 (HTTP port and gevent
  # websocket port = port + 1), nginx listens on loopback only, no firewall
  # port is opened and PostgreSQL keeps its default (unix socket, peer
  # auth, no TCP listener, no database password). Each instance can add:
  #   expose.lan     https://<name>.<lan.domain> (odoo.<host>.home.arpa),
  #                  80/443 open on lan.interfaces, nginx allow-list
  #                  lan.allowedClients, the local CA's certificate; a client
  #                  gets its hosts-file lines and the CA over plain HTTP at
  #                  http://<this machine's LAN IP>/hosts.txt and /ca.crt
  #   expose.public  https://<domain> for the internet, Let's Encrypt
  #                  (HTTP-01), 80/443 open, database manager 404, login
  #                  rate limit, HSTS, web.base.url frozen at the domain
  # Names nginx does not serve on a LAN or public address get their TLS
  # handshake refused (one catch-all default server).
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
  #   reset copy (database odoo-<name>@golden)           /var/lib/odoo-golden/<name>
  #   snapshots (databases odoo-<name>@snap-<tag>)       /var/lib/odoo-snapshots/<name>
  #
  # Start sequence of odoo-<name> (ExecStartPre, each step idempotent):
  #   1. runtime config with the master password
  #   2. first start (no .odoo.initialized): create the database with base
  #      + `modules` (+ demo data, + language), neutralize it, mark it
  #      for the reset copy
  #   3. the package or addons changed: `-u all`; `modules` changed:
  #      install the new apps
  #   4. as root: save a newly created database as the reset copy
  #   5. admin password (when the secret changed), web.base.url (public)
  # Restart=on-failure, MemoryMax per instance.
  #
  # odoo-reset NAME... | --all   back to the freshly created state: from the
  #                              reset copy in seconds, else from scratch
  # odoo-snapshot save|restore|list|rm NAME TAG   named states to go back to
  # odoo-purge [NAME...]         list or delete what removed instances left
  # odoo-hosts                   hosts-file lines for LAN clients
  #
  # Package: pkgs.odoo19 as fixed by external-systems/pkgs overlays.odoo
  # (part of overlays.default). Plain nixpkgs' odoo19 refuses to evaluate
  # (insecure pypdf2), so consumers apply the org overlay or set package.
  #
  # Secrets (clan vars generators, provisionSecrets = true), shared by
  # every instance so adding one never needs `clan vars generate`:
  #   odoo-local-ca   CA for HTTPS; name-constrained to baseDomain,
  #                   lan.domain and their subdomains, ca.key never
  #                   deployed, ca.crt trusted system wide and by Firefox
  #   odoo-tls        one nginx certificate for baseDomain, lan.domain and
  #                   their wildcards; key root:nginx 0440
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
    goldenRoot = "/var/lib/odoo-golden";
    snapshotRoot = "/var/lib/odoo-snapshots";

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
    # Read by nginx itself (root:nginx 0440 as a clan var), not as a systemd
    # credential: `systemctl reload nginx` runs `nginx -t` as the nginx
    # user, which cannot read the unit's credentials, so every reload (a
    # deploy, an ACME renewal) failed and kept the old certificates.
    tlsKeyFile = fileFor "tlsKeyFile" "odoo-tls" "tls.key";
    credentials = [
      "admin-password:${fileFor "adminPasswordFile" "odoo-passwords" "admin-password"}"
      "master-password:${fileFor "masterPasswordFile" "odoo-passwords" "master-password"}"
    ];

    loopback = ["127.0.0.1"] ++ lib.optional config.networking.enableIPv6 "[::1]";
    wildcard = ["0.0.0.0"] ++ lib.optional config.networking.enableIPv6 "[::]";
    # LAN and public vhosts listen on every address (no dependency on a
    # DHCP address) plus loopback explicitly: nginx matches the address a
    # connection arrived on before the name, and this machine reaches its
    # own LAN names over loopback. Who gets in is the firewall's job
    # (lan.interfaces) and lan.allowedClients'.
    exposedListen = wildcard ++ loopback;

    # Instances in name order; the index fixes the automatic port.
    instances = lib.imap0 mkInstance (lib.attrNames cfg.instances);
    hasInstances = instances != [];
    lanInstances = lib.filter (i: i.lan) instances;
    publicInstances = lib.filter (i: i.publicDomain != null) instances;
    hasLan = lanInstances != [];
    hasPublic = publicInstances != [];
    mailOn = cfg.mail.enable && hasInstances;
    mailLan = mailOn && cfg.mail.expose.lan && hasLan;

    # LAN vhosts answer allowedClients (and this machine) only; all
    # clients when the list is empty.
    lanAccess = lib.optionalString (cfg.lan.allowedClients != []) ''
      ${lib.concatMapStrings (client: "allow ${client};\n") (cfg.lan.allowedClients ++ ["127.0.0.1" "::1"])}deny all;
    '';

    proxyTimeouts = ''
      proxy_read_timeout 720s;
      proxy_connect_timeout 720s;
      proxy_send_timeout 720s;
    '';

    # Every name a LAN client needs in its hosts file.
    lanNames =
      [cfg.lan.domain]
      ++ map (i: i.lanHost) lanInstances
      ++ lib.optional mailLan "mail.${cfg.lan.domain}";

    mkInstance = index: name: let
      icfg = cfg.instances.${name};
      unit = "odoo-${name}";
      odoo = "${icfg.package}/bin/odoo";
      stateDir = "/var/lib/private/${unit}";
      dataDir = "${stateDir}/data";
      httpPort =
        if icfg.port != null
        then icfg.port
        else cfg.basePort + 2 * index;
      geventPort = httpPort + 1;
      host = "${name}.${cfg.baseDomain}";
      lanHost = "${name}.${cfg.lan.domain}";
      publicDomain =
        if icfg.expose.public.enable
        then icfg.expose.public.domain
        else null;

      # What a database is made from. The package key triggers `-u all`
      # when it changes, the modules key the install of new apps, and the
      # golden key (all of it) decides whether the reset copy still fits.
      packageKey = builtins.unsafeDiscardStringContext "${icfg.package} ${toString icfg.addons}";
      modulesKey = lib.concatStringsSep "," (lib.sort lib.lessThan icfg.modules);
      goldenKey = builtins.hashString "sha256" (builtins.toJSON {
        inherit packageKey modulesKey;
        inherit (icfg) demoData language neutralize;
      });

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
            # Per worker; MemoryMax caps the whole instance.
            limit_memory_soft = icfg.limits.memorySoft * 1024 * 1024;
            limit_memory_hard = icfg.limits.memoryHard * 1024 * 1024;
            limit_time_cpu = icfg.limits.timeCpu;
            limit_time_real = icfg.limits.timeReal;
            max_cron_threads = 1;
          }
          // lib.optionalAttrs mailOn {
            # Every mail goes to Mailpit; the neutralized database has no
            # mail server of its own.
            smtp_server = "127.0.0.1";
            smtp_port = cfg.mail.smtpPort;
            # A sender for mail that has none (system mail, a mail.mail
            # created by hand); Odoo refuses to send it otherwise.
            email_from = "${name}@${cfg.baseDomain}";
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

      # Neutralize: mail servers, payment providers, outgoing integrations
      # and crons off. Neutralize also adds an active mail server with the
      # host "invalid", which blocks every mail. With Mailpit, that server
      # is replaced by one for Mailpit and the mail queue runs again, so
      # mail is sent but reaches Mailpit only. Idempotent: runs again
      # after new apps.
      afterNeutralize = pkgs.writeText "${unit}-after-neutralize.py" (lib.optionalString mailOn ''
          Server = env["ir.mail_server"].sudo().with_context(active_test=False)
          mailpit = Server.search([("name", "=", "Mailpit")], limit=1)
          (Server.search([]) - mailpit).write({"active": False})
          values = {
              "name": "Mailpit",
              "smtp_host": "127.0.0.1",
              "smtp_port": ${toString cfg.mail.smtpPort},
              "smtp_encryption": "none",
              "sequence": 1,
              "active": True,
          }
          if mailpit:
              mailpit.write(values)
          else:
              Server.create(values)
          cron = env.ref("mail.ir_cron_mail_scheduler_action", raise_if_not_found=False)
          if cron:
              cron.active = True
        ''
        + ''
          env.cr.commit()
        '');
      neutralizeSteps = lib.optionalString icfg.neutralize ''
        echo "pre-start: neutralizing ${unit} (test database: nothing reaches the outside)"
        ${odoo} neutralize --database=${unit}
        ${odoo} shell --database=${unit} --no-http < ${afterNeutralize}
      '';

      initModules = lib.concatStringsSep "," (["base"] ++ icfg.modules);

      # First start, and the first start after a reset from scratch: the
      # marker is gone, so the (empty) database gets base, the apps and,
      # if asked, demo data.
      initDatabase = pkgs.writeShellScript "${unit}-init" ''
        set -euo pipefail
        mkdir -p ${dataDir}
        if [ ! -e ${dataDir}/.odoo.initialized ]; then
          echo "pre-start: creating database ${unit} (demo data: ${lib.boolToYesNo icfg.demoData}, apps: ${initModules})"
          ${odoo} --init=${initModules} --database=${unit} --stop-after-init \
            ${lib.optionalString icfg.demoData "--with-demo"} \
            ${lib.optionalString (icfg.language != null) "--load-language=${icfg.language}"}
          ${neutralizeSteps}
          echo ${lib.escapeShellArg packageKey} > ${dataDir}/.package
          echo ${lib.escapeShellArg modulesKey} > ${dataDir}/.modules
          touch ${dataDir}/.golden-pending
          touch ${dataDir}/.odoo.initialized
        fi
      '';

      # A new package or addons (a nixpkgs bump) leaves the database on
      # the old module data: update every module. New apps in `modules`
      # get installed; removed ones stay installed.
      syncDatabase = pkgs.writeShellScript "${unit}-sync" ''
        set -euo pipefail
        package=${dataDir}/.package
        modules=${dataDir}/.modules
        [ -e "$package" ] || echo ${lib.escapeShellArg packageKey} > "$package"
        [ -e "$modules" ] || echo ${lib.escapeShellArg modulesKey} > "$modules"
        if [ "$(cat "$package")" != ${lib.escapeShellArg packageKey} ]; then
          echo "pre-start: the Odoo package or addons changed; updating all modules of ${unit}"
          ${odoo} --update=all --database=${unit} --stop-after-init
          echo ${lib.escapeShellArg packageKey} > "$package"
        fi
        if [ "$(cat "$modules")" != ${lib.escapeShellArg modulesKey} ]; then
          ${lib.optionalString (icfg.modules != []) ''
          echo "pre-start: installing apps ${modulesKey} into ${unit}"
          ${odoo} --init=${lib.concatStringsSep "," icfg.modules} --database=${unit} --stop-after-init
          ${neutralizeSteps}
        ''}
          echo ${lib.escapeShellArg modulesKey} > "$modules"
        fi
      '';

      setAdminPassword = pkgs.writeText "${unit}-set-admin-password.py" ''
        import os

        with open(os.path.join(os.environ["CREDENTIALS_DIRECTORY"], "admin-password")) as f:
            password = f.read().strip()
        env.ref("base.user_admin").password = password
        env.cr.commit()
      '';

      # The marker holds the hash of the password last applied; a reset
      # removes it, so the provisioned password applies again.
      applyAdminPassword = pkgs.writeShellScript "${unit}-admin-password" ''
        set -euo pipefail
        marker=${dataDir}/.admin-password.sha256
        want=$(${pkgs.coreutils}/bin/sha256sum < "$CREDENTIALS_DIRECTORY/admin-password" | ${pkgs.coreutils}/bin/cut -d' ' -f1)
        if [ "$(cat "$marker" 2>/dev/null || true)" != "$want" ]; then
          echo "pre-start: setting the admin password"
          ${odoo} shell --database=${unit} --no-http < ${setAdminPassword}
          echo "$want" > "$marker"
        fi
      '';

      # A public instance builds its links (mails, reports, portal) from
      # the public URL, whichever name the admin logged in through.
      publicUrl = "https://${publicDomain}";
      setBaseUrl = pkgs.writeText "${unit}-set-base-url.py" ''
        params = env["ir.config_parameter"].sudo()
        params.set_param("web.base.url", "${publicUrl}")
        params.set_param("web.base.url.freeze", "True")
        env.cr.commit()
      '';
      applyBaseUrl = pkgs.writeShellScript "${unit}-base-url" ''
        set -euo pipefail
        marker=${dataDir}/.base-url
        if [ "$(cat "$marker" 2>/dev/null || true)" != "${publicUrl}" ]; then
          echo "pre-start: freezing web.base.url at ${publicUrl}"
          ${odoo} shell --database=${unit} --no-http < ${setBaseUrl}
          echo "${publicUrl}" > "$marker"
        fi
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

      # Loopback and LAN: the same proxy behind the shared certificate.
      ownCertificate = {
        forceSSL = true;
        sslCertificate = tlsCertFile;
        sslCertificateKey = tlsKeyFile;
        inherit locations;
      };
    in {
      inherit name unit stateDir dataDir httpPort geventPort host lanHost publicDomain goldenKey;
      inherit (icfg) demoData;
      inherit (icfg.expose) lan;
      url = "https://${host}";
      lanUrl = "https://${lanHost}";
      publicUrl =
        if publicDomain != null
        then publicUrl
        else null;

      service = {
        description = "Odoo instance ${name} (https://${host})";
        wantedBy = ["multi-user.target"];
        after = ["network.target" "postgresql.target"] ++ lib.optional mailOn "mailpit-odoo.service";
        requires = ["postgresql.target"];
        # pg_dump for Odoo's backups.
        path = [postgresql];
        environment.ODOO_RC = runtimeConfig;
        # A crashed or OOM-killed instance comes back; a broken one stops
        # retrying after 4 failures in 15 minutes.
        startLimitIntervalSec = 900;
        startLimitBurst = 4;
        serviceConfig = {
          ExecStart = odoo;
          ExecStartPre =
            [
              "${writeRuntimeConfig}"
              "${initDatabase}"
              "${syncDatabase}"
              # As root: copies databases as the postgres user.
              "+${odooGoldenSave}/bin/odoo-golden-save ${name}"
              "${applyAdminPassword}"
            ]
            ++ lib.optional (publicDomain != null) "${applyBaseUrl}";
          Restart = "on-failure";
          RestartSec = "10s";
          MemoryMax = lib.mkIf (icfg.memoryMax != null) icfg.memoryMax;
          # A static user (users.users below) with DynamicUser's sandbox,
          # as nixpkgs services.odoo does: state lands in /var/lib/private.
          DynamicUser = true;
          User = unit;
          Group = unit;
          StateDirectory = unit;
          RuntimeDirectory = unit;
          RuntimeDirectoryMode = "0700";
          LoadCredential = credentials;
          # Creating the database (with demo data and apps) or updating
          # every module takes minutes; systemd's 90 s default would kill it.
          TimeoutStartSec = "20min";
        };
      };

      virtualHost =
        ownCertificate
        // {
          listenAddresses = loopback;
          extraConfig = proxyTimeouts;
        };

      lanVirtualHost =
        ownCertificate
        // {
          listenAddresses = exposedListen;
          extraConfig = proxyTimeouts + lanAccess;
        };

      # Let's Encrypt (HTTP-01) and hardening for the internet: no database
      # manager, a login rate limit, HSTS.
      publicVirtualHost = {
        forceSSL = true;
        enableACME = true;
        listenAddresses = exposedListen;
        extraConfig =
          proxyTimeouts
          + ''
            add_header Strict-Transport-Security "max-age=31536000" always;
          '';
        locations =
          locations
          // {
            "~ ^/web/database".return = "404";
            "= /web/login" =
              locations."/"
              // {
                extraConfig = ''
                  proxy_redirect off;
                  limit_req zone=odoo_login burst=5 nodelay;
                  limit_req_status 429;
                '';
              };
          };
      };
    };

    # What the scripts know about the configured instances.
    instancesJson = pkgs.writeText "odoo-instances.json" (builtins.toJSON (map (i: {
        inherit (i) name unit stateDir dataDir httpPort url demoData lan publicUrl goldenKey;
      })
      instances));

    commonTools = [pkgs.coreutils pkgs.curl pkgs.findutils pkgs.gnused pkgs.gnutar pkgs.jq pkgs.systemd pkgs.util-linux postgresql];

    # The scripts share _odoo/lib.sh; shellcheck runs on each at build.
    mkScript = name: file:
      pkgs.writeShellApplication {
        inherit name;
        runtimeInputs = commonTools;
        text =
          ''
            export prog=${name} instances=${instancesJson} golden_root=${goldenRoot} snapshot_root=${snapshotRoot}
          ''
          + builtins.readFile ./_odoo/lib.sh
          + builtins.readFile file;
      };

    odooReset = mkScript "odoo-reset" ./_odoo/reset.sh;
    odooSnapshot = mkScript "odoo-snapshot" ./_odoo/snapshot.sh;
    odooPurge = mkScript "odoo-purge" ./_odoo/purge.sh;
    odooGoldenSave = mkScript "odoo-golden-save" ./_odoo/golden-save.sh;

    odooHosts = pkgs.writeShellApplication {
      name = "odoo-hosts";
      runtimeInputs = [pkgs.iproute2 pkgs.gawk];
      text = ''
        # The lines a LAN client (Windows: C:\Windows\System32\drivers\etc\hosts)
        # needs for this machine's LAN-exposed Odoo, with the IPv4 addresses
        # lan.interfaces have right now.
        names=(${lib.escapeShellArgs lanNames})
        ${
          if hasLan
          then ''
            interfaces=(${lib.escapeShellArgs cfg.lan.interfaces})
            found=0
            for interface in "''${interfaces[@]}"; do
              while read -r address; do
                found=1
                for name in "''${names[@]}"; do
                  printf '%s  %s\n' "$address" "$name"
                done
              done < <(ip -o -4 addr show dev "$interface" scope global 2>/dev/null | awk '{split($4, a, "/"); print a[1]}')
            done
            if [ "$found" = 0 ]; then
              echo "odoo-hosts: no IPv4 address on ${toString cfg.lan.interfaces} right now" >&2
              exit 1
            fi
          ''
          else ''
            echo "# No Odoo instance on this machine is exposed to the LAN."
            : "''${names[@]}"
          ''
        }
      '';
    };

    statusText = i:
      (
        if i.demoData
        then "demo data"
        else "no demo data"
      )
      + lib.optionalString i.lan ", LAN: ${i.lanUrl}"
      + lib.optionalString (i.publicUrl != null) ", public: ${i.publicUrl}";

    pageStyle = ''
      <style>
        body { font-family: Georgia, serif; background: #1f1e1d; color: #faf9f5; max-width: 44rem; margin: 3rem auto; padding: 0 1rem; }
        a { color: #e8a48a; }
        li { margin: 0.5rem 0; }
        pre { background: #2b2a27; padding: 0.75rem; overflow-x: auto; }
        .muted { color: #b0aea5; }
      </style>
    '';

    indexPage = pkgs.writeTextDir "index.html" ''
      <!doctype html>
      <html lang="en">
        <head>
          <meta charset="utf-8">
          <title>Odoo instances</title>
          ${pageStyle}
        </head>
        <body>
          <h1>Odoo instances</h1>
          <ul>
            ${lib.concatMapStringsSep "\n" (i: ''<li><a href="${i.url}/">${i.name}</a> <span class="muted">${statusText i}</span></li>'') instances}
          </ul>
          ${lib.optionalString mailOn ''<p>Mail sent by the instances: <a href="https://mail.${cfg.baseDomain}/">Mailpit</a>.</p>''}
          <p class="muted"><code>odoo-reset --list</code>, <code>sudo odoo-reset NAME</code>,
          <code>sudo odoo-snapshot save NAME TAG</code>.</p>
        </body>
      </html>
    '';

    lanIndexPage = pkgs.writeTextDir "index.html" ''
      <!doctype html>
      <html lang="en">
        <head>
          <meta charset="utf-8">
          <title>Odoo on ${config.networking.hostName}</title>
          ${pageStyle}
        </head>
        <body>
          <h1>Odoo on ${config.networking.hostName}</h1>
          <ul>
            ${lib.concatMapStringsSep "\n" (i: ''<li><a href="${i.lanUrl}/">${i.name}</a> <span class="muted">${statusText i}</span></li>'') lanInstances}
          </ul>
          ${lib.optionalString mailLan ''<p>Mail sent by the instances: <a href="https://mail.${cfg.lan.domain}/">Mailpit</a>.</p>''}
          <h2>Setting up a client</h2>
          <p>1. Add <a href="/hosts.txt">these lines</a> to the hosts file (Windows, as
          administrator: <code>C:\Windows\System32\drivers\etc\hosts</code>, then
          <code>ipconfig /flushdns</code>).</p>
          <p>2. Trust the CA once: <a href="/ca.crt">ca.crt</a>. Windows, PowerShell as
          administrator: <code>Import-Certificate -FilePath ca.crt -CertStoreLocation Cert:\LocalMachine\Root</code>.
          It is only valid for names under ${cfg.baseDomain} and ${cfg.lan.domain}.</p>
          <p class="muted">Both also at <code>http://&lt;this machine's IP&gt;/hosts.txt</code> and
          <code>/ca.crt</code>, before the hosts file knows any name.</p>
        </body>
      </html>
    '';

    # The client's view of this machine: nginx fills in the address the
    # request arrived on, so the lines are right whatever DHCP handed out.
    # `return` runs in nginx's rewrite phase, before allow/deny (access
    # phase), so the allow-list is checked here with the geo map.
    hostsTxtLocation = {
      extraConfig = ''
        default_type text/plain;
        ${lib.optionalString (cfg.lan.allowedClients != []) ''
          if ($odoo_lan_client = 0) {
            return 403;
          }
        ''}
        return 200 "${lib.concatMapStrings (name: "$server_addr  ${name}\\n") lanNames}";
      '';
    };
    caCrtLocation = {
      alias = caFile;
      extraConfig = ''
        ${lanAccess}
        default_type application/x-x509-ca-cert;
      '';
    };

    mailVirtualHost = listen: access: {
      forceSSL = true;
      listenAddresses = listen;
      sslCertificate = tlsCertFile;
      sslCertificateKey = tlsKeyFile;
      extraConfig = access;
      locations."/" = {
        proxyPass = "http://127.0.0.1:${toString cfg.mail.uiPort}";
        proxyWebsockets = true;
        recommendedProxySettings = true;
      };
    };
  in {
    options.hostSpec.services.odoo = {
      enable = lib.mkEnableOption ''
        Odoo instances for testing: PostgreSQL, the HTTPS CA and
        certificate, Mailpit, odoo-reset, odoo-snapshot, odoo-purge and
        odoo-hosts. The instances themselves come from `instances`; with
        none, only PostgreSQL runs (so odoo-purge can still clean up)'';

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
          https://<baseDomain> lists the instances, https://mail.<baseDomain>
          is Mailpit. Every name resolves to loopback through
          networking.hosts (Firefox resolves *.localhost itself). The CA is
          name-constrained to this domain, lan.domain and their subdomains.
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

      mail = {
        enable = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = ''
            Run Mailpit and send every instance's mail to it, at
            https://mail.<baseDomain>: nothing reaches a real mailbox, and
            every mail can be read. Off, mail goes nowhere (no SMTP server
            on localhost:25).
          '';
        };
        expose.lan = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = "Also serve Mailpit at https://mail.<lan.domain> while an instance is LAN-exposed.";
        };
        uiPort = lib.mkOption {
          type = lib.types.port;
          default = 8025;
          description = "Mailpit's web UI port on 127.0.0.1 (nginx proxies it).";
        };
        smtpPort = lib.mkOption {
          type = lib.types.port;
          default = 1025;
          description = "Mailpit's SMTP port on 127.0.0.1, where every instance sends its mail.";
        };
      };

      lan = {
        domain = lib.mkOption {
          type = lib.types.str;
          default = "odoo.${config.networking.hostName}.home.arpa";
          defaultText = lib.literalExpression ''"odoo.''${config.networking.hostName}.home.arpa"'';
          description = ''
            LAN-exposed instance NAME is served at https://NAME.<lan.domain>;
            https://<lan.domain> lists them. home.arpa is reserved for home
            networks (RFC 8375). *.localhost cannot work from other
            machines: browsers send it to the client itself.
          '';
        };
        interfaces = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [];
          description = ''
            Interfaces the firewall opens 80 and 443 on while an instance
            sets expose.lan; odoo-hosts reads their addresses. nginx listens
            on every address, so a DHCP address change needs no rebuild.
          '';
        };
        allowedClients = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [];
          description = ''
            Addresses or CIDRs (nginx allow) that may use the LAN names
            (this machine always may); everyone else gets 403. Empty allows
            every client that reaches the port, including over trusted
            interfaces such as a VPN. Required when an instance is also
            public.
          '';
        };
      };

      acme.email = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = ''
          Let's Encrypt account email, needed once an instance sets
          expose.public (unless security.acme.defaults.email is set).
        '';
      };

      instances = lib.mkOption {
        default = {};
        example = lib.literalExpression ''
          {
            demo.modules = ["sale_management" "crm"];   # demo data + apps
            blank.demoData = false;                      # empty database
          }
        '';
        description = ''
          Odoo instances, by name (a DNS label of at most 24 characters:
          lowercase letters, digits and hyphens, starting with a letter;
          not "mail"). Each gets its own unit, user, database and state, all
          named odoo-NAME. Removing one leaves its database and state
          behind: odoo-purge deletes them.
        '';
        type = lib.types.attrsOf (lib.types.submodule {
          options = {
            demoData = lib.mkOption {
              type = lib.types.bool;
              default = true;
              description = ''
                Load Odoo's demo data when the database is created: at the
                first start and on every reset.
              '';
            };

            modules = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              default = [];
              example = ["sale_management" "crm" "stock" "l10n_us"];
              description = ''
                Apps (Odoo module names) installed when the database is
                created, and installed on the next start when added later.
                Removing one does not uninstall it; a reset does.
              '';
            };

            language = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              example = "de_DE";
              description = "Language loaded when the database is created (--load-language).";
            };

            neutralize = lib.mkOption {
              type = lib.types.bool;
              default = true;
              description = ''
                Run `odoo neutralize` on every new database and after new
                apps: mail servers, payment providers, outgoing integrations
                and scheduled actions off (the mail queue stays on, and its
                mail reaches Mailpit only). Odoo shows a "neutralized"
                banner.
              '';
            };

            package = lib.mkOption {
              type = lib.types.package;
              default = cfg.package;
              defaultText = lib.literalExpression "config.hostSpec.services.odoo.package";
              description = ''
                Odoo package of this instance. When it changes, the next
                start updates every module (`-u all`).
              '';
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

            memoryMax = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = "4G";
              description = ''
                systemd MemoryMax for the whole instance (workers, cron,
                websocket, database creation). An instance over it is
                killed and restarted, instead of starving the machine.
                null: no cap.
              '';
            };

            limits = {
              memorySoft = lib.mkOption {
                type = lib.types.ints.positive;
                default = 1536;
                description = "Odoo limit_memory_soft per worker, MiB: a worker over it is recycled after its request.";
              };
              memoryHard = lib.mkOption {
                type = lib.types.ints.positive;
                default = 2048;
                description = "Odoo limit_memory_hard per worker, MiB: a worker over it is killed at once.";
              };
              timeCpu = lib.mkOption {
                type = lib.types.ints.positive;
                default = 600;
                description = "Odoo limit_time_cpu per request, seconds (generous for imports and reports).";
              };
              timeReal = lib.mkOption {
                type = lib.types.ints.positive;
                default = 1200;
                description = "Odoo limit_time_real per request, seconds.";
              };
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

            expose = {
              lan = lib.mkEnableOption ''
                https://NAME.<lan.domain> for other machines on the LAN
                (lan.interfaces, lan.allowedClients), with the local CA's
                certificate'';

              public = {
                enable = lib.mkEnableOption ''
                  https://<domain> for the internet, with a Let's Encrypt
                  certificate (HTTP-01: the domain's A/AAAA records point at
                  this machine and port 80 reaches it). The database manager
                  answers 404, /web/login is rate limited and web.base.url is
                  frozen at the public URL'';
                domain = lib.mkOption {
                  type = lib.types.nullOr lib.types.str;
                  default = null;
                  example = "erp.example.com";
                  description = "Public domain of this instance. From the values flake, never a literal here.";
                };
              };
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
        description = "External certificate PEM for baseDomain, lan.domain and their wildcards. Required when provisionSecrets = false.";
      };
      tlsKeyFile = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "External private key PEM for tlsCertFile, readable by the nginx user. Required when provisionSecrets = false.";
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
          names = lib.attrNames cfg.instances;
          ports = lib.concatMap (i: [i.httpPort i.geventPort]) instances;
          publicDomains = map (i: i.publicDomain) publicInstances;
          ownDomain = domain: domain == cfg.baseDomain || lib.hasSuffix ".${cfg.baseDomain}" domain || domain == cfg.lan.domain || lib.hasSuffix ".${cfg.lan.domain}" domain;
        in [
          {
            assertion = lib.all (name: builtins.match "[a-z][a-z0-9-]{0,23}" name != null) names;
            message = "hostSpec.services.odoo.instances: names must be DNS labels of at most 24 characters (lowercase letters, digits, hyphens, starting with a letter)";
          }
          {
            assertion = !(cfg.mail.enable && lib.elem "mail" names);
            message = "hostSpec.services.odoo.instances: \"mail\" is Mailpit's name (https://mail.${cfg.baseDomain})";
          }
          {
            assertion = lib.length ports == lib.length (lib.unique ports);
            message = "hostSpec.services.odoo.instances: two instances share a port (each uses port and port + 1)";
          }
          {
            assertion = lib.all (i: i.geventPort <= 65535) instances;
            message = "hostSpec.services.odoo.instances: port + 1 must be a valid port";
          }
          {
            assertion = !mailOn || !(lib.elem cfg.mail.uiPort ports || lib.elem cfg.mail.smtpPort ports);
            message = "hostSpec.services.odoo.mail: uiPort and smtpPort must not be an instance's port";
          }
          {
            assertion = !hasLan || cfg.lan.interfaces != [];
            message = "hostSpec.services.odoo.lan.interfaces must be set when an instance sets expose.lan";
          }
          {
            assertion = !(hasLan && hasPublic) || cfg.lan.allowedClients != [];
            message = "hostSpec.services.odoo.lan.allowedClients must be set when instances are both LAN-exposed and public: the LAN names would otherwise answer the internet";
          }
          {
            assertion = lib.all (i: i.publicDomain != null) (lib.filter (i: cfg.instances.${i.name}.expose.public.enable) instances);
            message = "hostSpec.services.odoo.instances.<name>.expose.public: domain must be set when enable = true";
          }
          {
            assertion = lib.length publicDomains == lib.length (lib.unique publicDomains);
            message = "hostSpec.services.odoo.instances: two public instances share a domain";
          }
          {
            assertion = !lib.any ownDomain publicDomains;
            message = "hostSpec.services.odoo.instances.<name>.expose.public.domain must be a real domain, not under baseDomain or lan.domain";
          }
          {
            assertion = !hasPublic || cfg.acme.email != null || config.security.acme.defaults.email != null;
            message = "hostSpec.services.odoo.acme.email (or security.acme.defaults.email) must be set when an instance sets expose.public";
          }
        ];

        clan.core.vars.generators = lib.mkIf cfg.provisionSecrets {
          # ca.key is never deployed (deploy = false): it only signs the
          # server certificate during `clan vars generate`. The name
          # constraints limit the trust this CA gets (here, and on LAN
          # clients that import it) to baseDomain, lan.domain and their
          # subdomains, even if the key leaked.
          odoo-local-ca = {
            files = {
              "ca.crt".secret = false;
              "ca.key".deploy = false;
            };
            validation.domains = "${cfg.baseDomain} ${cfg.lan.domain}";
            runtimeInputs = [pkgs.openssl];
            script = ''
              openssl req -x509 -newkey rsa:3072 -nodes \
                -keyout "$out"/ca.key -out "$out"/ca.crt \
                -days 3650 -subj "/CN=odoo-local-ca ${config.networking.hostName}" \
                -addext "basicConstraints=critical,CA:TRUE,pathlen:0" \
                -addext "keyUsage=critical,keyCertSign,cRLSign" \
                -addext "nameConstraints=critical,permitted;DNS:${cfg.baseDomain},permitted;DNS:${cfg.lan.domain}"
            '';
          };

          # One certificate for every local and LAN name, so adding or
          # exposing an instance needs no new certificate. Only root and
          # nginx can read the key. Public instances get Let's Encrypt
          # certificates instead.
          odoo-tls = {
            files = {
              "tls.crt".secret = false;
              "tls.key" = {
                owner = "root";
                group = config.services.nginx.group;
                mode = "0440";
                restartUnits = ["nginx.service"];
              };
            };
            dependencies = ["odoo-local-ca"];
            validation.names = "${cfg.baseDomain} *.${cfg.baseDomain} ${cfg.lan.domain} *.${cfg.lan.domain}";
            runtimeInputs = [pkgs.openssl];
            script = ''
              work=$(mktemp -d)
              openssl req -newkey rsa:2048 -nodes \
                -keyout "$out"/tls.key -out "$work/tls.csr" \
                -subj "/CN=${cfg.baseDomain}"
              printf 'subjectAltName=DNS:%s,DNS:*.%s,DNS:%s,DNS:*.%s\nextendedKeyUsage=serverAuth\nbasicConstraints=critical,CA:FALSE\n' \
                '${cfg.baseDomain}' '${cfg.baseDomain}' '${cfg.lan.domain}' '${cfg.lan.domain}' > "$work/ext"
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

        environment.systemPackages = [odooReset odooSnapshot odooPurge odooHosts];

        # Reset copies and snapshots: whole databases' files, root only.
        systemd.tmpfiles.rules = [
          "d ${goldenRoot} 0700 root root -"
          "d ${snapshotRoot} 0700 root root -"
        ];

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

        systemd.services = lib.listToAttrs (map (i: lib.nameValuePair i.unit i.service) instances);

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
                sslCertificateKey = tlsKeyFile;
                root = indexPage;
              };
            };
        };

        networking.hosts = let
          names =
            [cfg.baseDomain]
            ++ map (i: i.host) instances
            ++ lib.optional mailOn "mail.${cfg.baseDomain}"
            # This machine reaches its LAN names over loopback.
            ++ lib.optionals hasLan lanNames;
        in
          {"127.0.0.1" = names;}
          // lib.optionalAttrs config.networking.enableIPv6 {"::1" = names;};
      })

      # Mailpit: every mail the instances send, readable in a browser.
      (lib.mkIf mailOn {
        services = {
          mailpit.instances.odoo = {
            listen = "127.0.0.1:${toString cfg.mail.uiPort}";
            smtp = "127.0.0.1:${toString cfg.mail.smtpPort}";
            database = "odoo.db";
            max = 2000;
          };
          nginx.virtualHosts."mail.${cfg.baseDomain}" = mailVirtualHost loopback "";
        };
      })

      # LAN: the exposed instances, an index, hosts.txt and the CA; 80/443
      # open on the LAN interfaces only.
      (lib.mkIf hasLan {
        services.nginx = {
          virtualHosts =
            lib.listToAttrs (map (i: lib.nameValuePair i.lanHost i.lanVirtualHost) lanInstances)
            // {
              ${cfg.lan.domain} = {
                # HTTP too: a new client fetches /ca.crt before it trusts HTTPS.
                addSSL = true;
                listenAddresses = exposedListen;
                sslCertificate = tlsCertFile;
                sslCertificateKey = tlsKeyFile;
                root = lanIndexPage;
                extraConfig = lanAccess;
                locations = {
                  "= /ca.crt" = caCrtLocation;
                  "= /hosts.txt" = hostsTxtLocation;
                };
              };
            }
            // lib.optionalAttrs mailLan {
              "mail.${cfg.lan.domain}" = mailVirtualHost exposedListen lanAccess;
            };

          # lan.allowedClients for locations that answer with `return`.
          appendHttpConfig = lib.mkIf (cfg.lan.allowedClients != []) ''
            geo $odoo_lan_client {
              default 0;
              ${lib.concatMapStrings (client: "${client} 1;\n") (cfg.lan.allowedClients ++ ["127.0.0.1" "::1"])}}
          '';
        };

        networking.firewall.interfaces = lib.genAttrs cfg.lan.interfaces (_: {allowedTCPPorts = [80 443];});
      })

      # One catch-all for every exposed address: unknown names (local-only
      # instances, *.localhost, a bare IP) get their TLS handshake refused.
      # On a LAN, plain http://<IP>/hosts.txt and /ca.crt bootstrap a client
      # that knows no name yet.
      (lib.mkIf (hasLan || hasPublic) {
        services.nginx.virtualHosts.odoo-default = {
          serverName = "_";
          default = true;
          rejectSSL = true;
          listenAddresses = wildcard;
          locations =
            {"/".return = "444";}
            // lib.optionalAttrs hasLan {
              "= /ca.crt" = caCrtLocation;
              "= /hosts.txt" = hostsTxtLocation;
            };
        };
      })

      # Internet: Let's Encrypt over HTTP-01 (port 80 must reach this
      # machine), 80/443 open.
      (lib.mkIf hasPublic {
        security.acme = {
          acceptTerms = true;
          defaults.email = lib.mkIf (cfg.acme.email != null) (lib.mkDefault cfg.acme.email);
        };

        services.nginx = {
          appendHttpConfig = ''
            limit_req_zone $binary_remote_addr zone=odoo_login:10m rate=10r/m;
          '';
          virtualHosts = lib.listToAttrs (map (i: lib.nameValuePair i.publicDomain i.publicVirtualHost) publicInstances);
        };

        networking.firewall.allowedTCPPorts = [80 443];
      })
    ]);
  };
}
