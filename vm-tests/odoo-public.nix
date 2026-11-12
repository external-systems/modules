# expose.public: shop gets a Let's Encrypt-style certificate over HTTP-01
# from pebble (the ACME test server, nixpkgs' common/acme helpers), all
# offline. An internet client trusting pebble's root reaches
# https://erp.example.test; the database manager answers 404, logins are
# rate limited, HSTS is set and web.base.url is frozen at the public URL.
# intern stays local only: unreachable from the internet under any name.
{inputs, ...}: let
  common = import ./_odoo-common.nix {inherit inputs;};
  domain = "erp.example.test";
in {
  nodes = {
    # Pebble at https://acme.test; resolves every node's ACME domains.
    acme = {imports = ["${inputs.nixpkgs}/nixos/tests/common/acme/server"];};

    server = {
      imports = [
        common.module
        # security.acme against pebble, trusting its API certificate.
        "${inputs.nixpkgs}/nixos/tests/common/acme/client"
      ];
      hostSpec.services.odoo.instances = {
        shop = {
          demoData = false;
          workers = 1;
          expose.public = {
            enable = true;
            inherit domain;
          };
        };
        intern = {
          demoData = false;
          workers = 1;
        };
      };
      virtualisation = {
        memorySize = 4096;
        cores = 2;
      };
    };

    internet = {nodes, ...}: {
      imports = [common.clientModule];
      # Trusts pebble's API certificate, to fetch its root at runtime.
      security.pki.certificateFiles = [nodes.acme.test-support.acme.caCert];
      networking.hosts.${nodes.server.networking.primaryIPAddress} = [domain];
    };
  };

  globalTimeout = 2400;

  testScript = {nodes, ...}: ''
    ${common.pythonHelpers}

    server_ip = "${nodes.server.networking.primaryIPAddress}"
    domain = "${domain}"
    root = "/tmp/pebble-root.pem"

    start_all()
    acme.wait_for_unit("pebble.service", timeout=300)
    wait_ready(server, ["shop", "intern"])

    with subtest("shop gets its certificate over HTTP-01"):
        # Pebble makes a new root each run: fetch it from its API.
        internet.wait_until_succeeds(f"curl -sf https://acme.test:15000/roots/0 -o {root}", timeout=300)
        # nginx first serves a self-signed placeholder, then reloads with
        # the issued certificate.
        server.wait_until_succeeds(
            f"journalctl -u acme-order-renew-{domain}.service | grep 'Server responded with a certificate' >/dev/null",
            timeout=300,
        )
        try:
            internet.wait_until_succeeds(
                f"curl -sf --cacert {root} https://{domain}/web/login | grep 'name=\"login\"' >/dev/null",
                timeout=300,
            )
        except Exception:
            # What the client saw, and what nginx serves.
            print(internet.execute(f"curl -sv --cacert {root} -o /dev/null https://{domain}/web/login 2>&1")[1])
            print(internet.execute(f"openssl s_client -connect {domain}:443 -servername {domain} -showcerts </dev/null 2>&1 | grep -E 's:|i:|Verify'")[1])
            print(internet.execute(f"openssl x509 -noout -subject -issuer < {root}")[1])
            print(server.execute(f"ls -la /var/lib/acme/{domain}/; openssl x509 -noout -subject -issuer < /var/lib/acme/{domain}/fullchain.pem")[1])
            raise
        location = internet.succeed(
            f"curl -s -o /dev/null -w '%{{http_code}} %{{redirect_url}}' http://{domain}/web/login"
        ).strip()
        assert location == f"301 https://{domain}/web/login", location

    with subtest("the internet client logs in; web.base.url is the public URL"):
        probe(internet, "shop", "login", admin_password, host=domain, cafile=root)
        probe(internet, "shop", "base-url", admin_password, f"https://{domain}", host=domain, cafile=root)
        headers = internet.succeed(f"curl -sf -D - -o /dev/null --cacert {root} https://{domain}/web/login")
        assert "strict-transport-security: max-age=31536000" in headers.lower(), headers

    with subtest("the database manager answers 404"):
        for path in ("/web/database/manager", "/web/database/selector", "/web/database/list"):
            code = internet.succeed(f"curl -s -o /dev/null -w '%{{http_code}}' --cacert {root} https://{domain}{path}").strip()
            assert code == "404", f"{path}: {code}"

    with subtest("a local-only instance is unreachable from the internet"):
        internet.fail(f"curl -sk --resolve intern.odoo.localhost:443:{server_ip} https://intern.odoo.localhost/web/login")
        internet.fail(f"curl -sk --resolve shop.odoo.localhost:443:{server_ip} https://shop.odoo.localhost/web/login")
        # No SNI or an unknown one: the handshake is refused.
        internet.fail(f"curl -sk https://{server_ip}/")
        for port in range(18069, 18073):
            internet.fail(f"curl -s --connect-timeout 3 http://{server_ip}:{port}/")
        server.succeed("curl -sf https://intern.odoo.localhost/web/login >/dev/null")

    with subtest("logins are rate limited"):
        codes = internet.succeed(
            "for i in $(seq 20); do "
            f"curl -s -o /dev/null -w '%{{http_code}}\\n' --cacert {root} https://{domain}/web/login; done"
        ).split()
        assert "429" in codes, codes
        assert codes[0] == "200", codes
  '';
}
