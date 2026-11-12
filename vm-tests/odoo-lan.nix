# expose.lan, the Windows-laptop path on a Linux client: the server
# exposes demo (demo data) and blank (none) to the LAN and keeps private
# local only. The client does what a Windows user does: pastes the
# odoo-hosts lines into its hosts file, downloads the CA over HTTP and
# trusts it, then uses both instances. private stays unreachable under
# any name, the Odoo ports stay closed, a stranger outside allowedClients
# gets 403, the CA cannot vouch for names outside its constraints, and
# nginx still starts while the LAN address is missing.
{inputs, ...}: let
  common = import ./_odoo-common.nix {inherit inputs;};
in {
  nodes = {
    server = {nodes, ...}: {
      imports = [common.module];
      hostSpec.services.odoo = {
        lan = {
          addresses = [nodes.server.networking.primaryIPAddress];
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
    ca = "/tmp/odoo-ca.crt"

    start_all()
    wait_ready(server, ["demo", "blank", "private"])
    server.wait_for_open_port(443, server_ip, timeout=300)

    with subtest("odoo-hosts prints one line per LAN name"):
        hosts = server.succeed("odoo-hosts")
        for name in (lan, f"demo.{lan}", f"blank.{lan}"):
            assert f"{server_ip}  {name}\n" in hosts, hosts
        assert "private" not in hosts, hosts
        listing = server.succeed("odoo-reset --list")
        assert "local only" in listing and "lan" in listing, listing

    with subtest("a client adds the lines and downloads the CA over HTTP"):
        for node in (client, stranger):
            # /etc/hosts is a store symlink; a user edits a real file.
            node.succeed('cp --remove-destination "$(readlink -f /etc/hosts)" /etc/hosts')
            node.succeed(f"cat >> /etc/hosts <<'EOF'\n{hosts}{server_ip}  private.{lan}\nEOF")
        # Untrusted until the CA is imported.
        client.fail(f"curl -sf https://demo.{lan}/web/login")
        client.succeed(f"curl -sf http://{lan}/ca.crt -o {ca}")
        served = client.succeed(f"sha256sum < {ca}")
        assert served == server.succeed("sha256sum < /etc/odoo-test-tls/ca.crt"), "served CA differs"
        content_type = client.succeed(f"curl -sf -o /dev/null -w '%{{content_type}}' http://{lan}/ca.crt")
        assert content_type == "application/x-x509-ca-cert", content_type

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
        code = stranger.succeed(f"curl -s -o /dev/null -w '%{{http_code}}' http://{lan}/ca.crt").strip()
        assert code == "403", code

    with subtest("the CA cannot vouch for names outside its constraints"):
        server.succeed("openssl verify -CAfile /etc/odoo-test-tls/ca.crt /etc/odoo-test-tls/tls.crt")
        server.fail("openssl verify -CAfile /etc/odoo-test-tls/ca.crt /etc/odoo-test-tls/evil.crt")

    with subtest("the server keeps its local names and reaches its LAN names"):
        server.succeed("curl -sf https://private.odoo.localhost/web/login >/dev/null")
        server.succeed(f"curl -sf https://demo.{lan}/web/login >/dev/null")

    with subtest("nginx starts while the LAN address is missing (DHCP not there yet)"):
        prefix = server.succeed(f"ip -o -4 addr show dev eth1 | grep -o '{server_ip}/[0-9]*'").strip()
        server.succeed(f"ip addr del {prefix} dev eth1")
        server.succeed("systemctl restart nginx.service")
        # nginx is Type=simple: restart returns before it listens.
        server.wait_until_succeeds("curl -sf https://demo.odoo.localhost/web/login >/dev/null", timeout=60)
        server.succeed("systemctl is-active nginx.service")
        server.fail("journalctl -u nginx.service -b | grep 'Cannot assign requested address' >/dev/null")
        server.succeed(f"ip addr add {prefix} dev eth1")
        client.wait_until_succeeds(f"curl -sf --cacert {ca} https://demo.{lan}/web/login >/dev/null", timeout=60)
  '';
}
