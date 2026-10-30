{
  inputs,
  lib,
  ...
}: {
  # ------ Home-manager Module ------ #
  # AI coding agents and the shared repo skill set, consolidated under
  # one namespace:
  #
  #   homeSpec.agents.skills.enabled   — build the merged skills tree
  #     (external-systems/skills: its skills/ + the "hosts" preset of
  #     external sources, composed by inputs.skills.lib.mkSkillsTree)
  #     and wire it into every enabled
  #     agent's skills dir. Defaults to true when any agent is enabled.
  #   homeSpec.agents.skills.extraSources — per-machine external skill
  #     sources appended after the preset.
  #   homeSpec.agents.<agent>.enabled  — install pi / kimi / claude /
  #     opencode and point the agent's skills dir at the shared tree.
  flake.homeModules.agents = {
    pkgs,
    config,
    # The NixOS config this home-manager user runs on (null only for
    # standalone home-manager evals, which never happens here). Used to
    # identify the machine for the global AGENTS.md machine context below.
    osConfig,
    ...
  }: let
    cfg = config.homeSpec.agents;
    oc = cfg.opencode;
    headroomCfg = config.homeSpec.programs.headroom;
    headroomEnabled = config.homeSpec.programs.headroom.enable or false;
    headroomProxyUrl = "http://${headroomCfg.proxy.host}:${toString headroomCfg.proxy.port}/v1";
    mcpCfg = cfg.mcp;
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
    headroomProxyRoot = "http://${headroomCfg.proxy.host}:${toString headroomCfg.proxy.port}";
    headroomPiModels = {
      providers = {
        kimi-coding = {
          baseUrl = headroomProxyRoot;
          headers."x-headroom-base-url" = "https://api.kimi.com/coding";
        };
        anthropic.baseUrl = headroomProxyRoot;
      };
    };

    # ---- Shared skills tree (homeSpec.agents.skills) ---- #
    # external-systems/skills composes its own skills/ tree with the
    # fleet-wide "hosts" preset of external skill sources into one
    # derivation (a linkFarm of per-skill symlinks), reused as the skills
    # dir of every enabled agent below. Custom skills override external
    # ones on name collision; among externals, earlier entries win.
    # homeSpec.agents.skills.extraSources appends per-machine entries.
    skillsDir = inputs.skills.lib.mkSkillsTree {
      inherit pkgs;
      inherit (cfg.skills) extraSources;
    };

    # ---- Shared MCP bindings (homeSpec.agents.mcp.*) ---- #
    # PAT file used by the wrapper: explicit patFile override or the
    # canonical sops-nix deployment path of the per-user "github-<user>"
    # clan var (one token for MCP + git + gh; generator declared by
    # nixosModules/git).
    githubMcpPatFile =
      if cfg.mcp.github.patFile == null
      then "/run/secrets/vars/shared/github-${config.home.username}/pat"
      else cfg.mcp.github.patFile;
    # Wrapper for the PAT auth method: exports GITHUB_PERSONAL_ACCESS_TOKEN
    # from the PAT file before exec'ing the server. The github-mcp-server
    # exits immediately when that env var is unset, so a readable file is a
    # hard requirement for the server to start.
    githubMcpWrapper = pkgs.writeShellScriptBin "github-mcp-server-opencode" ''
      if [ -r ${lib.escapeShellArg githubMcpPatFile} ]; then
        export GITHUB_PERSONAL_ACCESS_TOKEN="$(cat ${lib.escapeShellArg githubMcpPatFile})"
      fi
      exec ${lib.getExe pkgs.unstable.github-mcp-server} stdio "$@"
    '';

    # ---- Machine context (global AGENTS.md system-prompt header) ---- #
    # Home-manager runs as a NixOS module here, so osConfig carries the
    # machine this user is on. From it, the machine's nixos-facter report
    # (hardware.facter.reportPath, which clan sets from
    # machines/<host>/facter.json) is read at eval time and summarized
    # into ~/.config/opencode/AGENTS.md — opencode v2's global AGENTS.md
    # discovery spot, loaded into the system prompt of every session (a
    # project's own AGENTS.md still auto-loads on top of it). The
    # settings.instructions array is NOT a viable wiring: opencode v2
    # decodes it but never resolves its entries (see
    # services/www/src/docs/content/instructions.mdx at the pinned
    # opencode rev).
    hostName =
      if osConfig == null
      then ""
      else osConfig.networking.hostName;
    inherit (oc.machineContext) facterFile;
    # Not every opencode consumer has a facter report (the installer ISO
    # has none, KubeVirt agent VMs have a hostname without a machines/
    # entry), so the facter-derived content is optional and everything
    # below stays lazy: nothing is read unless this user enables opencode.
    hasFacter = hostName != "" && facterFile != null && builtins.pathExists facterFile;
    # A synthetic report (machineContext.facterReport, set by VM tests)
    # overrides the on-disk read; the accessors below work identically on
    # either shape.
    facterReport =
      if oc.machineContext.facterReport != null
      then oc.machineContext.facterReport
      else if hasFacter
      then builtins.fromJSON (builtins.readFile facterFile)
      else {};
    # Best-effort accessors: facter reports differ per machine and facter
    # version (absent keys, null values, generic PCI class strings) — any
    # missing fact is skipped rather than failing the build.
    facterList = value:
      if lib.isList value
      then value
      else [];
    facterFirst = list:
      if list != []
      then lib.head list
      else null;
    facterLine = prefix: parts:
      if parts == []
      then null
      else "- ${prefix}: ${lib.concatStringsSep ", " parts}";
    # facterGet walks an attrset path (["hardware" "cpu"]), returning null
    # for any missing step; facterAttr reads one attribute off a possibly
    # null/missing object. Both are null-safe instead of throwing.
    facterGet = path: lib.attrByPath path null facterReport;
    facterAttr = set: name:
      if lib.isAttrs set
      then set.${name} or null
      else null;
    cpuEntry = facterFirst (facterList (facterGet ["hardware" "cpu"]));
    cpuModel = facterAttr cpuEntry "model_name";
    cpuThreads = facterAttr cpuEntry "units";
    gpuEntry = facterFirst (facterList (facterGet ["hardware" "graphics_card"]));
    gpuVendor = facterAttr (facterAttr gpuEntry "vendor") "name";
    gpuDriver = facterAttr gpuEntry "driver";
    diskModels =
      lib.unique
      (lib.remove null
        (lib.map (d: facterAttr d "model")
          (facterList (facterGet ["hardware" "disk"]))));
    memDevices =
      lib.filter (d: lib.isAttrs d && ((d.size or 0) > 0))
      (facterList (facterGet ["smbios" "memory_device"]));
    # memory_device sizes are reported in KiB; empty DIMM slots are 0 and
    # filtered out above.
    memGiB = builtins.div (lib.foldl' (sum: d: sum + (d.size or 0)) 0 memDevices) (1024 * 1024);
    memVendor =
      if memDevices == []
      then null
      else (lib.head memDevices).manufacturer or null;
    # Token-lean rendering: the first word is enough for a DIMM
    # manufacturer ("Micron Technology" -> "Micron").
    memVendorShort =
      if memVendor == null
      then null
      else lib.head (lib.splitString " " memVendor);
    machineContextHardware = lib.remove null [
      (facterLine "CPU"
        (lib.remove null [
          cpuModel
          (
            if cpuThreads == null
            then null
            else "${toString cpuThreads} threads"
          )
        ]))
      (facterLine "GPU"
        (lib.remove null [
          gpuVendor
          (
            if gpuDriver == null
            then null
            else "driver ${gpuDriver}"
          )
        ]))
      (facterLine "Memory"
        (lib.remove null [
          (
            if memDevices == []
            then null
            else "${toString memGiB} GiB${lib.optionalString (memVendorShort != null) " (${toString (lib.length memDevices)}x ${memVendorShort} DIMMs)"}"
          )
        ]))
      (facterLine "Disk" diskModels)
    ];
    # Environment annotation (plain line right after the Machine line):
    # the explicit option wins — NixOS has no eval-time "this is a VM"
    # marker (nixpkgs' kubevirt.nix / qemu-vm.nix set none), so VM images
    # set it (e.g. the KubeVirt agent). Otherwise NixOS containers are
    # detected via boot.isContainer (a real eval-time signal). Bare metal
    # emits no line (token-lean).
    machineContextEnvironment =
      if oc.machineContext.environment != null
      then "Environment: ${oc.machineContext.environment}"
      else if (osConfig != null && (osConfig.boot.isContainer or false))
      then "Environment: nixos-container"
      else null;
    # Plain, matter-of-fact and token-lean machine descriptor (no markdown
    # decoration) — written to the global AGENTS.md loaded into the system
    # prompt of every opencode session on this machine: what the machine
    # is, where it runs, what hardware it has and where the facts about it
    # live. The read-only rule and the AGENTS.md rule apply on every
    # machine; the hardware and facts paths only when a facter report
    # exists (installer ISO, KubeVirt agent VMs have none). The repo's
    # skills (incl. nix-style, the user's Nix-writing preferences) are
    # advertised by opencode itself from ~/.config/opencode/skills.
    machineContextLines =
      (
        ["Machine: ${hostName} (NixOS ${pkgs.stdenv.hostPlatform.system})"]
        ++ lib.optionals (machineContextEnvironment != null) [machineContextEnvironment]
        ++ [""]
      )
      ++ lib.optionals (machineContextHardware != [])
      (["Hardware:"] ++ machineContextHardware ++ [""])
      ++ [
        "Repo: github.com/${oc.machineContext.repoOwner}/${oc.machineContext.repoName} (local: ${config.home.homeDirectory}/${oc.machineContext.repoPath})"
      ]
      ++ lib.optionals hasFacter [
        "Machine facts: machines/${hostName}/facter.json, disko.nix, configuration.nix"
      ]
      ++ [
        "Machine config is strictly read-only: changes only by repo owner ${oc.machineContext.repoOwner}, or when instructed to while working in the home repo."
        ""
        "Read a repo's AGENTS.md before working in it."
      ]
      ++ lib.optionals (oc.machineContext.extraText != null)
      ([""]
        ++ lib.filter (line: line != "")
        (lib.splitString "\n" oc.machineContext.extraText));
    # The same text rendered once, written to every enabled agent's
    # user-level instructions spot (see the config blocks below).
    machineContextText = lib.concatStringsSep "\n" machineContextLines + "\n";

    # Local stdio MCP servers shared by all four agents, rendered from
    # homeSpec.agents.mcp.* — one entry per enabled server, command as
    # an exe+args list; each consumer formats it for its own config
    # dialect (opencode {type=local; command=[...];} vs the
    # claude-compatible {command; args;} JSON).
    sharedMcpCommands =
      lib.optionalAttrs cfg.mcp.github.enable {
        github.command = ["${githubMcpWrapper}/bin/github-mcp-server-opencode"];
      }
      // lib.optionalAttrs headroomMcpEnabled {
        headroom.command = [(lib.getExe headroomCfg.package) "mcp" "serve"];
      }
      // lib.optionalAttrs cfg.mcp.nixos.enable {
        nixos.command = ["${lib.getExe inputs.mcp-nixos.packages.${pkgs.stdenv.hostPlatform.system}.mcp-nixos}"];
      }
      // lib.optionalAttrs cfg.mcp.kubernetes.enable {
        kubernetes.command =
          ["${lib.getExe pkgs.kubernetes-mcp-server}"]
          ++ lib.optional cfg.mcp.kubernetes.readOnly "--read-only";
      }
      // lib.optionalAttrs cfg.mcp.artifacthub.enable {
        artifacthub.command = ["${lib.getExe pkgs.artifacthub-mcp}"];
      }
      // cfg.mcp.extraServers;
    # TOML renderer for kimi-code's config.toml (homeSpec.agents.kimi.config).
    tomlFmt = pkgs.formats.toml {};
    # claude-compatible mcpServers attrset (command + args), shared by the
    # per-agent renderers below.
    sharedMcpServersClaude =
      lib.mapAttrs (_: v: {
        command = lib.head v.command;
        args = lib.tail v.command;
      })
      sharedMcpCommands;
    # claude-compatible mcpServers JSON, written to kimi-code
    # (~/.kimi-code/mcp.json) and merged into claude-code's settings.
    sharedMcpJson = builtins.toJSON {
      mcpServers = sharedMcpServersClaude;
    };
    # pi's own mcp.json: same servers, plus the pi-specific per-server
    # description/exposure fields when the server entry carries them
    # (mcp.extraServers — e.g. the OpenShell code-agent image pins all
    # its servers `direct` so their tools are listed in the system
    # prompt at session start instead of hidden behind codemode).
    piMcpJson = builtins.toJSON {
      mcpServers = lib.mapAttrs (_: v:
        {
          command = lib.head v.command;
          args = lib.tail v.command;
        }
        // lib.optionalAttrs ((v.description or null) != null) {inherit (v) description;}
        // lib.optionalAttrs ((v.exposure or null) != null) {inherit (v) exposure;})
      sharedMcpCommands;
    };
    # claude-code's settings.json content: the caller's settings attrs
    # (homeSpec.agents.claude.settings) merged with the shared MCP table.
    claudeSettingsJson = builtins.toJSON (
      cfg.claude.settings
      // lib.optionalAttrs (sharedMcpCommands != {}) {
        mcpServers = sharedMcpServersClaude;
      }
    );
  in {
    options.homeSpec.agents = {
      # ---- Shared skills: homeSpec.agents.skills.* ---- #
      skills = {
        enabled = lib.mkOption {
          type = lib.types.bool;
          default =
            oc.enabled
            || cfg.kimi.enabled
            || cfg.pi.enabled
            || cfg.claude.enabled;
          description = ''
            Build the shared skills tree (external-systems/skills' skills/
            merged with its "hosts" external sources via inputs.skills.lib.mkSkillsTree)
            and wire it into every enabled agent's skills dir. Defaults to
            true when at least one agent is enabled.
          '';
        };
        extraSources = lib.mkOption {
          type = lib.types.listOf lib.types.attrs;
          default = [];
          example = lib.literalExpression "[{src = inputs.skills.lib.sources.cloudflare;}]";
          description = ''
            External skill sources appended after the "hosts" preset —
            e.g. {src = inputs.skills.lib.sources.cloudflare;}, optionally
            with skillsDir and selectSkills for cherry-picking. Custom
            skills override external ones on name collision; among
            externals, earlier entries win.
          '';
        };
      };

      # ---- pi: homeSpec.agents.pi.* ---- #
      pi = {
        enabled = lib.mkEnableOption "the pi coding agent (badlogic/pi-mono)";
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
        # ~/.pi/agent/APPEND_SYSTEM.md: appended to pi's system prompt
        # every session. The sandbox image bakes its environment
        # briefing here; NixOS hosts use the machineContext AGENTS.md.
        appendSystemMd = lib.mkOption {
          type = with lib.types; nullOr str;
          default = null;
          description = "Text for ~/.pi/agent/APPEND_SYSTEM.md (appended to pi's system prompt); null = not written.";
        };
      };

      # ---- kimi-code: homeSpec.agents.kimi.* ---- #
      kimi = {
        enabled = lib.mkEnableOption "the Kimi Code CLI (MoonshotAI)";
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
        # ~/.kimi-code/SYSTEM.md ($KIMI_CODE_HOME/SYSTEM.md): added to
        # kimi's system prompt every session — the sandbox image's
        # environment briefing lives here.
        systemMd = lib.mkOption {
          type = with lib.types; nullOr str;
          default = null;
          description = "Text for ~/.kimi-code/SYSTEM.md (added to kimi's system prompt); null = not written.";
        };
      };

      # ---- claude-code: homeSpec.agents.claude.* ---- #
      claude = {
        enabled = lib.mkEnableOption "the Claude Code CLI (Anthropic)";
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
        # Extra ~/.claude/settings.json attrs, merged with the shared
        # mcpServers table — e.g. hasCompletedOnboarding, theme, or an
        # env block pinning ANTHROPIC_BASE_URL to a local headroom
        # proxy (the settings env block applies to claude's own process
        # and survives a process-env scrub, unlike HM sessionVariables).
        settings = lib.mkOption {
          type = lib.types.attrs;
          default = {};
          description = "Extra claude-code settings.json attrs (merged with the shared mcpServers table).";
        };
        # Also write the merged settings to ~/.claude.json (claude
        # merges either file; the sandbox bakes both so the onboarding
        # skip survives claude rewriting its mutable state file).
        writeClaudeJson = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = "Also write the merged settings to ~/.claude.json (claude's mutable state file; claude merges either).";
        };
        # ~/.claude/CLAUDE.md override text (user-level memory loaded
        # every session). Takes precedence over the machineContext
        # CLAUDE.md; a standalone/no-osConfig eval (the OCI sandbox
        # image) never fires machineContext anyway.
        claudeMd = lib.mkOption {
          type = with lib.types; nullOr str;
          default = null;
          description = "Override text for ~/.claude/CLAUDE.md (user-level memory); null = machineContext default.";
        };
      };

      # ---- opencode: homeSpec.agents.opencode.* ---- #
      opencode = {
        enabled = lib.mkEnableOption "default opencode configuration";
        # Per-machine system-prompt context (machineContext.*): generates
        # the global ~/.config/opencode/AGENTS.md with the hostname, an
        # optional environment annotation, hardware facts from the machine's
        # facter.json and pointers to where machine facts live. opencode v2
        # loads this file into every session's system prompt (the
        # settings.instructions array is not resolved in v2 — see the
        # machine-context comment above).
        machineContext = {
          enable = lib.mkOption {
            type = lib.types.bool;
            default = true;
            description = "Generate the global ~/.config/opencode/AGENTS.md machine context (hostname + environment + hardware facts from machineContext.facterFile).";
          };
          repoPath = lib.mkOption {
            type = lib.types.str;
            default = "home";
            description = "Directory name of the home flake repo relative to the user's home directory, written into the generated file.";
          };
          repoOwner = lib.mkOption {
            type = lib.types.str;
            default = "andrewthomaslee";
            description = "Owner of the remote flake repo, written into the generated file's Remote line.";
          };
          repoName = lib.mkOption {
            type = lib.types.str;
            default = "home";
            description = "Name of the remote flake repo, written into the generated file's Remote line.";
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
          facterFile = lib.mkOption {
            type = with lib.types; nullOr path;
            default =
              if osConfig == null
              then null
              else osConfig.hardware.facter.reportPath or null;
            defaultText = lib.literalExpression "osConfig.hardware.facter.reportPath";
            description = "nixos-facter report summarized into the machine context. Null skips the hardware lines.";
          };
          facterReport = lib.mkOption {
            type = with lib.types; nullOr attrs;
            default = null;
            description = ''
              Synthetic nixos-facter report overriding the facterFile read
              (VM tests: the test hostname has no real report). Null reads the real file.
            '';
          };
        };
      };

      # ---- Shared MCP servers: homeSpec.agents.mcp.<name>.enable ---- #
      # ONE namespace, FOUR consumers: every server enabled here is
      # written into each enabled agent's MCP config — opencode
      # (settings.mcp.servers), pi (~/.pi/agent/mcp.json), kimi-code
      # (~/.kimi-code/mcp.json) and claude-code (~/.claude/settings.json
      # mcpServers — ~/.claude.json itself is claude's mutable state
      # file and must stay writable). pi/kimi/claude speak the
      # claude-compatible mcpServers JSON shape ({"mcpServers": {name:
      # {command, args} / {url}}}); opencode gets its native
      # {type = local|remote} rendering of the same set. The github
      # "oauth" method stays opencode-only — file-configured agents
      # can't run a browser flow, so they always get the local PAT
      # wrapper.
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
            type = with lib.types;
              nullOr str;
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
        # default, enabled via the netsa tag profile). Helm-chart tools
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

        # (https://docs.mcp.varlock.dev/mcp, public, no auth). Off by
        # default, enabled via the netsa tag profile. opencode-only: the
        # file-configured agents get only local servers (remote url MCP
        # support varies).
        varlock-docs.enable = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = "Enable the Varlock docs MCP server (search varlock.dev documentation) in opencode.";
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
      # ---- pi ---- #
      (lib.mkIf cfg.pi.enabled {
        home.packages = lib.optional cfg.pi.installPackage cfg.pi.package;
        # NOTE: mkMerge, not `mkIf … // …` — attrs //-appended to an
        # mkIf sentinel are SILENTLY DISCARDED by the module system
        # (verified 2026-10; the pre-refactor version of this block
        # never wrote pi's mcp.json/AGENTS.md on hosts).
        home.file = lib.mkMerge [
          (lib.mkIf cfg.skills.enabled {
            ".agents/skills".source = skillsDir;
          })
          # pi user instructions: ~/.pi/agent/AGENTS.md is applied
          # across working directories (pi configuration docs) — the
          # same machine context opencode gets via its global
          # AGENTS.md. Gated on the opencode machineContext switch +
          # a resolvable hostname, same as the opencode write.
          (lib.optionalAttrs (oc.machineContext.enable && hostName != "") {
            ".pi/agent/AGENTS.md".text = machineContextText;
          })
          # pi MCP servers: ~/.pi/agent/mcp.json (available in every
          # project), same shared set as the other agents — with pi's
          # per-server description/exposure fields when present
          # (mcp.extraServers).
          (lib.optionalAttrs (sharedMcpCommands != {}) {
            ".pi/agent/mcp.json".text = piMcpJson;
          })
          (lib.optionalAttrs (cfg.pi.settings != {}) {
            ".pi/agent/settings.json".text = builtins.toJSON cfg.pi.settings;
          })
          (lib.optionalAttrs (cfg.pi.models != null || headroomRouteProviders) {
            ".pi/agent/models.json".text = builtins.toJSON (
              if headroomRouteProviders
              then
                lib.recursiveUpdate headroomPiModels (
                  if cfg.pi.models == null
                  then {}
                  else cfg.pi.models
                )
              else cfg.pi.models
            );
          })
          (lib.optionalAttrs (cfg.pi.appendSystemMd != null) {
            ".pi/agent/APPEND_SYSTEM.md".text = cfg.pi.appendSystemMd;
          })
        ];
      })

      # ---- kimi-code ---- #
      (lib.mkIf cfg.kimi.enabled {
        home = {
          packages = lib.optional cfg.kimi.installPackage cfg.kimi.package;
          file = lib.mkMerge [
            (lib.mkIf cfg.skills.enabled {
              ".kimi-code/skills".source = skillsDir;
            })
            # kimi-code user-level AGENTS.md ($KIMI_CODE_HOME/AGENTS.md),
            # same machine context as the other agents.
            (lib.optionalAttrs (oc.machineContext.enable && hostName != "") {
              ".kimi-code/AGENTS.md".text = machineContextText;
            })
            # kimi MCP servers: ~/.kimi-code/mcp.json, same shared set.
            (lib.optionalAttrs (sharedMcpCommands != {}) {
              ".kimi-code/mcp.json".text = sharedMcpJson;
            })
            (lib.optionalAttrs (cfg.kimi.config != null) {
              ".kimi-code/config.toml".source = tomlFmt.generate "kimi-config.toml" cfg.kimi.config;
            })
            (lib.optionalAttrs (cfg.kimi.systemMd != null) {
              ".kimi-code/SYSTEM.md".text = cfg.kimi.systemMd;
            })
          ];
          # Route kimi's OAuth-managed provider traffic through the headroom
          # proxy via the documented managed-base override (env-vars docs:
          # KIMI_CODE_BASE_URL is the managed API base URL used after OAuth
          # login). Skipped when kimi.config is managed (the sandbox image
          # sets providers.*.base_url in config.toml itself). Requires the
          # proxy's OpenAI pipeline pinned at the managed service upstream
          # (homeSpec.programs.headroom.proxy.openaiApiUrl =
          # https://api.kimi.ai/coding/v1 — the netsa profile sets it).
          sessionVariables = lib.mkIf (headroomRouteProviders && cfg.kimi.config == null) {
            KIMI_CODE_BASE_URL = headroomProxyUrl;
          };
        };
      })

      # ---- claude-code ---- #
      (lib.mkIf cfg.claude.enabled {
        home = {
          packages = lib.optional cfg.claude.installPackage cfg.claude.package;
          file = lib.mkMerge [
            (lib.mkIf cfg.skills.enabled {
              ".claude/skills".source = skillsDir;
            })
            # claude-code user-level memory (~/.claude/CLAUDE.md), loaded
            # into every session — same machine context as the other
            # agents (claude.claudeMd overrides; a standalone eval never
            # fires this branch anyway).
            (lib.optionalAttrs (oc.machineContext.enable && hostName != "" && cfg.claude.claudeMd == null) {
              ".claude/CLAUDE.md".text = machineContextText;
            })
            (lib.optionalAttrs (cfg.claude.claudeMd != null) {
              ".claude/CLAUDE.md".text = cfg.claude.claudeMd;
            })
            # claude settings: ~/.claude/settings.json, same shared MCP
            # set merged with the caller's extra settings attrs
            # (claude.settings). NOTE: current claude-code IGNORES
            # settings.json mcpServers — the live MCP wiring is the
            # activation-time merge into ~/.claude.json below.
            (lib.optionalAttrs (sharedMcpCommands != {} || cfg.claude.settings != {}) {
              ".claude/settings.json".text = claudeSettingsJson;
            })
            # The sandbox also bakes ~/.claude.json (claude merges
            # either file) so the onboarding skip survives claude
            # rewriting its mutable state file.
            (lib.optionalAttrs cfg.claude.writeClaudeJson {
              ".claude.json".text = claudeSettingsJson;
            })
          ];
          # Route claude-code provider traffic through the headroom proxy
          # (documented ANTHROPIC_BASE_URL flow; the proxy systemd user
          # service holds Restart=always).
          sessionVariables = lib.mkIf headroomRouteProviders {
            ANTHROPIC_BASE_URL = headroomProxyUrl;
          };
          # claude-code reads user-scope MCP servers from ~/.claude.json's
          # top-level mcpServers — the settings.json mcpServers table is
          # IGNORED (verified with `claude mcp list` on kamrui-h1, 2026-10;
          # the settings.json write above stays as documentation / for
          # versions that do read it). ~/.claude.json is claude's mutable
          # state file, so HM can't own it — merge the shared set in at
          # activation instead, preserving every other key. Skipped when
          # writeClaudeJson already baked the file (the sandbox image: HM
          # owns ~/.claude.json there, and merging into a store symlink
          # would corrupt the link).
          activation = lib.mkIf (sharedMcpCommands != {} && !cfg.claude.writeClaudeJson) {
            claudeMcpServers = config.lib.dag.entryAfter ["writeBoundary"] ''
              claudeJson="${config.home.homeDirectory}/.claude.json"
              if [ -L "$claudeJson" ]; then
                echo "claudeMcpServers: $claudeJson is a symlink — skipping mcpServers merge" >&2
              else
                [ -f "$claudeJson" ] || echo '{}' > "$claudeJson"
                servers='${builtins.toJSON sharedMcpServersClaude}'
                tmp=$(mktemp)
                if ${lib.getExe pkgs.jq} --argjson servers "$servers" \
                    '.mcpServers = ((.mcpServers // {}) * $servers)' \
                    "$claudeJson" > "$tmp"; then
                  cat "$tmp" > "$claudeJson"
                else
                  echo "claudeMcpServers: jq merge failed, leaving $claudeJson untouched" >&2
                fi
                rm -f "$tmp"
              fi
            '';
          };
        };
      })

      # ---- opencode ---- #
      (lib.mkIf oc.enabled {
        xdg.configFile = {
          # Global machine context (built above from osConfig + the machine's
          # facter report): written to opencode's global AGENTS.md discovery
          # spot. opencode v2 loads ~/.config/opencode/AGENTS.md into every
          # session's system prompt (a project's own AGENTS.md still
          # auto-loads on top). The settings.instructions array is decoded
          # but never resolved in v2 (see
          # services/www/src/docs/content/instructions.mdx at the pinned
          # opencode rev), so file instructions ride AGENTS.md.
          "opencode/AGENTS.md" = lib.mkIf (oc.machineContext.enable && hostName != "") {
            text = machineContextText;
          };

          # Skills: the shared skillsDir above (external-systems/skills),
          # linked as ~/.config/opencode/skills.
          "opencode/skills" = lib.mkIf cfg.skills.enabled {
            source = skillsDir;
          };
        };

        assertions = [
          {
            assertion = cfg.mcp.github.auth == "oauth" -> cfg.mcp.github.patFile == null;
            message = "agents.mcp: github.patFile is only valid with github.auth = \"pat\" — the oauth and pat methods are mutually exclusive.";
          }
        ];
        programs.opencode = {
          enable = true;
          # nixpkgs' opencode v2 package.
          package = pkgs.opencode;
          tui.theme = "tokyonight";
          settings = lib.mkMerge [
            {
              model = "glm-5.3-flash";
              # small_model V1 field -> the model of the built-in title agent
              # (native V2 shape; V1 small_model is normalized silently).
              agents.title.model = "glm-5.3-flash";
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
                  resource = "/home/netsa/.config/opencode/";
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
            # Shared local MCP servers (homeSpec.agents.mcp.*): opencode's
            # native {type = local;} rendering of the same set the
            # file-configured agents get (pi/kimi mcp.json, claude
            # settings.json). github is EXCLUDED here when opencode uses
            # the oauth method — servers.github.type is a typed enum, so
            # the remote override below would conflict with the shared
            # local definition (mkMerge does not silently override typed
            # options).
            (lib.mkIf (sharedMcpCommands != {}) {
              mcp.servers =
                lib.mapAttrs (_: v: {
                  type = "local";
                  inherit (v) command;
                }) (
                  if cfg.mcp.github.enable && cfg.mcp.github.auth == "oauth"
                  then removeAttrs sharedMcpCommands ["github"]
                  else sharedMcpCommands
                );
            })
            # GitHub oauth (opencode-only): remote hosted server,
            # browser flow on first use. github was already excluded
            # from the shared local set above when oauth is selected.
            # pi/kimi/claude always keep the local PAT wrapper.
            (lib.mkIf (cfg.mcp.github.enable && cfg.mcp.github.auth == "oauth") {
              mcp.servers.github = {
                type = "remote";
                url = "https://api.githubcopilot.com/mcp/";
              };
            })
            # Headroom proxy reroute for opencode's own provider traffic
            # (the headroom MCP server itself rides the shared set above).
            # NOTE: the V1 transport plugin (headroom's entry.opencode.js)
            # is gone — its default export is a V1 plugin function and V2
            # only loads V2 plugins ({ id, setup }); headroom compresses
            # via these providers.*.settings.baseURL overrides (native V2
            # shape; V1 was provider.<p>.options.baseURL) plus its MCP
            # compress/retrieve tools. Anthropic only: the proxy carries
            # ONE upstream per wire pipeline and its OpenAI pipeline is
            # pinned at kimi-code's managed service (for the kimi reroute)
            # — an opencode openai/deepseek baseURL override would land
            # on the wrong upstream.
            (lib.mkIf headroomRouteProviders {
              providers = {
                anthropic.settings.baseURL = headroomProxyUrl;
              };
            })
            # Varlock docs: hosted docs-search server
            # (https://docs.mcp.varlock.dev/mcp) — public, no auth.
            # opencode-only (remote url MCP is not in the shared set).
            (lib.mkIf cfg.mcp.varlock-docs.enable {
              mcp.servers.varlock-docs = {
                type = "remote";
                url = "https://docs.mcp.varlock.dev/mcp";
              };
            })
          ];
        };
      })
    ];
  };
}
