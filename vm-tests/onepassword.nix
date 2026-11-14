# hostSpec.services.onepassword: the system-wide pieces every desktop user
# gets. The allowed-browsers file is root-owned with the listed binaries,
# the autostart entry starts the app minimised, the polkit policy names
# the owners, and ssh uses the 1Password agent socket only for a user
# whose socket exists (the app is never started: it needs a sign-in).
_: {
  nodes.machine = {pkgs, ...}: {
    virtualisation = {
      memorySize = 2048;
      cores = 2;
    };
    hostSpec.services.onepassword = {
      enable = true;
      polkitPolicyOwners = ["alice"];
      customAllowedBrowsers = ["zen" "librewolf"];
    };
    users.users = {
      alice.isNormalUser = true;
      bob.isNormalUser = true;
    };
    environment.systemPackages = [pkgs.python3];
  };

  testScript = ''
    machine.wait_for_unit("multi-user.target", timeout=300)

    with subtest("allowed browsers file is root-owned and lists the binaries"):
        f = "/etc/1password/custom_allowed_browsers"
        machine.succeed(f"test \"$(stat -L -c '%U %a' {f})\" = 'root 755'")
        machine.succeed(f"test \"$(cat {f})\" = \"$(printf 'zen\\nlibrewolf')\"")

    with subtest("autostart entry starts the app minimised"):
        d = "/etc/xdg/autostart/1password.desktop"
        machine.succeed(f"grep -E '^Exec=/nix/store/.*/bin/1password --silent$' {d}")
        machine.succeed(f"test -x \"$(sed -n 's/^Exec=\\(.*\\) --silent$/\\1/p' {d})\"")

    with subtest("polkit policy names the owners"):
        machine.succeed(
            "grep 'unix-user:alice' "
            "/run/current-system/sw/share/polkit-1/actions/com.1password.1Password.policy"
        )

    def agent(user):
        return machine.succeed(
            f"su - {user} -c 'ssh -G host.example' | sed -n 's/^identityagent //p'"
        ).strip()

    with subtest("no agent socket: ssh keeps the default agent"):
        for user in ["alice", "bob", "root"]:
            assert ".1password" not in agent(user), user

    with subtest("agent socket present: ssh uses it for that user only"):
        machine.succeed(
            "su - alice -c 'mkdir -p ~/.1password && python3 -c "
            "\"import socket; socket.socket(socket.AF_UNIX).bind(\\\"/home/alice/.1password/agent.sock\\\")\"'"
        )
        assert agent("alice") == "/home/alice/.1password/agent.sock", agent("alice")
        assert ".1password" not in agent("bob"), agent("bob")
        # The Match block must not swallow the global options after it.
        machine.succeed("su - alice -c 'ssh -G host.example' | grep -x 'forwardx11 no'")
  '';
}
