# Firefox trusts the Odoo CA: alice runs the home-manager Firefox
# (homeModules.default with homeSpec.programs.firefox, as on beelink)
# headless against https://demo.odoo.localhost. Firefox sends an HTTP
# request only after the TLS handshake succeeds, so a request in nginx's
# access log proves the certificate was trusted. The negative control,
# https://untrusted.localhost with a self-signed certificate, must never
# reach the access log, though Firefox must reach its TLS handshake.
# Firefox's own background requests fail (no network).
{
  inputs,
  self,
  ...
}: let
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

    users.users.alice.isNormalUser = true;
    # certutil, to read the CA out of the Firefox profile.
    environment.systemPackages = [pkgs.nss.tools];
    home-manager = {
      useGlobalPkgs = true;
      useUserPackages = true;
      # As a real profile: homeModules.default (the NixOS modules read
      # its homeSpec options), with only Firefox turned on.
      sharedModules = [inputs.plasma-manager.homeModules.plasma-manager];
      users.alice = {
        imports = [self.homeModules.default];
        homeSpec.programs.firefox.enable = true;
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

    def firefox(url, shot, must_finish=True):
        # A fresh profile each time: the policy must install the CA into it.
        # --screenshot never finishes on a certificate error page, so the
        # control only gets a short run whose exit status is ignored.
        cmd = "su - alice -c " + shlex.quote(
            f"rm -rf /tmp/ff-{shot} && mkdir /tmp/ff-{shot} && "
            f"timeout {180 if must_finish else 60} firefox --headless --no-remote "
            f"--profile /tmp/ff-{shot} --screenshot /tmp/{shot}.png {url}"
        )
        if must_finish:
            machine.succeed(cmd)
        else:
            machine.execute(cmd)

    start_all()
    wait_ready(machine, ["demo"])
    machine.wait_for_unit("home-manager-alice.service", timeout=300)
    machine.succeed("test -x /etc/profiles/per-user/alice/bin/firefox")

    with subtest("the untrusted control never gets past TLS"):
        firefox("https://untrusted.localhost/control-probe", "untrusted", must_finish=False)
        # Firefox reached nginx and gave up during the handshake ...
        machine.succeed(
            "grep -E 'SSL_do_handshake\\(\\) failed|peer closed connection in SSL handshake' "
            "/var/log/nginx/error.log >/dev/null"
        )
        # ... and never sent the request.
        machine.fail("grep control-probe /var/log/nginx/access.log >/dev/null")

    with subtest("Firefox opens the instance without a certificate error"):
        firefox(f"https://demo.{base_domain}/web/login?firefox-probe=1", "demo")
        machine.succeed(
            f"grep '^demo.{base_domain} \"GET /web/login?firefox-probe=1 ' /var/log/nginx/access.log | grep Firefox >/dev/null"
        )

    with subtest("the policy installed the CA into the profile"):
        machine.succeed(
            "certutil -L -d sql:/tmp/ff-demo | grep odoo-vm-test-ca >/dev/null"
        )
  '';
}
