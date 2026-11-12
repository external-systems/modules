# odoo-reset and odoo-purge on two instances: demo (demo data) and blank
# (none). Records, an attachment in the filestore and a password changed
# in the UI disappear on reset; the instance comes back as freshly
# created, with or without demo data as configured, and the other
# instance is untouched. odoo-purge removes what a removed instance left
# behind (database, role, state) and never touches a configured one.
# Refusals change nothing.
{inputs, ...}: let
  common = import ./_odoo-common.nix {inherit inputs;};
in {
  nodes.machine = {
    imports = [common.module];
    hostSpec.services.odoo.instances = {
      demo.workers = 1;
      blank = {
        demoData = false;
        workers = 1;
      };
    };
    virtualisation = {
      memorySize = 6144;
      cores = 4;
    };
  };

  # Five database creations: two at boot, one reset, then both again.
  globalTimeout = 3600;

  testScript = ''
    ${common.pythonHelpers}

    def marker(name):
        return machine.succeed(f"stat -c %Y /var/lib/private/odoo-{name}/data/.odoo.initialized").strip()

    def sql(query):
        return machine.succeed(f"runuser -u postgres -- psql -qtA -d postgres -c {shlex.quote(query)}").strip()

    start_all()
    wait_ready(machine, ["demo", "blank"])

    with subtest("seed both instances"):
        for name in ("demo", "blank"):
            probe(machine, name, "partner-create", admin_password, f"seeded-{name}")
        attachment = probe(machine, "demo", "attachment-create", admin_password)
        machine.succeed(f"test -f {attachment}")
        probe(machine, "demo", "set-password", admin_password, "changed-in-the-ui")
        demo_marker = marker("demo")

    with subtest("refusals change nothing"):
        # Without a terminal and without --yes.
        machine.fail("odoo-reset demo < /dev/null")
        # An unknown name, even next to a known one.
        machine.fail("odoo-reset --yes demo nope")
        # --all with names.
        machine.fail("odoo-reset --yes --all demo")
        # Not root.
        machine.fail("runuser -u nobody -- odoo-reset --yes demo")
        machine.succeed("systemctl is-active odoo-demo.service")
        probe(machine, "demo", "partner-exists", "changed-in-the-ui", "seeded-demo")
        machine.succeed(f"test -f {attachment}")
        assert marker("demo") == demo_marker

    with subtest("odoo-reset demo: fresh demo database, blank untouched"):
        machine.succeed("odoo-reset --yes demo >&2")
        machine.succeed("systemctl is-active odoo-demo.service")
        assert marker("demo") != demo_marker
        # The provisioned admin password is back; the UI change is gone.
        probe(machine, "demo", "login", admin_password)
        probe_fails(machine, "demo", "login", "changed-in-the-ui")
        probe(machine, "demo", "demo", admin_password)
        probe_fails(machine, "demo", "partner-exists", admin_password, "seeded-demo")
        machine.fail(f"test -e {attachment}")
        # blank kept its record.
        probe(machine, "blank", "partner-exists", admin_password, "seeded-blank")

    with subtest("odoo-reset --all: each instance comes back as configured"):
        probe(machine, "demo", "partner-create", admin_password, "seeded-again")
        machine.succeed("odoo-reset --yes --all >&2")
        for name in ("demo", "blank"):
            machine.succeed(f"systemctl is-active odoo-{name}.service")
            probe(machine, name, "login", admin_password)
        probe_fails(machine, "demo", "partner-exists", admin_password, "seeded-again")
        probe_fails(machine, "blank", "partner-exists", admin_password, "seeded-blank")
        probe(machine, "demo", "demo", admin_password)
        probe(machine, "blank", "no-demo", admin_password)
        listing = machine.succeed("odoo-reset --list")
        assert "active" in listing, listing

    with subtest("odoo-purge lists and deletes what a removed instance left"):
        assert "Nothing left behind" in machine.succeed("odoo-purge")
        # What a removed instance "gone" leaves: role, database, state.
        sql('CREATE ROLE "odoo-gone" LOGIN')
        sql('CREATE DATABASE "odoo-gone" OWNER "odoo-gone"')
        machine.succeed("mkdir -p /var/lib/private/odoo-gone/data/filestore")
        listing = machine.succeed("odoo-purge")
        assert listing.strip().splitlines()[-1] == "gone", listing
        # Refusals: configured instances, bad names, no terminal, not root.
        machine.fail("odoo-purge --yes demo")
        machine.fail("odoo-purge --yes 'x; rm -rf /'")
        machine.fail("odoo-purge gone < /dev/null")
        machine.fail("runuser -u nobody -- odoo-purge --yes gone")
        assert sql("SELECT count(*) FROM pg_database WHERE datname = 'odoo-gone'") == "1"
        machine.succeed("odoo-purge --yes gone >&2")
        assert sql("SELECT count(*) FROM pg_database WHERE datname = 'odoo-gone'") == "0"
        assert sql("SELECT count(*) FROM pg_roles WHERE rolname = 'odoo-gone'") == "0"
        machine.fail("test -e /var/lib/private/odoo-gone")
        assert "Nothing left behind" in machine.succeed("odoo-purge")
        # The configured instances are untouched.
        for name in ("demo", "blank"):
            probe(machine, name, "login", admin_password)
        assert sql("SELECT count(*) FROM pg_database WHERE datname IN ('odoo-demo', 'odoo-blank')") == "2"
  '';
}
