# Reaching Odoo from other machines

Every Odoo instance starts out local: `https://<name>.odoo.localhost`
works on the machine that runs it and nowhere else (see [Odoo](odoo.md)).
Each instance can add two more ways in, independently of the others:

| Exposure | Address | Certificate | Who can connect |
| --- | --- | --- | --- |
| local (always) | `https://<name>.odoo.localhost` | local CA | this machine |
| `expose.lan` | `https://<name>.odoo.<host>.home.arpa` | local CA, imported once per client | machines on the LAN, limited to `lan.allowedClients` |
| `expose.public` | `https://<your domain>` | Let's Encrypt (ACME HTTP-01) | anyone on the internet |

```nix
hostSpec.services.odoo = {
  enable = true;
  lan = {
    addresses = [ /* this machine's LAN IPs, from the values flake */ ];
    interfaces = [ /* e.g. the Wi-Fi or Ethernet interface */ ];
    allowedClients = [ /* the LAN's CIDRs */ ];
  };
  acme.email = /* only with expose.public */;
  instances = {
    demo.expose.lan = true;              # local + LAN
    blank = {                            # local + LAN, empty database
      demoData = false;
      expose.lan = true;
    };
    scratch = {};                        # local only
    shop = {                             # local + internet
      demoData = false;
      expose.public = {
        enable = true;
        domain = "erp.example.com";
      };
    };
  };
};
```

Nothing listens beyond loopback until an instance asks for it. Odoo's
own ports (18069 and up) stay on 127.0.0.1 in every mode; only nginx
faces the network.

## Why not `*.odoo.localhost` from the LAN

Browsers, Windows included, send every `*.localhost` name to the
machine they run on and ignore the hosts file for it, so another
machine can never use those names. LAN names live under `home.arpa`,
the domain reserved for home networks (RFC 8375), as
`<name>.odoo.<host>.home.arpa` (`lan.domain`, default
`odoo.<hostName>.home.arpa`): `https://demo.odoo.beelink.home.arpa`.

## LAN: setting up a Windows laptop

Do this once per laptop. Adding another LAN instance later only needs
its line in the hosts file.

### 1. Get the hosts-file lines

On the Odoo machine:

```sh
odoo-hosts
```

```text
198.51.100.230  odoo.beelink.home.arpa
198.51.100.230  blank.odoo.beelink.home.arpa
198.51.100.230  demo.odoo.beelink.home.arpa
```

The same lines are on the LAN index page. Hosts files have no
wildcards: one line per name.

### 2. Add them to the Windows hosts file

1. Start Notepad as administrator (Start, type *Notepad*, right-click,
   *Run as administrator*).
2. Open `C:\Windows\System32\drivers\etc\hosts` (set the file filter to
   *All files*).
3. Paste the lines at the end and save.
4. In a terminal: `ipconfig /flushdns`.

Or in PowerShell as administrator, with the lines in the clipboard:

```powershell
Add-Content -Path "$env:SystemRoot\System32\drivers\etc\hosts" -Value (Get-Clipboard)
ipconfig /flushdns
```

A router that lets you add local DNS entries can hold the same names
instead, for every device on the network at once.

### 3. Trust the CA

The certificate comes from the machine's own CA. Download it over plain
HTTP (it is public, and HTTPS is not trusted yet):
`http://odoo.beelink.home.arpa/ca.crt`. Then, in PowerShell as
administrator:

```powershell
Import-Certificate -FilePath "$env:USERPROFILE\Downloads\ca.crt" -CertStoreLocation Cert:\LocalMachine\Root
```

or double-click `ca.crt`, *Install Certificate*, *Local Machine*,
*Place all certificates in the following store*, *Trusted Root
Certification Authorities*.

The CA is name-constrained: Windows trusts it for names under
`odoo.localhost` and `odoo.<host>.home.arpa` only, so importing it
cannot make any other site look genuine. Its private key never leaves
the machine that ran `clan vars generate`.

- **Edge and Chrome** use the Windows store: done.
- **Firefox** uses it when `security.enterprise_roots.enabled` is true
  in `about:config` (the default in current versions). Otherwise import
  `ca.crt` under *Settings*, *Privacy & Security*, *Certificates*, *View
  Certificates*, *Authorities*, *Import*, and tick *Trust this CA to
  identify websites*.

### 4. Open it

`https://odoo.beelink.home.arpa` lists the LAN instances. Log in as
`admin` with `clan vars get beelink odoo-passwords/admin-password`.

### Removing it again

Delete the lines from the hosts file, and remove the CA: `certlm.msc`,
*Trusted Root Certification Authorities*, *Certificates*,
`odoo-local-ca ...`, *Delete*.

### macOS and Linux clients

The same lines go into `/etc/hosts`. Trust the CA with
`sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain ca.crt`
(macOS) or your distribution's CA store (on NixOS:
`security.pki.certificateFiles`).

### What the LAN side enforces

- nginx listens on `lan.addresses` only, and the firewall opens 80 and
  443 on `lan.interfaces` only.
- Clients outside `lan.allowedClients` get 403 for every LAN name.
- A name that is not a LAN-exposed instance (a local-only one, a
  `*.odoo.localhost` name, a bare IP) has its TLS handshake refused.
- When the CA's names change (first LAN exposure, a new `lan.domain`),
  `clan vars generate` makes a new CA: import the new `ca.crt` on each
  client and delete the old one.

## Internet: a real domain with Let's Encrypt

`expose.public` serves the instance at its own domain with a Let's
Encrypt certificate, renewed automatically (`security.acme`, HTTP-01
challenge).

Before enabling it:

1. **DNS:** an A record (and AAAA for IPv6) for the domain pointing at
   the public address that reaches this machine.
2. **Port 80 and 443 from the internet:** behind a home router, forward
   TCP 80 and 443 to this machine's LAN address. Let's Encrypt
   validates over port 80, so it must stay open.
3. **An ACME contact:** `hostSpec.services.odoo.acme.email` (or
   `security.acme.defaults.email`), from the values flake.
4. Put the domain in the values flake, not in a module or machine file.

What the module adds for a public instance:

- the firewall opens 80 and 443 on every interface;
- `/web/database/*` answers 404 (the database manager is off anyway);
- `/web/login` is rate limited (10 per minute per address, bursts of 5,
  then 429);
- HSTS (`Strict-Transport-Security: max-age=31536000`);
- `web.base.url` is set to `https://<domain>` and frozen, so links in
  mails, reports and the portal use the public address whichever name
  the admin logged in through;
- names nginx does not serve publicly (local and LAN names, bare IPs)
  get their TLS handshake refused.

Demo data is allowed on any exposure, but a public instance with demo
data has Odoo's demo users (`demo`/`demo`, `portal`/`portal`): anyone
can log in with them.

## Checking an exposure

```sh
odoo-reset --list   # EXPOSED column: lan, the public URL, or local only
odoo-hosts          # LAN hosts-file lines
```

## VM tests

| Test | Covers |
| --- | --- |
| `odoo-lan` | a client pastes the `odoo-hosts` lines, downloads `ca.crt` over HTTP and uses two LAN instances (logins, demo data, websocket, index); a local-only instance is unreachable under any name; Odoo ports closed; a client outside `allowedClients` gets 403; the CA rejects a certificate for another domain |
| `odoo-public` | Let's Encrypt-style issuance over HTTP-01 from pebble; an internet client logs in at the public domain; 404 for the database manager, HSTS, frozen `web.base.url`, login rate limit; a local-only instance is unreachable |
