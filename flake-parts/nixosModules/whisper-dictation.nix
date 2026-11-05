{inputs, ...}: {
  # ------ NixOS Modules ------ #
  # Whisper Dictation — local push-to-talk speech-to-text (whisper.cpp).
  # https://github.com/jacopone/whisper-dictation
  #
  # Deliberately minimal, upstream-faithful: user service + ydotool glue
  # only. Driven entirely by home-manager: the users whose profile enables
  # flake.homeModules.whisper-dictation (homeSpec.programs.whisper-dictation)
  # get the daemon, and that module also writes their config.yaml and links
  # their model. Hosts set nothing.
  # With several keyboards, pin the dictation one via
  # input_device: the daemon watches exactly one device, so the pin must
  # name the keyboard that triggers dictation.
  flake.nixosModules.whisper-dictation = {
    config,
    lib,
    pkgs,
    ...
  }: let
    cfg = config.hostSpec.services.whisper-dictation;

    # Read-only scan of home-manager.users (merged option values, mkIf
    # flattened), like nixosModules.git: users whose profile enables the
    # home module. Mirrors the option path in
    # homeModules/whisper-dictation.nix; `or` keeps hosts without
    # home-manager or the home module evaluating.
    dictationUsers = lib.attrNames (lib.filterAttrs (
      _: hmUser: ((((hmUser.homeSpec or {}).programs or {}).whisper-dictation or {}).enable or false)
    ) (config.home-manager.users or {}));

    # Upstream's wrapper omits glib's typelib dir from GI_TYPELIB_PATH, so
    # pygobject cannot import Gtk (ui.py, imported at daemon startup).
    # Re-wrap with the full Gtk-4.0 typelib closure. The input follows our
    # nixpkgs, so pkgs' typelibs match the package. Missing dirs are
    # harmless.
    package = pkgs.symlinkJoin {
      name = "whisper-dictation-vulkan";
      paths = [inputs.whisper-dictation.packages.${pkgs.stdenv.hostPlatform.system}.whisper-dictation-vulkan];
      nativeBuildInputs = [pkgs.makeWrapper];
      postBuild = let
        typelibDirs =
          map (a: "${pkgs.${a}.out}/lib/girepository-1.0")
          ["glib" "graphene" "pango" "gdk-pixbuf" "cairo" "harfbuzz"];
      in ''
        wrapProgram $out/bin/whisper-dictation \
          --prefix GI_TYPELIB_PATH : "${lib.concatStringsSep ":" typelibDirs}"
      '';
    };
  in {
    options.hostSpec.services.whisper-dictation.users = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      readOnly = true;
      default = dictationUsers;
      defaultText = lib.literalMD "home-manager users with `homeSpec.programs.whisper-dictation.enable`";
      description = ''
        Users that run the daemon, discovered from home-manager: every user
        whose profile enables homeSpec.programs.whisper-dictation. The host
        sets nothing; the daemon, ydotoold and the groups follow from this
        list and are off while it is empty. Read-only, for inspection.
      '';
    };

    config = lib.mkIf (cfg.users != []) {
      # ydotoold system daemon (socket /run/ydotoold/socket) + ydotool CLI.
      programs.ydotool.enable = true;

      # /dev/uinput must exist for ydotoold. hardware.uinput loads the
      # module and adds the uinput group and udev rule.
      hardware.uinput.enable = true;

      # Group membership through users.groups, not users.users:
      # home-manager reads users.users.<name> (home, name), so keys derived
      # from the scan above would recurse.
      users.groups = {
        input.members = cfg.users; # evdev hotkey capture
        ${config.programs.ydotool.group}.members = cfg.users; # ydotool socket access
      };

      systemd.user.services.whisper-dictation = {
        description = "Whisper Dictation - local push-to-talk speech-to-text";
        # Other desktop users lack the groups. "|" makes each a triggering
        # condition: the unit starts when any one of them matches.
        unitConfig.ConditionUser = map (user: "|${user}") cfg.users;
        after = ["graphical-session.target"];
        partOf = ["graphical-session.target"];
        wantedBy = ["graphical-session.target"];
        serviceConfig = {
          ExecStart = "${package}/bin/whisper-dictation";
          Restart = "on-failure";
          RestartSec = 5;
          Environment = [
            "PYTHONUNBUFFERED=1"
            # ydotoold is a system service; the CLI needs this to find the
            # socket instead of its /run/user default.
            "YDOTOOL_SOCKET=/run/ydotoold/socket"
            # Upstream shells out to pgrep (procps), missing from the NixOS
            # default unit PATH.
            "PATH=/run/current-system/sw/bin"
          ];
        };
      };
    };
  };
}
