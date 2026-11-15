{
  inputs,
  lib,
  ...
}: {
  # ------ Home-manager Module ------ #
  # AI coding agents and the shared repo skill set, consolidated under
  # one namespace:
  #
  #   homeSpec.agents.skills.enable   — build the merged skills tree
  #     (external-systems/skills: its skills/ + a preset of external
  #     sources, composed by inputs.skills.lib.mkSkillsTree) and wire it
  #     into every enabled agent's skills dir, with the skills runtime
  #     (the tools their scripts call) installed next to it. Defaults to
  #     true when any agent is enabled.
  #   homeSpec.agents.skills.preset — "base" (the core own skills, the
  #     shared default), "full" or "sandbox".
  #   homeSpec.agents.skills.extraSources — the user's own picks,
  #     appended after the preset (inputs.skills.lib.selections).
  #   homeSpec.agents.<agent>.enable  — install pi / kimi / claude /
  #     opencode and point the agent's skills dir at the shared tree.
  #   homeSpec.agents.claude.desktop  — Claude Desktop next to claude
  #     (on with it), Cowork's QEMU when the machine has KVM; the host
  #     side (kvm group, vhost_vsock) is nixosModules.claude-desktop.
  #
  #   homeSpec.agents.instructions    — what every agent is told:
  #     machine context, the org ground rules, the user's text, then the
  #     agent's own (homeSpec.agents.<agent>.instructions); "append" adds
  #     it to the built-in system prompt, "replace" replaces it.
  #
  # Every agent gets the same config (MCP servers, skills, workflow,
  # instructions) unless the agent cannot take it; those exceptions are
  # commented where they are made.
  #
  # Helpers live next to this file: _machine-context.nix (the machine
  # facts in every agent's instructions) and _claude.nix (the
  # ~/.claude.json MCP sync and the .nix format hook).
  flake.homeModules.agents = {
    pkgs,
    config,
    # The NixOS config this home-manager user runs on; null in a
    # standalone eval (the OpenShell code-agent image). No `? null`
    # default: the module system looks every formal up by name and
    # never applies a default.
    osConfig,
    ...
  }: let
    cfg = config.homeSpec.agents;
    oc = cfg.opencode;
    mcpCfg = cfg.mcp;
    headroomCfg = config.homeSpec.programs.headroom;
    headroomEnabled = headroomCfg.enable or false;
    headroomProxyRoot = "http://${headroomCfg.proxy.host}:${toString headroomCfg.proxy.port}";
    headroomProxyUrl = "${headroomProxyRoot}/v1";
    # Effective headroom MCP switch: the package, proxy URL and systemd
    # service all come from homeSpec.programs.headroom — this only
    # gates whether the agents get the MCP server (and claude the
    # provider reroute).
    headroomMcpEnabled = mcpCfg.headroom.enable && headroomEnabled;
    # Provider-traffic reroute through the headroom proxy (token savings),
    # gated separately from the headroom MCP server. Per agent:
    #   claude   — ANTHROPIC_BASE_URL session var (documented flow)
    #   opencode — providers.anthropic.settings.baseURL (native V2 shape)
    #   pi       — models.json provider overrides (kimi-coding rides the
    #     Anthropic pipeline with a per-request x-headroom-base-url
    #     override to api.kimi.com/coding — pi hardwires that provider to
    #     the anthropic-messages wire —, anthropic rides the default
    #     pipeline). baseUrl/headers-only overrides preserve pi's built-in
    #     model catalogs and auth.json credentials.
    #   kimi     — KIMI_CODE_BASE_URL session var (the documented managed
    #     OAuth service base override), but only when kimi.config is null:
    #     a managed config.toml (the sandbox image) sets base_url itself.
    headroomRouteProviders = headroomMcpEnabled && mcpCfg.headroom.routeProviders;
    headroomPiModels.providers = {
      kimi-coding = {
        baseUrl = headroomProxyRoot;
        headers."x-headroom-base-url" = "https://api.kimi.com/coding";
      };
      anthropic.baseUrl = headroomProxyRoot;
    };

    # ---- Shared skills tree (homeSpec.agents.skills) ---- #
    # external-systems/skills composes its own skills/ tree with the
    # chosen preset of external skill sources into one derivation (a
    # linkFarm of per-skill symlinks), reused as the skills dir of every
    # enabled agent below. Custom skills override external ones on name
    # collision; among externals, earlier entries win.
    skillsComposition = {
      inherit pkgs;
      inherit (cfg.skills) preset extraSources;
    };
    skillsDir = inputs.skills.lib.mkSkillsTree skillsComposition;
    # Everything the scripts of that same composition call (python and
    # node modules, CLIs, optionally LibreOffice).
    skillsRuntime = inputs.skills.lib.mkSkillsRuntime (skillsComposition
      // {
        inherit (cfg.skills.runtime) office;
      });
    skillsRuntimeEnabled = cfg.skills.enable && cfg.skills.runtime.enable;

    # ---- Machine context (user-level instructions) ---- #
    # Written to every enabled agent's user-level instructions spot:
    # opencode ~/.config/opencode/AGENTS.md (v2's global discovery spot;
    # settings.instructions is decoded but never resolved in v2), pi
    # ~/.pi/agent/AGENTS.md, kimi ~/.kimi-code/AGENTS.md, claude
    # ~/.claude/CLAUDE.md. Nothing is evaluated unless an agent is on.
    machineContext = import ./_machine-context.nix {
      inherit lib osConfig;
      inherit (pkgs.stdenv.hostPlatform) system;
      inherit (config.home) homeDirectory;
      mc = cfg.machineContext;
      skillsRuntime = skillsRuntimeEnabled;
      nixWorkflow = wf.enable;
    };

    claudeLib = import ./_claude.nix {inherit pkgs;};

    # Appended to the default ~/.claude/CLAUDE.md only: Claude Code's Bash
    # tool replaces `grep` with its bundled ugrep.
    # ---- Instructions (homeSpec.agents.instructions) ---- #
    # One text per agent, in order: the machine context, the org ground
    # rules (external-systems/skills lib.groundRules), the user's text,
    # then the agent's own text. "append" keeps the agent's built-in
    # system prompt and adds the text (its user-level instructions
    # file); "replace" puts the text in place of that prompt (pi and kimi
    # SYSTEM.md, a claude output style; opencode has no equivalent).
    instructionsFor = agent: let
      own = cfg.${agent}.instructions;
    in {
      mode = lib.defaultTo cfg.instructions.mode own.mode;
      text = lib.concatStringsSep "\n" (lib.filter (t: t != "") [
        (lib.optionalString machineContext.enable machineContext.text)
        (lib.optionalString cfg.groundRules.enable inputs.skills.lib.groundRules)
        cfg.instructions.text
        own.text
      ]);
    };
    piInstructions = instructionsFor "pi";
    kimiInstructions = instructionsFor "kimi";
    claudeInstructions = instructionsFor "claude";
    opencodeInstructions = instructionsFor "opencode";
    # Per-agent options: the shared mode unless set, and text added after
    # the shared text for this agent only.
    agentInstructionsOptions = agent: {
      mode = lib.mkOption {
        type = with lib.types; nullOr (enum ["append" "replace"]);
        default = null;
        description = "${agent}'s instructions mode; null follows homeSpec.agents.instructions.mode.";
      };
      text = lib.mkOption {
        type = lib.types.lines;
        default = "";
        description = "Text added to ${agent}'s instructions only, after homeSpec.agents.instructions.text.";
      };
    };
    # The claude output style that replace mode selects: it takes the
    # place of claude's default software-engineering prompt.
    claudeOutputStyle = "home-manager";

    claudeShellNote = ''

      Shell: `grep` is Claude Code's bundled ugrep: use `grep -E` (no PCRE lookarounds such as `(?!...)`).
    '';

    # ---- Nix workflow (homeSpec.agents.nixWorkflow) ---- #
    # One set of defaults, rendered per agent in _nix-workflow.nix.
    wf = cfg.nixWorkflow;
    formatOnEdit = wf.enable && wf.formatOnEdit;
    nixWorkflow = import ./_nix-workflow.nix {inherit lib pkgs;};

    # ---- Shared MCP bindings (homeSpec.agents.mcp.*) ---- #
    # PAT file used by the wrapper: explicit patFile override or the
    # canonical sops-nix deployment path of the per-user "github-<user>"
    # clan var (one token for MCP + git + gh; generator declared by
    # nixosModules/git).
    githubMcpPatFile =
      if mcpCfg.github.patFile == null
      then "/run/secrets/vars/shared/github-${config.home.username}/pat"
      else mcpCfg.github.patFile;
    # Wrapper for the PAT auth method: exports GITHUB_PERSONAL_ACCESS_TOKEN
    # from the PAT file before exec'ing the server. The github-mcp-server
    # exits immediately when that env var is unset, so a readable file is a
    # hard requirement for the server to start.
    githubMcpWrapper = pkgs.writeShellScriptBin "github-mcp-server-pat" ''
      if [ -r ${lib.escapeShellArg githubMcpPatFile} ]; then
        export GITHUB_PERSONAL_ACCESS_TOKEN="$(cat ${lib.escapeShellArg githubMcpPatFile})"
      fi
      exec ${lib.getExe mcpCfg.github.package} stdio "$@"
    '';

    # Local stdio MCP servers shared by all four agents, rendered from
    # homeSpec.agents.mcp.* — one entry per enabled server, command as
    # an exe+args list; each consumer formats it for its own config
    # dialect (opencode {type=local; command=[...];} vs the
    # claude-compatible {command; args;} JSON).
    sharedMcpCommands =
      lib.optionalAttrs mcpCfg.github.enable {
        github.command = ["${githubMcpWrapper}/bin/github-mcp-server-pat"];
      }
      // lib.optionalAttrs headroomMcpEnabled {
        headroom.command = [(lib.getExe headroomCfg.package) "mcp" "serve"];
      }
      // lib.optionalAttrs mcpCfg.nixos.enable {
        nixos.command = [(lib.getExe inputs.mcp-nixos.packages.${pkgs.stdenv.hostPlatform.system}.mcp-nixos)];
      }
      // lib.optionalAttrs mcpCfg.kubernetes.enable {
        kubernetes.command =
          [(lib.getExe pkgs.kubernetes-mcp-server)]
          ++ lib.optional mcpCfg.kubernetes.readOnly "--read-only";
      }
      // lib.optionalAttrs mcpCfg.artifacthub.enable {
        artifacthub.command = [(lib.getExe pkgs.artifacthub-mcp)];
      }
      // mcpCfg.extraServers;
    # TOML renderer for kimi-code's config.toml (homeSpec.agents.kimi.config).
    tomlFmt = pkgs.formats.toml {};
    # Remote (streamable HTTP) MCP servers, name -> URL, for every agent
    # that takes one in its config file: opencode, pi, kimi and claude
    # (not Claude Desktop's Chat, whose config file takes local servers
    # only).
    remoteMcpServers = lib.optionalAttrs mcpCfg.varlock-docs.enable {
      varlock-docs = "https://docs.mcp.varlock.dev/mcp";
    };
    # claude-compatible mcpServers attrset (command + args), written to
    # kimi-code (~/.kimi-code/mcp.json) and synced into ~/.claude.json.
    sharedMcpServersClaude =
      lib.mapAttrs (_: v: {
        command = lib.head v.command;
        args = lib.tail v.command;
      })
      sharedMcpCommands;
    # pi's own mcp.json: same servers, plus the pi-specific per-server
    # description/exposure fields when the server entry carries them
    # (mcp.extraServers — e.g. the OpenShell code-agent image pins all
    # its servers `direct` so their tools are listed in the system
    # prompt at session start instead of hidden behind codemode).
    piMcpServers =
      lib.mapAttrs (name: v:
        sharedMcpServersClaude.${name}
        // lib.optionalAttrs ((v.description or null) != null) {inherit (v) description;}
        // lib.optionalAttrs ((v.exposure or null) != null) {inherit (v) exposure;})
      sharedMcpCommands
      // lib.mapAttrs (_: url: {inherit url;}) remoteMcpServers;
    # claude and kimi: the local servers plus the remote ones as
    # {type = "http"; url;}.
    agentMcpServers =
      sharedMcpServersClaude
      // lib.mapAttrs (_: url: {
        type = "http";
        inherit url;
      })
      remoteMcpServers;

    # ---- claude-code settings ---- #
    # ~/.claude/settings.json: the Nix workflow defaults, the skills
    # runtime env, then the caller's claude.settings on top (the caller
    # wins key by key). The settings env block applies to claude's own
    # process and survives a launcher's env scrub, unlike HM
    # sessionVariables, which only login shells see.
    claudeSettings = lib.foldl' lib.recursiveUpdate {} [
      (lib.optionalAttrs wf.enable {
        permissions = {
          additionalDirectories = ["/nix/store" "/tmp"];
          inherit (nixWorkflow.claude) allow;
        };
        inherit (nixWorkflow.claude) env;
      })
      (lib.optionalAttrs formatOnEdit {
        hooks.PostToolUse = [nixWorkflow.claude.hook];
      })
      (lib.optionalAttrs skillsRuntimeEnabled {inherit (skillsRuntime) env;})
      (lib.optionalAttrs (claudeInstructions.mode == "replace") {outputStyle = claudeOutputStyle;})
      cfg.claude.settings
    ];
  in {
    imports = [
      (lib.mkRemovedOptionModule ["homeSpec" "agents" "claude" "claudeMd"] "Use homeSpec.agents.instructions (or homeSpec.agents.claude.instructions) instead; its text is added to the machine context and ground rules, and mode = \"replace\" replaces the system prompt.")
      (lib.mkRemovedOptionModule ["homeSpec" "agents" "pi" "appendSystemMd"] "Use homeSpec.agents.instructions (or homeSpec.agents.pi.instructions) instead.")
      (lib.mkRemovedOptionModule ["homeSpec" "agents" "kimi" "systemMd"] "Use homeSpec.agents.instructions (or homeSpec.agents.kimi.instructions) with mode = \"replace\" instead.")
    ];

    options.homeSpec.agents = {
      # ---- Instructions: homeSpec.agents.instructions.* ---- #
      # What every enabled agent is told each session, on top of or in
      # place of its built-in system prompt.
      instructions = {
        mode = lib.mkOption {
          type = lib.types.enum ["append" "replace"];
          default = "append";
          description = ''
            How the instructions reach every enabled agent:
            - "append": the agent keeps its built-in system prompt and gets
              the instructions as user-level instructions (claude
              ~/.claude/CLAUDE.md, pi ~/.pi/agent/AGENTS.md, kimi
              ~/.kimi-code/AGENTS.md, opencode ~/.config/opencode/AGENTS.md).
            - "replace": the instructions take the place of the built-in
              system prompt (pi ~/.pi/agent/SYSTEM.md, kimi
              ~/.kimi-code/SYSTEM.md, claude a user output style without
              the coding instructions). opencode has no equivalent and
              fails the assertion; set its own mode to "append".
            Per agent: homeSpec.agents.<agent>.instructions.mode.
          '';
        };
        text = lib.mkOption {
          type = lib.types.lines;
          default = "";
          example = "The user is new to Linux: explain each command before running it.";
          description = "Text every enabled agent gets after the machine context and the ground rules: who the user is and how to work with them. Merges across modules (a shared module and the user's profile).";
        };
      };
      groundRules.enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Add the external-systems org ground rules (inputs.skills.lib.groundRules: clones on main, worktrees, no deploys, secrets through varlock) to every enabled agent's instructions.";
      };

      # ---- Shared skills: homeSpec.agents.skills.* ---- #
      skills = {
        enable = lib.mkOption {
          type = lib.types.bool;
          default = oc.enable || cfg.kimi.enable || cfg.pi.enable || cfg.claude.enable;
          defaultText = lib.literalMD "true when any agent is enabled";
          description = ''
            Build the shared skills tree (external-systems/skills' skills/
            merged with the preset's external sources and extraSources via
            inputs.skills.lib.mkSkillsTree)
            and wire it into every enabled agent's skills dir. Defaults to
            true when at least one agent is enabled.
          '';
        };
        preset = lib.mkOption {
          type = lib.types.enum (lib.attrNames inputs.skills.lib.externalSkills);
          default = "base";
          description = ''
            External skill preset from external-systems/skills: "base"
            (a core group of its own skills, the shared default every user gets),
            "full" (the former fleet-wide host set) or "sandbox" (the
            code-agent image set). Users add their own picks with
            extraSources.
          '';
        };
        extraSources = lib.mkOption {
          type = lib.types.listOf lib.types.attrs;
          default = [];
          example = lib.literalExpression "with inputs.skills.lib.selections; anthropic ++ fluxcd ++ terraform";
          description = ''
            External skill sources appended after the preset — usually
            ready-made lists from inputs.skills.lib.selections, or
            {src = inputs.skills.lib.sources.<name>;} entries with
            skillsDir and selectSkills for cherry-picking. Custom skills
            override external ones on name collision; among externals,
            earlier entries win.
          '';
        };
        runtime = {
          enable = lib.mkOption {
            type = lib.types.bool;
            default = true;
            description = ''
              Install the skills runtime (inputs.skills.lib.mkSkillsRuntime)
              for the same composition: the executables, python and node
              modules the installed skills' scripts call, plus NODE_PATH
              (also set in claude's settings env).
            '';
          };
          office = lib.mkOption {
            type = lib.types.bool;
            default = true;
            description = ''
              Include LibreOffice (about 2.5 GiB) when an installed skill
              needs it (the docx/xlsx/pptx skills). Turn off to keep the
              closure small at the cost of those skills' conversions.
            '';
          };
        };
      };

      # ---- Shared machine context: homeSpec.agents.machineContext.* ---- #
      # Per-machine user-level instructions for every enabled agent:
      # hostname, environment, where Nix builds run, hardware from
      # osConfig.hardware.facter.report, and where machine facts live.
      machineContext = {
        enable = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = "Generate user-level machine-context instructions for every enabled agent (hostname, environment, Nix builders and hardware facts from osConfig).";
        };
        repoPath = lib.mkOption {
          type = with lib.types; nullOr str;
          default = null;
          example = "home";
          description = "Directory name of the machine flake repo relative to the user's home directory, written into the generated file's Repo line. null leaves the local path out.";
        };
        repoOwner = lib.mkOption {
          type = with lib.types; nullOr str;
          default = null;
          example = "my-org";
          description = "Owner of the remote machine flake repo, written into the generated file's Repo line. The Repo line is written only when repoOwner and repoName are both set.";
        };
        repoName = lib.mkOption {
          type = with lib.types; nullOr str;
          default = null;
          example = "home";
          description = "Name of the remote machine flake repo, written into the generated file's Repo line. The Repo line is written only when repoOwner and repoName are both set.";
        };
        extraText = lib.mkOption {
          type = with lib.types; nullOr str;
          default = null;
          description = "Optional per-machine notes appended to the generated file (set from machines/<hostname>/configuration.nix).";
        };
        environment = lib.mkOption {
          type = with lib.types; nullOr str;
          default = null;
          description = ''
            Host-environment annotation written after the Machine line (e.g. "vm (KubeVirt guest)").
            NixOS has no eval-time "this is a VM" marker, so VM images set this explicitly; NixOS
            containers are auto-detected (boot.isContainer); bare metal stays null (no line).
          '';
        };
      };

      # ---- Shared Nix workflow: homeSpec.agents.nixWorkflow.* ---- #
      # The same defaults for every enabled agent, each in its own
      # dialect (_nix-workflow.nix has the per-agent table).
      nixWorkflow = {
        enable = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = ''
            Nix workflow defaults for every enabled agent: Nix reads,
            evaluations and builds plus the dev shell's fmt and check run
            without a prompt (claude, opencode; pi never prompts; kimi
            gets no allow rules, it cannot check compound commands),
            /nix/store is readable, and shell commands get room for
            closure builds and VM tests (10 min default, 60 min max where
            the agent has a setting; the machine context says so for the
            rest).
          '';
        };
        formatOnEdit = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = "Format every .nix file with alejandra right after an agent edits it (claude and kimi hooks, opencode formatter, pi extension). Only with nixWorkflow.enable.";
        };
      };

      # ---- pi: homeSpec.agents.pi.* ---- #
      pi = {
        enable = lib.mkEnableOption "the pi coding agent (badlogic/pi-mono)";
        instructions = agentInstructionsOptions "pi";
        package = lib.mkOption {
          type = lib.types.package;
          default = pkgs.pi-coding-agent;
          defaultText = lib.literalExpression "pkgs.pi-coding-agent";
          description = "The pi package to install.";
        };
        installPackage = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = "Add the pi package to home.packages. The OpenShell code-agent image sets false: it ships its own launcher wrapper (headroom proxy ensure + exec) as the sole bin/pi.";
        };
        # ~/.pi/agent/settings.json content (verbatim JSON attrs). The
        # sandbox image uses it for the baked skills resource path.
        settings = lib.mkOption {
          type = lib.types.attrs;
          default = {};
          description = "pi settings.json content (attrs rendered to JSON); empty = not written.";
        };
        # ~/.pi/agent/models.json: provider overrides — apiKey env
        # indirection, baseUrl rerouting (e.g. through a local headroom
        # proxy). Registering only baseUrl/apiKey preserves pi's
        # built-in model catalog for the provider (pi custom-provider
        # docs).
        models = lib.mkOption {
          type = with lib.types; nullOr attrs;
          default = null;
          description = "pi models.json provider overrides (attrs rendered to JSON); null = not written.";
        };
      };

      # ---- kimi-code: homeSpec.agents.kimi.* ---- #
      kimi = {
        enable = lib.mkEnableOption "the Kimi Code CLI (MoonshotAI)";
        instructions = agentInstructionsOptions "kimi";
        # Package comes from numtide/llm-agents.nix via overlays/default.nix
        # (from-source pnpm build, binary `kimi`, auto-update disabled by the
        # wrapper). Overridable so a caller can pin another build.
        package = lib.mkOption {
          type = lib.types.package;
          default = pkgs.kimi-code;
          defaultText = lib.literalExpression "pkgs.kimi-code";
          description = "The kimi-code package to install.";
        };
        installPackage = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = "Add the kimi-code package to home.packages. The OpenShell code-agent image sets false: it ships its own launcher wrapper (headroom proxy ensure + exec) as the sole bin/kimi.";
        };
        # ~/.kimi-code/config.toml content (attrs rendered TOML):
        # provider wiring, models, identity, permission rules. null =
        # not written (kimi's own defaults apply).
        config = lib.mkOption {
          type = with lib.types; nullOr attrs;
          default = null;
          description = "kimi-code config.toml content (attrs rendered to TOML); null = not written.";
        };
      };

      # ---- claude-code: homeSpec.agents.claude.* ---- #
      claude = {
        enable = lib.mkEnableOption "the Claude Code CLI (Anthropic)";
        instructions = agentInstructionsOptions "claude";
        package = lib.mkOption {
          type = lib.types.package;
          default = pkgs.claude-code;
          defaultText = lib.literalExpression "pkgs.claude-code";
          description = "The claude-code package to install.";
        };
        installPackage = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = "Add the claude-code package to home.packages. The OpenShell code-agent image sets false: it ships its own launcher wrapper (headroom proxy ensure + exec) as the sole bin/claude.";
        };
        # Extra ~/.claude/settings.json attrs, merged over the defaults
        # above — e.g. hasCompletedOnboarding, theme, or an env block
        # pinning ANTHROPIC_BASE_URL to a local headroom proxy.
        settings = lib.mkOption {
          type = lib.types.attrs;
          default = {};
          description = "Extra claude-code settings.json attrs, merged over the homeSpec.agents.nixWorkflow defaults (these win key by key).";
        };
        # The sandbox bakes ~/.claude.json too (claude merges either
        # file) so the onboarding skip survives claude rewriting its
        # mutable state file.
        writeClaudeJson = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = "Write ~/.claude.json from claude.settings plus the shared mcpServers (home-manager then owns claude's mutable state file; the activation-time MCP sync is skipped).";
        };
        # Claude Desktop (Chat, Code, Cowork). Its Code tab runs the same
        # engine as the CLI and reads the ~/.claude files above; Chat
        # gets the shared MCP servers through claude_desktop_config.json.
        desktop = {
          enable = lib.mkOption {
            type = lib.types.bool;
            default = cfg.claude.enable && cfg.claude.installPackage;
            defaultText = lib.literalExpression "homeSpec.agents.claude.enable && homeSpec.agents.claude.installPackage";
            description = "Install the Claude Desktop app and sync the shared MCP servers into ~/.config/Claude/claude_desktop_config.json. On with claude-code, except where claude.installPackage is false (the OpenShell code-agent image).";
          };
          package = lib.mkOption {
            type = lib.types.package;
            default = pkgs.claude-desktop;
            defaultText = lib.literalExpression "pkgs.claude-desktop";
            description = "The Claude Desktop package (external-systems/pkgs overlays.llm-agents).";
          };
          cowork = {
            # Read from the NixOS config; null in a standalone eval.
            enable = lib.mkOption {
              type = lib.types.bool;
              default = cfg.claude.desktop.enable && osConfig != null && (osConfig.hostSpec.hardware.kvm.enable or false);
              defaultText = lib.literalExpression "homeSpec.agents.claude.desktop.enable && osConfig.hostSpec.hardware.kvm.enable";
              description = "Cowork's local VM: QEMU in home.packages; nixosModules.claude-desktop adds the user to the kvm group and loads vhost_vsock. On when the machine supports KVM.";
            };
            qemuPackage = lib.mkOption {
              type = lib.types.package;
              default = pkgs.qemu_kvm;
              defaultText = lib.literalExpression "pkgs.qemu_kvm";
              description = "QEMU for Cowork's VM; the app finds qemu-system-* on PATH.";
            };
          };
        };
      };

      # ---- opencode: homeSpec.agents.opencode.* ---- #
      opencode = {
        enable = lib.mkEnableOption "default opencode configuration";
        instructions = agentInstructionsOptions "opencode";
        package = lib.mkOption {
          type = lib.types.package;
          default = pkgs.opencode;
          defaultText = lib.literalExpression "pkgs.opencode";
          description = "The opencode package to install (v2: external-systems/pkgs maps pkgs.opencode to llm-agents.nix's opencode2).";
        };
        installPackage = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = "Add the opencode package to home.packages. false writes the config only (an image that ships its own launcher).";
        };
        settings = lib.mkOption {
          type = lib.types.attrs;
          default = {};
          description = "Extra opencode.json settings, merged over the module's defaults.";
        };
        model = lib.mkOption {
          type = lib.types.str;
          default = "glm-5.3-flash";
          description = "opencode's default model.";
        };
        titleModel = lib.mkOption {
          type = lib.types.str;
          default = oc.model;
          defaultText = lib.literalExpression "config.homeSpec.agents.opencode.model";
          description = "Model of opencode's built-in title agent (the V1 small_model).";
        };
      };

      # ---- Shared MCP servers: homeSpec.agents.mcp.<name>.enable ---- #
      # ONE namespace, FOUR consumers: every server enabled here is
      # written into each enabled agent's MCP config — opencode
      # (settings.mcp.servers), pi (~/.pi/agent/mcp.json), kimi-code
      # (~/.kimi-code/mcp.json) and claude-code (synced into
      # ~/.claude.json at activation). pi/kimi/claude speak the
      # claude-compatible mcpServers JSON shape ({"mcpServers": {name:
      # {command, args}}}); opencode gets its native {type =
      # local|remote} rendering of the same set. The github "oauth"
      # method stays opencode-only — file-configured agents can't run a
      # browser flow, so they always get the local PAT wrapper.
      mcp = {
        # mcp-nixos: NixOS / Home Manager / nix-darwin package & option
        # search (local stdio, flake package).
        nixos.enable = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = "Enable the mcp-nixos MCP server in every enabled agent.";
        };
        # GitHub: auth method selected by `auth`; the two methods are
        # mutually exclusive (enum + assertion below). pat-mode rides the
        # per-user clan vars generator declared by nixosModules/git.
        github = {
          enable = lib.mkOption {
            type = lib.types.bool;
            default = true;
            description = "Enable the GitHub MCP server in every enabled agent.";
          };
          package = lib.mkPackageOption pkgs "github-mcp-server" {};
          auth = lib.mkOption {
            type = lib.types.enum ["oauth" "pat"];
            default = "oauth";
            description = ''
              GitHub MCP auth method for opencode (mutually exclusive):
              - "oauth": remote hosted server (https://api.githubcopilot.com/mcp/);
                opencode runs the browser OAuth flow on first use. No secret.
                pi/kimi/claude always use the local PAT wrapper regardless —
                they cannot run the browser flow from a file config.
              - "pat": local stdio server reading the PAT from `patFile`
                (usually the per-user clan var at
                /run/secrets/vars/shared/github-<user>/pat).
            '';
          };
          patFile = lib.mkOption {
            type = with lib.types; nullOr str;
            default = null;
            description = ''
              Path to a file containing the GitHub Personal Access Token.
              Only used with mcp.github.auth = "pat" (and always by
              pi/kimi/claude); must be null for "oauth".
            '';
          };
        };
        # headroom: context-compression MCP (compress/retrieve/stats)
        # for every agent. Effective only when
        # homeSpec.programs.headroom.enable (the package, proxy URL and
        # systemd service all come from that module).
        headroom = {
          enable = lib.mkOption {
            type = lib.types.bool;
            default = true;
            description = "Enable the headroom MCP server in every enabled agent (no-op unless homeSpec.programs.headroom.enable).";
          };
          routeProviders = lib.mkOption {
            type = lib.types.bool;
            default = true;
            description = ''
              Route every enabled agent's provider traffic through the headroom
              proxy (the proxy's systemd user service holds Restart=always):
              claude via ANTHROPIC_BASE_URL, opencode via providers.anthropic
              baseURL, pi via models.json provider overrides (kimi-coding rides
              a per-request x-headroom-base-url override; anthropic the default
              pipeline), kimi via KIMI_CODE_BASE_URL (skipped when kimi.config
              is managed — the sandbox sets base_url in config.toml itself).
              Requires the proxy upstreams pinned in
              homeSpec.programs.headroom.proxy.{anthropic,openai}ApiUrl.
            '';
          };
        };
        # ArtifactHub MCP server (local stdio, hermetic nix build; off by
        # default, enabled per user by the consumer). Helm-chart tools
        # against artifacthub.io: chart info, default values, templates.
        artifacthub.enable = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = "Enable the ArtifactHub MCP server (Helm chart info/values/templates from artifacthub.io) in every enabled agent.";
        };
        # Kubernetes MCP server (containers/kubernetes-mcp-server, hermetic
        # Go build; stdio is the default transport). Reads the user's
        # kubeconfig.
        kubernetes = {
          enable = lib.mkOption {
            type = lib.types.bool;
            default = false;
            description = "Enable the Kubernetes MCP server in every enabled agent. Off by default: it exits at startup without a kubeconfig (~/.kube/config); enable per profile/machine once cluster credentials exist.";
          };
          readOnly = lib.mkOption {
            type = lib.types.bool;
            default = false;
            description = "Run the Kubernetes MCP server in read-only mode (--read-only: only readOnlyHint tools exposed).";
          };
        };
        # Varlock docs (https://docs.mcp.varlock.dev/mcp, public, no
        # auth). Off by default, enabled per user by the consumer.
        varlock-docs.enable = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = "Enable the Varlock docs MCP server (search varlock.dev documentation) in every enabled agent (remote, streamable HTTP; not Claude Desktop's Chat).";
        };
        # Extra local stdio servers merged verbatim into the shared set
        # (the OpenShell code-agent image's env-mapping credential
        # wrapper trio: headroom/nixos/github). description/exposure are
        # pi-only fields — pi's mcp.json carries them, the claude-shape
        # renderers (kimi/claude) drop them.
        extraServers = lib.mkOption {
          type = with lib.types;
            attrsOf (submodule {
              options = {
                command = lib.mkOption {
                  type = lib.types.listOf lib.types.str;
                  description = "Server command as an exe+args list (split into command/args per consumer dialect).";
                };
                description = lib.mkOption {
                  type = with lib.types; nullOr str;
                  default = null;
                  description = "One-line server description (pi's mcp.json only).";
                };
                exposure = lib.mkOption {
                  type = with lib.types; nullOr (enum ["direct" "codemode"]);
                  default = null;
                  description = "pi tool exposure for this server (pi's mcp.json only).";
                };
              };
            });
          default = {};
          description = "Extra local stdio MCP servers merged into the shared set for every enabled agent.";
        };
      };
    };

    config = lib.mkMerge [
      {
        # Checked whether or not opencode is on: a patFile with oauth is
        # a mistake in any profile.
        assertions = [
          {
            assertion = mcpCfg.github.auth == "oauth" -> mcpCfg.github.patFile == null;
            message = "homeSpec.agents.mcp: github.patFile is only valid with github.auth = \"pat\" — the oauth and pat methods are mutually exclusive.";
          }
          {
            assertion = oc.enable -> opencodeInstructions.mode == "append";
            message = "homeSpec.agents: opencode cannot replace its system prompt from a config file; set homeSpec.agents.opencode.instructions.mode = \"append\".";
          }
        ];
      }

      # ---- skills runtime ---- #
      (lib.mkIf skillsRuntimeEnabled {
        home = {
          packages = [skillsRuntime];
          sessionVariables = skillsRuntime.env;
        };
      })

      # ---- pi ---- #
      (lib.mkIf cfg.pi.enable {
        home.packages = lib.optional cfg.pi.installPackage cfg.pi.package;
        # NOTE: mkMerge, not `mkIf … // …` — attrs //-appended to an
        # mkIf sentinel are SILENTLY DISCARDED by the module system.
        home.file = lib.mkMerge [
          (lib.mkIf cfg.skills.enable {
            ".agents/skills".source = skillsDir;
          })
          # ~/.pi/agent/AGENTS.md applies across working directories
          # (pi configuration docs).
          (lib.mkIf (piInstructions.text != "") (
            if piInstructions.mode == "replace"
            then {".pi/agent/SYSTEM.md".text = piInstructions.text;}
            else {".pi/agent/AGENTS.md".text = piInstructions.text;}
          ))
          # ~/.pi/agent/mcp.json (every project), with pi's per-server
          # description/exposure fields when present (mcp.extraServers).
          (lib.mkIf (piMcpServers != {}) {
            ".pi/agent/mcp.json".text = builtins.toJSON {mcpServers = piMcpServers;};
          })
          (lib.mkIf (cfg.pi.settings != {}) {
            ".pi/agent/settings.json".text = builtins.toJSON cfg.pi.settings;
          })
          (lib.mkIf (cfg.pi.models != null || headroomRouteProviders) {
            ".pi/agent/models.json".text = builtins.toJSON (
              if headroomRouteProviders
              then lib.recursiveUpdate headroomPiModels (lib.defaultTo {} cfg.pi.models)
              else cfg.pi.models
            );
          })
          # The Nix workflow as a global pi extension (auto-discovered).
          (lib.mkIf wf.enable {
            ".pi/agent/extensions/nix-workflow.ts".text = nixWorkflow.piExtension {inherit formatOnEdit;};
          })
        ];
      })

      # ---- kimi-code ---- #
      (lib.mkIf cfg.kimi.enable {
        home = {
          packages = lib.optional cfg.kimi.installPackage cfg.kimi.package;
          file = lib.mkMerge [
            (lib.mkIf cfg.skills.enable {
              ".kimi-code/skills".source = skillsDir;
            })
            # kimi-code user-level AGENTS.md ($KIMI_CODE_HOME/AGENTS.md).
            (lib.mkIf (kimiInstructions.text != "") (
              if kimiInstructions.mode == "replace"
              then {".kimi-code/SYSTEM.md".text = kimiInstructions.text;}
              else {".kimi-code/AGENTS.md".text = kimiInstructions.text;}
            ))
            (lib.mkIf (agentMcpServers != {}) {
              ".kimi-code/mcp.json".text = builtins.toJSON {mcpServers = agentMcpServers;};
            })
            (lib.mkIf (cfg.kimi.config != null) {
              ".kimi-code/config.toml".source = tomlFmt.generate "kimi-config.toml" (
                if wf.enable
                then
                  nixWorkflow.kimiBaked {
                    inherit (cfg.kimi) config;
                    inherit formatOnEdit;
                  }
                else cfg.kimi.config
              );
            })
          ];
          # Route kimi's OAuth-managed provider traffic through the headroom
          # proxy via the documented managed-base override (env-vars docs:
          # KIMI_CODE_BASE_URL is the managed API base URL used after OAuth
          # login). Skipped when kimi.config is managed (the sandbox image
          # sets providers.*.base_url in config.toml itself). Requires the
          # proxy's OpenAI pipeline pinned at the managed service upstream
          # (homeSpec.programs.headroom.proxy.openaiApiUrl =
          # https://api.kimi.ai/coding/v1 — the consumer sets it).
          sessionVariables = lib.mkIf (headroomRouteProviders && cfg.kimi.config == null) {
            KIMI_CODE_BASE_URL = headroomProxyUrl;
          };
          # The Nix workflow's kimi keys (format hook, task timeout),
          # merged into the config.toml kimi's /login also writes. Runs
          # with the workflow off too, so the module's hook is removed.
          # A baked config (kimi.config) carries them itself.
          activation = lib.mkIf (cfg.kimi.config == null) {
            kimiNixWorkflow = config.lib.dag.entryAfter ["writeBoundary"] ''
              run ${lib.getExe nixWorkflow.kimiConfigMerge} ${lib.escapeShellArgs [
                "${config.home.homeDirectory}/.kimi-code/config.toml"
                (builtins.toJSON {
                  marker = nixWorkflow.kimi.hookMarker;
                  hooks = lib.optional formatOnEdit nixWorkflow.kimi.hook;
                  taskTimeoutS =
                    if wf.enable
                    then nixWorkflow.kimi.taskTimeoutS
                    else null;
                })
              ]}
            '';
          };
        };
      })

      # ---- claude-code ---- #
      (lib.mkIf cfg.claude.enable {
        home = {
          packages = lib.optional cfg.claude.installPackage cfg.claude.package;
          file = lib.mkMerge [
            (lib.mkIf cfg.skills.enable {
              ".claude/skills".source = skillsDir;
            })
            # append: user-level memory (~/.claude/CLAUDE.md), loaded into
            # every session. replace: a user output style without claude's
            # coding instructions, selected in settings.json (outputStyle).
            # Claude Code runs Bash with its own `grep` function (bundled
            # ugrep), which every agent there trips over; no other agent has it.
            (lib.mkIf (claudeInstructions.text != "") (
              if claudeInstructions.mode == "replace"
              then {
                ".claude/output-styles/${claudeOutputStyle}.md".text = ''
                  ---
                  name: ${claudeOutputStyle}
                  description: The system prompt from homeSpec.agents.instructions (replace mode)
                  keep-coding-instructions: false
                  ---

                  ${claudeInstructions.text + claudeShellNote}'';
              }
              else {".claude/CLAUDE.md".text = claudeInstructions.text + claudeShellNote;}
            ))
            # settings.json carries no mcpServers: current claude-code
            # ignores them there (`claude mcp list`, 2026-10); the live
            # wiring is ~/.claude.json, synced below.
            (lib.mkIf (claudeSettings != {}) {
              ".claude/settings.json".text = builtins.toJSON claudeSettings;
            })
            (lib.mkIf cfg.claude.writeClaudeJson {
              ".claude.json".text = builtins.toJSON (
                cfg.claude.settings // lib.optionalAttrs (agentMcpServers != {}) {mcpServers = agentMcpServers;}
              );
            })
          ];
          # Route claude-code provider traffic through the headroom proxy
          # (documented ANTHROPIC_BASE_URL flow; the proxy systemd user
          # service holds Restart=always). The proxy root, not /v1: claude
          # appends /v1/messages itself, and /v1/v1/messages is a 404 from
          # api.anthropic.com.
          sessionVariables = lib.mkIf headroomRouteProviders {
            ANTHROPIC_BASE_URL = headroomProxyRoot;
          };
          # ~/.claude.json is claude's mutable state file, so the shared
          # set is synced in at activation (claudeLib.mcpSync), which
          # also drops servers the module no longer manages. Runs with an
          # empty set too, so turning the last server off removes it.
          # Skipped when writeClaudeJson bakes the file (the sandbox
          # image: home-manager owns it there).
          activation = lib.mkIf (!cfg.claude.writeClaudeJson) {
            claudeMcpServers = config.lib.dag.entryAfter ["writeBoundary"] ''
              run ${lib.getExe claudeLib.mcpSync} ${lib.escapeShellArgs [
                "${config.home.homeDirectory}/.claude.json"
                "${config.xdg.stateHome}/home-manager/claude-mcp-servers.json"
                (builtins.toJSON agentMcpServers)
                (builtins.toJSON (lib.unique (claudeLib.knownServers ++ lib.attrNames agentMcpServers)))
              ]}
            '';
          };
        };
      })

      # ---- Claude Desktop ---- #
      (lib.mkIf cfg.claude.desktop.enable {
        home = {
          packages =
            [cfg.claude.desktop.package]
            ++ lib.optional cfg.claude.desktop.cowork.enable cfg.claude.desktop.cowork.qemuPackage;
          # claude_desktop_config.json is the app's mutable state too
          # (it writes its preferences there), so the shared set is
          # merged in at activation exactly like ~/.claude.json.
          activation.claudeDesktopMcpServers = config.lib.dag.entryAfter ["writeBoundary"] ''
            run ${lib.getExe claudeLib.mcpSync} ${lib.escapeShellArgs [
              "${config.xdg.configHome}/Claude/claude_desktop_config.json"
              "${config.xdg.stateHome}/home-manager/claude-desktop-mcp-servers.json"
              (builtins.toJSON sharedMcpServersClaude)
              (builtins.toJSON (lib.unique (claudeLib.knownServers ++ lib.attrNames sharedMcpCommands)))
            ]}
          '';
        };
      })

      # ---- opencode ---- #
      (lib.mkIf oc.enable {
        xdg.configFile = {
          "opencode/AGENTS.md" = lib.mkIf (opencodeInstructions.text != "") {
            inherit (opencodeInstructions) text;
          };
          "opencode/skills" = lib.mkIf cfg.skills.enable {
            source = skillsDir;
          };
        };

        programs.opencode = {
          enable = true;
          # v2 only (external-systems/pkgs: llm-agents.nix's opencode2).
          package =
            if oc.installPackage
            then oc.package
            else null;
          tui.theme = "tokyonight";
          settings = lib.mkMerge [
            {
              inherit (oc) model;
              # small_model V1 field -> the model of the built-in title agent
              # (native V2 shape; V1 small_model is normalized silently).
              agents.title.model = oc.titleModel;
              # V2 keeps compaction.auto; the V1 tail_turns budget is replaced
              # by checkpoint-based compaction (keep.tokens) — dropped here.
              compaction.auto = true;
              # V2 ordered permissions array (last matching rule wins; the V1
              # permission.* map is normalized silently). Path actions keep
              # their names ("read", "external_directory"); bash/task/write
              # were renamed shell/subagent/edit upstream.
              permissions = [
                {
                  action = "read";
                  resource = "/nix/store/**";
                  effect = "allow";
                }
                {
                  action = "read";
                  resource = "/tmp/**";
                  effect = "allow";
                }
                {
                  action = "read";
                  resource = "${config.home.homeDirectory}/.config/opencode/";
                  effect = "allow";
                }
                {
                  action = "read";
                  resource = "/etc/hostname";
                  effect = "allow";
                }
                {
                  action = "external_directory";
                  resource = "/nix/store/**";
                  effect = "allow";
                }
                {
                  action = "external_directory";
                  resource = "/tmp/**";
                  effect = "allow";
                }
              ];
            }
            # Shared local MCP servers: opencode's native {type = local;}
            # rendering. github is EXCLUDED when opencode uses oauth —
            # servers.github.type is a typed enum, so the remote override
            # below would conflict with the shared local definition.
            (lib.mkIf (sharedMcpCommands != {}) {
              mcp.servers =
                lib.mapAttrs (_: v: {
                  type = "local";
                  inherit (v) command;
                }) (
                  if mcpCfg.github.enable && mcpCfg.github.auth == "oauth"
                  then removeAttrs sharedMcpCommands ["github"]
                  else sharedMcpCommands
                );
            })
            # GitHub oauth (opencode-only): remote hosted server,
            # browser flow on first use.
            (lib.mkIf (mcpCfg.github.enable && mcpCfg.github.auth == "oauth") {
              mcp.servers.github = {
                type = "remote";
                url = "https://api.githubcopilot.com/mcp/";
              };
            })
            # Headroom proxy reroute for opencode's own provider traffic.
            # NOTE: the V1 transport plugin (headroom's entry.opencode.js)
            # is gone — V2 only loads V2 plugins ({ id, setup }). Anthropic
            # only: the proxy carries ONE upstream per wire pipeline and
            # its OpenAI pipeline is pinned at kimi-code's managed service
            # (for the kimi reroute) — an openai/deepseek baseURL override
            # would land on the wrong upstream.
            (lib.mkIf headroomRouteProviders {
              providers.anthropic.settings.baseURL = headroomProxyUrl;
            })
            # The Nix workflow: shell allow rules after the base rules
            # (the last matching rule wins), and alejandra for .nix.
            (lib.mkIf wf.enable {
              inherit (nixWorkflow.opencode) permissions;
            })
            (lib.mkIf formatOnEdit {
              inherit (nixWorkflow.opencode) formatter;
            })
            # Remote servers (varlock docs, ...): opencode's {type = remote;}.
            (lib.mkIf (remoteMcpServers != {}) {
              mcp.servers =
                lib.mapAttrs (_: url: {
                  type = "remote";
                  inherit url;
                })
                remoteMcpServers;
            })
            # The caller's settings last.
            oc.settings
          ];
        };
      })
    ];
  };
}
