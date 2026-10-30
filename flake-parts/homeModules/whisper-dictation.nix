{lib, ...}: {
  # ------ Home-manager Modules ------ #
  # Whisper Dictation user configuration: writes
  # ~/.config/whisper-dictation/config.yaml for the NixOS-side daemon
  # (flake.nixosModules.whisper-dictation, which provides the service,
  # ydotoold, and the group memberships). This module only declaratively
  # manages the config the daemon reads at startup.
  flake.homeModules.whisper-dictation = {config, ...}: let
    cfg = config.homeSpec.programs.whisper-dictation;

    # Upstream (config.py) yaml.safe_load()s this file and merges it over
    # its defaults; JSON is a YAML subset, so the toYAML (JSON-compatible)
    # output parses fine. extraConfig wins over the typed options.
    configFile = lib.generators.toYAML {} ({
        hotkey = {
          modifiers = cfg.hotkey.modifiers;
          key = cfg.hotkey.key;
        };
        whisper = {
          inherit (cfg.whisper) model language;
        };
      }
      // lib.optionalAttrs (cfg.inputDevice != null) {
        input_device = cfg.inputDevice;
      }
      // cfg.extraConfig);
  in {
    options.homeSpec.programs.whisper-dictation = {
      enable = lib.mkEnableOption ''
        whisper-dictation user configuration
        (~/.config/whisper-dictation/config.yaml). Pairs with the NixOS
        module flake.nixosModules.whisper-dictation, which provides the
        daemon; this module does not install or run anything by itself.
      '';

      inputDevice = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = ''
          Device name substring or /dev/input/eventN path pinned for
          push-to-talk capture (upstream watches exactly one device).
          Null omits the key and lets upstream auto-select. Prefer a name
          substring: event nodes renumber across reboots/reconnects.
        '';
      };

      hotkey = {
        modifiers = lib.mkOption {
          type = lib.types.listOf (lib.types.enum ["super" "ctrl" "alt" "shift"]);
          default = ["super"];
          description = ''
            Hotkey modifier(s). Each name matches BOTH the left and right
            variant, so a keyboard without a right ctrl is fine. Combine
            as a list (["ctrl" "alt"]).
          '';
        };
        key = lib.mkOption {
          type = lib.types.enum ["period" "comma" "space" "slash" "semicolon"];
          default = "semicolon";
          description = ''
            Hotkey trigger key. Upstream only recognizes these five —
            any other name silently falls back to period (no F-keys).
          '';
        };
      };

      whisper = {
        model = lib.mkOption {
          type = lib.types.enum ["tiny" "base" "small" "medium" "large"];
          default = "small";
          description = ''
            Whisper model size; the daemon loads ggml-<model>.bin from
            ~/.local/share/whisper/models.
          '';
        };
        language = lib.mkOption {
          type = lib.types.str;
          default = "en";
          description = "Transcription language ('auto' for detection).";
        };
      };

      extraConfig = lib.mkOption {
        type = lib.types.attrs;
        default = {};
        description = ''
          Extra top-level keys merged into config.yaml — upstream knobs
          not covered above (processing, typing, ui).
        '';
      };
    };

    config = lib.mkIf cfg.enable {
      xdg.configFile."whisper-dictation/config.yaml".text = configFile;
    };
  };
}
