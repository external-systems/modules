# hostSpec.services.odoo end to end: Odoo + PostgreSQL + nginx on one
# machine, reachable at https://odoo.localhost from that machine only.
# Secrets are build-time fakes (provisionSecrets = false); the outsider
# node proves nothing listens beyond loopback.
{inputs, ...}: let
  domain = "odoo.localhost";
  adminPassword = "vm-test-admin-password";
  masterPassword = "vm-test-master-password";
in {
  nodes = {
    machine = {pkgs, ...}: let
      # Same shape as the clan vars generators: a name-constrained CA and
      # a server certificate for the domain.
      tls = pkgs.runCommand "odoo-vm-test-tls" {nativeBuildInputs = [pkgs.openssl];} ''
        mkdir -p $out
        openssl req -x509 -newkey rsa:2048 -nodes \
          -keyout ca.key -out $out/ca.crt -days 30 -subj "/CN=odoo-vm-test-ca" \
          -addext "basicConstraints=critical,CA:TRUE,pathlen:0" \
          -addext "keyUsage=critical,keyCertSign,cRLSign" \
          -addext "nameConstraints=critical,permitted;DNS:${domain}"
        openssl req -newkey rsa:2048 -nodes -keyout $out/tls.key -out tls.csr -subj "/CN=${domain}"
        printf 'subjectAltName=DNS:${domain}\nextendedKeyUsage=serverAuth\nbasicConstraints=critical,CA:FALSE\n' > ext
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

      # Database init with demo data and two workers.
      virtualisation = {
        memorySize = 4096;
        cores = 2;
      };
    };

    outsider = {pkgs, ...}: {
      environment.systemPackages = [pkgs.curl];
    };
  };

  testScript = ''
    import json

    domain = "${domain}"
    admin_password = "${adminPassword}"
    master_password = "${masterPassword}"

    def probe(*args):
        return machine.succeed("python3 /etc/odoo-probe.py " + " ".join(args)).strip()

    def wait_ready():
        machine.wait_for_unit("postgresql.service", timeout=300)
        # First boot creates the database with demo data.
        machine.wait_for_unit("odoo.service", timeout=1500)
        machine.wait_for_unit("nginx.service", timeout=300)
        for port in (8069, 8072, 443, 80):
            machine.wait_for_open_port(port, timeout=300)
        machine.wait_until_succeeds(f"curl -sf https://{domain}/web/login", timeout=300)

    start_all()

    with subtest("Odoo, PostgreSQL and nginx come up"):
        wait_ready()

    with subtest("the domain resolves to loopback"):
        machine.succeed(f"getent ahostsv4 {domain} | grep -q '^127\\.0\\.0\\.1 '")

    with subtest("HTTPS is trusted without -k, HTTP redirects to it"):
        machine.succeed(f"curl -sf https://{domain}/web/login | grep -q 'name=\"login\"'")
        location = machine.succeed(
            f"curl -s -o /dev/null -w '%{{http_code}} %{{redirect_url}}' http://{domain}/web/login"
        ).strip()
        assert location == f"301 https://{domain}/web/login", location
        # Firefox gets the CA through its enterprise policy.
        policy = json.loads(machine.succeed("cat /etc/firefox/policies/policies.json"))
        assert policy["policies"]["Certificates"]["Install"][0].endswith("/ca.crt"), policy

    with subtest("admin logs in with the provisioned password, not admin/admin"):
        probe("login", admin_password)
        machine.fail("python3 /etc/odoo-probe.py login admin")

    with subtest("demo data is loaded"):
        probe("demo", admin_password)

    with subtest("the websocket upgrades through nginx"):
        code = machine.succeed(
            f"curl --http1.1 -s -o /dev/null -w '%{{http_code}}' --max-time 5 "
            "-H 'Connection: Upgrade' -H 'Upgrade: websocket' -H 'Sec-WebSocket-Version: 13' "
            "-H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' "
            f"-H 'Origin: https://{domain}' https://{domain}/websocket || true"
        ).strip()
        assert code == "101", code

    with subtest("the master password stays out of the store"):
        pid = machine.succeed("systemctl show -p MainPID --value odoo.service").strip()
        machine.succeed(f"tr '\\0' '\\n' < /proc/{pid}/environ | grep -qx 'ODOO_RC=/run/odoo/odoo.cfg'")
        assert machine.succeed("stat -c '%a %U' /run/odoo/odoo.cfg").strip() == "600 odoo"
        machine.succeed(f"grep -qx 'admin_passwd = {master_password}' /run/odoo/odoo.cfg")
        machine.succeed("ls /nix/store/*-odoo.cfg")
        machine.fail(f"grep -qs '{master_password}' /nix/store/*-odoo.cfg")

    with subtest("the database manager is disabled"):
        # Odoo 19 still renders the page (200), with a notice; the
        # database service itself refuses, even with the master password.
        machine.succeed(
            f"curl -sf https://{domain}/web/database/manager | grep -q 'disabled by the administrator'"
        )
        machine.fail("python3 /etc/odoo-probe.py db-list")
        machine.fail(f"python3 /etc/odoo-probe.py db-drop {master_password}")
        probe("login", admin_password)

    with subtest("everything listens on loopback only"):
        listeners = machine.succeed("ss -ltnH").split("\n")
        for port in ("80", "443", "8069", "8072"):
            local = [line.split()[3] for line in listeners if line and line.split()[3].endswith(":" + port)]
            assert local, f"nothing listens on {port}"
            for address in local:
                assert address.startswith(("127.0.0.1:", "[::1]:")), f"{address} is not loopback"
        for port in (80, 443, 8069, 8072):
            outsider.fail(f"curl -s --connect-timeout 3 http://machine:{port}/")

    with subtest("a password changed in Odoo survives a restart"):
        probe("set-password", admin_password, "changed-in-the-ui")
        machine.succeed("systemctl restart odoo.service")
        machine.wait_for_unit("odoo.service", timeout=300)
        machine.wait_until_succeeds(f"curl -sf https://{domain}/web/login", timeout=300)
        probe("login", "changed-in-the-ui")
        probe("set-password", "changed-in-the-ui", admin_password)

    with subtest("a reboot neither re-initialises nor resets anything"):
        marker = "/var/lib/private/odoo/data/.odoo.initialized"
        before = machine.succeed(f"stat -c %Y {marker}").strip()
        machine.shutdown()
        machine.start()
        wait_ready()
        assert machine.succeed(f"stat -c %Y {marker}").strip() == before
        machine.fail("journalctl -b -u odoo.service | grep -q 'setting the admin password'")
        probe("login", admin_password)
        probe("demo", admin_password)
  '';
}
