# An instance's life after creation: apps from `modules` installed with
# the database; the database neutralized, so every mail lands in Mailpit
# (https://mail.odoo.localhost) and nothing leaves the machine; then a
# new Odoo package and a new app arrive (the "changed" specialisation, as
# after a nixpkgs bump plus a config edit) and the next start updates
# every module and installs the app, keeping the data, while the reset
# copy turns stale.
{inputs, ...}: let
  common = import ./_odoo-common.nix {inherit inputs;};
in {
  nodes.machine = {
    lib,
    pkgs,
    ...
  }: let
    odoo = inputs.org-pkgs.packages.${pkgs.stdenv.hostPlatform.system}.odoo19;
  in {
    imports = [common.module];
    hostSpec.services.odoo.instances.app = {
      demoData = false;
      modules = ["mail"];
      workers = 1;
    };
    # Same Odoo under another store path: what a package bump looks like.
    specialisation.changed.configuration.hostSpec.services.odoo.instances.app = {
      package = lib.mkForce (pkgs.symlinkJoin {
        name = "odoo19-bumped";
        paths = [odoo];
      });
      modules = lib.mkForce ["mail" "contacts"];
    };
    environment.systemPackages = [pkgs.jq];
    virtualisation = {
      memorySize = 4096;
      cores = 4;
    };
  };

  # Create with mail, then -u all and an install.
  globalTimeout = 3600;

  testScript = ''
    ${common.pythonHelpers}

    start_all()
    wait_ready(machine, ["app"])

    with subtest("apps from `modules` come with the database"):
        probe(machine, "app", "installed", admin_password, "mail")
        probe_fails(machine, "app", "installed", admin_password, "contacts")

    with subtest("the database is neutralized, the mail queue still runs"):
        probe(machine, "app", "neutralized", admin_password)
        active = machine.succeed(
            "runuser -u postgres -- psql -qtA -d odoo-app -c "
            "\"SELECT c.active FROM ir_cron c JOIN ir_model_data d ON d.res_id = c.id AND d.model = 'ir.cron' "
            "WHERE d.module = 'mail' AND d.name = 'ir_cron_mail_scheduler_action'\""
        ).strip()
        assert active == "t", active

    with subtest("mail lands in Mailpit, readable over HTTPS"):
        machine.wait_for_unit("mailpit-odoo.service", timeout=120)
        probe(machine, "app", "send-mail", admin_password, "someone@example.com", "vm-test-mail-subject")
        try:
            machine.wait_until_succeeds(
                "curl -sf http://127.0.0.1:8025/api/v1/messages | jq -e '.messages | any(.Subject == \"vm-test-mail-subject\")'",
                timeout=60,
            )
        except Exception:
            print(probe(machine, "app", "mail-state", admin_password, "vm-test-mail-subject"))
            print(machine.execute("journalctl -u odoo-app -u mailpit-odoo -b --no-pager | grep -iE 'mail|smtp' | tail -40")[1])
            raise
        assert "'sent'" in probe(machine, "app", "mail-state", admin_password, "vm-test-mail-subject")
        # Sent from the instance's default sender (email_from).
        machine.succeed(
            "curl -sf http://127.0.0.1:8025/api/v1/messages | "
            f"jq -e '.messages | any(.From.Address == \"app@{base_domain}\")'"
        )
        machine.succeed(f"curl -sf https://mail.{base_domain}/ >/dev/null")
        machine.succeed("grep -x 'smtp_port=1025' /run/odoo-app/odoo.cfg >/dev/null")

    with subtest("a new package and a new app: -u all and the install, data kept"):
        probe(machine, "app", "partner-create", admin_password, "kept-across-the-bump")
        assert "ready" in machine.succeed("odoo-reset --list")
        machine.succeed("/run/current-system/specialisation/changed/bin/switch-to-configuration test >&2")
        machine.wait_for_unit("odoo-app.service", timeout=1500)
        machine.wait_until_succeeds(f"curl -sf https://app.{base_domain}/web/login >/dev/null", timeout=300)
        journal = machine.succeed("journalctl -u odoo-app.service -b")
        assert "the Odoo package or addons changed; updating all modules" in journal, journal[-3000:]
        assert "installing apps contacts,mail" in journal, journal[-3000:]
        probe(machine, "app", "installed", admin_password, "contacts")
        probe(machine, "app", "partner-exists", admin_password, "kept-across-the-bump")
        probe(machine, "app", "neutralized", admin_password)
        # The copy was made from the old package and apps.
        assert "stale" in machine.succeed("odoo-reset --list")

    with subtest("the next start changes nothing"):
        machine.succeed("systemctl restart odoo-app.service")
        machine.wait_until_succeeds(f"curl -sf https://app.{base_domain}/web/login >/dev/null", timeout=300)
        since = machine.succeed("systemctl show -p ExecMainStartTimestamp --value odoo-app.service").strip()
        journal = machine.succeed(f"journalctl -u odoo-app.service --since {shlex.quote(since)}")
        assert "updating all modules" not in journal and "installing apps" not in journal, journal[-2000:]
  '';
}
