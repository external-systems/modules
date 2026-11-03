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
(home-manager) option enables it, so importing `default` changes nothing
else except the defaults listed below. Single modules are exported too,
e.g. `nixosModules.tailscale` or `homeModules.starship`.

### What the consumer provides

- **Overlay.** The modules read packages built by the consumer: `pkgs.openshell`, `pkgs.openshell-gateway`,
  `pkgs.openshell-driver-vm`, `pkgs.code-sandbox`, `pkgs.devenv`,
  `pkgs.headroom-sandbox`, and for `homeModules.agents` `pkgs.pi-coding-agent`,
  `pkgs.kimi-code`, `pkgs.claude-code`, `pkgs.artifacthub-mcp` and
  `pkgs.kubernetes-mcp-server`. Apply an overlay that provides them (home's
  `overlays.default` does).
- **plasma-manager.** `homeModules.plasma-manager` sets `programs.plasma`;
  add `inputs.plasma-manager.homeModules.plasma-manager` to
  `home-manager.sharedModules`.
- **clan-core.** `clan`, `git`, `ssh`, `storagebox` and `openshell-gateway`
  declare clan vars generators, so they need `clan.core` (any clan
  machine has it).
- **Package choice.** Modules use plain `pkgs` and never pin a nixpkgs
  branch. To take a package from elsewhere (e.g. unstable), set the
  package option: the upstream one (`programs.ghostty.package`,
  `services.tailscale.package`, ...) or this repo's
  (`hostSpec.services.ollama.package`, `hostSpec.hardware.gpu.amd.packages`,
  `homeSpec.programs.media.packages`, `homeSpec.agents.mcp.github.package`).
- **Users and fleet values.** No module names a user, host or account.
  These have no default and must be set when their module is enabled:
  each `homeSpec.programs.storagebox.boxes.<name>.{user,host}` (from the
  values flake), `hostSpec.services.onepassword.polkitPolicyOwners` and
  `hostSpec.services.whisper-dictation.user`. Optional, off when unset:
  `homeSpec.agents.machineContext.repoOwner`/`repoName`/`repoPath`
  (the machine context's Repo line) and `homeSpec.programs.vscode.nixdFlake`
  (nixd's option source). `hostSpec.services.nix` trusts only `root`; add
  users with `nix.settings.trusted-users`. Personal shell aliases go in the
  consumer's `programs.bash.shellAliases`.
- **Storage Boxes.** Mounts are per user. In a home-manager profile set
  `homeSpec.programs.storagebox.enabled = true` and one
  `boxes.<name> = {inherit (values.storageboxes.<box>.subAccounts.<user>) user host port;}`
  per box (zero or more; the main account works the same way with
  `values.storageboxes.<box>`). Each box becomes an rclone remote and a
  FUSE mount at `~/storagebox/<name>` (a systemd user unit, started at
  login or by hand with `startOn = "manual"`) and an ssh alias
  `storagebox-<name>`, so `rsync storagebox-<name>:dir/ ./dir/` works.
  `nixosModules.storagebox` declares one clan vars key per user,
  `storagebox-ssh-<user>`; install its public half on each login with
  `clan vars get <machine> storagebox-ssh-<user>/ssh-public-key | ssh -p23 <login>@<login>.your-storagebox.de install-ssh-key`.
  Nothing mounts until that key is generated. The old host-level
  `hostSpec.services.storagebox` is removed.
- **1Password.** `hostSpec.services.onepassword` enables
  `programs._1password` (the setgid `op` at `/run/wrappers/bin/op`) and
  `programs._1password-gui`; `polkitPolicyOwners` has no default, so
  set it to the machine's users. Don't also install `_1password-cli` as a
  package: a Nix-store `op` first on `PATH` can't reach the desktop app.

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
| `flake-parts/compositions.nix` | The `default` compositions |
| `tests/` | The module eval checks and their fixtures (`fixtures/`, `clan-stub.nix`) |
| `devenv.yaml`, `devenv.nix` | The dev shell (devenv CLI, imports `org-pkgs/devenv`) |
| `documentation/` | MkDocs site (`docs/*.md`) and deck (`slides/slides.md`); `flake-module.nix` holds the `docs.*` settings |

## Development

The repo follows the org flake standard. Needs Nix and devenv.

```sh
devenv allow     # auto-activates the shell on cd (after `devenv hook`)
fmt              # nix fmt: treefmt with the org linters
check            # nix flake check: treefmt, lock-sync, eval, docs
docs-build       # static docs to ./result-docs; open index.html from disk
```

The formatter, docs, slides and the org checks come from
`org-pkgs.flakeModules.dev`, so the repo has no dev inputs and no dev
partition. `checks.treefmt` runs the org linters (alejandra, deadnix,
statix, nixf-diagnose, shellcheck, sizelint); `checks.lock-sync` keeps
`flake.lock` and `devenv.lock` on one nixpkgs (after
`nix flake update org-pkgs`, run `sync-locks`).
`checks.eval-all-enabled` evaluates a machine with every
`hostSpec` toggle and a user with every `homeSpec` toggle on, down to the
system derivation, using stand-ins for the consumer overlay and for
`clan.core` (`tests/fixtures/`, `tests/clan-stub.nix`).
