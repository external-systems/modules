# hostSpec.system.gaming.steamSharing: alice and bob keep Steam
# libraries of their own on one btrfs filesystem. steam-copy-game gives
# bob alice's game as a reflink copy he owns; steam-shader-sync hands the
# biggest shader cache of a game to the other users who have it. No real
# Steam: its folders are faked, and a process named "steam" stands in for
# a running Steam. Both refuse to write through symlinks.
_: {
  nodes.machine = {pkgs, ...}: {
    virtualisation = {
      emptyDiskImages = [1024];
      fileSystems."/mnt/steam" = {
        device = "/dev/vdb";
        fsType = "btrfs";
        autoFormat = true;
      };
    };
    hostSpec.system.gaming.steamSharing.enable = true;
    users.users = {
      alice.isNormalUser = true;
      bob.isNormalUser = true;
    };
    environment.systemPackages = [
      pkgs.btrfs-progs
      # A process named "steam" (a symlink would keep python's name).
      (pkgs.runCommand "fake-steam" {} ''
        mkdir -p $out/bin
        cp -L ${pkgs.python3}/bin/python3 $out/bin/steam
      '')
    ];
  };

  testScript = ''
    import shlex

    def lib(user):
        return f"/mnt/steam/users/{user}"

    def as_user(user, cmd):
        return machine.succeed(f"su {user} -c {shlex.quote(cmd)}")

    def owner(path):
        return machine.succeed(f"stat -c %U {shlex.quote(path)}").strip()

    def shared(path):
        return int(machine.succeed(f"btrfs filesystem du -s --raw {shlex.quote(path)} | awk 'NR == 2 {{ print $3 }}'"))

    def steam_running(user):
        machine.succeed(f"systemd-run --uid={user} --unit=fake-steam-{user} steam -c 'import time; time.sleep(600)'")
        machine.wait_until_succeeds(f"pgrep -u {user} -x steam", timeout=30)

    def steam_quit(user):
        machine.succeed(f"systemctl stop fake-steam-{user}")

    def manifest(user, appid, installdir):
        as_user(user, f"printf '\"AppState\"\\n{{\\n\\t\"appid\"\\t\\t\"{appid}\"\\n\\t\"installdir\"\\t\\t\"{installdir}\"\\n}}\\n' > {lib(user)}/steamapps/appmanifest_{appid}.acf")

    machine.wait_for_unit("multi-user.target")

    with subtest("each user has a Steam library of their own"):
        machine.succeed("install -d -m 0755 /mnt/steam/users")
        for user in ["alice", "bob"]:
            machine.succeed(f"install -d -o {user} -g users {lib(user)} {lib(user)}/steamapps")
            as_user(user, "mkdir -p ~/.local/share/Steam/config")
            as_user(user, f"printf '\"libraryfolders\"\\n{{\\n\\t\"0\"\\n\\t{{\\n\\t\\t\"path\"\\t\\t\"/home/{user}/.local/share/Steam\"\\n\\t}}\\n\\t\"1\"\\n\\t{{\\n\\t\\t\"path\"\\t\\t\"{lib(user)}\"\\n\\t}}\\n}}\\n' > ~/.local/share/Steam/config/libraryfolders.vdf")
        # alice installed game 100 and compiled its shaders.
        manifest("alice", 100, "Game")
        as_user("alice", f"mkdir -p {lib('alice')}/steamapps/common/Game {lib('alice')}/steamapps/shadercache/100")
        as_user("alice", f"head -c 8M /dev/urandom > {lib('alice')}/steamapps/common/Game/game.bin")
        as_user("alice", f"head -c 1M /dev/urandom > {lib('alice')}/steamapps/shadercache/100/cache")
        machine.succeed("systemctl is-enabled steam-shader-sync.timer")

    with subtest("steam-copy-game waits for the receiver's Steam to close"):
        steam_running("bob")
        machine.fail("steam-copy-game --from alice --to bob 100")
        steam_quit("bob")

    with subtest("steam-copy-game gives bob his own reflink copy"):
        machine.succeed("steam-copy-game --from alice --to bob 100")
        game = f"{lib('bob')}/steamapps/common/Game/game.bin"
        machine.succeed(f"cmp {lib('alice')}/steamapps/common/Game/game.bin {game}")
        for path in [game, f"{lib('bob')}/steamapps/common/Game", f"{lib('bob')}/steamapps/shadercache/100/cache", f"{lib('bob')}/steamapps/appmanifest_100.acf"]:
            assert owner(path) == "bob", (path, owner(path))
        # A reflink: the data is stored once.
        assert shared(game) >= 8 * 1024 * 1024, shared(game)
        # bob can now change it, as his Steam will.
        as_user("bob", f"chmod 600 {game} && touch -d 2020-01-01 {game}")

    with subtest("an existing copy needs --force"):
        machine.fail("steam-copy-game --from alice --to bob 100")
        machine.succeed("steam-copy-game --from alice --to bob --force 100")
        assert owner(game) == "bob"

    with subtest("steam-copy-game never writes through a link"):
        as_user("bob", f"mv {lib('bob')}/steamapps/common {lib('bob')}/steamapps/common.real && ln -s /etc {lib('bob')}/steamapps/common")
        machine.fail("steam-copy-game --from alice --to bob --force 100")
        machine.fail("test -e /etc/Game")
        as_user("bob", f"rm {lib('bob')}/steamapps/common && mv {lib('bob')}/steamapps/common.real {lib('bob')}/steamapps/common")

    with subtest("shader sync: the bigger cache goes to the other users who have the game"):
        # alice played on (her cache for 100 grew); bob installed and
        # compiled game 200, which alice has too; only bob has game 300.
        as_user("alice", f"head -c 2M /dev/urandom >> {lib('alice')}/steamapps/shadercache/100/cache")
        manifest("alice", 200, "Other")
        manifest("bob", 200, "Other")
        manifest("bob", 300, "Third")
        as_user("bob", f"mkdir -p {lib('bob')}/steamapps/shadercache/200 {lib('bob')}/steamapps/shadercache/300")
        as_user("bob", f"head -c 1M /dev/urandom > {lib('bob')}/steamapps/shadercache/200/cache && echo x > {lib('bob')}/steamapps/shadercache/300/cache")
        # A link bob planted where alice's cache would go is replaced, not followed.
        machine.succeed("mkdir -p /etc/precious && echo keep > /etc/precious/cache")
        as_user("alice", f"ln -s /etc/precious {lib('alice')}/steamapps/shadercache/200")

        machine.succeed("systemctl start steam-shader-sync.service")
        machine.succeed(f"cmp {lib('alice')}/steamapps/shadercache/100/cache {lib('bob')}/steamapps/shadercache/100/cache")
        machine.succeed(f"cmp {lib('bob')}/steamapps/shadercache/200/cache {lib('alice')}/steamapps/shadercache/200/cache")
        machine.succeed(f"test ! -L {lib('alice')}/steamapps/shadercache/200")
        assert machine.succeed("cat /etc/precious/cache").strip() == "keep"
        assert owner(f"{lib('bob')}/steamapps/shadercache/100/cache") == "bob"
        assert owner(f"{lib('alice')}/steamapps/shadercache/200/cache") == "alice"
        machine.fail(f"test -e {lib('alice')}/steamapps/shadercache/300")

    with subtest("shader sync leaves users whose Steam runs alone"):
        as_user("bob", f"head -c 4M /dev/urandom >> {lib('bob')}/steamapps/shadercache/100/cache")
        steam_running("alice")
        machine.succeed("systemctl start steam-shader-sync.service")
        machine.fail(f"cmp {lib('alice')}/steamapps/shadercache/100/cache {lib('bob')}/steamapps/shadercache/100/cache")
        steam_quit("alice")
        machine.succeed("systemctl start steam-shader-sync.service")
        machine.succeed(f"cmp {lib('alice')}/steamapps/shadercache/100/cache {lib('bob')}/steamapps/shadercache/100/cache")
  '';
}
