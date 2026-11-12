# Shared by the odoo VM tests (a helper, not a test: the name starts
# with _). Secrets are build-time fakes in the same shape as the clan
# vars generators: a CA name-constrained to the base domain and one
# certificate for the base domain and every instance under it.
{inputs}: rec {
  baseDomain = "odoo.localhost";
  adminPassword = "vm-test-admin-password";
  masterPassword = "vm-test-master-password";

  # hostSpec.services.odoo with the fakes, the probe and its tools. A test
  # adds instances. The fakes cover the node's own LAN domain
  # (odoo.<hostName>.home.arpa); evil.crt is signed by the same CA for a
  # name outside its constraints, which clients must reject.
  module = {
    config,
    pkgs,
    ...
  }: let
    inherit (config.hostSpec.services.odoo.lan) domain;
    tls = pkgs.runCommand "odoo-vm-test-tls" {nativeBuildInputs = [pkgs.openssl];} ''
      mkdir -p $out
      openssl req -x509 -newkey rsa:2048 -nodes \
        -keyout ca.key -out $out/ca.crt -days 30 -subj "/CN=odoo-vm-test-ca" \
        -addext "basicConstraints=critical,CA:TRUE,pathlen:0" \
        -addext "keyUsage=critical,keyCertSign,cRLSign" \
        -addext "nameConstraints=critical,permitted;DNS:${baseDomain},permitted;DNS:${domain}"
      sign() {
        openssl req -newkey rsa:2048 -nodes -keyout "$1.key" -out "$1.csr" -subj "/CN=$2"
        printf 'subjectAltName=%s\nextendedKeyUsage=serverAuth\nbasicConstraints=critical,CA:FALSE\n' "$3" > "$1.ext"
        openssl x509 -req -in "$1.csr" -CA $out/ca.crt -CAkey ca.key -CAcreateserial \
          -out "$1.crt" -days 30 -sha256 -extfile "$1.ext"
      }
      sign tls ${baseDomain} "DNS:${baseDomain},DNS:*.${baseDomain},DNS:${domain},DNS:*.${domain}"
      sign evil evil.example.com "DNS:evil.example.com"
      cp tls.crt tls.key evil.crt $out/
    '';
  in {
    hostSpec.services.odoo = {
      enable = true;
      package = inputs.org-pkgs.packages.${pkgs.stdenv.hostPlatform.system}.odoo19;
      provisionSecrets = false;
      caFile = "${tls}/ca.crt";
      tlsCertFile = "${tls}/tls.crt";
      tlsKeyFile = "${tls}/tls.key";
      adminPasswordFile = "${pkgs.writeText "admin-password" adminPassword}";
      masterPasswordFile = "${pkgs.writeText "master-password" masterPassword}";
    };

    environment = {
      systemPackages = [pkgs.curl pkgs.python3 pkgs.openssl];
      etc = {
        "odoo-probe.py".source = ./_odoo-probe.py;
        "odoo-test-tls".source = tls;
      };
    };
  };

  # A LAN client: the probe and its tools, no Odoo.
  clientModule = {pkgs, ...}: {
    environment = {
      systemPackages = [pkgs.curl pkgs.python3 pkgs.openssl];
      etc."odoo-probe.py".source = ./_odoo-probe.py;
    };
  };

  # Python for the test scripts: constants, the probe and readiness.
  pythonHelpers = ''
    import shlex

    base_domain = "${baseDomain}"
    admin_password = "${adminPassword}"
    master_password = "${masterPassword}"

    def probe_cmd(instance, args, domain=None, cafile=None, host=None):
        env = ""
        if domain:
            env += f"ODOO_PROBE_DOMAIN={shlex.quote(domain)} "
        if host:
            env += f"ODOO_PROBE_HOST={shlex.quote(host)} "
        if cafile:
            env += f"ODOO_PROBE_CAFILE={shlex.quote(cafile)} "
        return env + " ".join(shlex.quote(a) for a in ("python3", "/etc/odoo-probe.py", instance, *args))

    def probe(node, instance, *args, domain=None, cafile=None, host=None):
        return node.succeed(probe_cmd(instance, args, domain, cafile, host)).strip()

    def probe_fails(node, instance, *args, domain=None, cafile=None, host=None):
        node.fail(probe_cmd(instance, args, domain, cafile, host))

    def wait_ready(node, instances):
        node.wait_for_unit("postgresql.service", timeout=300)
        # The first start creates each database (with demo data, minutes).
        for name in instances:
            node.wait_for_unit(f"odoo-{name}.service", timeout=1500)
        node.wait_for_unit("nginx.service", timeout=300)
        node.wait_for_open_port(443, timeout=300)
        for name in instances:
            node.wait_until_succeeds(f"curl -sf https://{name}.{base_domain}/web/login", timeout=300)
  '';
}
