# A machine with every hostSpec toggle on and one home-manager user with
# every homeSpec toggle on. Built only as far as its derivation.
{
  inputs,
  self,
}: {
  lib,
  pkgs,
  ...
}: {
  imports = [
    self.nixosModules.default
    ../clan-stub.nix
  ];

  nixpkgs.overlays = [
    (import ./overlay.nix)
    # The VS Code extension sets homeModules.vscodium reads.
    inputs.org-pkgs.overlays.vscode-extensions
  ];

  # Minimal bootable shape.
  fileSystems."/" = {
    device = "/dev/disk/by-label/nixos";
    fsType = "ext4";
  };
  boot.loader.grub.devices = ["nodev"];
  networking.hostName = "eval";
  system.stateVersion = "26.11";

  hostSpec = {
    clan.enable = true;
    hardware = {
      bluetooth.enable = true;
      gpu = {
        amd.enable = true;
        intel.enable = true;
        nvidia.enable = true;
      };
      sound.enable = true;
    };
    networking = {
      optimization = {
        enable = true;
        bufferMax = 67108864;
      };
      tailscale.enable = true;
      warp.enable = true;
    };
    services = {
      docker.enable = true;
      flatpak.enable = true;
      kde.enable = true;
      nix-ld.enable = true;
      nix.enable = true;
      ollama.enable = true;
      onepassword = {
        enable = true;
        polkitPolicyOwners = ["alice"];
      };
      openshell.gateway.enable = true;
      openssh.enable = true;
      rancher.enable = true;
      wayland.enable = true;
    };
    system = {
      developerSpecialisation.enable = true;
      # Gaming Mode logs in as the dedicated user (gaming.user), which
      # is declared because of it; alice and gamer share the libraries.
      gaming = {
        sharedLibraries = {
          enable = true;
          paths = ["/srv/games" "/mnt/games2"];
        };
        steamConfig.enable = true;
      };
      jovian = {
        enable = true;
        gamingMode = true;
        outputs = ["DP-1"];
        steamdeck = true;
        powerProfile.profile = "performance";
      };
    };
  };

  users.users.alice = {
    isNormalUser = true;
    home = "/home/alice";
  };

  home-manager = {
    useGlobalPkgs = true;
    sharedModules = [inputs.plasma-manager.homeModules.plasma-manager];
    users.alice = {
      imports = [self.homeModules.default];
      homeSpec = {
        xdg.enable = true;
        agents = {
          opencode.enable = true;
          machineContext = {
            repoOwner = "example";
            repoName = "home";
            repoPath = "home";
          };
          pi.enable = true;
          kimi.enable = true;
          claude.enable = true;
          mcp.github.auth = "pat";
          skills = {
            preset = "full";
            extraSources = inputs.skills.lib.selections.cloudflare;
          };
        };
        programs = {
          devenv.enabled = true;
          docker.enable = true;
          firefox.enable = true;
          ghostty.enable = true;
          git = {
            enable = true;
            userName = "alice";
            userEmail = "alice@example.com";
            githubAuth.enabled = true;
          };
          headroom.enable = true;
          k9s.enable = true;
          ksshaskpass.enable = true;
          media.enable = true;
          openshell.enable = true;
          password-store.enable = true;
          plasma-manager.enable = true;
          shell.enable = true;
          ssh = {
            enable = true;
            clanKey.enabled = true;
          };
          starship.enable = true;
          storagebox = {
            enabled = true;
            boxes = {
              # A sub-account mounted at login, and the main account on
              # demand: both shapes the module supports.
              main = {
                user = "u000000-sub1";
                host = "u000000-sub1.your-storagebox.de";
              };
              archive = {
                user = "u000000";
                host = "u000000.your-storagebox.de";
                remotePath = "BACKUPS";
                startOn = "manual";
              };
            };
          };
          tmux.enable = true;
          vscodium = {
            enable = true;
            mutableExtensions = false;
            theme = {
              color = "Red";
              icons = "catppuccin-macchiato";
              extensions = [pkgs.open-vsx-release.catppuccin.catppuccin-vsc-icons];
              font = {
                family = "'Atkinson Hyperlegible Mono', monospace";
                package = pkgs.atkinson-hyperlegible-mono;
                size = 15;
                lineHeight = 1.6;
                letterSpacing = 0.5;
                ligatures = true;
              };
            };
            tweaks.enable = true;
            claude.enable = true;
            remoteSsh.enable = true;
            envSpec.enable = true;
            todoTree.enable = true;
            githubActions.enable = true;
            languages = {
              nix = {
                enable = true;
                flake = "/home/alice/home";
              };
              go.enable = true;
              shell.enable = true;
              markdown.enable = true;
              python.enable = true;
              rust.enable = true;
              gleam.enable = true;
              zig.enable = true;
              web = {
                enable = true;
                tailwind.enable = true;
              };
              yaml.enable = true;
            };
            kubernetes.enable = true;
            containers = {
              enable = true;
              client = "podman";
            };
            extraExtensions = [pkgs.open-vsx-release.usernamehw.errorlens];
            extraSettings."workbench.sideBar.location" = "left";
          };
          whisper-dictation.enable = true;
        };
      };
    };
  };

  # Pretend the Storage Box key is generated, so the user units render.
  clan.core.vars.generators.storagebox-ssh-alice.files.ssh-public-key.exists = true;

  # Keep the eval focused on these modules.
  documentation.enable = lib.mkDefault false;
}
