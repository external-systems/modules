# Odoo for local testing

`hostSpec.services.odoo` runs any number of Odoo instances on one
machine, for testing only (never production). Each instance has its own
PostgreSQL database and state, is served over trusted HTTPS at
`https://<name>.odoo.localhost`, comes with the apps you list, sends its
mail to a local Mailpit instead of the world, and goes back to a freshly
created state in seconds. Nothing is reachable from other machines
unless an instance asks for it: see
[Reaching Odoo from other machines](odoo-access.md) for the LAN (a
Windows laptop, say) and the internet (a real domain with Let's
Encrypt).

## Enabling and adding instances

```nix
hostSpec.services.odoo = {
  enable = true;
  instances = {
    demo.modules = [ "sale_management" "crm" ];   # demo data + apps
    blank.demoData = false;                        # empty database
  };
};
```

Run `clan vars generate <machine>` once after enabling, then deploy.
Adding or removing an instance afterwards needs only a deploy: every
instance shares one certificate and one pair of passwords.

| Address | What |
| --- | --- |
| `https://odoo.localhost` | index of the instances |
| `https://<name>.odoo.localhost` | an instance |
| `https://mail.odoo.localhost` | Mailpit: every mail the instances sent |

`instances = {}` is valid: then no Odoo, nginx or Mailpit runs, only
PostgreSQL (so `odoo-purge` can still clean up).

| Option (per instance) | Default | Meaning |
| --- | --- | --- |
| `demoData` | `true` | Odoo's demo data in the database (at creation and every reset) |
| `modules` | `[]` | apps installed with the database, e.g. `[ "sale_management" "crm" "stock" "l10n_us" ]`; added later, they are installed on the next start |
| `language` | `null` | a language loaded at creation, e.g. `"de_DE"` |
| `neutralize` | `true` | `odoo neutralize` the database (see Mail) |
| `workers` | `2` | HTTP worker processes; at least 1, so the websocket service (Discuss, live updates) runs |
| `memoryMax` | `"4G"` | systemd `MemoryMax` for the whole instance; `null` for none |
| `limits.memorySoft`, `.memoryHard` | `1536`, `2048` | Odoo's per-worker memory limits, MiB |
| `limits.timeCpu`, `.timeReal` | `600`, `1200` | Odoo's per-request time limits, seconds (generous for imports and reports) |
| `addons` | `[]` | extra addon packages |
| `package` | `hostSpec.services.odoo.package` (`pkgs.odoo19`) | Odoo for this instance |
| `port` | automatic | HTTP port on 127.0.0.1; the websocket port is `port + 1` |
| `expose.lan` | `false` | also at `https://<name>.odoo.<host>.home.arpa` for the LAN ([details](odoo-access.md)) |
| `expose.public.enable`, `.domain` | off | also at `https://<domain>` for the internet, Let's Encrypt ([details](odoo-access.md)) |

Instance names are DNS labels of at most 24 characters: lowercase
letters, digits and hyphens, starting with a letter, and not `mail`.
Automatic ports follow the name order from `basePort` (18069): with
`blank` and `demo`, blank gets 18069/18070 and demo 18071/18072. Other
machine-wide options: `baseDomain` (`odoo.localhost`), `package`,
`mail.*`, `trustCertificate`, `lan.*` and `acme.email` for exposure, and
the secret options below.

## What each instance gets

For an instance `<name>`, everything is called `odoo-<name>`:

| Thing | Where |
| --- | --- |
| systemd unit | `odoo-<name>.service` |
| system user, PostgreSQL role and database | `odoo-<name>` (peer auth over the unix socket, no database password) |
| state: filestore, sessions, markers | `/var/lib/private/odoo-<name>/data` |
| config with the master password (0600) | `/run/odoo-<name>/odoo.cfg` |
| reset copy | database `odoo-<name>@golden`, files in `/var/lib/odoo-golden/<name>` |
| snapshots | databases `odoo-<name>@snap-<tag>`, files in `/var/lib/odoo-snapshots/<name>` |
| URL | `https://<name>.odoo.localhost` |

Odoo, nginx and Mailpit bind loopback only, no firewall port is opened
and PostgreSQL has no TCP listener. Odoo's database manager is off.

## Logging in

User `admin`, with the password from clan vars, the same for every
instance:

```sh
clan vars get <machine> odoo-passwords/admin-password
```

The master password (`odoo-passwords/master-password`) never reaches the
Nix store. A password changed in the Odoo UI survives restarts and
reboots; a reset sets the provisioned one again.

## Mail: Mailpit and neutralized databases

Test data has real-looking addresses, and a test instance must never
mail them. Two things make sure of it:

- **Every instance sends to Mailpit** (`127.0.0.1:1025`), which keeps the
  mail and shows it at `https://mail.odoo.localhost`: open it to read
  what Odoo sent (invoices, password resets, follow-ups).
- **Every new database is neutralized** (`odoo neutralize`): mail
  servers configured in the database, fetchmail, payment providers,
  outgoing integrations and scheduled actions are switched off, and Odoo
  shows a "neutralized database" banner. Neutralize also adds a mail
  server with the host `invalid` that blocks all mail; the module
  replaces it with one named `Mailpit` and turns the mail queue back on,
  so mail is sent, to Mailpit only. This runs again after new apps are
  installed. Mail without a sender gets `<name>@odoo.localhost`.

`mail.enable = false` drops Mailpit and keeps neutralize's blocking mail
server: mail goes nowhere.

## Starting, crashing, updating

Each start runs these steps before Odoo serves:

1. The first start (and a reset from scratch) creates the database:
   base, the `modules`, demo data if asked, the `language`; then
   neutralizes it and saves it as the instance's **reset copy**.
2. When the Odoo package or addons changed since the last start (a
   nixpkgs bump), every module is updated (`odoo -u all`), keeping the
   data. When apps were added to `modules`, they are installed. Removing
   an app from `modules` does not uninstall it; a reset does.
3. The provisioned admin password is applied when the secret changed.

A crashed or memory-killed instance restarts after 10 s; after four
failures in 15 minutes it stays down (`systemctl status odoo-<name>`,
`journalctl -u odoo-<name>`). `memoryMax` caps the whole instance, so a
runaway import or report cannot starve the machine or PostgreSQL.

## Resetting an instance: odoo-reset

`odoo-reset` puts an instance back to how it was when it was first
created: every record, file and setting made since is gone, the demo
data and apps are back as configured, and the provisioned admin
password applies.

```sh
odoo-reset --list               # name, URL, data, state, reset copy, exposure
sudo odoo-reset demo            # asks, then resets demo
sudo odoo-reset demo blank      # several
sudo odoo-reset --all           # every instance
sudo odoo-reset --yes demo      # no question (scripts, no terminal)
sudo odoo-reset --clean demo    # create the database from scratch
```

A reset restores the **reset copy** (a PostgreSQL template copy of the
database as first created, plus its files): seconds. The copy is made
automatically whenever a database is created from scratch. It is
`stale` in `--list` once the package, addons, demo data, apps or
language changed; a reset then creates the database from scratch
(minutes with demo data) and makes a new copy. `--clean` does that on
purpose. The certificate, the CA and both passwords never change.
Snapshots survive a reset. An unknown name, `--all` with names, a
missing `--yes` without a terminal, or running it without root changes
nothing.

## Saving a state: odoo-snapshot

A snapshot keeps an instance as it is now, to come back to after a
test: "the state just before step X".

```sh
sudo odoo-snapshot save demo before-import     # stops demo for a few seconds
sudo odoo-snapshot list [demo]
sudo odoo-snapshot restore demo before-import  # asks, then puts it back
sudo odoo-snapshot rm demo before-import
```

A restore brings back everything as saved, the admin password included.
After a package change, the next start updates the restored database
(`-u all`) as for any other. Tags: lowercase letters, digits, `.`, `_`
and `-`, at most 24.

## Removing an instance: odoo-purge

Removing an instance from `instances` and deploying stops it, but its
database, role, state, reset copy and snapshots stay. `odoo-purge` lists
and deletes them:

```sh
sudo odoo-purge                 # list what removed instances left behind
sudo odoo-purge old-demo        # asks, then deletes all of it
sudo odoo-purge --yes old-demo  # no question
```

It refuses a name that is still configured (use `odoo-reset` for
those) and needs PostgreSQL, which keeps running while the module is
enabled, even with no instances. After `enable = false`, PostgreSQL is
no longer started by this module: purge first.

## Troubleshooting

| Symptom | Look at |
| --- | --- |
| an instance does not come up | `journalctl -u odoo-<name> -b`: the `pre-start:` lines say which step ran (creating, updating, installing apps, reset copy, admin password) |
| it stays down after crashes | `systemctl status odoo-<name>` (start limit hit), then `systemctl reset-failed odoo-<name>` and start it |
| it was killed | `journalctl -u odoo-<name> | grep -i oom`; raise `memoryMax` or lower `workers` |
| a request times out | Odoo's `limit_time_*` (`limits.timeCpu`, `.timeReal`) |
| reset takes minutes | `odoo-reset --list` shows the copy `stale` or `none`; the next reset rebuilds it |
| no mail arrives in Mailpit | `systemctl status mailpit-odoo`; the mail queue cron in Odoo (Settings, Technical, Scheduled Actions) |
| an app is missing after adding it | the next start installs it: `systemctl restart odoo-<name>` |

## One-time migration from the single instance

Before this layout the module ran one instance: unit `odoo.service`,
database and role `odoo`, state `/var/lib/private/odoo`, at
`https://odoo.localhost`. That data is not migrated. To wipe it (for
example on beelink):

1. Regenerate the CA and the certificate: they now also cover
   `*.odoo.localhost` and the LAN domain (`odoo.beelink.home.arpa`).
   Firefox on beelink picks up the new CA through its policy at the
   next start; LAN clients import the new `ca.crt`
   ([Reaching Odoo from other machines](odoo-access.md)).

    ```sh
    clan vars generate beelink
    ```

2. Deploy the new configuration (`clan machines update beelink`). The
   old `odoo.service` and its user go away; the new instances start.
3. On beelink, delete the old database, role and state:

    ```sh
    sudo -u postgres psql -c 'DROP DATABASE IF EXISTS odoo WITH (FORCE)' -c 'DROP ROLE IF EXISTS odoo'
    sudo rm -rf /var/lib/private/odoo /var/lib/odoo
    ```

4. Check: `sudo -u postgres psql -l` lists only `odoo-<name>` databases
   and their `@golden` copies (plus PostgreSQL's own), `odoo-reset --list`
   shows the new instances as active with a `ready` copy, and
   `https://odoo.localhost` lists them.

## Secrets without clan vars

`provisionSecrets = false` turns the clan vars generators off; then set
`caFile`, `tlsCertFile`, `tlsKeyFile` (a certificate for `baseDomain`,
`lan.domain` and their wildcards, the key readable by nginx),
`adminPasswordFile` and `masterPasswordFile`. The VM tests do this with
build-time fakes.

## VM tests

Run by hand, never in CI (`vm-test <name> --remote` builds on the remote
builder):

| Test | Covers |
| --- | --- |
| `odoo` | two instances (demo and no demo) and a machine with none: trusted HTTPS, index page, logins, isolation between instances, websocket, nginx reloads, master password outside the store, loopback only, a killed instance restarting, memory caps, password changes surviving restarts, reboots not re-initialising |
| `odoo-reset` | the reset copy (made at first start, restored in seconds, `--clean`, stale), resets of one and all instances, snapshots, `odoo-purge` (copies and snapshots too), and every refusal |
| `odoo-lifecycle` | apps from `modules`, neutralize, mail landing in Mailpit, then a package bump and an added app: `-u all` and the install keep the data |
| `odoo-lan`, `odoo-public` | exposure: see [Reaching Odoo from other machines](odoo-access.md) |
| `odoo-firefox` | a home-manager Firefox loads an instance without a certificate error, and does not get past TLS on an untrusted control site |
