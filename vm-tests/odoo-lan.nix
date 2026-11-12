# expose.lan, the Windows-laptop path on a Linux client: the server
# exposes demo (demo data) and blank (none) to the LAN and keeps private
# local only. The client does what a Windows user does: knowing only the
# server's IP, it fetches http://<IP>/hosts.txt into its hosts file and
# http://<IP>/ca.crt into its trust store, then uses both instances and
# Mailpit. private stays unreachable under any name, the Odoo ports stay
# closed, a stranger outside allowedClients gets 403, the CA cannot vouch
# for names outside its constraints, and nginx does not depend on the LAN
# address (DHCP may change it).
{inputs, ...}: let
  common = import ./_odoo-common.nix {inherit inputs;};
in {
  nodes = {
    server = {nodes, ...}: {
      imports = [common.module];
      hostSpec.services.odoo = {
        lan = {
          interfaces = ["eth1"];
          allowedClients = map (n: "${nodes.${n}.networking.primaryIPAddress}/32") ["server" "client"];
        };
        instances = {
          demo = {
            workers = 1;
            expose.lan = true;
          };
          blank = {
            demoData = false;
            workers = 1;
            expose.lan = true;
          };
          private = {
            demoData = false;
            workers = 1;
          };
        };
      };
      # Three databases created at once, one with demo data.
      virtualisation = {
        memorySize = 6144;
        cores = 4;
      };
    };

    client = {imports = [common.clientModule];};
    stranger = {imports = [common.clientModule];};
  };

  globalTimeout = 3600;

  testScript = {nodes, ...}: ''
    ${common.pythonHelpers}

    server_ip = "${nodes.server.networking.primaryIPAddress}"
    lan = "odoo.server.home.arpa"
    names = (lan, f"demo.{lan}", f"blank.{lan}", f"mail.{lan}")
    ca = "/tmp/odoo-ca.crt"

    start_all()
    wait_ready(server, ["demo", "blank", "private"])
    server.wait_for_open_port(443, server_ip, timeout=300)

    with subtest("odoo-hosts prints the current address for every LAN name"):
        hosts = server.succeed("odoo-hosts")
        for name in names:
            assert f"{server_ip}  {name}\n" in hosts, hosts
        assert "private" not in hosts, hosts
        listing = server.succeed("odoo-reset --list")
        assert "local only" in listing and "lan" in listing, listing

    with subtest("a client knowing only the IP bootstraps itself over HTTP"):
        served = client.succeed(f"curl -sf http://{server_ip}/hosts.txt")
        assert served == hosts, f"hosts.txt {served!r} != odoo-hosts {hosts!r}"
        for node in (client, stranger):
            # /etc/hosts is a store symlink; a user edits a real file.
            node.succeed('cp --remove-destination "$(readlink -f /etc/hosts)" /etc/hosts')
            node.succeed(f"cat >> /etc/hosts <<'EOF'\n{hosts}{server_ip}  private.{lan}\nEOF")
        # Untrusted until the CA is imported.
        client.fail(f"curl -sf https://demo.{lan}/web/login")
        client.succeed(f"curl -sf http://{server_ip}/ca.crt -o {ca}")
        assert client.succeed(f"sha256sum < {ca}") == server.succeed("sha256sum < /etc/odoo-test-tls/ca.crt"), "served CA differs"
        assert client.succeed(f"curl -sf http://{lan}/ca.crt | sha256sum") == client.succeed(f"sha256sum < {ca}")
        content_type = client.succeed(f"curl -sf -o /dev/null -w '%{{content_type}}' http://{lan}/ca.crt")
        assert content_type == "application/x-x509-ca-cert", content_type
        # Anything else on the bare IP: closed.
        client.fail(f"curl -sf http://{server_ip}/")

    with subtest("Mailpit is on the LAN too"):
        client.succeed(f"curl -sf --cacert {ca} https://mail.{lan}/ >/dev/null")

    with subtest("with the CA, both LAN instances work from the client"):
        for name in ("demo", "blank"):
            client.succeed(f"curl -sf --cacert {ca} https://{name}.{lan}/web/login | grep 'name=\"login\"' >/dev/null")
            probe(client, name, "login", admin_password, domain=lan, cafile=ca)
        probe(client, "demo", "demo", admin_password, domain=lan, cafile=ca)
        probe(client, "blank", "no-demo", admin_password, domain=lan, cafile=ca)
        index = client.succeed(f"curl -sf --cacert {ca} https://{lan}/")
        for name in ("demo", "blank"):
            assert f'href="https://{name}.{lan}/"' in index, index
        assert "private" not in index, index
        code = client.succeed(
            f"curl --cacert {ca} --http1.1 -s -o /dev/null -w '%{{http_code}}' --max-time 5 "
            "-H 'Connection: Upgrade' -H 'Upgrade: websocket' -H 'Sec-WebSocket-Version: 13' "
            "-H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' "
            f"-H 'Origin: https://demo.{lan}' https://demo.{lan}/websocket || true"
        ).strip()
        assert code == "101", code

    with subtest("a local-only instance is unreachable from the LAN"):
        # Its would-be LAN name and its loopback name: the handshake is refused.
        client.fail(f"curl -s --cacert {ca} https://private.{lan}/web/login")
        client.fail(f"curl -sk --resolve private.odoo.localhost:443:{server_ip} https://private.odoo.localhost/web/login")
        client.fail(f"curl -sk --resolve demo.odoo.localhost:443:{server_ip} https://demo.odoo.localhost/web/login")
        # Plain HTTP with an unknown name: the catch-all closes the connection.
        client.fail(f"curl -sf -H 'Host: private.{lan}' http://{server_ip}/")
        for port in range(18069, 18075):
            client.fail(f"curl -s --connect-timeout 3 http://{server_ip}:{port}/")

    with subtest("clients outside allowedClients get 403"):
        for url in (f"https://demo.{lan}/web/login", f"https://{lan}/"):
            code = stranger.succeed(f"curl -sk -o /dev/null -w '%{{http_code}}' {url}").strip()
            assert code == "403", f"{url}: {code}"
        for url in (f"http://{lan}/ca.crt", f"http://{server_ip}/hosts.txt", f"http://{server_ip}/ca.crt"):
            code = stranger.succeed(f"curl -s -o /dev/null -w '%{{http_code}}' {url}").strip()
            assert code == "403", f"{url}: {code}"
        code = stranger.succeed(f"curl -sk -o /dev/null -w '%{{http_code}}' https://mail.{lan}/").strip()
        assert code == "403", code

    with subtest("the CA cannot vouch for names outside its constraints"):
        server.succeed("openssl verify -CAfile /etc/odoo-test-tls/ca.crt /etc/odoo-test-tls/tls.crt")
        server.fail("openssl verify -CAfile /etc/odoo-test-tls/ca.crt /etc/odoo-test-tls/evil.crt")

    with subtest("the server keeps its local names and reaches its LAN names"):
        server.succeed("curl -sf https://private.odoo.localhost/web/login >/dev/null")
        server.succeed(f"curl -sf https://demo.{lan}/web/login >/dev/null")

    with subtest("a new DHCP address needs no rebuild or restart"):
        prefix = server.succeed(f"ip -o -4 addr show dev eth1 | grep -o '{server_ip}/[0-9]*'").strip()
        length = prefix.split("/")[1]
        new_ip = server_ip.rsplit(".", 1)[0] + ".99"
        server.succeed(f"ip addr del {prefix} dev eth1 && ip addr add {new_ip}/{length} dev eth1")
        assert f"{new_ip}  demo.{lan}\n" in server.succeed("odoo-hosts")
        assert server_ip not in server.succeed("odoo-hosts")
        client.succeed(f"curl -sf --cacert {ca} --resolve demo.{lan}:443:{new_ip} https://demo.{lan}/web/login >/dev/null")
        assert client.succeed(f"curl -sf http://{new_ip}/hosts.txt").startswith(f"{new_ip}  ")
        # nginx starts whatever the address (or none).
        server.succeed(f"ip addr del {new_ip}/{length} dev eth1")
        server.succeed("systemctl restart nginx.service")
        # nginx is Type=simple: restart returns before it listens.
        server.wait_until_succeeds("curl -sf https://demo.odoo.localhost/web/login >/dev/null", timeout=60)
        server.fail("odoo-hosts")
        server.succeed(f"ip addr add {prefix} dev eth1")
        client.wait_until_succeeds(f"curl -sf --cacert {ca} https://demo.{lan}/web/login >/dev/null", timeout=60)
  '';
}
