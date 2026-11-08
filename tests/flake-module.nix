# The module eval checks: every hostSpec/homeSpec toggle on, evaluated
# against the fixtures here. Formatting, docs and lock-sync come from
# org-pkgs flakeModules.default (flake.nix). Checks are evaluated only on
# demand, so a consumer of nixosModules/homeModules never touches them.
{
  inputs,
  lib,
  self,
  ...
}: {
  perSystem = {
    pkgs,
    system,
    ...
  }: let
    # Every hostSpec/homeSpec toggle on, evaluated down to the system
    # derivation. Only instantiated, never built: the check fails when a
    # module stops evaluating, not when a package fails to build.
    machine = inputs.nixpkgs.lib.nixosSystem {
      modules = [
        (import ./fixtures/nixos.nix {inherit inputs self;})
        {nixpkgs.hostPlatform = system;}
      ];
    };
  in {
    # Formatting and lint: checks.treefmt (pkgs flakeModules.default).
    # The fleet is x86_64-linux; jovian and the GPU modules are not meant
    # for aarch64.
    checks = lib.optionalAttrs (system == "x86_64-linux") {
      eval-all-enabled = pkgs.writeText "eval-all-enabled" (
        builtins.unsafeDiscardStringContext machine.config.system.build.toplevel.drvPath
      );

      # Per-user Storage Box wiring: the NixOS companion declares alice's
      # key, feeds its path back, and the user units come out right.
      storagebox-per-user = let
        inherit (machine.config.clan.core.vars) generators;
        hm = machine.config.home-manager.users.alice;
        units = hm.systemd.user.services;
        key = generators.storagebox-ssh-alice.files.ssh-private-key;
        mainUnit = units."rclone-mount:@storagebox-main";
        archiveUnit = units."rclone-mount:BACKUPS@storagebox-archive";
        expect = cond: msg: lib.assertMsg cond "storagebox-per-user: ${msg}";
      in
        assert expect (generators ? storagebox-ssh-alice) "no storagebox-ssh-alice generator";
        assert expect (key.owner == "alice" && key.mode == "0400") "key not owned by alice with mode 0400";
        assert expect (hm.homeSpec.programs.storagebox.keyFile == key.path) "keyFile not fed back";
        assert expect (mainUnit.Install.WantedBy == ["default.target"]) "main box does not start on login";
        assert expect (archiveUnit.Install.WantedBy == []) "manual box starts on login";
        assert expect (lib.hasInfix "storagebox-archive:BACKUPS" (toString archiveUnit.Service.ExecStart)) "remotePath not mounted";
        assert expect (hm.programs.ssh.settings.storagebox-main.data.Port == 23) "ssh alias missing";
          pkgs.writeText "storagebox-per-user" "ok";

      # VSCodium gets GH_TOKEN from alice's PAT: the wrapper reads the
      # deployed clan-var path at launch (never the token itself).
      vscodium-gh-token = let
        hm = machine.config.home-manager.users.alice;
        inherit (hm.homeSpec.programs.git.githubAuth) patFile;
        inherit (hm.programs.vscodium) package;
        expect = cond: msg: lib.assertMsg cond "vscodium-gh-token: ${msg}";
      in
        assert expect (patFile != null) "no patFile fed back";
        assert expect (lib.hasInfix patFile (package.buildCommand or "")) "codium not wrapped with the PAT file";
        assert expect (lib.getExe package == "${package}/bin/codium") "wrapper lost bin/codium";
          pkgs.writeText "vscodium-gh-token" "ok";

      # The three boot entries: default (jovian, Steam on the desktop, no
      # Gaming Mode), gaming (Gaming Mode as the dedicated user) and
      # developer (no jovian, no Steam). The user and libraries exist in
      # every entry; each hook lands only in its own entry. defaultEntry =
      # "gaming" (a Steam Deck) swaps default and specialisation.
      gaming = let
        cfg = machine.config;
        gamer = cfg.users.users.gamer;
        entryWith = extra:
          inputs.nixpkgs.lib.nixosSystem {
            modules = [
              self.nixosModules.default
              ./clan-stub.nix
              {
                nixpkgs.hostPlatform = system;
                fileSystems = {
                  "/" = {
                    device = "/dev/disk/by-label/nixos";
                    fsType = "ext4";
                  };
                  "/mnt/steam" = {
                    device = "/dev/disk/by-label/root";
                    fsType = "btrfs";
                  };
                };
                boot.loader.grub.devices = ["nodev"];
                system.stateVersion = "26.11";
                swapDevices = [{device = "/dev/disk/by-label/swap";}];
                users.users.alice.isNormalUser = true;
                hostSpec.system = {
                  gamingSpecialisation.enable = true;
                  developerSpecialisation = {
                    enable = true;
                    diskSwap = false;
                    configuration.environment.etc.developer-hook.text = "on";
                  };
                  jovian.gamingMode = true;
                  gaming = {
                    sharedLibraries = {
                      enable = true;
                      paths = ["/mnt/steam"];
                    };
                    steamConfig.enable = true;
                  };
                };
              }
              extra
            ];
          };
        entry = entryWith {hostSpec.system.gamingSpecialisation.configuration.environment.etc.gaming-hook.text = "on";};
        # A Steam Deck: Gaming Mode by default, the desktop as the
        # specialisation; there the gaming hook is refused.
        deckWith = extra: (entryWith ({hostSpec.system.gamingSpecialisation.defaultEntry = "gaming";} // extra)).config;
        deck = deckWith {};
        deskEntry = deck.specialisation.desktop.configuration;
        failed = c: map (a: a.message) (lib.filter (a: !a.assertion) c.assertions);
        parent = entry.config;
        # NixOS types specialisation.<name>.configuration as the child's
        # own evaluated config, so this is the gaming entry itself.
        gaming = parent.specialisation.gaming.configuration;
        developer = parent.specialisation.developer.configuration;
        expect = c: msg: lib.assertMsg c "gaming: ${msg}";
      in
        assert expect (gamer.isNormalUser && gamer.uid == 1500 && gamer.hashedPassword == "!") "gamer not a locked normal user with uid 1500";
        assert expect (!(lib.elem "wheel" gamer.extraGroups) && gamer.openssh.authorizedKeys.keys == []) "gamer has wheel or SSH keys";
        assert expect (cfg.services.displayManager.sddm.settings.Users.HideUsers == "gamer") "gamer not hidden from SDDM";
        assert expect (cfg.jovian.steam.user == "gamer") "Gaming Mode does not log in as gamer";
        assert expect (lib.sort lib.lessThan cfg.users.groups.gamers.members == ["alice" "gamer"]) "gamers group is not alice and gamer";
        assert expect (cfg.systemd.services.steam-library-mnt-games2.unitConfig.RequiresMountsFor == "/mnt/games2") "library service not tied to its mount";
        assert expect (lib.hasInfix "/srv/games/users/alice/steamapps/common" cfg.systemd.services.steam-library-srv-games.script) "alice has no common link";
        assert expect (parent.hostSpec.system.jovian.enable && gaming.hostSpec.system.jovian.enable && !developer.hostSpec.system.jovian.enable) "jovian not on in default and gaming, off in developer";
        assert expect (parent.programs.steam.enable && !developer.programs.steam.enable) "Steam not on the default desktop, or still in developer";
        assert expect (!parent.jovian.steam.enable && !(parent.jovian.steam.autoStart or false)) "default entry boots into Gaming Mode";
        assert expect (lib.all (e: e.users.users ? gamer) [parent gaming developer]) "gamer missing from an entry";
        assert expect (!(parent.environment.etc ? gaming-hook) && gaming.environment.etc.gaming-hook.text == "on" && !(developer.environment.etc ? gaming-hook)) "gaming hook not only in the gaming entry";
        assert expect (!(parent.environment.etc ? developer-hook) && developer.environment.etc.developer-hook.text == "on" && !(gaming.environment.etc ? developer-hook)) "developer hook not only in the developer entry";
        assert expect (parent.swapDevices != [] && gaming.swapDevices != [] && developer.swapDevices == []) "diskSwap = false not only in the developer entry";
        assert expect (gaming.jovian.steam.user == "gamer" && gaming.jovian.steam.autoStart) "gaming entry does not autostart Gaming Mode as gamer";
        assert expect (!developer.programs.steam.config.enable) "steam-config on without Steam";
        assert expect (!(parent.specialisation ? desktop) && !(deck.specialisation ? gaming) && deck.specialisation ? developer) "wrong specialisations for defaultEntry";
        assert expect (deck.jovian.steam.autoStart && deck.jovian.steam.user == "gamer") "defaultEntry = gaming does not boot Gaming Mode";
        assert expect (deskEntry.hostSpec.system.jovian.enable && deskEntry.programs.steam.enable && !(deskEntry.jovian.steam.autoStart or false)) "desktop entry of a gaming-default machine boots Gaming Mode or lost Steam";
        assert expect (!deck.specialisation.developer.configuration.hostSpec.system.jovian.enable) "developer entry of a gaming-default machine has jovian";
        assert expect (failed deck == [] && failed entry.config == []) "an entry fails its assertions";
        assert expect (failed (deckWith {imports = [{hostSpec.system.gamingSpecialisation.configuration.environment.etc.x.text = "y";}];}) != []) "gaming hook accepted with defaultEntry = gaming";
        assert expect (lib.all (e: e.programs.steam.config.enable && lib.getName e.programs.steam.config.defaultCompatTool == lib.getName pkgs.proton-ge-bin) [parent gaming]) "GE-Proton is not Steam's default in the default and gaming entries";
        assert expect (lib.all (u: lib.elem "steam-config-patcher@${u}.service" gaming.systemd.targets.multi-user.wants) ["alice" "gamer"]) "steam-config patcher not run for alice and gamer";
          pkgs.writeText "gaming" "ok";

      # Hardware modules configure themselves from the nixos-facter report:
      # a Pascal card (GTX 1070 Ti) gets the closed module and legacy_580, a
      # Turing card the open module, an Intel iGPU and Bluetooth come on,
      # AMD stays off, and a machine can still opt out.
      hardware-from-facter = let
        configOf = nvidiaDevice: extra:
          (inputs.nixpkgs.lib.nixosSystem {
            modules = [
              self.nixosModules.amd
              self.nixosModules.bluetooth
              self.nixosModules.intel
              self.nixosModules.kvm
              self.nixosModules.nvidia
              {
                nixpkgs.hostPlatform = system;
                hardware.facter.report.hardware = {
                  bluetooth = [{driver_modules = ["btusb"];}];
                  cpu = [{features = ["fpu" "svm"];}];
                  graphics_card = [
                    {
                      vendor.value = 4318; # 0x10de NVIDIA
                      device.value = nvidiaDevice;
                      driver_modules = [];
                    }
                    {
                      vendor.value = 32902; # 0x8086 Intel
                      device.value = 39497;
                      driver_modules = ["i915"];
                    }
                  ];
                };
              }
              extra
            ];
          }).config;
        pascal = configOf 7042 {}; # 0x1b82 GTX 1070 Ti
        turing = configOf 7810 {}; # 0x1e82 RTX 2080
        optedOut = configOf 7042 {hostSpec.hardware.gpu.intel.enable = false;};
        noVirt = configOf 7042 {hardware.facter.report.hardware.cpu = lib.mkForce [{features = ["fpu"];}];};
        expect = cond: msg: lib.assertMsg cond "hardware-from-facter: ${msg}";
      in
        assert expect pascal.hostSpec.hardware.gpu.nvidia.enable "NVIDIA card not detected";
        assert expect pascal.hostSpec.hardware.bluetooth.enable "Bluetooth not detected";
        assert expect pascal.hostSpec.hardware.gpu.intel.enable "Intel GPU not detected";
        assert expect (!pascal.hostSpec.hardware.gpu.amd.enable) "AMD on without an AMD card";
        assert expect pascal.hostSpec.hardware.kvm.enable "KVM (svm) not detected";
        assert expect (!noVirt.hostSpec.hardware.kvm.enable) "KVM on without svm or vmx";
        assert expect (!pascal.hardware.nvidia.open && pascal.hardware.nvidia.branch == "legacy_580") "Pascal not on the closed module and legacy_580";
        assert expect pascal.hardware.nvidia.powerManagement.enable "NVIDIA power management off";
        assert expect (turing.hardware.nvidia.open && turing.hardware.nvidia.branch == "stable") "Turing not on the open module and stable";
        assert expect (!optedOut.hostSpec.hardware.gpu.intel.enable) "a machine cannot switch a detected GPU off";
          pkgs.writeText "hardware-from-facter" "ok";

      # What homeModules.agents writes for alice: claude's settings carry
      # the Nix workflow and the skills runtime env but no (ignored)
      # mcpServers, the github pat server is local everywhere, pi's
      # models.json carries the headroom reroute, and every agent gets
      # the same machine context.
      agents-wiring = let
        hm = machine.config.home-manager.users.alice;
        files = hm.home.file;
        json = name: builtins.fromJSON (builtins.unsafeDiscardStringContext files.${name}.text);
        claude = json ".claude/settings.json";
        context = files.".claude/CLAUDE.md".text;
        opencodeNixEval = {
          action = "shell";
          resource = "nix eval *";
          effect = "allow";
        };
        expect = cond: msg: lib.assertMsg cond "agents-wiring: ${msg}";
      in
        assert expect (lib.elem "/nix/store" claude.permissions.additionalDirectories) "claude cannot read /nix/store";
        assert expect (lib.elem "Bash(nix eval:*)" claude.permissions.allow) "nix eval not allowed";
        assert expect (claude.env ? BASH_MAX_TIMEOUT_MS && claude.env ? NODE_PATH) "claude env misses the timeouts or the skills runtime";
        assert expect (lib.length claude.hooks.PostToolUse == 1) "no .nix format hook";
        assert expect (!(claude ? mcpServers)) "settings.json carries mcpServers";
        assert expect (hm.home.activation ? claudeMcpServers) "no ~/.claude.json MCP sync";
        assert expect (hm.programs.opencode.settings.mcp.servers.github.type == "local") "opencode github not on the pat server";
        assert expect ((json ".kimi-code/mcp.json").mcpServers ? github) "kimi has no github server";
        assert expect ((json ".pi/agent/models.json").providers.kimi-coding.headers ? x-headroom-base-url) "pi models.json lacks the headroom reroute";
        assert expect (lib.hasPrefix "Machine: eval (NixOS " context) "no Machine line";
        assert expect (lib.hasInfix "Repo: github.com/example/home (local: /home/alice/home)" context) "no Repo line";
        assert expect (lib.all (f: files.${f}.text == context) [".pi/agent/AGENTS.md" ".kimi-code/AGENTS.md"]) "agents disagree on the machine context";
        assert expect (hm.xdg.configFile."opencode/AGENTS.md".text == context) "opencode has another machine context";
        assert expect (lib.hasInfix "Nix builds and VM tests run long" context) "no timeout advice in the machine context";
        assert expect (lib.elem opencodeNixEval hm.programs.opencode.settings.permissions) "opencode does not allow nix eval";
        assert expect (hm.programs.opencode.settings.formatter.nixfmt.extensions == [".nix"]) "opencode has no .nix formatter";
        assert expect (lib.hasInfix "tool_result" files.".pi/agent/extensions/nix-workflow.ts".text) "pi extension does not format";
        assert expect (hm.home.activation ? kimiNixWorkflow) "no kimi config.toml merge";
          pkgs.writeText "agents-wiring" "ok";

      # Each agent on its own: it writes exactly its own files, and still
      # gets the shared machine context, MCP servers, skills and Nix
      # workflow; the other three leave nothing behind.
      agents-independent = let
        names = ["claude" "kimi" "opencode" "pi"];
        own = {
          claude = [".claude/CLAUDE.md" ".claude/settings.json" ".claude/skills"];
          kimi = [".kimi-code/AGENTS.md" ".kimi-code/mcp.json" ".kimi-code/skills"];
          opencode = ["opencode/AGENTS.md" "opencode/opencode.json" "opencode/skills" "opencode/tui.json"];
          pi = [".agents/skills" ".pi/agent/AGENTS.md" ".pi/agent/extensions/nix-workflow.ts" ".pi/agent/mcp.json" ".pi/agent/models.json"];
        };
        activations = {
          claude = ["claudeDesktopMcpServers" "claudeMcpServers"];
          kimi = ["kimiNixWorkflow"];
          opencode = [];
          pi = [];
        };
        full = machine.config.home-manager.users.alice;
        solo = only:
          (machine.extendModules {
            modules = [
              {home-manager.users.alice.homeSpec.agents = lib.genAttrs names (a: {enable = lib.mkForce (a == only);});}
            ];
          }).config.home-manager.users.alice;
        enabledNames = lib.filterAttrs (_: f: f.enable);
        agentFiles = hm:
          lib.sort lib.lessThan (
            lib.filter (n: lib.any (p: lib.hasPrefix p n) [".agents/" ".claude/" ".kimi-code/" ".pi/"]) (lib.attrNames (enabledNames hm.home.file))
            ++ lib.filter (lib.hasPrefix "opencode/") (lib.attrNames (enabledNames hm.xdg.configFile))
          );
        agentActivations = hm: lib.filter (n: lib.elem n (lib.concatLists (lib.attrValues activations))) (lib.attrNames hm.home.activation);
        contextFile = {
          claude = hm: hm.home.file.".claude/CLAUDE.md".text;
          kimi = hm: hm.home.file.".kimi-code/AGENTS.md".text;
          opencode = hm: hm.xdg.configFile."opencode/AGENTS.md".text;
          pi = hm: hm.home.file.".pi/agent/AGENTS.md".text;
        };
        expect = cond: msg: lib.assertMsg cond "agents-independent: ${msg}";
        checkAlone = only: let
          hm = solo only;
        in
          expect (agentFiles hm == own.${only}) "${only} alone writes ${toString (agentFiles hm)}"
          && expect (agentActivations hm == activations.${only}) "${only} alone runs ${toString (agentActivations hm)}"
          && expect hm.homeSpec.agents.skills.enable "${only} alone has no skills"
          && expect (contextFile.${only} hm == contextFile.${only} full) "${only} alone gets another machine context";
      in
        assert lib.all checkAlone names;
          pkgs.writeText "agents-independent" "ok";

      # Claude Desktop follows claude-code, and Cowork follows the
      # machine's KVM: QEMU for alice, the kvm group and vhost_vsock on
      # the host. Without KVM there is no Cowork, without claude no app,
      # and a standalone home-manager user (osConfig = null) gets no
      # Cowork.
      claude-desktop = let
        with' = module: (machine.extendModules {modules = [module];}).config;
        noKvm = with' {hostSpec.hardware.kvm.enable = lib.mkForce false;};
        noClaude = with' {home-manager.users.alice.homeSpec.agents.claude.enable = lib.mkForce false;};
        names = c: map lib.getName c.home-manager.users.alice.home.packages;
        # pkgs.qemu_kvm is named qemu-host-cpu-only.
        hasQemu = c: lib.any (lib.hasPrefix "qemu") (names c);
        desktop = c: c.home-manager.users.alice.homeSpec.agents.claude.desktop;
        hostSide = c: lib.elem "vhost_vsock" c.boot.kernelModules || lib.elem "kvm" c.users.users.alice.extraGroups;
        standalone = inputs.home-manager.lib.homeManagerConfiguration {
          pkgs = pkgs.extend (import ./fixtures/overlay.nix);
          extraSpecialArgs.osConfig = null;
          modules = [
            self.homeModules.agents
            {
              home = {
                username = "alice";
                homeDirectory = "/home/alice";
                stateVersion = "26.11";
              };
              homeSpec.agents.claude.enable = true;
            }
          ];
        };
        hm = machine.config.home-manager.users.alice;
        expect = cond: msg: lib.assertMsg cond "claude-desktop: ${msg}";
      in
        assert expect (lib.elem "claude-desktop" (names machine.config) && hasQemu machine.config) "Claude Desktop or QEMU not installed";
        assert expect (lib.hasInfix "/Claude/claude_desktop_config.json" hm.home.activation.claudeDesktopMcpServers.data) "no claude_desktop_config.json MCP sync";
        assert expect (lib.elem "vhost_vsock" machine.config.boot.kernelModules) "vhost_vsock not loaded";
        assert expect (lib.elem "kvm" machine.config.users.users.alice.extraGroups) "alice not in the kvm group";
        assert expect ((desktop noKvm).enable && !(desktop noKvm).cowork.enable) "Cowork on without KVM";
        assert expect (!(hasQemu noKvm) && !(hostSide noKvm)) "QEMU, kvm group or vhost_vsock without KVM";
        assert expect (!(desktop noClaude).enable && !(lib.elem "claude-desktop" (names noClaude)) && !(hostSide noClaude)) "Claude Desktop without claude";
        assert expect (standalone.config.homeSpec.agents.claude.desktop.enable && !standalone.config.homeSpec.agents.claude.desktop.cowork.enable) "standalone user: no desktop, or Cowork without a host";
          pkgs.writeText "claude-desktop" "ok";

      # The machine context rendered from a synthetic NixOS config: the
      # hardware from an inline facter report, local KVM and a remote
      # builder, line for line.
      agents-machine-context = let
        render = osConfig:
          (import ../flake-parts/homeModules/agents/_machine-context.nix {
            inherit lib osConfig system;
            homeDirectory = "/home/alice";
            mc = {
              enable = true;
              repoOwner = "example";
              repoName = "home";
              repoPath = "home";
              environment = null;
              extraText = null;
            };
            skillsRuntime = true;
            nixWorkflow = osConfig.networking.hostName == "box";
          }).text;
        box = {
          networking.hostName = "box";
          boot.kernelModules = ["kvm-amd"];
          nix = {
            settings.system-features = ["kvm" "nixos-test"];
            distributedBuilds = true;
            buildMachines = [
              {
                hostName = "builder";
                system = null;
                systems = ["x86_64-linux" "aarch64-linux"];
                supportedFeatures = ["big-parallel" "kvm"];
              }
            ];
          };
          hardware.facter = {
            reportPath = "/machines/box/facter.json";
            report = {
              hardware = {
                cpu = [
                  {
                    model_name = "Example CPU";
                    units = 16;
                  }
                ];
                graphics_card = [
                  {
                    vendor.name = "Example GPU";
                    driver = "amdgpu";
                  }
                ];
                disk = [{model = "Example SSD";}];
              };
              smbios.memory_device = [
                {
                  size = 16 * 1024 * 1024;
                  manufacturer = "Micron Technology";
                }
                {size = 0;}
                {
                  size = 16 * 1024 * 1024;
                  manufacturer = "Micron Technology";
                }
              ];
            };
          };
        };
        expected = ''
          Machine: box (NixOS ${system})
          Nix builds: local KVM; remote builders: builder (x86_64-linux, aarch64-linux, kvm)

          Hardware:
          - CPU: Example CPU, 16 threads
          - GPU: Example GPU, driver amdgpu
          - Memory: 32 GiB (2x Micron DIMMs)
          - Disk: Example SSD

          Repo: github.com/example/home (local: /home/alice/home)
          Machine facts: machines/box/facter.json, disko.nix, configuration.nix
          Machine config is strictly read-only: changes only by repo owner example, or when instructed to while working in the machine repo.

          Read a repo's AGENTS.md before working in it.
          Skill script dependencies are preinstalled; don't pip/npm install them.
          Nix builds and VM tests run long: give shell commands a timeout of up to 60 min, or run them in the background.
        '';
        # A KubeVirt guest: no kvm module, no builders, no facter report.
        guest = render {
          networking.hostName = "guest";
          boot.kernelModules = [];
          nix.settings.system-features = ["kvm"];
          hardware.facter = {
            reportPath = null;
            report = {};
          };
        };
        expect = cond: msg: lib.assertMsg cond "agents-machine-context: ${msg}";
      in
        assert expect (render box == expected) "box rendered as:\n${render box}";
        assert expect (lib.hasInfix "Nix builds: no local KVM\n" guest) "guest claims local KVM";
        assert expect (!(lib.hasInfix "Hardware:" guest || lib.hasInfix "Machine facts" guest)) "guest without a report got hardware lines";
          pkgs.writeText "agents-machine-context" "ok";

      # The agents' scripts, run for real: the ~/.claude.json MCP sync
      # replaces and prunes managed servers and keeps everything else,
      # the format hook formats .nix files only (claude's file_path and
      # kimi's path), and the kimi config.toml merge swaps the module's
      # hook while keeping what kimi's /login wrote.
      agents-scripts = let
        claudeLib = import ../flake-parts/homeModules/agents/_claude.nix {inherit pkgs;};
        nixWorkflow = import ../flake-parts/homeModules/agents/_nix-workflow.nix {inherit lib pkgs;};
        kimiFragment = hooks:
          lib.escapeShellArg (builtins.toJSON {
            marker = nixWorkflow.kimi.hookMarker;
            inherit hooks;
            taskTimeoutS = 3600;
          });
      in
        pkgs.runCommand "agents-scripts" {
          nativeBuildInputs = [claudeLib.mcpSync nixWorkflow.formatHook nixWorkflow.kimiConfigMerge pkgs.jq pkgs.yq-go];
        } ''
          set -euo pipefail
          known='["headroom","nixos"]'
          echo '{"numStartups":3,"mcpServers":{"headroom":{"command":"old"},"mine":{"command":"x"},"nixos":{"command":"old","env":{"A":"1"}}}}' > claude.json

          # First run, no state file: the known names are pruned first.
          claude-mcp-sync claude.json state/servers.json '{"nixos":{"command":"new","args":[]}}' "$known"
          jq -e '.numStartups == 3' claude.json
          jq -e '.mcpServers == {"mine":{"command":"x"},"nixos":{"command":"new","args":[]}}' claude.json
          jq -e '. == ["nixos"]' state/servers.json

          # The last managed server turned off: removed, "mine" kept.
          claude-mcp-sync claude.json state/servers.json '{}' "$known"
          jq -e '.mcpServers == {"mine":{"command":"x"}}' claude.json

          # A symlinked file (home-manager owns it) is never written.
          echo '{}' > owned.json
          ln -s owned.json linked.json
          claude-mcp-sync linked.json state/other.json '{"nixos":{"command":"new","args":[]}}' "$known"
          jq -e '. == {}' owned.json

          # The format hook: claude's file_path, kimi's path, .nix only.
          printf '{ a=1;}\n' > claude.nix
          printf '{ a=1;}\n' > kimi.nix
          printf '{ a=1;}\n' > edited.txt
          echo '{"tool_input":{"file_path":"claude.nix"}}' | agent-format-nix
          echo '{"tool_input":{"path":"kimi.nix"}}' | agent-format-nix
          echo '{"tool_input":{"file_path":"edited.txt"}}' | agent-format-nix
          [ "$(cat claude.nix)" = "{a = 1;}" ]
          [ "$(cat kimi.nix)" = "{a = 1;}" ]
          [ "$(cat edited.txt)" = "{ a=1;}" ]

          # kimi config.toml: /login's keys and the user's own hook stay,
          # a stale module hook is replaced, the timeout is set.
          cat > config.toml <<'TOML'
          default_model = "managed:kimi-code/k3"
          # written by /login
          [providers."managed:kimi-code"]
          type = "kimi"

          [[hooks]]
          event = "Stop"
          matcher = ".*"
          command = "notify-send done"
          timeout = 5

          [[hooks]]
          event = "PostToolUse"
          matcher = "^(Edit|Write)$"
          command = "/nix/store/old-agent-format-nix/bin/agent-format-nix"
          timeout = 30
          TOML
          kimi-config-merge config.toml ${kimiFragment [nixWorkflow.kimi.hook]}
          grep -q '# written by /login' config.toml
          [ "$(yq -p toml -o json '.default_model' config.toml)" = '"managed:kimi-code/k3"' ]
          [ "$(yq -p toml -oy '.hooks | length' config.toml)" = 2 ]
          [ "$(yq -p toml -oy '.hooks[0].command' config.toml)" = "notify-send done" ]
          [ "$(yq -p toml -oy '.hooks[1].command' config.toml)" = ${lib.escapeShellArg nixWorkflow.kimi.hook.command} ]
          [ "$(yq -p toml -oy '.task.bash_task_timeout_s' config.toml)" = 3600 ]

          # The workflow's hook off: only the user's hook is left.
          kimi-config-merge config.toml ${kimiFragment []}
          [ "$(yq -p toml -oy '.hooks | length' config.toml)" = 1 ]

          # No config.toml yet and nothing to add: none is created.
          kimi-config-merge fresh.toml '{"marker":"agent-format-nix","hooks":[],"taskTimeoutS":null}'
          [ ! -e fresh.toml ]
          touch $out
        '';
    };
  };
}
