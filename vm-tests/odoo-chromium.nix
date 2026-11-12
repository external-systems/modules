# Chromium trusts the Odoo CA: alice has Chromium in her user packages
# (as matt does on beelink) and runs it headless against
# https://demo.odoo.localhost. Chromium sends an HTTP request only after
# the TLS handshake succeeds, so a request in nginx's access log proves
# the certificate was trusted. Each trust path is checked on its own:
# system trust (security.pki, which Chromium reads through NSS, whose
# built-in roots NixOS replaces with p11-kit and /etc/ssl/trust-source)
# and the CACertificates policy each suffice, and with neither Chromium
# refuses the CA (alice's NSS database is empty). The negative control, https://untrusted.localhost
# with a self-signed certificate, must never reach the access log,
# though Chromium must reach its TLS handshake.
{inputs, ...}: let
  common = import ./_odoo-common.nix {inherit inputs;};
in {
  nodes.machine = {pkgs, ...}: let
    untrusted = pkgs.runCommand "untrusted-tls" {nativeBuildInputs = [pkgs.openssl];} ''
      mkdir -p $out
      openssl req -x509 -newkey rsa:2048 -nodes -keyout $out/tls.key -out $out/tls.crt \
        -days 30 -subj "/CN=untrusted.localhost" -addext "subjectAltName=DNS:untrusted.localhost"
    '';
  in {
    imports = [common.module];
    # No demo data: the database is ready sooner, and only TLS matters here.
    hostSpec.services.odoo.instances.demo = {
      demoData = false;
      workers = 1;
    };

    services.nginx = {
      # Log the host, so each request is attributable to its vhost.
      commonHttpConfig = ''
        log_format withhost '$host "$request" "$http_user_agent"';
        access_log /var/log/nginx/access.log withhost;
        # info: handshakes a client aborts (the untrusted control).
        error_log /var/log/nginx/error.log info;
      '';
      virtualHosts."untrusted.localhost" = {
        forceSSL = true;
        listenAddresses = ["127.0.0.1"];
        sslCertificate = "${untrusted}/tls.crt";
        sslCertificateKey = "${untrusted}/tls.key";
        locations."/".return = "200 untrusted";
      };
    };
    networking.hosts."127.0.0.1" = ["untrusted.localhost"];

    users.users.alice = {
      isNormalUser = true;
      packages = [pkgs.chromium];
    };
    environment = {
      # jq reads the policy, trust (p11-kit) lists the system anchors.
      systemPackages = [pkgs.jq pkgs.p11-kit];
      # System trust without the Odoo CA, swapped in to test the policy alone.
      etc = {
        "stock-ca-bundle.crt".source = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
        "stock-trust-source".source = "${pkgs.cacert.p11kit}/etc/ssl/trust-source";
      };
    };

    virtualisation = {
      memorySize = 4096;
      cores = 2;
    };
  };

  globalTimeout = 2400;

  testScript = ''
    ${common.pythonHelpers}

    def chromium(url, profile):
        # A fresh profile each time. --dump-dom exits on an interstitial
        # too, so the exit status says nothing about trust; the timeout
        # only guards against a hang.
        machine.execute("su - alice -c " + shlex.quote(
            f"rm -rf /tmp/cr-{profile} && "
            f"timeout 120 chromium --headless --disable-gpu --no-first-run "
            f"--user-data-dir=/tmp/cr-{profile} --dump-dom {url} > /tmp/cr-{profile}.html"
        ))

    start_all()
    wait_ready(machine, ["demo"])
    machine.succeed("test -x /etc/profiles/per-user/alice/bin/chromium")
    machine.succeed(
        "jq -e '.CACertificates | length == 1' /etc/chromium/policies/managed/odoo-ca.json"
    )

    with subtest("the untrusted control never gets past TLS"):
        chromium("https://untrusted.localhost/control-probe", "untrusted")
        machine.succeed(
            "grep -E 'SSL_do_handshake\\(\\) failed|peer closed connection in SSL handshake|SSL alert' "
            "/var/log/nginx/error.log >/dev/null"
        )
        machine.fail("grep control-probe /var/log/nginx/access.log >/dev/null")

    def trusted(probe):
        chromium(f"https://demo.{base_domain}/web/login?{probe}=1", probe)
        return machine.execute(
            f"grep '^demo.{base_domain} \"GET /web/login?{probe}=1 ' /var/log/nginx/access.log | grep Chrome >/dev/null"
        )[0] == 0

    policy = "/etc/chromium/policies/managed/odoo-ca.json"
    bundles = "/etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/ca-bundle.crt /etc/pki/tls/certs/ca-bundle.crt"

    with subtest("Chromium opens the instance without a certificate error"):
        assert trusted("both-probe"), "Chromium rejected the Odoo CA"

    with subtest("system trust alone is enough"):
        machine.succeed(f"cp -L {policy} /tmp/odoo-ca.json && rm {policy}")
        machine.succeed(
            "openssl verify -CAfile /etc/ssl/certs/ca-certificates.crt /etc/odoo-test-tls/tls.crt"
        )
        assert trusted("system-probe"), "Chromium ignored system trust"

    with subtest("with neither, Chromium refuses the CA"):
        machine.succeed(
            f"for b in {bundles}; do ln -sfn /etc/stock-ca-bundle.crt $b; done && "
            "ln -sfn /etc/stock-trust-source /etc/ssl/trust-source && "
            "! trust list --filter=ca-anchors | grep odoo-vm-test-ca"
        )
        machine.fail(
            "openssl verify -CAfile /etc/ssl/certs/ca-certificates.crt /etc/odoo-test-tls/tls.crt"
        )
        assert not trusted("neither-probe"), "Chromium trusted the CA from somewhere else"

    with subtest("the policy alone is enough"):
        machine.succeed(f"cp /tmp/odoo-ca.json {policy}")
        assert trusted("policy-probe"), "Chromium ignored the CACertificates policy"
  '';
}
