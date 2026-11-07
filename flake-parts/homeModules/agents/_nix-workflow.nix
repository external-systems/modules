# homeSpec.agents.nixWorkflow, rendered once per agent in its own
# dialect: the same commands run without a prompt, long Nix builds get
# room, and edited .nix files are formatted. A plain function, not a
# module (the leading _ keeps import-tree off it); agents.nix calls it
# and tests/flake-module.nix runs its scripts.
#
# What each agent can express (upstream sources: opencode v2 docs
# permissions.mdx/formatters.mdx, kimi-code docs config-files.md/hooks.md,
# pi-mono coding-agent docs extensions.md):
#
#   capability     claude            opencode v2        kimi-code          pi
#   no-prompt cmds permissions.allow permissions[shell] — (see below)      no prompts at all
#   /nix/store     additionalDirs    external_directory reads auto-allowed reads unrestricted
#   long commands  BASH_*_TIMEOUT_MS — (instructions)   task timeout       extension
#   format .nix    PostToolUse hook  formatter          PostToolUse hook   extension
#
# kimi gets no command allow rules on purpose: it matches a rule against
# the whole command string without splitting it, so an allowed
# `nix build` prefix would also approve `nix build . && rm -rf ~`.
# claude and opencode check each part of a compound command.
{
  lib,
  pkgs,
}: let
  # Commands taking arguments, allowed by prefix.
  prefixCommands = [
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
  ];
  # The org dev shell's scripts, allowed as bare commands.
  bareCommands = ["check" "fmt"];

  # Timeouts: closure builds and flake checks outlast the usual 2-minute
  # default, and a VM test can take most of an hour.
  defaultTimeoutS = 10 * 60;
  maxTimeoutS = 60 * 60;

  formatFile = pkgs.writeShellApplication {
    name = "nix-format-file";
    runtimeInputs = [pkgs.alejandra];
    text = ''alejandra --quiet "$1" > /dev/null 2>&1 || true'';
  };
in rec {
  inherit formatFile;

  # PostToolUse hook for claude and kimi: both pass the tool call as
  # JSON on stdin (claude names the path file_path, kimi path). Never
  # fails the tool call: a file that does not parse yet is left for
  # the next edit.
  formatHook = pkgs.writeShellApplication {
    name = "agent-format-nix";
    runtimeInputs = [pkgs.jq formatFile];
    text = ''
      file=$(jq -r '.tool_input.file_path // .tool_input.path // empty')
      case "$file" in
        *.nix)
          if [ -f "$file" ]; then
            nix-format-file "$file"
          fi
          ;;
      esac
    '';
  };

  claude = {
    allow =
      map (c: "Bash(${c}:*)") prefixCommands
      ++ map (c: "Bash(${c})") bareCommands;
    env = {
      BASH_DEFAULT_TIMEOUT_MS = toString (defaultTimeoutS * 1000);
      BASH_MAX_TIMEOUT_MS = toString (maxTimeoutS * 1000);
    };
    hook = {
      matcher = "Edit|MultiEdit|Write";
      hooks = [
        {
          type = "command";
          command = lib.getExe formatHook;
        }
      ];
    };
  };

  opencode = {
    # A shell pattern ending in " *" also matches the bare command.
    permissions =
      map (c: {
        action = "shell";
        resource = "${c} *";
        effect = "allow";
      })
      (prefixCommands ++ bareCommands);
    # Built-in formatters run first and the first success wins, so the
    # alejandra command replaces the built-in nixfmt entry for .nix.
    formatter.nixfmt = {
      command = [(lib.getExe formatFile) "$FILE"];
      extensions = [".nix"];
    };
  };

  kimi = {
    hook = {
      event = "PostToolUse";
      matcher = "^(Edit|Write)$";
      command = lib.getExe formatHook;
      timeout = 30;
    };
    # A foreground command is capped at 300 s, then moves to the
    # background, where this limit applies.
    taskTimeoutS = maxTimeoutS;
    # Hooks whose command contains this are the module's own.
    hookMarker = formatHook.name;
  };

  # ~/.pi/agent/extensions/nix-workflow.ts: pi has no timeout setting
  # (bash runs unbounded unless the model passes seconds) and no
  # formatter, but extensions may mutate a tool call's input and act on
  # its result.
  piExtension = {formatOnEdit}:
    ''
      // Managed by home-manager (homeSpec.agents.nixWorkflow).
      import { resolve } from "node:path";

      export default function (pi: any) {
        // Long Nix builds and VM tests: a default bash timeout, and a cap.
        pi.on("tool_call", async (event: any) => {
          if (event.toolName === "bash") {
            event.input.timeout = Math.min(event.input.timeout ?? ${toString defaultTimeoutS}, ${toString maxTimeoutS});
          }
        });
    ''
    + lib.optionalString formatOnEdit ''

      // Format a .nix file right after pi edits it.
      pi.on("tool_result", async (event: any, ctx: any) => {
        const path = event.input?.path;
        if ((event.toolName === "edit" || event.toolName === "write") && !event.isError
            && typeof path === "string" && path.endsWith(".nix")) {
          await pi.exec(${builtins.toJSON (lib.getExe formatFile)}, [resolve(ctx.cwd, path)], { signal: ctx.signal });
        }
      });
    ''
    + ''
      }
    '';

  # Merges the module's kimi keys into ~/.kimi-code/config.toml at
  # activation. kimi's /login writes providers, models and oauth into
  # that same file, so home-manager cannot own it (unless kimi.config
  # bakes the whole file). Drops the hooks whose command contains the
  # marker, appends the module's, and sets [task] bash_task_timeout_s
  # when given; tomlkit keeps every other key and comment.
  #
  # Usage: kimi-config-merge CONFIG_TOML FRAGMENT_JSON
  #   FRAGMENT_JSON = {"marker": str, "hooks": [...], "taskTimeoutS": int|null}
  kimiConfigMerge =
    pkgs.writers.writePython3Bin "kimi-config-merge" {
      libraries = [pkgs.python3Packages.tomlkit];
    } ''
      import json
      import os
      import sys

      import tomlkit

      path, fragment = sys.argv[1], json.loads(sys.argv[2])
      if os.path.islink(path):
          print(f"kimi-config-merge: {path} is a symlink, skipping",
                file=sys.stderr)
          sys.exit(0)
      exists = os.path.exists(path)
      timeout = fragment["taskTimeoutS"]
      if not exists and not fragment["hooks"] and timeout is None:
          sys.exit(0)

      doc = tomlkit.parse(open(path).read()) if exists else tomlkit.document()
      hooks = tomlkit.aot()
      for hook in doc.get("hooks", []):
          if fragment["marker"] not in str(hook.get("command", "")):
              hooks.append(hook)
      for hook in fragment["hooks"]:
          table = tomlkit.table()
          table.update(hook)
          hooks.append(table)
      if "hooks" in doc:
          del doc["hooks"]
      if len(hooks):
          doc["hooks"] = hooks
      if timeout is not None:
          task = doc.setdefault("task", tomlkit.table())
          task["bash_task_timeout_s"] = timeout

      os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
      with open(path, "w") as out:
          out.write(tomlkit.dumps(doc))
    '';

  # The kimi keys for a baked config.toml (kimi.config set): appended to
  # the caller's hooks, the task timeout only where the caller set none.
  kimiBaked = {
    config,
    formatOnEdit,
  }:
    config
    // {
      task = {bash_task_timeout_s = kimi.taskTimeoutS;} // (config.task or {});
    }
    // lib.optionalAttrs formatOnEdit {
      hooks = (config.hooks or []) ++ [kimi.hook];
    };
}
