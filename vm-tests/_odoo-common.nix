# Shared by the odoo VM tests (a helper, not a test: the name starts
# with _). Secrets are build-time fakes in the same shape as the clan
# vars generators: a CA name-constrained to the base domain and one
# certificate for the base domain and every instance under it.
{inputs}: rec {
  baseDomain = "odoo.localhost";
  adminPassword = "vm-test-admin-password";
  masterPassword = "vm-test-master-password";

  # hostSpec.services.odoo with the fakes, the probe and its tools. A test
  # adds instances.
  module = {pkgs, ...}: let
    tls = pkgs.runCommand "odoo-vm-test-tls" {nativeBuildInputs = [pkgs.openssl];} ''
      mkdir -p $out
      openssl req -x509 -newkey rsa:2048 -nodes \
        -keyout ca.key -out $out/ca.crt -days 30 -subj "/CN=odoo-vm-test-ca" \
        -addext "basicConstraints=critical,CA:TRUE,pathlen:0" \
        -addext "keyUsage=critical,keyCertSign,cRLSign" \
        -addext "nameConstraints=critical,permitted;DNS:${baseDomain}"
      openssl req -newkey rsa:2048 -nodes -keyout $out/tls.key -out tls.csr -subj "/CN=${baseDomain}"
      printf 'subjectAltName=DNS:${baseDomain},DNS:*.${baseDomain}\nextendedKeyUsage=serverAuth\nbasicConstraints=critical,CA:FALSE\n' > ext
      openssl x509 -req -in tls.csr -CA $out/ca.crt -CAkey ca.key -CAcreateserial \
        -out $out/tls.crt -days 30 -sha256 -extfile ext
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
      systemPackages = [pkgs.curl pkgs.python3];
      etc."odoo-probe.py".source = ./_odoo-probe.py;
    };
  };

  # Python for the test scripts: constants, the probe and readiness.
  pythonHelpers = ''
    import shlex

    base_domain = "${baseDomain}"
    admin_password = "${adminPassword}"
    master_password = "${masterPassword}"

    def probe(node, instance, *args):
        cmd = " ".join(shlex.quote(a) for a in ("python3", "/etc/odoo-probe.py", instance, *args))
        return node.succeed(cmd).strip()

    def probe_fails(node, instance, *args):
        cmd = " ".join(shlex.quote(a) for a in ("python3", "/etc/odoo-probe.py", instance, *args))
        node.fail(cmd)

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
