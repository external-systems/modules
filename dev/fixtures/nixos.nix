# A machine with every hostSpec toggle on and one home-manager user with
# every homeSpec toggle on. Built only as far as its derivation.
{
  inputs,
  self,
}: {lib, ...}: {
  imports = [
    self.nixosModules.default
    ../clan-stub.nix
  ];

  nixpkgs.overlays = [(import ./overlay.nix)];

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
      cpu.intel.enable = true;
      gpu.amd.enable = true;
      sound.enable = true;
      virtualization.nested.enable = true;
    };
    networking = {
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
      openshell.gateway.enable = true;
      openssh.enable = true;
      rancher.enable = true;
      storagebox = {
        enable = true;
        boxUser = "u000000";
      };
      wayland.enable = true;
      whisper-dictation = {
        enable = true;
        user = "alice";
      };
    };
    system.jovian.enable = true;
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
          opencode.enabled = true;
          pi.enabled = true;
          kimi.enabled = true;
          claude.enabled = true;
          mcp.github.auth = "pat";
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
          tmux.enable = true;
          vscode.enable = true;
          whisper-dictation.enable = true;
        };
      };
    };
  };

  # Keep the eval focused on these modules.
  documentation.enable = lib.mkDefault false;
}
