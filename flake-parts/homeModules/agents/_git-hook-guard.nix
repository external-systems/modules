# The git hook guard: a claude-code PreToolUse hook on Bash that blocks
# git commands that skip git hooks. The org shell's hooks (fmt on commit,
# a repo's own on push) are part of the gate, and the ground rules say
# never to skip them; this makes that hold for the agent. The owner can
# still skip a hook from their own shell, or from claude with the `!`
# prefix (that runs outside the agent's tool calls).
#
# Blocked, in any part of a compound command (and inside `sh -c`/`bash -c`):
# - `--no-verify` on any git subcommand (commit, push, merge, rebase, am)
# - `git commit -n` (also in a short-option cluster such as `-anm`)
# - core.hooksPath set by `git -c` or `git config`
# - PREK_ALLOW_NO_CONFIG or SKIP (prek skips the named hooks) on a git command
#
# Exit 2 blocks the tool call; claude shows the stderr to the model. A
# command that does not parse as shell is left alone (claude's own Bash
# tool rejects it). A plain function, not a module.
{
  lib,
  pkgs,
}: let
  guard = pkgs.writers.writePython3Bin "agent-git-hook-guard" {flakeIgnore = ["E501"];} ''
    import json
    import os
    import shlex
    import sys

    OPERATORS = {"&&", "||", ";", "|", "&", "(", ")", ";;", "|&"}
    SHELLS = {"sh", "bash", "zsh", "dash"}
    # git commit short options that take a value: the rest of the cluster,
    # or the next word, is that value.
    COMMIT_VALUE_OPTS = set("mFCct")
    SKIP_ENV = {"PREK_ALLOW_NO_CONFIG", "SKIP"}


    def simple_commands(command):
        lexer = shlex.shlex(command, posix=True, punctuation_chars=True)
        lexer.whitespace_split = True
        words = []
        for token in lexer:
            if token in OPERATORS:
                if words:
                    yield words
                words = []
            else:
                words.append(token)
        if words:
            yield words


    def commit_skips(args):
        for arg in args:
            if arg == "--":
                return False
            if arg.startswith("-") and not arg.startswith("--"):
                for letter in arg[1:]:
                    if letter == "n":
                        return True
                    if letter in COMMIT_VALUE_OPTS:
                        break
        return False


    def git_reason(words, env):
        i = 1
        while i < len(words) and words[i].startswith("-"):
            if words[i] in ("-C", "-c"):
                if words[i] == "-c" and i + 1 < len(words) and words[i + 1].lower().startswith("core.hookspath"):
                    return "sets core.hooksPath"
                i += 2
            else:
                i += 1
        if i >= len(words):
            return None
        sub, args = words[i], words[i + 1:]
        if env & SKIP_ENV:
            return "sets " + ", ".join(sorted(env & SKIP_ENV))
        if "--no-verify" in args:
            return "uses --no-verify"
        if sub == "commit" and commit_skips(args):
            return "uses git commit -n"
        if sub == "config" and any(a.lower() == "core.hookspath" for a in args):
            return "sets core.hooksPath"
        return None


    def reason(command, depth=0):
        try:
            commands = list(simple_commands(command))
        except ValueError:
            return None
        for words in commands:
            env = set()
            while words and "=" in words[0] and not words[0].startswith("="):
                env.add(words[0].split("=", 1)[0])
                words = words[1:]
            if words and words[0] == "env":
                words = words[1:]
                while words and "=" in words[0]:
                    env.add(words[0].split("=", 1)[0])
                    words = words[1:]
            if not words:
                continue
            name = os.path.basename(words[0])
            if name == "git":
                found = git_reason(words, env)
                if found:
                    return found
            elif name in SHELLS and depth < 3 and "-c" in words[1:]:
                script = words[words.index("-c") + 1:][:1]
                if script:
                    found = reason(script[0], depth + 1)
                    if found:
                        return found
        return None


    try:
        event = json.load(sys.stdin)
    except ValueError:
        sys.exit(0)
    command = (event.get("tool_input") or {}).get("command") or ""
    found = reason(command)
    if found:
        print(
            f"Blocked: this git command {found}, which skips the git hooks. "
            "The hooks are part of the gate (external-systems ground rules): "
            "fix what the hook reports and commit or push again. If a skip is "
            "really needed, ask the owner to run the command.",
            file=sys.stderr,
        )
        sys.exit(2)
  '';
in {
  package = guard;
  claude.hook = {
    matcher = "Bash";
    hooks = [
      {
        type = "command";
        command = lib.getExe guard;
      }
    ];
  };
}
