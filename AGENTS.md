# AGENTS.md

Reusable NixOS and home-manager modules for external-systems flakes, split
out of external-systems/home. Modules only: no machines, inventory, clan
vars, packages, overlays or fleet values. Every module is off until its
`hostSpec.*` (NixOS) or `homeSpec.*` (home-manager) option enables it.

## Layout
- `flake.nix`: consumer-facing inputs (all follow external-systems/pkgs where they can) and the dev partition wiring.
- `flake-parts/nixosModules/`, `flake-parts/homeModules/`: one module per file, auto-imported (import-tree). `flake-parts/compositions.nix`: the `default` compositions.
- `dev/flake.nix` + `dev/flake.lock`: dev-only inputs. `dev/flake-module.nix`: the dev partition (formatter, checks, docs). `dev/fixtures/`, `dev/clan-stub.nix`: the eval-all-enabled machine and its stand-ins.
- `devenv.yaml` + `devenv.lock` + `devenv.nix`: the dev shell. The org shell comes from external-systems/pkgs (`org-pkgs/devenv` in devenv.yaml).
- `documentation/`: MkDocs site (`docs/`) and reveal.js deck (`slides/`).

## Tool loop
- The shell is devenv. If `DEVENV_ROOT` is unset, run commands with `devenv shell -- <cmd>`.
- `git add` new files before any `nix` command.
- `fmt`, then `check`. Both must pass before a change is done.
- After `nix flake update org-pkgs`, run `sync-locks` in the same commit.

## Rules
- Load the `nix-style` skill before editing any `.nix` file.
- Dev-only inputs go in `dev/flake.nix`, never `flake.nix`.
- A new toggle gets turned on in `dev/fixtures/nixos.nix` so `checks.eval-all-enabled` covers it.
- Modules use plain `pkgs` and expose package options; never pin a nixpkgs branch here.
- No IP literals or account ids: they come from the values flake (external-systems/secrets or not-secrets).
- Work on a branch and open a PR. Never push to `main`.
