# claude-code's ~/.claude.json MCP sync for agents.nix. A plain function, not a module
# (the leading _ keeps import-tree off it), so tests/flake-module.nix
# can build and run the scripts on their own.
{pkgs}: {
  # Syncs the module's MCP servers into ~/.claude.json at activation.
  # claude-code reads user-scope servers only from that file's top-level
  # mcpServers (settings.json mcpServers is ignored), and the file is
  # claude's mutable state, so home-manager cannot own it. Every other
  # key, and every server the user added with `claude mcp add`, is kept.
  #
  # A plain merge never removes a server the module stopped managing,
  # so the names written last time are kept in STATE_FILE and dropped
  # before the merge. Without a state file (first run) BOOTSTRAP_JSON
  # stands in: the names the module has ever managed.
  #
  # Usage: claude-mcp-sync CLAUDE_JSON STATE_FILE SERVERS_JSON BOOTSTRAP_JSON
  mcpSync = pkgs.writeShellApplication {
    name = "claude-mcp-sync";
    runtimeInputs = [pkgs.coreutils pkgs.jq];
    text = ''
      claudeJson=$1
      stateFile=$2
      servers=$3
      bootstrap=$4

      if [ -L "$claudeJson" ]; then
        echo "claude-mcp-sync: $claudeJson is a symlink, skipping" >&2
        exit 0
      fi
      [ -f "$claudeJson" ] || echo '{}' > "$claudeJson"

      if [ -f "$stateFile" ]; then
        previous=$(cat "$stateFile")
      else
        previous=$bootstrap
      fi

      tmp=$(mktemp)
      trap 'rm -f "$tmp"' EXIT
      if jq --argjson servers "$servers" --argjson previous "$previous" \
        '.mcpServers = (((.mcpServers // {}) | delpaths([$previous[] | [.]])) * $servers)' \
        "$claudeJson" > "$tmp"; then
        # cat, not mv: keeps the file's inode, mode and owner.
        cat "$tmp" > "$claudeJson"
        mkdir -p "$(dirname "$stateFile")"
        jq -n --argjson servers "$servers" '$servers | keys' > "$stateFile"
      else
        echo "claude-mcp-sync: jq merge failed, leaving $claudeJson untouched" >&2
      fi
    '';
  };

  # The server names the module has ever written to ~/.claude.json:
  # the bootstrap for the first sync, when no state file exists yet.
  knownServers = ["artifacthub" "github" "headroom" "kubernetes" "nixos"];
}
