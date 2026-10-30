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
            generator = "github-${config.home.username}";
            hasGenerator = osConfig != null && ((osConfig.clan.core.vars.generators or {}) ? ${generator});
          in {
            homeSpec.programs.git.githubAuth.patFile =
              lib.mkIf hasGenerator
              osConfig.clan.core.vars.generators.${generator}.files.pat.path;
          }
        )
      ];
    };
  };
}
