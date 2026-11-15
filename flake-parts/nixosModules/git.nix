_: {
  # ------ NixOS Modules ------ #
  # Per-user GitHub PAT provisioning: ONE token per user for everything —
  # github.com HTTPS git operations, GH_TOKEN for the gh CLI, and the github
  # MCP wrapper. A shared clan vars generator "github-<user>" is declared
  # for every home-manager user with either consumer enabled:
  #   - homeSpec.programs.git.githubAuth.enabled  (git + gh)
  #   - homeSpec.agents.mcp.github PAT consumers  (pi/kimi/claude always
  #     ride the local PAT wrapper; opencode only with mcp.github.auth =
  #     "pat")
  # share = true: one token per user across machines, deployed per machine
  # owned by that user. sops-nix deploys it to
  #   /run/secrets/vars/shared/github-<user>/pat
  # (owner = user, mode 0400, neededFor = services).
  # With homeSpec.programs.git.githubAuth.nix.enable, a derived generator
  # "nix-access-tokens-<user>" renders the same PAT as a nix.conf line that
  # the user's ~/.config/nix/nix.conf `!include`s (never the system one).
  #
  # Provisioning (interactive, human-only):
  #   clan vars generate <machine>   (prompts for github-<user> pat)
  # Token scopes: a classic PAT with `repo` on the user's own account covers
  # git, gh and the MCP server for private org repos (PATs belong to user
  # accounts, not orgs; fine-grained PATs with an org resource owner may
  # need org-admin approval).
  #
  # NOTE: this scan mirrors the option paths in homeModules/git.nix and
  # homeModules/agents.nix by hand (defensive `or` access to avoid fixpoint
  # recursion). If you rename or restructure those options, update BOTH
  # places — a stale scan silently stops declaring the generator (and
  # pi/kimi/claude's github MCP then fails at startup with "authentication
  # required").
  flake.nixosModules.git = {
    config,
    lib,
    pkgs,
    ...
  }: let
    # Read-only scan of home-manager.users (attrsOf hmModule submodule —
    # merged option values, mkIf flattened): users with any GitHub-token
    # consumer. The patFile write below targets githubAuth.patFile, which
    # this scan never reads, so no fixpoint recursion is possible.
    authUsers =
      lib.filterAttrs (
        _: hmUser: let
          git = ((hmUser.homeSpec or {}).programs or {}).git or {};
          agents = hmUser.homeSpec.agents or {};
          gh = (agents.mcp or {}).github or {};
          mcpPatConsumer =
            (gh.enable or false)
            && ((agents.pi.enabled or false)
              || (agents.kimi.enabled or false)
              || (agents.claude.enabled or false)
              || (((agents.opencode or {}).enabled or false) && ((gh.auth or "oauth") == "pat")));
        in
          ((git.enable or false) && ((git.githubAuth or {}).enabled or false)) || mcpPatConsumer
      )
      config.home-manager.users;

    # Users who also want the PAT as Nix access-tokens
    # (homeSpec.programs.git.githubAuth.nix.enable). Same defensive scan.
    nixTokenUsers =
      lib.filterAttrs (
        _: hmUser: ((((((hmUser.homeSpec or {}).programs or {}).git or {}).githubAuth or {}).nix or {}).enable or false)
      )
      authUsers;
  in {
    config = {
      clan.core.vars.generators = lib.mkMerge (
        lib.mapAttrsToList
        (
          userName: _: {
            "github-${userName}" = {
              share = true;
              prompts.pat = {
                persist = true;
                type = "hidden";
                description = "GitHub Personal Access Token for git HTTPS, the gh CLI and the github MCP server (needs repo read/write on private org repos)";
              };
              files.pat = {
                owner = userName;
                mode = "0400";
                neededFor = "services";
              };
            };
          }
        )
        authUsers
        # nix-access-tokens-<user>: the github-<user> PAT rendered as one
        # nix.conf line, derived (no prompt) so the PAT var is untouched.
        # The token is validated here: a malformed include is a hard
        # "syntax error in configuration line" for every nix command, so
        # it must fail at `clan vars generate`, never on the machine.
        # Regenerate it after rotating github-<user>.
        ++ lib.mapAttrsToList
        (
          userName: _: {
            "nix-access-tokens-${userName}" = {
              share = true;
              dependencies = ["github-${userName}"];
              files."access-tokens.conf" = {
                owner = userName;
                mode = "0400";
                neededFor = "services";
              };
              runtimeInputs = with pkgs; [coreutils gnugrep];
              script = ''
                token=$(tr -d '[:space:]' < "$in/github-${userName}/pat")
                if ! printf '%s' "$token" | grep -Eq '^(ghp_|github_pat_)[A-Za-z0-9_]+$'; then
                  echo "github-${userName}/pat is not a GitHub PAT (ghp_... or github_pat_...)" >&2
                  exit 1
                fi
                printf 'access-tokens = github.com=%s\n' "$token" > "$out/access-tokens.conf"
              '';
            };
          }
        )
        nixTokenUsers
      );

      # Feed the generator's deployed path into every home module as
      # homeSpec.programs.git.githubAuth.patFile — profiles never hardcode
      # /run/secrets paths. Goes through sharedModules (a static module
      # list): writing scan-derived keys into home-manager.users instead
      # would recurse on the option this file's scan reads. Pre-generation
      # the clan sops fileModule reports "/no-such-path", which the home
      # module treats as absent (git falls back to prompting).
      home-manager.sharedModules = [
        (
          {
            config,
            lib,
            osConfig,
            ...
          }: let
            generators =
              if osConfig == null
              then {}
              else osConfig.clan.core.vars.generators or {};
            generator = "github-${config.home.username}";
            nixGenerator = "nix-access-tokens-${config.home.username}";
          in {
            homeSpec.programs.git.githubAuth = {
              patFile =
                lib.mkIf (generators ? ${generator})
                generators.${generator}.files.pat.path;
              nix.accessTokensFile =
                lib.mkIf (generators ? ${nixGenerator})
                generators.${nixGenerator}.files."access-tokens.conf".path;
            };
          }
        )
      ];
    };
  };
}
