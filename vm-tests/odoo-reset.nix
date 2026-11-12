# odoo-reset, odoo-snapshot and odoo-purge on two instances: demo (demo
# data) and blank (none). The first start saves each new database as its
# reset copy; a reset restores it in seconds, and records, files and a
# password changed in the UI are gone. --clean and a stale copy fall back
# to creating the database from scratch, which makes a new copy.
# Snapshots save a state and bring it back, password included. odoo-purge
# removes what a removed instance left (database, role, state, reset copy,
# snapshots) and never touches a configured one. Refusals change nothing.
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

  # Four databases created from scratch: two at boot, --clean, a stale copy.
  globalTimeout = 3600;

  testScript = ''
    import time

    ${common.pythonHelpers}

    def marker(name):
        return machine.succeed(f"stat -c %Y /var/lib/private/odoo-{name}/data/.odoo.initialized").strip()

    def sql(query):
        return machine.succeed(f"runuser -u postgres -- psql -qtA -d postgres -c {shlex.quote(query)}").strip()

    def copy_state(name):
        line = [l for l in machine.succeed("odoo-reset --list").splitlines() if l.startswith(name + " ")]
        assert line, f"{name} not listed"
        return line[0].split()[4]

    def reset(args):
        start = time.monotonic()
        out = machine.succeed(f"odoo-reset --yes {args} 2>&1")
        return out, time.monotonic() - start

    start_all()
    wait_ready(machine, ["demo", "blank"])

    with subtest("the first start saves a reset copy of each new database"):
        for name in ("demo", "blank"):
            assert copy_state(name) == "ready", machine.succeed("odoo-reset --list")
            machine.succeed(f"test -s /var/lib/odoo-golden/{name}/data.tar")
            assert sql(f"SELECT datistemplate AND NOT datallowconn FROM pg_database WHERE datname = 'odoo-{name}@golden'") == "t"
            machine.fail(f"test -e /var/lib/private/odoo-{name}/data/.golden-pending")
        assert machine.succeed("stat -c '%a %U' /var/lib/odoo-golden").strip() == "700 root"

    with subtest("seed both instances"):
        for name in ("demo", "blank"):
            probe(machine, name, "partner-create", admin_password, f"seeded-{name}")
        attachment = probe(machine, "demo", "attachment-create", admin_password)
        machine.succeed(f"test -f {attachment}")
        probe(machine, "demo", "set-password", admin_password, "changed-in-the-ui")
        demo_marker = marker("demo")

    with subtest("refusals change nothing"):
        machine.fail("odoo-reset demo < /dev/null")
        machine.fail("odoo-reset --yes demo nope")
        machine.fail("odoo-reset --yes --all demo")
        machine.fail("runuser -u nobody -- odoo-reset --yes demo")
        machine.succeed("systemctl is-active odoo-demo.service")
        probe(machine, "demo", "partner-exists", "changed-in-the-ui", "seeded-demo")
        machine.succeed(f"test -f {attachment}")
        assert marker("demo") == demo_marker

    with subtest("odoo-reset demo restores the reset copy in seconds"):
        out, took = reset("demo")
        assert "restoring the reset copy" in out, out
        assert took < 120, f"reset took {took:.0f} s"
        machine.succeed("systemctl is-active odoo-demo.service")
        probe(machine, "demo", "login", admin_password)
        probe_fails(machine, "demo", "login", "changed-in-the-ui")
        probe(machine, "demo", "demo", admin_password)
        probe_fails(machine, "demo", "partner-exists", admin_password, "seeded-demo")
        machine.fail(f"test -e {attachment}")
        probe(machine, "blank", "partner-exists", admin_password, "seeded-blank")
        assert copy_state("demo") == "ready"

    with subtest("--clean creates the database from scratch and a new copy"):
        out, _ = reset("--clean demo")
        assert "from scratch" in out, out
        assert marker("demo") != demo_marker
        probe(machine, "demo", "demo", admin_password)
        assert copy_state("demo") == "ready"

    with subtest("a stale copy is not used"):
        machine.succeed("echo stale > /var/lib/odoo-golden/blank/key")
        assert copy_state("blank") == "stale"
        out, _ = reset("blank")
        assert "no valid reset copy" in out, out
        probe_fails(machine, "blank", "partner-exists", admin_password, "seeded-blank")
        probe(machine, "blank", "no-demo", admin_password)
        assert copy_state("blank") == "ready"

    with subtest("odoo-reset --all: each instance comes back as configured"):
        probe(machine, "demo", "partner-create", admin_password, "seeded-again")
        out, _ = reset("--all")
        assert out.count("restoring the reset copy") == 2, out
        probe_fails(machine, "demo", "partner-exists", admin_password, "seeded-again")
        probe(machine, "demo", "demo", admin_password)
        probe(machine, "blank", "no-demo", admin_password)

    with subtest("snapshots save a state and bring it back"):
        probe(machine, "demo", "partner-create", admin_password, "before-step-x")
        probe(machine, "demo", "set-password", admin_password, "snapshot-password")
        machine.succeed("odoo-snapshot save demo before-x >&2")
        assert "before-x" in machine.succeed("odoo-snapshot list demo")
        assert sql("SELECT count(*) FROM pg_database WHERE datname = 'odoo-demo@snap-before-x'") == "1"
        # Step X: more data, then a reset wipes everything.
        probe(machine, "demo", "partner-create", "snapshot-password", "after-step-x")
        reset("demo")
        probe_fails(machine, "demo", "partner-exists", admin_password, "before-step-x")
        # The snapshot survived the reset and brings back its state.
        machine.fail("odoo-snapshot restore demo before-x < /dev/null")
        machine.succeed("odoo-snapshot restore --yes demo before-x >&2")
        probe(machine, "demo", "partner-exists", "snapshot-password", "before-step-x")
        probe_fails(machine, "demo", "partner-exists", "snapshot-password", "after-step-x")
        # Refusals: an existing tag, a bad tag, an unknown instance, not root.
        machine.fail("odoo-snapshot save demo before-x")
        machine.fail("odoo-snapshot save demo 'Bad Tag'")
        machine.fail("odoo-snapshot save nope x")
        machine.fail("runuser -u nobody -- odoo-snapshot list")
        machine.succeed("odoo-snapshot rm --yes demo before-x")
        assert "before-x" not in machine.succeed("odoo-snapshot list")
        assert sql("SELECT count(*) FROM pg_database WHERE datname LIKE 'odoo-demo@snap-%'") == "0"
        reset("demo")

    with subtest("odoo-purge lists and deletes what a removed instance left"):
        assert "Nothing left behind" in machine.succeed("odoo-purge")
        # What a removed instance "gone" leaves: role, database, reset copy,
        # a snapshot, state.
        sql('CREATE ROLE "odoo-gone" LOGIN')
        sql('CREATE DATABASE "odoo-gone" OWNER "odoo-gone"')
        sql('CREATE DATABASE "odoo-gone@golden" TEMPLATE "odoo-gone"')
        sql('ALTER DATABASE "odoo-gone@golden" WITH IS_TEMPLATE true ALLOW_CONNECTIONS false')
        sql('CREATE DATABASE "odoo-gone@snap-x" TEMPLATE "odoo-gone"')
        machine.succeed("mkdir -p /var/lib/private/odoo-gone/data /var/lib/odoo-golden/gone /var/lib/odoo-snapshots/gone")
        listing = machine.succeed("odoo-purge")
        assert listing.strip().splitlines()[-1] == "gone", listing
        machine.fail("odoo-purge --yes demo")
        machine.fail("odoo-purge --yes 'x; rm -rf /'")
        machine.fail("odoo-purge gone < /dev/null")
        machine.fail("runuser -u nobody -- odoo-purge --yes gone")
        assert sql("SELECT count(*) FROM pg_database WHERE datname LIKE 'odoo-gone%'") == "3"
        machine.succeed("odoo-purge --yes gone >&2")
        assert sql("SELECT count(*) FROM pg_database WHERE datname LIKE 'odoo-gone%'") == "0"
        assert sql("SELECT count(*) FROM pg_roles WHERE rolname = 'odoo-gone'") == "0"
        machine.fail("test -e /var/lib/private/odoo-gone")
        machine.fail("test -e /var/lib/odoo-golden/gone")
        machine.fail("test -e /var/lib/odoo-snapshots/gone")
        assert "Nothing left behind" in machine.succeed("odoo-purge")
        for name in ("demo", "blank"):
            probe(machine, name, "login", admin_password)
            assert copy_state(name) == "ready"
  '';
}
