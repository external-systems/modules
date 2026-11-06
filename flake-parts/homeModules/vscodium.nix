{lib, ...}: {
  # ------ Home-manager Modules ------ #
  # VSCodium only (programs.vscodium). Extensions come from
  # nix-community/nix-vscode-extensions through org-pkgs'
  # overlays.vscode-extensions (part of overlays.default, applied by the
  # consumer): Open VSX releases, VSCodium's own gallery, so updating that
  # input in pkgs updates them all. Claude Code is Marketplace-only. Each
  # language, the Kubernetes and container tooling, Claude, the theme and
  # the layout tweaks are separate per-user toggles.
  flake.homeModules.vscodium = {
    pkgs,
    config,
    ...
  }: let
    cfg = config.homeSpec.programs.vscodium;
    inherit (cfg) languages;
    ext = pkgs.open-vsx-release;

    # Settings are VS Code setting IDs, written dotted ("nix.serverPath"):
    # nested attrsets would become nested JSON objects, which VS Code reads
    # as unknown settings.
    settings = lib.mkMerge [
      (lib.mkIf (yamlEnabled || languages.web.enable) {"redhat.telemetry.enabled" = false;})

      (lib.mkIf (cfg.theme.color != null) {"workbench.colorTheme" = cfg.theme.color;})
      (lib.mkIf (cfg.theme.icons != null) {"workbench.iconTheme" = cfg.theme.icons;})

      # Same font in the editor and the terminal.
      (lib.mkIf (font.family != null) {
        "editor.fontFamily" = font.family;
        "terminal.integrated.fontFamily" = font.family;
      })
      (lib.mkIf (font.size != null) {
        "editor.fontSize" = font.size;
        "terminal.integrated.fontSize" = font.size;
      })
      (lib.mkIf (font.lineHeight != null) {
        "editor.lineHeight" = font.lineHeight;
        "terminal.integrated.lineHeight" = font.lineHeight;
      })
      (lib.mkIf (font.letterSpacing != null) {
        "editor.letterSpacing" = font.letterSpacing;
        "terminal.integrated.letterSpacing" = font.letterSpacing;
      })
      (lib.mkIf font.ligatures {"editor.fontLigatures" = true;})

      (lib.mkIf cfg.tweaks.enable {
        "security.workspace.trust.untrustedFiles" = "open";
        "terminal.integrated.defaultProfile.linux" = "bash";
        "terminal.integrated.enableMultiLinePasteWarning" = "never";
        "terminal.integrated.initialHint" = false;
        "workbench.sideBar.location" = "right";
        "workbench.startupEditor" = "none";
        "workbench.secondarySideBar.defaultVisibility" = "hidden";
        "editor.minimap.enabled" = false;
        "explorer.confirmDragAndDrop" = false;
        "explorer.confirmDelete" = false;
        "explorer.confirmPasteNative" = false;
        "git.autofetch" = true;
        "git.enableSmartCommit" = true;
        "git.confirmSync" = false;
        "git.replaceTagsWhenPull" = true;
        # What treefmt enforces, done on save, so `nix fmt` finds nothing.
        "editor.formatOnSave" = true;
        "files.trimTrailingWhitespace" = true;
        "files.insertFinalNewline" = true;
        "files.trimFinalNewlines" = true;
      })

      # direnv loads the repo's .envrc (the devenv shell) into the editor,
      # so language servers, tasks and the terminal get the project's
      # toolchains (go, cargo, zig, gleam, python); extensions restart
      # when it changes.
      (lib.mkIf cfg.direnv.enable {
        "direnv.path.executable" = lib.getExe pkgs.direnv;
        "direnv.restart.automatic" = true;
      })

      # shellcheck and shfmt from Nix: the Open VSX builds would use
      # bundled or downloaded binaries. shfmt reads .editorconfig.
      (lib.mkIf languages.shell.enable {
        "shellcheck.executablePath" = lib.getExe pkgs.shellcheck;
        "shellformat.path" = lib.getExe pkgs.shfmt;
        "shellformat.useEditorConfig" = true;
        "[shellscript]"."editor.defaultFormatter" = "foxundermoon.shell-format";
      })

      # markdownlint reads a repo's .markdownlint* config; line length is
      # off by default because docs here wrap by sentence or not at all.
      (lib.mkIf languages.markdown.enable {
        "markdownlint.config".MD013 = false;
        "[markdown]"."editor.defaultFormatter" = "DavidAnson.vscode-markdownlint";
      })

      (lib.mkIf languages.nix.enable {
        "nix.enableLanguageServer" = true;
        "nix.serverPath" = lib.getExe pkgs.nixd;
        "nix.formatterPath" = lib.getExe pkgs.alejandra;
        "alejandra.program" = lib.getExe pkgs.alejandra;
        "[nix]" = {
          "editor.defaultFormatter" = "kamadorueda.alejandra";
          "editor.formatOnSave" = true;
        };
        # nixd reads nixpkgs and NixOS/home-manager/flake-parts options from
        # languages.nix.flake (user-wide; a repo's .vscode/settings.json
        # overrides it per workspace).
        "nix.serverSettings".nixd =
          {formatting.command = [(lib.getExe pkgs.alejandra)];}
          // lib.optionalAttrs (languages.nix.flake != null) {
            nixpkgs.expr = ''import (builtins.getFlake "${languages.nix.flake}").inputs.nixpkgs { }'';
            options = {
              # `''${` keeps the hostname selector as literal text for nixd
              # to evaluate at LSP time (machine-agnostic config).
              nixos.expr = ''
                (builtins.getFlake "${languages.nix.flake}").nixosConfigurations.''${builtins.replaceStrings ["\n"] [""] (builtins.readFile /etc/hostname)}.options'';
              home-manager.expr = ''
                (builtins.getFlake "${languages.nix.flake}").nixosConfigurations.''${builtins.replaceStrings ["\n"] [""] (builtins.readFile /etc/hostname)}.options.home-manager.users.type.getSubOptions []'';
              flake-parts.expr = ''(builtins.getFlake "${languages.nix.flake}").debug.options'';
            };
          };
      })

      # The go toolchain comes from the project's shell; gopls from Nix, and
      # the extension never downloads or updates tools itself.
      (lib.mkIf languages.go.enable {
        "go.alternateTools".gopls = lib.getExe pkgs.gopls;
        "go.toolsManagement.autoUpdate" = false;
        "go.toolsManagement.checkForUpdates" = "off";
      })

      # basedpyright replaces Pylance (licensed for VS Code only); ruff
      # formats and sorts imports. The interpreter is the project's.
      (lib.mkIf languages.python.enable {
        "python.languageServer" = "None";
        "python.createEnvironment.trigger" = "off";
        "python.experiments.enabled" = false;
        "ruff.configurationPreference" = "filesystemFirst";
        "[python]" = {
          "editor.defaultFormatter" = "charliermarsh.ruff";
          "editor.formatOnSave" = true;
          "editor.codeActionsOnSave"."source.organizeImports" = "explicit";
        };
      })

      # rust-analyzer's server comes with the nixpkgs extension; cargo and
      # rustc come from the project's shell.
      (lib.mkIf languages.rust.enable {
        "rust-analyzer.check.command" = "clippy";
        "[rust]" = {
          "editor.defaultFormatter" = "rust-lang.rust-analyzer";
          "editor.formatOnSave" = true;
        };
      })

      # The gleam binary is also its language server: the extension runs
      # the one on PATH (the project's shell), so it matches the project.
      (lib.mkIf languages.gleam.enable {
        "[gleam]"."editor.formatOnSave" = true;
      })

      # zig from PATH (the project's shell), zls from Nix; the extension
      # never downloads either.
      (lib.mkIf languages.zig.enable {
        "zig.path" = "zig";
        "zig.zls.enabled" = "on";
        "zig.zls.path" = lib.getExe pkgs.zls;
        "[zig]"."editor.formatOnSave" = true;
      })

      # HTML and CSS language support is built in; this adds class
      # completion, linked tag editing (renames the closing tag) and XML. lemminx from Nix: the binary the
      # extension bundles is not linked for NixOS, and the fallback needs
      # Java.
      (lib.mkIf languages.web.enable {
        "editor.linkedEditing" = true;
        "xml.server.preferBinary" = true;
        "xml.server.binary.path" = lib.getExe pkgs.lemminx;
      })
      (lib.mkIf (languages.web.enable && languages.web.tailwind.enable) {
        "tailwindCSS.classAttributes" = [
          "class"
          "className"
          "ngClass"
          "class:list"
          "_klass"
          "klass"
          "_style"
          "style"
        ];
        "tailwindCSS.includeLanguages".python = "html";
      })

      # schemaStore stays on (GitHub workflows, compose files, ...);
      # languages.yaml.schemas adds file-specific ones.
      (lib.mkIf yamlEnabled {
        "yaml.schemas" = languages.yaml.schemas;
        "yaml.customTags" = languages.yaml.customTags;
      })

      # kubectl and helm from Nix, so the extension never downloads its
      # own (it would otherwise offer to on first start).
      (lib.mkIf cfg.kubernetes.enable {
        vs-kubernetes = {
          "vs-kubernetes.kubectl-path" = lib.getExe pkgs.kubectl;
          "vs-kubernetes.helm-path" = lib.getExe pkgs.kubernetes-helm;
          "vs-kubernetes.crd-code-completion" = "enabled";
          "vs-kubernetes.ignore-recommendations" = true;
          checkForMinikubeUpgrade = false;
        };
      })

      # Container Tools (the successor of the Docker extension, which is
      # now an empty shell over it) for the explorer, compose and debug;
      # Docker DX for Dockerfile and compose language support. Container
      # Tools hands the compose language features to DX and YAML when they
      # are installed.
      (lib.mkIf cfg.containers.enable {
        "containers.containerClient" =
          {
            docker = "com.microsoft.visualstudio.containers.docker";
            podman = "com.microsoft.visualstudio.containers.podman";
          }.${
            cfg.containers.client
          };
        "[dockercompose]"."editor.defaultFormatter" = "redhat.vscode-yaml";
        "[dockerfile]"."editor.defaultFormatter" = "docker.docker";
        "docker.lsp.telemetry" = "off";
      })

      # Above the module's definitions, so a user can replace any of them.
      (lib.mapAttrs (_: lib.mkOverride 90) cfg.extraSettings)
    ];

    # YAML support comes with the YAML language and is required by the
    # Kubernetes extension and used for compose files.
    yamlEnabled = languages.yaml.enable || cfg.kubernetes.enable || cfg.containers.enable;

    inherit (cfg.theme) font;

    extensions = lib.unique (
      # Not on Open VSX. Its bundled claude binary is patched for NixOS
      # (autoPatchelf), like nixpkgs' claude-code.
      lib.optionals cfg.claude.enable [pkgs.vscode-marketplace-release.anthropic.claude-code]
      ++ lib.optionals cfg.remoteSsh.enable [ext.jeanp413.open-remote-ssh]
      ++ lib.optionals cfg.envSpec.enable [ext.varlock.env-spec-language]
      ++ lib.optionals cfg.todoTree.enable [ext.gruntfuggly.todo-tree]
      ++ lib.optionals cfg.direnv.enable [ext.mkhl.direnv]
      ++ lib.optionals cfg.githubActions.enable [ext.github.vscode-github-actions]
      ++ lib.optionals languages.shell.enable [
        ext.timonwong.shellcheck
        ext.foxundermoon.shell-format
      ]
      ++ lib.optionals languages.markdown.enable [ext.davidanson.vscode-markdownlint]
      ++ lib.optionals languages.nix.enable [
        ext.jnoortheen.nix-ide
        ext.kamadorueda.alejandra
      ]
      ++ lib.optionals languages.go.enable [ext.golang.go]
      ++ lib.optionals languages.python.enable [
        ext.ms-python.python
        ext.ms-python.debugpy
        ext.detachhead.basedpyright
        ext.charliermarsh.ruff
      ]
      ++ lib.optionals languages.rust.enable [
        ext.rust-lang.rust-analyzer
        ext.tamasfe.even-better-toml
        ext.vadimcn.vscode-lldb
      ]
      ++ lib.optionals languages.gleam.enable [ext.gleam.gleam]
      ++ lib.optionals languages.zig.enable [ext.ziglang.vscode-zig]
      ++ lib.optionals languages.web.enable (
        [ext.ecmel.vscode-html-css]
        # vscode-xml is built for x86_64-linux (and darwin) only.
        ++ lib.optional (lib.meta.availableOn pkgs.stdenv.hostPlatform ext.redhat.vscode-xml) ext.redhat.vscode-xml
        ++ lib.optional languages.web.tailwind.enable ext.bradlc.vscode-tailwindcss
      )
      ++ lib.optionals yamlEnabled [ext.redhat.vscode-yaml]
      ++ lib.optionals cfg.kubernetes.enable [
        ext.ms-kubernetes-tools.vscode-kubernetes-tools
        ext.tim-koehler.helm-intellisense
      ]
      ++ lib.optionals cfg.containers.enable [
        ext.ms-azuretools.vscode-containers
        ext.docker.docker
      ]
      ++ cfg.theme.extensions
      ++ cfg.extraExtensions
    );

    language = name:
      lib.mkEnableOption "${name} support (extensions and settings)";
  in {
    options.homeSpec.programs.vscodium = {
      enable = lib.mkEnableOption "VSCodium, configured per user";

      mutableExtensions = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Allow installing extensions from VSCodium's gallery (Open VSX) beside the ones listed here. false makes the extension set exactly the configured one.";
      };

      theme = {
        color = lib.mkOption {
          type = with lib.types; nullOr str;
          default = null;
          example = "Red";
          description = "Color theme (workbench.colorTheme) by its label. null keeps VSCodium's default (Default Dark Modern). A theme from an extension needs that extension in theme.extensions.";
        };
        icons = lib.mkOption {
          type = with lib.types; nullOr str;
          default = null;
          example = "catppuccin-macchiato";
          description = "File icon theme (workbench.iconTheme) by its id. null keeps VSCodium's default (Seti). A theme from an extension needs that extension in theme.extensions.";
        };
        extensions = lib.mkOption {
          type = with lib.types; listOf package;
          default = [];
          example = lib.literalExpression "[pkgs.open-vsx-release.catppuccin.catppuccin-vsc-icons]";
          description = "Extensions that provide theme.color or theme.icons.";
        };
        font = {
          family = lib.mkOption {
            type = with lib.types; nullOr str;
            default = null;
            example = "'Atkinson Hyperlegible Mono', monospace";
            description = "Editor and terminal font family (CSS font-family list). null keeps VSCodium's default. The font must be installed: put its package in theme.font.package.";
          };
          package = lib.mkOption {
            type = with lib.types; nullOr package;
            default = null;
            example = lib.literalExpression "pkgs.atkinson-hyperlegible-mono";
            description = "Font package installed for this user (with fontconfig) so theme.font.family resolves.";
          };
          size = lib.mkOption {
            type = with lib.types; nullOr (either ints.positive float);
            default = null;
            example = 15;
            description = "Editor and terminal font size in pixels. null keeps the default (14).";
          };
          lineHeight = lib.mkOption {
            type = with lib.types; nullOr (either ints.unsigned float);
            default = null;
            example = 1.6;
            description = "Editor and terminal line height: below 8 a multiple of the font size, otherwise pixels. More space between lines helps dyslexic readers.";
          };
          letterSpacing = lib.mkOption {
            type = with lib.types; nullOr (either int float);
            default = null;
            example = 0.5;
            description = "Editor and terminal letter spacing in pixels.";
          };
          ligatures = lib.mkEnableOption "font ligatures in the editor (when the font has them)";
        };
      };

      tweaks.enable = lib.mkEnableOption "the layout and workflow tweaks: side bar on the right, no minimap, no start page, no delete/drag confirmations, git autofetch and smart commit, bash terminal, format on save, trailing whitespace trimmed and one final newline";

      direnv.enable = lib.mkOption {
        type = lib.types.bool;
        default = lib.any (language: language.enable or false) (lib.attrValues languages);
        defaultText = lib.literalExpression "any languages.<name>.enable";
        description = "direnv (mkhl.direnv): load the repo's .envrc (its devenv shell) into the editor, so language servers and the terminal use the project's toolchains. On when any language is.";
      };
      githubActions.enable = lib.mkEnableOption "GitHub Actions (github.vscode-github-actions): workflow validation against the actions' inputs, run status";

      claude.enable =
        lib.mkEnableOption "Claude Code for VSCodium (anthropic.claude-code, unfree)"
        // {default = true;};
      remoteSsh.enable = lib.mkEnableOption "Open Remote - SSH (jeanp413.open-remote-ssh), VSCodium's remote development over SSH";
      envSpec.enable = lib.mkEnableOption "@env-spec support for .env.schema and .env files (varlock.env-spec-language)";
      todoTree.enable = lib.mkEnableOption "Todo Tree (TODO/FIXME comments in a tree view)";

      languages = {
        nix = {
          enable = language "Nix: Nix IDE with the nixd language server, alejandra formatting on save";
          flake = lib.mkOption {
            type = with lib.types; nullOr str;
            default = null;
            example = "/home/alice/home";
            description = "Absolute path of the machine flake that nixd reads nixpkgs and NixOS/home-manager/flake-parts options from (user-wide default; a repo's .vscode/settings.json overrides it). null leaves the option exprs unset.";
          };
        };
        go.enable = language "Go: the Go extension with gopls from Nix";
        shell.enable = language "shell scripts: ShellCheck and shfmt (both from Nix), format on save";
        markdown.enable = language "Markdown: markdownlint";
        python.enable = language "Python: Python, debugpy, basedpyright and ruff (format and import sorting on save)";
        rust.enable = language "Rust: rust-analyzer (clippy on save), Even Better TOML, CodeLLDB";
        gleam.enable = language "Gleam: the Gleam extension, using gleam from PATH";
        zig.enable = language "Zig: the Zig extension with zls from Nix, zig from PATH";
        web = {
          enable = language "HTML, CSS and XML: class completion, linked tag editing, XML with lemminx";
          tailwind.enable = lib.mkEnableOption "Tailwind CSS IntelliSense, including class attributes in Python templates";
        };
        yaml = {
          enable = language "YAML: Red Hat YAML with the schema store and the schemas below";
          schemas = lib.mkOption {
            type = with lib.types; attrsOf (either str (listOf str));
            default = {
              "https://squidfunk.github.io/mkdocs-material/schema.json" = "mkdocs.yml";
            };
            description = "yaml.schemas: schema URL (or kubernetes) to a file glob or list of globs, on top of the schema store.";
          };
          customTags = lib.mkOption {
            type = with lib.types; listOf str;
            default = [
              "!ENV scalar"
              "!ENV sequence"
              "!relative scalar"
            ];
            description = "yaml.customTags: tags the YAML server accepts (the defaults are MkDocs').";
          };
        };
      };

      kubernetes.enable = lib.mkEnableOption "Kubernetes: the Kubernetes extension with kubectl and helm from Nix, Helm IntelliSense, YAML";

      containers = {
        enable = lib.mkEnableOption "containers: Container Tools and Docker DX, compose formatted by YAML";
        client = lib.mkOption {
          type = lib.types.enum [
            "docker"
            "podman"
          ];
          default = "docker";
          description = "Container runtime Container Tools drives.";
        };
      };

      extraExtensions = lib.mkOption {
        type = with lib.types; listOf package;
        default = [];
        example = lib.literalExpression "[pkgs.open-vsx-release.usernamehw.errorlens]";
        description = "More extensions for this user.";
      };

      extraSettings = lib.mkOption {
        type = with lib.types; attrsOf anything;
        default = {};
        example = {"editor.fontSize" = 15;};
        description = "More settings.json entries, by setting ID (\"editor.fontSize\"); they replace the module's value for the same ID.";
      };
    };

    config = lib.mkIf (cfg.enable && config.home.username != "root") {
      home.packages =
        lib.optionals languages.nix.enable [
          pkgs.alejandra
          pkgs.nixd
        ]
        ++ lib.optional (font.package != null) font.package;
      fonts.fontconfig.enable = lib.mkIf (font.package != null) true;

      programs = {
        vscodium = {
          enable = true;
          mutableExtensionsDir = cfg.mutableExtensions;
          profiles.default = {
            inherit extensions;
            # Nix updates VSCodium itself.
            enableUpdateCheck = false;
            userSettings = settings;
          };
        };
        bash.shellAliases = {
          c = "codium .";
          cknownhosts = "codium ~/.ssh/known_hosts";
        };
      };
    };
  };
}
