"""JSON-RPC probe for the odoo VM tests, run inside the guest.

Talks to https://INSTANCE.odoo.localhost through nginx, verifying TLS
against the system CA bundle (security.pki), so every call also proves
the CA trust. The database is always odoo-INSTANCE.

  INSTANCE login PASSWORD              exit 0 if admin logs in with PASSWORD
  INSTANCE demo PASSWORD               exit 0 if demo data is installed
  INSTANCE no-demo PASSWORD            exit 0 if it is not
  INSTANCE set-password OLD NEW        change admin's password as admin
  INSTANCE partner-create PASSWORD N   create a contact named N
  INSTANCE partner-exists PASSWORD N   exit 0 if a contact named N exists
  INSTANCE attachment-create PASSWORD  store a file, print its filestore path
  INSTANCE db-list                     exit 0 if the database service lists databases
  INSTANCE db-drop MASTER_PASSWORD     exit 0 if the database service drops the database
"""

import base64
import json
import ssl
import sys
import urllib.request
import uuid

CONTEXT = ssl.create_default_context(cafile="/etc/ssl/certs/ca-certificates.crt")


class Instance:
    def __init__(self, name):
        self.url = f"https://{name}.odoo.localhost/jsonrpc"
        self.db = f"odoo-{name}"

    def call(self, service, method, *args):
        body = json.dumps(
            {
                "jsonrpc": "2.0",
                "method": "call",
                "params": {"service": service, "method": method, "args": list(args)},
            }
        ).encode()
        request = urllib.request.Request(
            self.url, data=body, headers={"Content-Type": "application/json"}
        )
        with urllib.request.urlopen(request, context=CONTEXT, timeout=120) as response:
            reply = json.load(response)
        if "error" in reply:
            raise SystemExit(f"odoo error: {json.dumps(reply['error'])[:2000]}")
        return reply["result"]

    def login(self, password):
        uid = self.call("common", "login", self.db, "admin", password)
        if not uid:
            raise SystemExit("login refused")
        return uid

    def execute(self, password, model, method, *args, **kwargs):
        uid = self.login(password)
        return self.call(
            "object", "execute_kw", self.db, uid, password, model, method, list(args), kwargs
        )

    def has_demo(self, password):
        base = self.execute(
            password, "ir.module.module", "search_read", [["name", "=", "base"]], fields=["demo"]
        )
        assert base, "base is not installed"
        return bool(base[0]["demo"])


def main():
    name, action, *args = sys.argv[1:]
    odoo = Instance(name)
    if action == "login":
        odoo.login(args[0])
    elif action == "demo":
        assert odoo.has_demo(args[0]), "base installed without demo data"
    elif action == "no-demo":
        assert not odoo.has_demo(args[0]), "base installed with demo data"
    elif action == "set-password":
        old, new = args
        uid = odoo.login(old)
        odoo.execute(old, "res.users", "write", [uid], {"password": new})
        odoo.login(new)
    elif action == "partner-create":
        password, partner = args
        odoo.execute(password, "res.partner", "create", {"name": partner})
    elif action == "partner-exists":
        password, partner = args
        found = odoo.execute(password, "res.partner", "search_count", [["name", "=", partner]])
        assert found, f"no contact named {partner}"
    elif action == "attachment-create":
        password = args[0]
        data = base64.b64encode(f"vm-test {uuid.uuid4()}".encode()).decode()
        attachment = odoo.execute(
            password, "ir.attachment", "create", {"name": "vm-test.txt", "datas": data}
        )
        [record] = odoo.execute(
            password, "ir.attachment", "read", [attachment], fields=["store_fname"]
        )
        assert record["store_fname"], f"attachment not in the filestore: {record}"
        print(f"/var/lib/private/{odoo.db}/data/filestore/{odoo.db}/{record['store_fname']}")
    elif action == "db-list":
        odoo.call("db", "list")
    elif action == "db-drop":
        odoo.call("db", "drop", args[0], odoo.db)
    else:
        raise SystemExit(f"unknown action {action}")


if __name__ == "__main__":
    main()
