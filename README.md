# modules

External Systems' reusable NixOS and home-manager modules, split out of
[external-systems/home](https://github.com/external-systems/home) so they
can be versioned on their own life cycle. This repo has modules only: no
machines, no inventory, no clan vars, no packages or overlays (those live
in [external-systems/pkgs](https://github.com/external-systems/pkgs)), no
IP literals or account ids (those come from
[external-systems/secrets](https://github.com/external-systems/secrets),
or the public placeholders in
[external-systems/not-secrets](https://github.com/external-systems/not-secrets)).

## Consuming

```nix
# flake.nix
inputs.modules = {
  url = "github:external-systems/modules";
  inputs = {
    pkgs.follows = "pkgs"; # if you already follow external-systems/pkgs
    home-manager.follows = "home-manager";
  };
};

# a machine
{inputs, ...}: {
  imports = [inputs.modules.nixosModules.default];
  hostSpec.services.openssh.enable = true;
  home-manager.users.alice.imports = [inputs.modules.homeModules.default];
}
```

Every module is off until its `hostSpec.*` (NixOS) or `homeSpec.*`
(home-manager) option enables it, so importing `default` changes nothing
else except the defaults listed below. Single modules are exported too,
e.g. `nixosModules.tailscale` or `homeModules.starship`.

### What the consumer provides

- **Overlay.** The modules read `pkgs.unstable` and packages built by the
  consumer: `pkgs.openshell`, `pkgs.openshell-gateway`,
  `pkgs.openshell-driver-vm`, `pkgs.code-sandbox`, `pkgs.devenv`,
  `pkgs.headroom-slim`, and for `homeModules.agents` `pkgs.pi-coding-agent`,
  `pkgs.kimi-code`, `pkgs.claude-code`, `pkgs.artifacthub-mcp` and
  `pkgs.kubernetes-mcp-server`. Apply an overlay that provides them (home's
  `overlays.default` does).
- **plasma-manager.** `homeModules.plasma-manager` sets `programs.plasma`;
  add `inputs.plasma-manager.homeModules.plasma-manager` to
  `home-manager.sharedModules`.
- **clan-core.** `clan`, `git`, `ssh`, `storagebox` and `openshell-gateway`
  declare clan vars generators, so they need `clan.core` (any clan
  machine has it).
- **Fleet values.** `hostSpec.services.storagebox.boxUser` has no default;
  set it from the values flake.

### Defaults set by `default`

- `nixosModules.default`: imports home-manager's NixOS module;
  `nixpkgs.config.allowUnfree`, `nixpkgs.hostPlatform = "x86_64-linux"`,
  tmp cleanup and GRUB EFI, all `mkDefault`.
- `homeModules.default`: `home.stateVersion = "26.11"`, US keyboard,
  `programs.home-manager.enable`.

## Not here

- The agent sandbox profiles (`profile-agent*`) stay with the code-agent
  image in home. The skills themselves live in
  [external-systems/skills](https://github.com/external-systems/skills);
  `homeModules.agents` consumes them through `inputs.skills.lib.mkSkillsTree`.
- User profiles (`profile-netsa`, `profile-wife`, ...) stay with the
  machines in home.
- The `lan`/`wan` networking modules are not carried over: they are
  replaced by the clanServices IfState `netif` service, with addresses from
  the values flake.

## Layout

| Path | What |
| --- | --- |
| `flake-parts/nixosModules/` | One NixOS module per file, auto-imported with import-tree |
| `flake-parts/homeModules/` | One home-manager module per file |
| `flake-parts/default.nix` | The `default` compositions |
| `dev/` | The `dev` flake-parts partition: checks, formatter, devShell |

## Development

```sh
nix fmt
nix flake check
```

Checks, formatter and devShell sit in a flake-parts
[partition](https://flake.parts/options/flake-parts-partitions.html), so
consumers never evaluate them. `checks.lint` runs alejandra, statix and
deadnix. `checks.eval-all-enabled` evaluates a machine with every
`hostSpec` toggle and a user with every `homeSpec` toggle on, down to the
system derivation, using stand-ins for the consumer overlay and for
`clan.core` (`dev/fixtures/`, `dev/clan-stub.nix`).
