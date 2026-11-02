_: {
  # ------ NixOS Modules ------ #
  # Companion of homeModules/storagebox.nix: one Storage Box SSH key per
  # Linux user, for every home-manager user with
  # homeSpec.programs.storagebox.enabled. Declares the shared clan vars
  # generator "storagebox-ssh-<user>" (share = true: one key per user
  # across the fleet), deployed to
  #   /run/secrets/vars/shared/storagebox-ssh-<user>/ssh-private-key
  # (owner = user, mode 0400, neededFor = services), and feeds that path
  # back as homeSpec.programs.storagebox.keyFile.
  #
  # Mounts are per user (systemd user units from home-manager); there is
  # no host-level mount and no shared main-account key any more.
  #
  # Install the public key on each box login the user mounts (asks for
  # that login's password once):
  #   clan vars get <machine> storagebox-ssh-<user>/ssh-public-key \
  #     | ssh -p23 <login>@<login>.your-storagebox.de install-ssh-key
  #
  # NOTE: this scan mirrors the option paths in homeModules/storagebox.nix
  # by hand (defensive `or` access to avoid fixpoint recursion). If you
  # rename or restructure those options, update BOTH places: a stale scan
  # silently stops declaring the generator.
  flake.nixosModules.storagebox = {
    config,
    lib,
    pkgs,
    ...
  }: let
    # Read-only scan of home-manager.users. The sharedModules write below
    # targets storagebox.keyFile, which this scan never reads, so no
    # fixpoint recursion is possible.
    boxUsers =
      lib.filterAttrs (
        _: hmUser: (((hmUser.homeSpec or {}).programs or {}).storagebox or {}).enabled or false
      )
      config.home-manager.users;
  in {
    imports = [
      (lib.mkRemovedOptionModule ["hostSpec" "services" "storagebox"] ''
        Storage Box mounts are per user now: set
        homeSpec.programs.storagebox.{enabled,boxes} in the user's
        home-manager profile. The key generator is storagebox-ssh-<user>.
      '')
    ];

    # No mkIf around this block: home-manager.sharedModules must not
    # depend on the home-manager.users scan.
    config = {
      clan.core.vars.generators = lib.mkMerge (
        lib.mapAttrsToList
        (
          userName: _: {
            "storagebox-ssh-${userName}" = {
              share = true;
              files = {
                ssh-private-key = {
                  owner = userName;
                  mode = "0400";
                  neededFor = "services";
                };
                ssh-public-key.secret = false;
              };
              runtimeInputs = [pkgs.openssh];
              script = ''
                ssh-keygen -t ed25519 -f "$out/ssh-private-key" -N "" -C "${userName}-storagebox"
                mv "$out/ssh-private-key.pub" "$out/ssh-public-key"
              '';
            };
          }
        )
        boxUsers
      );

      # The user mounts need the setuid fusermount3 wrapper, which NixOS
      # installs by default (programs.fuse.enable); not forced here.

      # Feed the deployed key path into the home module: profiles never
      # hardcode /run/secrets paths. Goes through sharedModules (a static
      # module list): writing scan-derived keys into home-manager.users
      # would recurse on the option the scan reads. Null until the key is
      # generated (the public half exists), so nothing points at clan's
      # "/no-such-path" placeholder and the mounts stay off until then.
      home-manager.sharedModules = [
        (
          {
            config,
            lib,
            osConfig,
            ...
          }: let
            generator = "storagebox-ssh-${config.home.username}";
            generators = osConfig.clan.core.vars.generators or {};
            hasGenerator = osConfig != null && generators ? ${generator};
          in {
            homeSpec.programs.storagebox.keyFile =
              lib.mkIf (hasGenerator && generators.${generator}.files.ssh-public-key.exists)
              generators.${generator}.files.ssh-private-key.path;
          }
        )
      ];
    };
  };
}
