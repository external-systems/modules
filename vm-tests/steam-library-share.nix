# hostSpec.system.gaming.sharedLibraries: game files one user's Steam
# writes into the shared common/ become writable for the other users
# (steam-library-share@<user>). Steam downloads into the user's own
# steamapps/downloading and moves files in, so they arrive with the
# user's group and no group write; this test does the same with mv.
# Each user's run fixes only that user's files and never follows a
# symlink out of common/.
_: {
  nodes.machine = {
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
  '';
}
