# Odoo for local testing

`hostSpec.services.odoo` runs any number of Odoo instances on one
machine, for testing only. Each instance has its own PostgreSQL database
and state, is served over trusted HTTPS at
`https://<name>.odoo.localhost`, and can be reset to a freshly created
database (with or without demo data) by one command. Nothing is
reachable from other machines unless an instance asks for it: see
[Reaching Odoo from other machines](odoo-access.md) for the LAN (a
Windows laptop, say) and the internet (a real domain with Let's
Encrypt).

## Enabling and adding instances

```nix
hostSpec.services.odoo = {
  enable = true;
  instances = {
    demo = {};                # https://demo.odoo.localhost, demo data
    blank.demoData = false;   # https://blank.odoo.localhost, empty
  };
};
```

Run `clan vars generate <machine>` once after enabling, then deploy.
Adding or removing an instance afterwards needs only a deploy: every
instance shares one certificate (for `odoo.localhost` and
`*.odoo.localhost`) and one pair of passwords.

`https://odoo.localhost` is an index page linking every instance.
`instances = {}` is valid: then no Odoo or nginx runs, only PostgreSQL
(so `odoo-purge` can still clean up).

| Option (per instance) | Default | Meaning |
| --- | --- | --- |
| `demoData` | `true` | load Odoo's demo data when the database is created (first start and every reset) |
| `workers` | `2` | HTTP worker processes; at least 1, so the websocket service (Discuss, live updates) runs |
| `addons` | `[]` | extra addon packages |
| `package` | `hostSpec.services.odoo.package` (`pkgs.odoo19`) | Odoo for this instance |
| `port` | automatic | HTTP port on 127.0.0.1; the websocket port is `port + 1` |
| `expose.lan` | `false` | also at `https://<name>.odoo.<host>.home.arpa` for the LAN ([details](odoo-access.md)) |
| `expose.public.enable`, `.domain` | off | also at `https://<domain>` for the internet, Let's Encrypt ([details](odoo-access.md)) |

Instance names are DNS labels: lowercase letters, digits and hyphens,
starting with a letter. Automatic ports follow the name order from
`basePort` (18069): with `blank` and `demo`, blank gets 18069/18070 and
demo 18071/18072. Other machine-wide options: `baseDomain`
(`odoo.localhost`), `package`, `trustCertificate`, `lan.*` and
`acme.email` for exposure, and the secret options below.

## What each instance gets

For an instance `<name>`, everything is called `odoo-<name>`:

| Thing | Where |
| --- | --- |
| systemd unit | `odoo-<name>.service` |
| system user, PostgreSQL role and database | `odoo-<name>` (peer auth over the unix socket, no database password) |
| state: filestore, sessions, markers | `/var/lib/private/odoo-<name>/data` |
| config with the master password (0600) | `/run/odoo-<name>/odoo.cfg` |
| URL | `https://<name>.odoo.localhost` |

Odoo and nginx bind loopback only, no firewall port is opened and
PostgreSQL has no TCP listener. Odoo's database manager is off.

## Logging in

User `admin`, with the password from clan vars, the same for every
instance:

```sh
clan vars get <machine> odoo-passwords/admin-password
```

The master password (`odoo-passwords/master-password`) never reaches the
Nix store. A password changed in the Odoo UI survives restarts and
reboots; a reset sets the provisioned one again.

## HTTPS in Firefox

A CA made by clan vars (`odoo-local-ca`) signs the certificate. It is
name-constrained to `odoo.localhost`, the LAN domain
(`odoo.<host>.home.arpa`) and their subdomains, so trusting it cannot
vouch for any other site, and its private key never leaves the
machine that ran `clan vars generate`. With `trustCertificate = true`
(the default) the CA is trusted system wide and installed into every
Firefox profile through the enterprise policy
`/etc/firefox/policies/policies.json`, including a home-manager Firefox.
Firefox resolves `*.localhost` to loopback itself; `networking.hosts`
does it for everything else. Other browsers need the CA imported by
hand: `ca.crt` is in `clan vars get <machine> odoo-local-ca/ca.crt`.

## Resetting an instance: odoo-reset

`odoo-reset` puts an instance back to how it was when it was first
enabled: a freshly created database, with demo data or without it as the
instance is configured, no uploaded files, and the provisioned admin
password.

```sh
odoo-reset --list               # name, URL, demo or not, unit state
sudo odoo-reset demo            # asks, then resets demo
sudo odoo-reset demo blank      # several
sudo odoo-reset --all           # every instance
sudo odoo-reset --yes demo      # no question (scripts, no terminal)
```

For each instance it stops the unit, drops and recreates the PostgreSQL
database, deletes the state (filestore, sessions and the markers that
record the first start and the admin password), starts the unit again
and waits until Odoo answers. Creating a database with demo data takes a
few minutes. The certificate, the CA and both passwords do not change.
An unknown name, `--all` with names, a missing `--yes` without a
terminal, or running it without root changes nothing.

## Removing an instance: odoo-purge

Removing an instance from `instances` and deploying stops it, but its
database, role and state stay. `odoo-purge` lists and deletes them:

```sh
sudo odoo-purge                 # list what removed instances left behind
sudo odoo-purge old-demo        # asks, then deletes database, role and state
sudo odoo-purge --yes old-demo  # no question
```

It refuses a name that is still configured (use `odoo-reset` for
those) and needs PostgreSQL, which keeps running while the module is
enabled, even with no instances. After `enable = false`, PostgreSQL is
no longer started by this module: purge first.

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
   (plus PostgreSQL's own), `odoo-reset --list` shows the new instances
   as active, and `https://odoo.localhost` lists them.

## Secrets without clan vars

`provisionSecrets = false` turns the clan vars generators off; then set
`caFile`, `tlsCertFile`, `tlsKeyFile` (a certificate for `baseDomain`
and `*.baseDomain`), `adminPasswordFile` and `masterPasswordFile`. The VM
tests do this with build-time fakes.

## VM tests

Run by hand, never in CI (`vm-test <name> --remote` builds on the remote
builder):

| Test | Covers |
| --- | --- |
| `odoo` | two instances (demo and no demo) and a machine with none: trusted HTTPS, index page, logins, isolation between instances, websocket, master password outside the store, loopback only, password changes surviving restarts, reboots not re-initialising |
| `odoo-reset` | `odoo-reset` for one and all instances (records, files and UI password changes gone, demo data as configured, other instances untouched), `odoo-purge`, and every refusal |
| `odoo-lan`, `odoo-public` | exposure: see [Reaching Odoo from other machines](odoo-access.md) |
| `odoo-firefox` | a home-manager Firefox loads an instance without a certificate error, and does not get past TLS on an untrusted control site |
