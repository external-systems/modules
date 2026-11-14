{lib, ...}: {
  # ------ NixOS Modules ------ #
  # 1Password through the NixOS modules, never as a plain package. The
  # desktop app only talks to an `op` that is setgid to the
  # onepassword-cli group; programs._1password installs exactly that at
  # /run/wrappers/bin/op. Do NOT also add pkgs._1password-cli to system or
  # home packages: a Nix-store `op` earlier on PATH fails with
  # "connecting to desktop app" errors.
  #
  # Everything here is system-wide, so every desktop user (present and
  # future) gets it without a per-user toggle.
  #
  # After the rebuild, in the app, once per user: sign in, then Settings >
  # Security > "Unlock using system authentication" (a polkit prompt for
  # the Linux login password; fingerprint also needs services.fprintd and
  # an enrolled finger), Settings > General > "Keep 1Password in the
  # system tray", Settings > Developer > "Integrate with 1Password CLI"
  # and, for the SSH agent, "Set up the SSH Agent". `op vault list` should
  # then prompt for authorization. Quit 1Password from its menu once after
  # changing customAllowedBrowsers: it reads the file at start.
  flake.nixosModules.onepassword = {
    config,
    pkgs,
    ...
  }: let
    cfg = config.hostSpec.services.onepassword;
    gui = config.programs._1password-gui.package;
  in {
    options.hostSpec.services.onepassword = {
      enable = lib.mkEnableOption "1Password desktop app and the setgid op CLI wrapper";

      polkitPolicyOwners = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        example = ["alice"];
        description = "Users allowed to unlock 1Password with system authentication (polkit) and to use the CLI integration. No default: set it per machine.";
      };

      customAllowedBrowsers = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [];
        example = ["zen"];
        description = ''
          Binary names of browsers 1Password does not ship support for,
          written to /etc/1password/custom_allowed_browsers. The desktop
          app verifies the browser that starts its native-messaging host
          and refuses unknown ones ("UnknownBrowser ... isn't a supported
          browser" in ~/.config/1Password/logs/BrowserSupport), so the
          extension in such a browser cannot be unlocked by the app.
          Zen's binary is `zen`.
        '';
      };

      autostart.enable =
        lib.mkEnableOption ''
          starting 1Password minimised to the tray (`1password --silent`)
          at every desktop login, through /etc/xdg/autostart. 1Password
          asks for the account password whenever it starts and accepts
          system authentication only after that, so a running app is what
          makes system authentication and browser unlock useful. A user's
          own ~/.config/autostart/1password.desktop (the app's "Start at
          login") overrides this entry instead of starting a second copy''
        // {default = true;};

      sshAgent.enable =
        lib.mkEnableOption ''
          the 1Password SSH agent for every user who turned it on in the
          app. /etc/ssh/ssh_config points IdentityAgent at
          ~/.1password/agent.sock only while that socket exists, so users
          (and root) without it keep their usual agent. Keys outside
          1Password still work: ssh falls back to its default identity
          files after the agent's keys''
        // {default = true;};
    };

    config = lib.mkIf cfg.enable {
      # Both packages are unfree. mkDefault: a consumer's own predicate
      # (or nixpkgs.config.allowUnfree, which nixosModules.default sets)
      # takes over, so it must cover 1password and 1password-cli too.
      nixpkgs.config.allowUnfreePredicate = lib.mkDefault (
        pkg: builtins.elem (lib.getName pkg) ["1password" "1password-cli"]
      );

      # System authentication, CLI and SSH agent approvals are polkit
      # actions; desktops enable polkit anyway, a bare host would not.
      security.polkit.enable = true;

      programs = {
        _1password.enable = true;
        _1password-gui = {
          enable = true;
          inherit (cfg) polkitPolicyOwners;
        };
        # mkAfter: nixpkgs writes extraConfig above its own `Host *`, so
        # this Match block ends there and cannot swallow global options
        # another module appends. %d is the local user's home directory.
        ssh.extraConfig = lib.mkIf cfg.sshAgent.enable (lib.mkAfter ''
          # 1Password SSH agent, for users who turned it on in the app
          Match exec "test -S %d/.1password/agent.sock"
            IdentityAgent %d/.1password/agent.sock
        '');
      };

      environment.etc = {
        # 1Password requires the file to be root-owned and not writable by
        # anyone else; 0755 is the mode its docs and installers use.
        "1password/custom_allowed_browsers" = lib.mkIf (cfg.customAllowedBrowsers != []) {
          text = lib.concatLines cfg.customAllowedBrowsers;
          mode = "0755";
        };
        "xdg/autostart/1password.desktop" = lib.mkIf cfg.autostart.enable {
          source = pkgs.writeText "1password-autostart.desktop" ''
            [Desktop Entry]
            Name=1Password
            Exec=${lib.getExe gui} --silent
            Icon=1password
            Terminal=false
            Type=Application
            X-GNOME-Autostart-enabled=true
            X-KDE-autostart-after=panel
          '';
        };
      };
    };
  };
}
