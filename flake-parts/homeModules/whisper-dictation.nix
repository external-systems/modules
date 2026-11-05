{lib, ...}: {
  # ------ Home-manager Modules ------ #
  # Whisper Dictation user configuration: writes
  # ~/.config/whisper-dictation/config.yaml for the NixOS-side daemon
  # (flake.nixosModules.whisper-dictation, which provides the service,
  # ydotoold, and the group memberships). This module manages the config
  # the daemon reads at startup and, optionally, the Whisper model file.
  flake.homeModules.whisper-dictation = {
    config,
    pkgs,
    ...
  }: let
    cfg = config.homeSpec.programs.whisper-dictation;

    # sha256 of ggerganov/whisper.cpp's ggml-<model>.bin on Hugging Face.
    # Fill or refresh with:
    #   nix store prefetch-file --json \
    #     https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-<model>.bin
    # and paste its "hash". "large" is absent: upstream loads
    # ggml-large.bin, which Hugging Face does not publish.
    modelHashes = {
      tiny = "sha256-vgfgSOHlma1GNByNKhNWRQl6U4IhZ4t6zdGxkZxuGyE=";
      base = "sha256-YO1bw90U7qhWST0zQ0m0BXgt3K8AKNS130CINF+6Lv4=";
      small = "sha256-G+OpsgY4Z7k35k4ux0gzZKeZF+FX+pjF2UtcH//qmHs=";
      medium = "sha256-bBTVre5fhjlAN7Tk6LWfFnO2zuEOPPCxG72+55wVYgg=";
    };

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
        provisionModel = lib.mkOption {
          type = lib.types.bool;
          default = true;
          example = false;
          description = ''
            Whether to fetch ggml-<model>.bin into the Nix store (pinned by
            hash, one copy shared by every user) and link it into
            ~/.local/share/whisper/models. Replaces a model file already
            there. Not available for "large".
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
      assertions = [
        {
          assertion = cfg.whisper.provisionModel -> modelHashes ? ${cfg.whisper.model};
          message = "homeSpec.programs.whisper-dictation.whisper.provisionModel has no pinned hash for model \"${cfg.whisper.model}\"; pick another model or set provisionModel = false and download it by hand.";
        }
      ];

      xdg = {
        # The daemon reads its config only at startup: restart it on change.
        # try-restart leaves a stopped daemon alone (other machines, other
        # users).
        configFile."whisper-dictation/config.yaml" = {
          text = configFile;
          onChange = "${pkgs.systemd}/bin/systemctl --user try-restart whisper-dictation.service || true";
        };

        dataFile."whisper/models/ggml-${cfg.whisper.model}.bin" = lib.mkIf (cfg.whisper.provisionModel && modelHashes ? ${cfg.whisper.model}) {
          source = pkgs.fetchurl {
            url = "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-${cfg.whisper.model}.bin";
            hash = modelHashes.${cfg.whisper.model};
          };
          # A hand-downloaded model may already sit at this path.
          force = true;
        };
      };
    };
  };
}
