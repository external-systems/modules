# modules

External Systems' reusable NixOS and home-manager modules, split out of
`external-systems/home` so they are versioned on their own life cycle.
Modules only: packages and overlays come from `external-systems/pkgs`,
fleet values (IP literals, account ids) from `external-systems/secrets`
or its public placeholder twin `external-systems/not-secrets`.

<iframe src="slides/index.html" title="Slide deck"
  style="width: 100%; aspect-ratio: 16 / 9; border: 0;"
  allowfullscreen></iframe>

## Consuming

```nix
# flake.nix
inputs.modules = {
  url = "github:external-systems/modules";
  inputs = {
    org-pkgs.follows = "org-pkgs"; # if you already follow external-systems/pkgs
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
(home-manager) option enables it. Single modules are exported too, e.g.
`nixosModules.tailscale` or `homeModules.starship`.

## What the consumer provides

- An overlay with the repo-built packages the modules read
  (`pkgs.openshell*`, `pkgs.code-sandbox`, `pkgs.devenv`, ...).
- `inputs.plasma-manager.homeModules.plasma-manager` in
  `home-manager.sharedModules`, for `homeModules.plasma-manager`.
- `clan.core` (any clan machine) for the modules that declare clan vars
  generators.
- Package choice: modules use plain `pkgs`; set the package options to
  take a package from elsewhere.

## Checks

| Check | Fails when |
| --- | --- |
| `treefmt` | formatting or an org linter finding (alejandra, deadnix, statix, nixf-diagnose, shellcheck, sizelint) |
| `lock-sync` | `flake.lock`, `dev/flake.lock` and `devenv.lock` disagree on nixpkgs |
| `eval-all-enabled` | a machine with every `hostSpec`/`homeSpec` toggle on stops evaluating |
| `documentation`, `slides` | the docs site or the deck stops building |
