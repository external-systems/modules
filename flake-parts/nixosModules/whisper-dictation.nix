{inputs, ...}: {
  # ------ NixOS Modules ------ #
  # Whisper Dictation — local push-to-talk speech-to-text (whisper.cpp).
  # https://github.com/jacopone/whisper-dictation
  #
  # Deliberately minimal, upstream-faithful: user service + ydotool glue
  # only. The model lives in $HOME (see the whisper-dictation docs in external-systems/home);
  # config.yaml is managed declaratively by the home-manager module
  # flake.homeModules.whisper-dictation (homeSpec.programs.whisper-dictation).
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
    options.hostSpec.services.whisper-dictation = {
      enable = lib.mkEnableOption ''
        whisper-dictation: local push-to-talk speech-to-text daemon
        (whisper.cpp). Requires the user to be in the input group (granted
        here) and a Whisper model in ~/.local/share/whisper/models.
      '';

      user = lib.mkOption {
        type = lib.types.str;
        example = "alice";
        description = "User that runs the daemon (input + ydotool groups, ConditionUser). No default: set it per machine.";
      };
    };

    config = lib.mkIf cfg.enable {
      # ydotoold system daemon (socket /run/ydotoold/socket) + ydotool CLI.
      programs.ydotool.enable = true;

      # /dev/uinput must exist for ydotoold.
      boot.kernelModules = ["uinput"];

      users.users.${cfg.user}.extraGroups = [
        "input" # evdev hotkey capture
        config.programs.ydotool.group # ydotool socket access
      ];

      systemd.user.services.whisper-dictation = {
        description = "Whisper Dictation - local push-to-talk speech-to-text";
        unitConfig.ConditionUser = cfg.user; # other desktop users lack the groups
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
