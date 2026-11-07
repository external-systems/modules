"""JSON-RPC probe for the odoo VM test, run inside the guest.

Talks to https://odoo.localhost through nginx, verifying TLS against the
system CA bundle (security.pki), so every call also proves the CA trust.

  login PASSWORD                 exit 0 if admin logs in with PASSWORD
  demo PASSWORD                  exit 0 if demo data is installed
  set-password OLD NEW           change admin's password as admin
  db-list                        exit 0 if the database service lists databases
  db-drop MASTER_PASSWORD        exit 0 if the database service drops "odoo"
"""

import json
import ssl
import sys
import urllib.request

URL = "https://odoo.localhost/jsonrpc"
DB = "odoo"
CONTEXT = ssl.create_default_context(cafile="/etc/ssl/certs/ca-certificates.crt")


def call(service, method, *args):
    body = json.dumps(
        {
            "jsonrpc": "2.0",
            "method": "call",
            "params": {"service": service, "method": method, "args": list(args)},
        }
    ).encode()
    request = urllib.request.Request(
        URL, data=body, headers={"Content-Type": "application/json"}
    )
    with urllib.request.urlopen(request, context=CONTEXT, timeout=60) as response:
        reply = json.load(response)
    if "error" in reply:
        raise SystemExit(f"odoo error: {json.dumps(reply['error'])[:2000]}")
    return reply["result"]


def login(password):
    uid = call("common", "login", DB, "admin", password)
    if not uid:
        raise SystemExit("login refused")
    return uid


def execute(password, model, method, *args, **kwargs):
    uid = login(password)
    return call("object", "execute_kw", DB, uid, password, model, method, list(args), kwargs)


def main():
    action, *args = sys.argv[1:]
    if action == "login":
        login(args[0])
    elif action == "demo":
        base = execute(args[0], "ir.module.module", "search_read", [["name", "=", "base"]], fields=["demo"])
        assert base and base[0]["demo"], f"base installed without demo data: {base}"
    elif action == "set-password":
        old, new = args
        uid = login(old)
        execute(old, "res.users", "write", [uid], {"password": new})
        login(new)
    elif action == "db-list":
        call("db", "list")
    elif action == "db-drop":
        call("db", "drop", args[0], DB)
    else:
        raise SystemExit(f"unknown action {action}")


if __name__ == "__main__":
    main()
