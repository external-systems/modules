# hostSpec.system.gaming.sharedLibraries registers each user's shared
# library with their Steam (steam-library-register@<user>). No real
# Steam (unfree, and it would download itself): alice gets the files a
# first Steam run leaves, in the layout Steam writes, with two Steam
# accounts, and a process named "steam" stands in for a running Steam.
# bob never opened Steam and must be skipped, not failed.
_: {
  nodes.machine = {pkgs, ...}: let
    # A process whose name is "steam", as the script looks for: a copy
    # of the Python binary (a symlink would keep the target's name).
    fakeSteam = pkgs.runCommand "fake-steam" {} ''
      mkdir -p $out/bin
      cp -L ${pkgs.python3}/bin/python3 $out/bin/steam
    '';
  in {
    hostSpec.system.gaming.sharedLibraries = {
      enable = true;
      paths = ["/srv/games"];
    };
    users.users = {
      alice.isNormalUser = true;
      bob.isNormalUser = true;
    };
    environment.systemPackages = [fakeSteam];
  };

  testScript = ''
    import shlex

    steam = "/home/alice/.local/share/Steam"
    library = "/srv/games/users/alice"
    folders = f"{steam}/config/libraryfolders.vdf"
    accounts = ["111", "222"]

    def as_alice(cmd):
        return machine.succeed(f"su alice -c {shlex.quote(cmd)}")

    def write(path, text):
        as_alice(f"mkdir -p $(dirname {path}) && cat > {path} <<'EOF'\n{text}EOF")

    def unit_state(user):
        return machine.succeed(
            f"systemctl show -P ActiveState,Result steam-library-register@{user}"
        ).split()

    machine.wait_for_unit("multi-user.target")

    with subtest("shared layout and a first, empty pass"):
        machine.succeed(f"test -L {library}/steamapps/common")
        # Nobody had Steam at boot: both ran, skipped, and succeeded.
        machine.wait_until_succeeds(
            "systemctl show -P Result steam-library-register@alice | grep -qx success", timeout=60
        )
        machine.succeed("systemctl show -P Result steam-library-register@bob | grep -qx success")

    with subtest("alice's Steam after its first run"):
        default_lib = (
            '"libraryfolders"\n{\n\t"0"\n\t{\n'
            '\t\t"path"\t\t"/home/alice/.local/share/Steam"\n'
            '\t\t"label"\t\t""\n\t\t"contentid"\t\t"42"\n'
            '\t\t"apps"\n\t\t{\n\t\t}\n\t}\n}\n'
        )
        write(folders, default_lib)
        write(f"{steam}/steamapps/libraryfolders.vdf", default_lib)
        write(
            f"{steam}/userdata/111/config/localconfig.vdf",
            '"UserLocalConfigStore"\n{\n\t"x"\t\t"{\\"json\\":1}"\n}\n',
        )
        write(
            f"{steam}/userdata/222/config/localconfig.vdf",
            '"UserLocalConfigStore"\n{\n\t"LastInstallFolderIndex"\t\t"0"\n}\n',
        )

    with subtest("waits while Steam runs"):
        machine.succeed("systemd-run --uid=alice --unit=fake-steam steam -c 'import time; time.sleep(600)'")
        machine.wait_until_succeeds("pgrep -u alice -x steam", timeout=30)
        machine.succeed("systemctl start steam-library-register@alice")
        machine.wait_until_succeeds(
            "journalctl -u steam-library-register@alice | grep -q 'running: waiting'", timeout=30
        )
        assert unit_state("alice")[0] == "active", unit_state("alice")
        machine.fail(f"grep -q /srv/games {folders}")
        machine.succeed("systemctl stop fake-steam")
        machine.wait_until_succeeds(
            "systemctl show -P ActiveState steam-library-register@alice | grep -qx inactive", timeout=60
        )
        assert unit_state("alice") == ["inactive", "success"], unit_state("alice")

    with subtest("library registered and made the default"):
        machine.succeed(f'grep -qP \'^\\t\\t"path"\\t\\t"{library}"$\' {folders}')
        machine.succeed(f"cmp {folders} {steam}/steamapps/libraryfolders.vdf")
        contentid = machine.succeed(
            f"grep -oP '\"contentid\"\\t\\t\"\\K[0-9]+' {library}/libraryfolder.vdf"
        ).strip()
        machine.succeed(f'grep -qP \'"contentid"\\t\\t"{contentid}"\' {folders}')
        for account in accounts:
            config = f"{steam}/userdata/{account}/config/localconfig.vdf"
            machine.succeed(f'grep -qP \'^\\t"LastInstallFolderIndex"\\t\\t"1"$\' {config}')
            machine.succeed(f"test $(grep -c LastInstallFolderIndex {config}) = 1")
            machine.succeed(f"tail -n1 {config} | grep -qx '}}'")
        # Steam's own escaped JSON is left as it was.
        kept = machine.succeed(f"cat {steam}/userdata/111/config/localconfig.vdf")
        assert '\t"x"\t\t"{\\"json\\":1}"\n' in kept, kept
        machine.succeed(f"stat -c %U {folders} | grep -qx alice")

    with subtest("a second pass changes nothing"):
        before = as_alice(f"sha256sum {folders} {steam}/userdata/*/config/localconfig.vdf")
        machine.succeed("systemctl start steam-library-register@alice")
        machine.wait_until_succeeds(
            "systemctl show -P ActiveState steam-library-register@alice | grep -qx inactive", timeout=60
        )
        assert unit_state("alice") == ["inactive", "success"], unit_state("alice")
        assert before == as_alice(f"sha256sum {folders} {steam}/userdata/*/config/localconfig.vdf")

    with subtest("bob, without Steam, is skipped"):
        machine.succeed("systemctl start steam-library-register@bob")
        machine.wait_until_succeeds(
            "journalctl -u steam-library-register@bob | grep -q 'no Steam install for bob'", timeout=30
        )
        machine.succeed("systemctl show -P Result steam-library-register@bob | grep -qx success")
        machine.fail("test -e /srv/games/users/bob/libraryfolder.vdf")
  '';
}
