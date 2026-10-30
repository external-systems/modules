{
  # inputs,
  # self,
  lib,
  ...
}: {
  # ------ Home-manager Modules ------ #
  flake.homeModules.shell = {
    config,
    pkgs,
    ...
  }: let
    cfg = config.homeSpec.programs.shell;
  in {
    options.homeSpec.programs.shell.enable = lib.mkEnableOption "default shell configuration";
    config = lib.mkIf cfg.enable {
      programs = {
        # ------ Extras ------ #
        ripgrep = {
          enable = true;
          package = pkgs.unstable.ripgrep;
        };
        eza = {
          enable = true;
          package = pkgs.unstable.eza;
        };
        fzf = {
          enable = true;
          package = pkgs.unstable.fzf;
        };
        # ------ Bash ------ #
        bash = {
          enable = true;
          shellAliases = {
            sudo = "sudo ";
            root = "su root";
            sr = "su -l";
            ssh-key = "eval \"$(ssh-agent -s)\" && ssh-add ~/.ssh/id_ed25519";
            vact = "source .venv/bin/activate";
            # nix commands
            nfc = "nix flake check --all-systems --show-trace";
            nfu = "nix flake update";
            nd = "nix develop";
            nr = "nix run";
            nfs = "nix flake show --all-systems";
            nixos-facter = "sudo nix run nixpkgs#nixos-facter -- -o facter.json";
            # nixos-rebuild tests
            nixos-current-system = "readlink -f /nix/var/nix/profiles/system && readlink -f /run/current-system";
            # misc
            speedtest = "NIXPKGS_ALLOW_UNFREE=1 nix run --impure nixpkgs#ookla-speedtest";
            modrinth-prefetch = "nix run github:Infinidoge/nix-minecraft#nix-modrinth-prefetch -- $@";
            off = "shutdown -h now";
            virt-host-validate = "nix shell nixpkgs#libvirt";
            # backups
            fabric-backup = "rsync -av --progress --delete kamrui-h1:/srv/minecraft/fabric/world/ /mnt/storagebox/BACKUPS/minecraft/fabric/world/";
            fabric-backup-local = "rsync -av --progress --delete /srv/minecraft/fabric/world/ /mnt/storagebox/Backups/fabric/world/";
            obsidian-pull = "rsync -avz -e 'ssh -p 23' u488514@u488514.your-storagebox.de:/home/PRIVATE/OBSIDIAN/Main/ ~/Desktop/Main/";
            # k3s
            k3s-wipe = "systemctl stop k3s.service && k3s-killall.sh && rm -fr /var/lib/rancher/ && rm -fr /etc/rancher/ &&  ip link delete cilium_host && ip link delete cilium_vxlan && iptables-save | grep -iv cilium | iptables-restore && ip6tables-save | grep -iv cilium | ip6tables-restore";
            kubefetch-latest = ''nix run "https://flakehub.com/f/andrewthomaslee/kubefetch/*"'';
          };
        };
      };
    };
  };
}
