# modules

Reusable NixOS and home-manager modules for External Systems flakes.

Note: Press `S` for the speaker view, `F` for fullscreen.

---

## Off until enabled

- Import `nixosModules.default` / `homeModules.default`
- Every module waits for its `hostSpec.*` / `homeSpec.*` toggle
- Single modules are exported too

---

## What lives elsewhere

- Packages and overlays: `external-systems/pkgs`
- Fleet values: `external-systems/secrets` / `not-secrets`
- Skills: `external-systems/skills`
- Machines and user profiles: `external-systems/home`

---

## One check covers every toggle

`eval-all-enabled` turns everything on and evaluates the machine down to
its system derivation.

---

# Thanks
