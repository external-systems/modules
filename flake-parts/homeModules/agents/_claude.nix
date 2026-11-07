# claude-code helpers for agents.nix. A plain function, not a module
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

  # PostToolUse hook: formats a .nix file right after claude edits it,
  # so the alejandra layout never waits for the next `fmt`. claude
  # passes the tool call as JSON on stdin. Never fails the tool call:
  # a file that does not parse yet is left for the next edit.
  formatNixHook = pkgs.writeShellApplication {
    name = "claude-format-nix";
    runtimeInputs = [pkgs.alejandra pkgs.jq];
    text = ''
      file=$(jq -r '.tool_input.file_path // empty')
      case "$file" in
        *.nix)
          if [ -f "$file" ]; then
            alejandra --quiet "$file" > /dev/null 2>&1 || true
          fi
          ;;
      esac
    '';
  };

  # Commands claude may run without asking when nixWorkflow is on:
  # reading, evaluating and building Nix, and the org dev shell's fmt
  # and check scripts. Builds are sandboxed; nothing here deploys or
  # touches the system profile.
  nixAllow =
    map (command: "Bash(${command}:*)") [
      "nix build"
      "nix derivation show"
      "nix eval"
      "nix flake check"
      "nix flake metadata"
      "nix flake show"
      "nix fmt"
      "nix log"
      "nix path-info"
      "nix store cat"
      "nix store ls"
      "nix why-depends"
      "devenv shell -- check"
      "devenv shell -- fmt"
    ]
    ++ ["Bash(check)" "Bash(fmt)"];

  # Bash timeouts in ms: closure builds and flake checks outlast the
  # 2-minute default, and a VM test can take most of an hour.
  bashTimeouts = {
    BASH_DEFAULT_TIMEOUT_MS = toString (10 * 60 * 1000);
    BASH_MAX_TIMEOUT_MS = toString (60 * 60 * 1000);
  };

  # The server names the module has ever written to ~/.claude.json:
  # the bootstrap for the first sync, when no state file exists yet.
  knownServers = ["artifacthub" "github" "headroom" "kubernetes" "nixos"];
}
