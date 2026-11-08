# hostSpec.system.gaming.sharedLibraries: game files one user's Steam
# writes into the shared common/ become writable for the other users
# (steam-library-share@<user>). Steam downloads into the user's own
# steamapps/downloading and moves files in, so they arrive with the
# user's group and no group write; this test does the same with mv.
# Each user's run fixes only that user's files and never follows a
# symlink out of common/.
_: {
  nodes.machine = {pkgs, ...}: {
    # A process named "steam", as the shader-cache move checks for.
    environment.systemPackages = [
      (pkgs.runCommand "fake-steam" {} ''
        mkdir -p $out/bin
        cp -L ${pkgs.python3}/bin/python3 $out/bin/steam
      '')
    ];
    hostSpec.system.gaming.sharedLibraries = {
      enable = true;
      paths = ["/srv/games"];
    };
    users.users = {
      alice.isNormalUser = true;
      bob.isNormalUser = true;
    };
  };

  testScript = ''
    import shlex

    common = "/srv/games/common"

    def as_user(user, cmd):
        return machine.succeed(f"su {user} -c {shlex.quote(cmd)}")

    def stat(path):
        return machine.succeed(f"stat -c '%U %G %A' {shlex.quote(path)}").strip()

    def download(user, game, name):
        # Steam: write in the user's own staging folder, then move in.
        staging = f"/srv/games/users/{user}/steamapps/downloading"
        as_user(user, f"umask 022 && mkdir -p {staging}/{game}/sub && echo data > {staging}/{game}/sub/{name}")
        as_user(user, f"mkdir -p {common}/{game}/sub && mv {staging}/{game}/sub/{name} {common}/{game}/sub/{name}")

    machine.wait_for_unit("multi-user.target")
    machine.wait_for_unit("steam-library-srv-games.service")

    with subtest("the timer runs the share service for every user"):
        machine.succeed("systemctl is-enabled steam-library-share-alice.timer steam-library-share-bob.timer")
        machine.succeed("systemctl is-active steam-library-share-alice.timer")

    with subtest("files moved in keep the user's group and no group write"):
        download("alice", "Game", "alice.dat")
        download("bob", "Other", "bob.dat")
        # A link out of common/ to a private file of alice's.
        as_user("alice", "echo secret > ~/private && chmod 600 ~/private && ln -s ~/private /srv/games/common/Game/link")
        assert stat(f"{common}/Game/sub/alice.dat") == "alice users -rw-r--r--", stat(f"{common}/Game/sub/alice.dat")
        machine.fail(f"su bob -c 'echo more >> {common}/Game/sub/alice.dat'")

    with subtest("alice's run shares only alice's files"):
        machine.succeed("systemctl start steam-library-share@alice.service")
        machine.succeed("systemctl show -P Result steam-library-share@alice.service | grep -qx success")
        assert stat(f"{common}/Game/sub/alice.dat") == "alice gamers -rw-rw-r--", stat(f"{common}/Game/sub/alice.dat")
        sub = stat(f"{common}/Game/sub")
        assert sub.startswith("alice gamers drwxrws"), sub
        # bob's file and alice's private link target are untouched.
        assert stat(f"{common}/Other/sub/bob.dat") == "bob users -rw-r--r--", stat(f"{common}/Other/sub/bob.dat")
        assert stat("/home/alice/private") == "alice users -rw-------", stat("/home/alice/private")

    with subtest("another user can now update the game"):
        machine.succeed(f"su bob -c 'echo more >> {common}/Game/sub/alice.dat'")
        machine.succeed(f"su bob -c 'echo new > {common}/Game/sub/from-bob.dat'")

    with subtest("bob's run shares bob's files"):
        machine.succeed("systemctl start steam-library-share@bob.service")
        assert stat(f"{common}/Other/sub/bob.dat") == "bob gamers -rw-rw-r--", stat(f"{common}/Other/sub/bob.dat")
        machine.succeed(f"su alice -c 'echo more >> {common}/Other/sub/bob.dat'")

    shared = "/srv/games/shadercache"

    def own(user):
        return f"/srv/games/users/{user}/steamapps/shadercache"

    with subtest("every user's shader cache is the shared one"):
        for user in ["alice", "bob"]:
            assert machine.succeed(f"readlink {own(user)}").strip() == shared
        assert stat(shared).startswith("root gamers drwxrws"), stat(shared)

    with subtest("a user's own caches move into the shared one at the next run"):
        # bob compiled games 222 (fully) and 444 (barely) already; alice
        # has private caches for 111 (new), 222 (a smaller duplicate)
        # and 444 (a bigger one), as before this module.
        as_user("bob", f"mkdir -p {shared}/222 {shared}/444 && head -c 4096 /dev/zero > {shared}/222/cache && echo bob > {shared}/444/cache")
        as_user("alice", f"rm {own('alice')} && mkdir -p {own('alice')}/111 {own('alice')}/222 {own('alice')}/444 && echo a > {own('alice')}/111/cache && echo dup > {own('alice')}/222/cache && head -c 8192 /dev/zero > {own('alice')}/444/cache && echo h > {own('alice')}/.hidden")
        machine.succeed("systemctl restart steam-library-srv-games.service")
        assert machine.succeed(f"readlink {own('alice')}").strip() == shared
        assert machine.succeed(f"cat {shared}/111/cache").strip() == "a"
        assert machine.succeed(f"stat -c %s {shared}/222/cache").strip() == "4096"
        assert machine.succeed(f"stat -c %s {shared}/444/cache").strip() == "8192"
        machine.succeed(f"test -e {shared}/.hidden")

    with subtest("not while that user's Steam runs"):
        as_user("bob", f"rm {own('bob')} && mkdir -p {own('bob')}/333")
        machine.succeed("systemd-run --uid=bob --unit=fake-steam steam -c 'import time; time.sleep(600)'")
        machine.wait_until_succeeds("pgrep -u bob -x steam", timeout=30)
        machine.succeed("systemctl restart steam-library-srv-games.service")
        machine.succeed(f"test -d {own('bob')}/333 && test ! -L {own('bob')}")
        machine.succeed("systemctl stop fake-steam")
        machine.succeed("systemctl restart steam-library-srv-games.service")
        machine.succeed(f"test -d {shared}/333 && test -L {own('bob')}")

    with subtest("shared caches stay writable for everyone"):
        machine.succeed("systemctl start steam-library-share@alice.service steam-library-share@bob.service")
        machine.succeed(f"su bob -c 'echo more >> {shared}/111/cache'")
        machine.succeed(f"su alice -c 'echo more >> {shared}/333/../222/cache'")
  '';
}
