{
  # inputs,
  # self,
  lib,
  ...
}: {
  # ------ Home-manager Modules ------ #
  flake.homeModules.vscode = {
    pkgs,
    config,
    ...
  }: let
    cfg = config.homeSpec.programs.vscode;
  in {
    options.homeSpec.programs.vscode = {
      enable = lib.mkEnableOption "default vscode configuration";
      nixdFlake = lib.mkOption {
        type = with lib.types; nullOr str;
        default = null;
        example = "/home/alice/home";
        description = "Absolute path of the machine flake that nixd reads nixpkgs and NixOS/home-manager/flake-parts options from (user-wide default; a repo's .vscode/settings.json overrides it). null leaves the option exprs unset.";
      };
    };
    config = lib.mkIf (cfg.enable && config.home.username != "root") {
      # nixd: Nix IDE's language server (nixf diagnostics, option hints;
      # per-repo settings in .vscode/settings.json). alejandra: its
      # formatter and alejandra.program below.
      home.packages = with pkgs; [
        alejandra
        gh
        nixd
      ];
      programs.vscodium = {
        enable = true;
        mutableExtensionsDir = true;
        profiles = {
          default = {
            extensions = with pkgs.vscode-extensions; [
              kamadorueda.alejandra
              jnoortheen.nix-ide
              redhat.vscode-yaml
              gruntfuggly.todo-tree
            ];
            userSettings = {
              security.workspace.trust.untrustedFiles = "open";
              terminal.integrated = {
                defaultProfile.linux = "bash";
                enableMultiLinePasteWarning = "never";
                initialHint = false;
              };
              workbench = {
                sideBar.location = "right";
                colorTheme = "Red";
                iconTheme = "catppuccin-macchiato";
                startupEditor = "none";
                secondarySideBar.defaultVisibility = "hidden";
              };
              redhat.telemetry.enabled = false;
              editor.minimap = {
                renderCharacters = false;
                size = "fill";
                enabled = false;
              };
              explorer = {
                confirmDragAndDrop = false;
                confirmDelete = false;
                confirmPasteNative = false;
              };
              git = {
                autofetch = true;
                enableSmartCommit = true;
                confirmSync = false;
                replaceTagsWhenPull = true;
              };
              python = {
                createEnvironment.trigger = "off";
                defaultInterpreterPath = "";
                experiments.enabled = false;
                languageServer = "Default";
              };
              tailwindCSS = {
                classAttributes = [
                  "class"
                  "className"
                  "ngClass"
                  "class:list"
                  "_klass"
                  "klass"
                  "_style"
                  "style"
                ];
                includeLanguages.python = "html";
              };
              "[jsonc]".editor.defaultFormatter = "esbenp.prettier-vscode";
              ruff.configurationPreference = "filesystemFirst";
              supermaven.enable."*" = true;
              sqltools.useNodeRuntime = true;
              tailwind-fold.autoFold = false;
              "[python]" = {
                editor.formatOnSave = true;
                editor.defaultFormatter = "charliermarsh.ruff";
              };
              "[dockercompose]".editor = {
                insertSpaces = true;
                tabSize = 2;
                autoIndent = "advanced";
                defaultFormatter = "redhat.vscode-yaml";
              };
              "[github-actions-workflow]".editor.defaultFormatter = "redhat.vscode-yaml";
              vs-kubernetes.vs-kubernetes.crd-code-completion = "enabled";
              "[nix]".editor = {
                defaultFormatter = "kamadorueda.alejandra";
                formatOnPaste = false;
                formatOnSave = true;
                formatOnType = false;
              };
              alejandra.program = "alejandra";
              yaml = {
                schemaStore.url = "https://raw.githubusercontent.com/weaveworks/eksctl/main/pkg/apis/eksctl.io/v1alpha5/assets/schema.json";
                schemas = {
                  "https://squidfunk.github.io/mkdocs-material/schema.json" = "mkdocs.yml";
                };
                customTags = [
                  "!ENV scalar"
                  "!ENV sequence"
                  "!relative scalar"
                ];
                disableSchemaDetection = [
                  "**/.github/workflows/*.yml"
                  "**/.github/workflows/*.yaml"
                  "**/.gitea/workflows/*.yml"
                  "**/.gitea/workflows/*.yaml"
                  "**/.forgejo/workflows/*.yml"
                  "**/.forgejo/workflows/*.yaml"
                ];
              };
              nix = {
                enableLanguageServer = true;
                # nixd replaces nil: flake-aware option completion. The
                # per-user exprs point at nixdFlake (safe default for
                # arbitrary repos); per-repo .vscode/settings.json overrides
                # per workspace (repo root carries one for this flake).
                serverPath = "nixd";
                formatterPath = "alejandra";
                serverSettings.nixd =
                  {formatting.command = ["alejandra"];}
                  // lib.optionalAttrs (cfg.nixdFlake != null) {
                    nixpkgs.expr = "import (builtins.getFlake \"${cfg.nixdFlake}\").inputs.nixpkgs { }";
                    options = {
                      # `''${` keeps the hostname selector as literal text for
                      # nixd to evaluate at LSP time (machine-agnostic config).
                      nixos.expr = ''
                        (builtins.getFlake "${cfg.nixdFlake}").nixosConfigurations.''${builtins.replaceStrings ["\n"] [""] (builtins.readFile /etc/hostname)}.options'';
                      home-manager.expr = ''
                        (builtins.getFlake "${cfg.nixdFlake}").nixosConfigurations.''${builtins.replaceStrings ["\n"] [""] (builtins.readFile /etc/hostname)}.options.home-manager.users.type.getSubOptions []'';
                      flake-parts.expr = "(builtins.getFlake \"${cfg.nixdFlake}\").debug.options";
                    };
                  };
              };
            };
          };
        };
      };

      programs.bash.shellAliases = {
        c = "codium .";
        cknownhosts = "codium ~/.ssh/known_hosts";
      };
    };
  };
}
