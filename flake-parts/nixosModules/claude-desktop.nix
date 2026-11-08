{lib, ...}: {
  # ------ NixOS Modules ------ #
  # Host side of Claude Desktop's Cowork, for every home-manager user
  # with homeSpec.agents.claude.desktop.cowork.enable (on by default
  # when the user has Claude Desktop and hostSpec.hardware.kvm.enable).
  # Cowork runs its tasks in a QEMU/KVM VM and talks to it over vsock:
  #   - the vhost_vsock kernel module (/dev/vhost-vsock);
  #   - the kvm group, which owns /dev/kvm and /dev/vhost-vsock.
  # The user's QEMU comes from home.packages (homeModules/agents).
  #
  # NOTE: this scan mirrors the option paths in homeModules/agents
  # by hand (defensive `or` access, as nixosModules/git does). Rename
  # or move those options and update BOTH places, or Cowork silently
  # loses its kernel module and group.
  flake.nixosModules.claude-desktop = {config, ...}: let
    cowork = hmUser: let
      desktop = (((hmUser.homeSpec or {}).agents or {}).claude or {}).desktop or {};
    in
      (desktop.enable or false) && ((desktop.cowork or {}).enable or false);
    users = config.home-manager.users;
  in {
    config = {
      boot.kernelModules = lib.mkIf (lib.any cowork (lib.attrValues users)) ["vhost_vsock"];
      # Keys from home-manager.users' names, the condition per value:
      # filtering the keys by the scan would recurse (home-manager reads
      # users.users.<name>.home back).
      users.users = lib.mapAttrs (_: hmUser: {extraGroups = lib.mkIf (cowork hmUser) ["kvm"];}) users;
    };
  };
}
