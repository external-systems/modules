# hostSpec.services.odoo end to end: two Odoo instances on one machine,
# demo (demo data) and blank (none), each with its own database, user and
# state, behind nginx at https://<name>.odoo.localhost from that machine
# only; https://odoo.localhost lists them. empty enables the module with
# no instances: only PostgreSQL runs. The outsider node proves nothing
# listens beyond loopback. Secrets are build-time fakes
# (_odoo-common.nix, provisionSecrets = false).
{inputs, ...}: let
  common = import ./_odoo-common.nix {inherit inputs;};
in {
  nodes = {
    machine = {
      imports = [common.module];
      hostSpec.services.odoo.instances = {
        demo.workers = 1;
        blank = {
          demoData = false;
          workers = 1;
          memoryMax = "2G";
        };
      };
      # Two databases created at once, one with demo data.
      virtualisation = {
        memorySize = 6144;
        cores = 4;
      };
    };

    empty = {
      imports = [common.module];
    };

    outsider = {pkgs, ...}: {
      environment.systemPackages = [pkgs.curl];
    };
  };

  # Each first start creates a database (with demo data, minutes), and
  # the test reboots once.
  globalTimeout = 3600;

  testScript = ''
    import json

    ${common.pythonHelpers}

    instances = ["demo", "blank"]
    # Ports in name order from basePort: blank 18069/18070, demo 18071/18072.
    ports = {"blank": (18069, 18070), "demo": (18071, 18072)}

    start_all()

    with subtest("both instances, PostgreSQL and nginx come up"):
        wait_ready(machine, instances)
        for name, (http, gevent) in ports.items():
            machine.wait_for_open_port(http, timeout=300)
            machine.wait_for_open_port(gevent, timeout=300)
            pid = machine.succeed(f"systemctl show -p MainPID --value odoo-{name}.service").strip()
            assert machine.succeed(f"ps -o user= -p {pid}").strip() == f"odoo-{name}"

    with subtest("every name resolves to loopback"):
        for host in (base_domain, f"demo.{base_domain}", f"blank.{base_domain}"):
            machine.succeed(f"getent ahostsv4 {host} | grep '^127\\.0\\.0\\.1 ' >/dev/null")

    with subtest("HTTPS is trusted without -k, HTTP redirects to it"):
        for name in instances:
            host = f"{name}.{base_domain}"
            machine.succeed(f"curl -sf https://{host}/web/login | grep 'name=\"login\"' >/dev/null")
            location = machine.succeed(
                f"curl -s -o /dev/null -w '%{{http_code}} %{{redirect_url}}' http://{host}/web/login"
            ).strip()
            assert location == f"301 https://{host}/web/login", location
        # Firefox gets the CA through its enterprise policy.
        policy = json.loads(machine.succeed("cat /etc/firefox/policies/policies.json"))
        assert policy["policies"]["Certificates"]["Install"][0].endswith("/ca.crt"), policy

    with subtest("the index lists every instance"):
        index = machine.succeed(f"curl -sf https://{base_domain}/")
        for name in instances:
            assert f'href="https://{name}.{base_domain}/"' in index, index
        listing = machine.succeed("odoo-reset --list")
        assert f"https://demo.{base_domain}" in listing and "no-demo" in listing, listing

    with subtest("admin logs in with the provisioned password, not admin/admin"):
        for name in instances:
            probe(machine, name, "login", admin_password)
            probe_fails(machine, name, "login", "admin")

    with subtest("demo has demo data, blank has none"):
        probe(machine, "demo", "demo", admin_password)
        probe(machine, "blank", "no-demo", admin_password)

    with subtest("the instances are isolated"):
        probe(machine, "demo", "partner-create", admin_password, "only-in-demo")
        probe(machine, "demo", "partner-exists", admin_password, "only-in-demo")
        probe_fails(machine, "blank", "partner-exists", admin_password, "only-in-demo")
        # One instance's role cannot read the other's database.
        machine.fail(
            "runuser -u odoo-demo -- psql -d odoo-blank -c 'SELECT count(*) FROM res_partner'"
        )
        machine.succeed(
            "runuser -u odoo-blank -- psql -d odoo-blank -c 'SELECT count(*) FROM res_partner'"
        )
        for name in instances:
            machine.succeed(f"test -e /var/lib/private/odoo-{name}/data/.odoo.initialized")

    with subtest("the websocket upgrades through nginx"):
        for name in instances:
            host = f"{name}.{base_domain}"
            code = machine.succeed(
                f"curl --http1.1 -s -o /dev/null -w '%{{http_code}}' --max-time 5 "
                "-H 'Connection: Upgrade' -H 'Upgrade: websocket' -H 'Sec-WebSocket-Version: 13' "
                "-H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' "
                f"-H 'Origin: https://{host}' https://{host}/websocket || true"
            ).strip()
            assert code == "101", f"{name}: {code}"

    with subtest("nginx reloads (deploys and certificate renewals reload it)"):
        machine.succeed("systemctl reload nginx.service")
        machine.succeed("systemctl is-active nginx.service")
        machine.succeed(f"curl -sf https://demo.{base_domain}/web/login >/dev/null")

    with subtest("the master password stays out of the store"):
        for name in instances:
            unit = f"odoo-{name}"
            pid = machine.succeed(f"systemctl show -p MainPID --value {unit}.service").strip()
            machine.succeed(f"tr '\\0' '\\n' < /proc/{pid}/environ | grep -x 'ODOO_RC=/run/{unit}/odoo.cfg' >/dev/null")
            assert machine.succeed(f"stat -c '%a %U' /run/{unit}/odoo.cfg").strip() == f"600 {unit}"
            machine.succeed(f"grep -qx 'admin_passwd = {master_password}' /run/{unit}/odoo.cfg")
            machine.succeed(f"ls /nix/store/*-{unit}.cfg")
            machine.fail(f"grep -qs '{master_password}' /nix/store/*-{unit}.cfg")

    with subtest("the database manager is disabled"):
        # Odoo 19 still renders the page (200), with a notice; the
        # database service itself refuses, even with the master password.
        machine.succeed(
            f"curl -sf https://demo.{base_domain}/web/database/manager | grep 'disabled by the administrator' >/dev/null"
        )
        probe_fails(machine, "demo", "db-list")
        probe_fails(machine, "demo", "db-drop", master_password)
        probe(machine, "demo", "login", admin_password)

    with subtest("everything listens on loopback only"):
        listeners = machine.succeed("ss -ltnH").split("\n")
        # Odoo, nginx and Mailpit (UI 8025, SMTP 1025).
        for port in ("80", "443", "18069", "18070", "18071", "18072", "8025", "1025"):
            local = [line.split()[3] for line in listeners if line and line.split()[3].endswith(":" + port)]
            assert local, f"nothing listens on {port}"
            for address in local:
                assert address.startswith(("127.0.0.1:", "[::1]:")), f"{address} is not loopback"
        for port in (80, 443, 18069, 18070, 18071, 18072, 8025, 1025):
            outsider.fail(f"curl -s --connect-timeout 3 http://machine:{port}/")

    with subtest("a crashed instance comes back on its own"):
        pid = machine.succeed("systemctl show -p MainPID --value odoo-blank.service").strip()
        machine.succeed(f"kill -9 {pid}")
        machine.wait_until_succeeds(
            f"[ \"$(systemctl show -p MainPID --value odoo-blank.service)\" != {pid} ] && systemctl is-active odoo-blank.service",
            timeout=120,
        )
        machine.wait_until_succeeds(f"curl -sf https://blank.{base_domain}/web/login >/dev/null", timeout=300)
        assert machine.succeed("systemctl show -p NRestarts --value odoo-blank.service").strip() == "1"

    with subtest("memory is capped per instance and per worker"):
        assert machine.succeed("systemctl show -p MemoryMax --value odoo-demo.service").strip() == str(4 * 1024**3)
        assert machine.succeed("systemctl show -p MemoryMax --value odoo-blank.service").strip() == str(2 * 1024**3)
        machine.succeed(f"grep -x 'limit_memory_hard={2048 * 1024 * 1024}' /run/odoo-demo/odoo.cfg >/dev/null")
        machine.succeed("grep -x 'max_cron_threads=1' /run/odoo-demo/odoo.cfg >/dev/null")

    with subtest("a password changed in Odoo survives a restart"):
        probe(machine, "demo", "set-password", admin_password, "changed-in-the-ui")
        machine.succeed("systemctl restart odoo-demo.service")
        machine.wait_for_unit("odoo-demo.service", timeout=300)
        machine.wait_until_succeeds(f"curl -sf https://demo.{base_domain}/web/login", timeout=300)
        probe(machine, "demo", "login", "changed-in-the-ui")
        probe(machine, "demo", "set-password", "changed-in-the-ui", admin_password)

    with subtest("a reboot neither re-initialises nor resets anything"):
        markers = {name: f"/var/lib/private/odoo-{name}/data/.odoo.initialized" for name in instances}
        before = {name: machine.succeed(f"stat -c %Y {m}").strip() for name, m in markers.items()}
        machine.shutdown()
        machine.start()
        wait_ready(machine, instances)
        for name, marker in markers.items():
            assert machine.succeed(f"stat -c %Y {marker}").strip() == before[name], name
            machine.fail(f"journalctl -b -u odoo-{name}.service | grep 'setting the admin password' >/dev/null")
            probe(machine, name, "login", admin_password)
        probe(machine, "demo", "demo", admin_password)
        probe(machine, "demo", "partner-exists", admin_password, "only-in-demo")

    with subtest("no instances: only PostgreSQL runs"):
        empty.wait_for_unit("multi-user.target", timeout=300)
        empty.wait_for_unit("postgresql.service", timeout=300)
        empty.fail("systemctl list-units --all --plain --no-legend 'odoo-*' | grep . >/dev/null")
        empty.fail("systemctl is-active nginx.service")
        empty.fail("systemctl is-active mailpit-odoo.service")
        assert "No Odoo instances configured." in empty.succeed("odoo-reset --list")
        empty.succeed("odoo-reset --all --yes")
        assert "Nothing left behind" in empty.succeed("odoo-purge")
  '';
}
