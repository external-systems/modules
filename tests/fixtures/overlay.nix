# Eval-only stand-ins for the attributes consumers' overlays provide
# (external-systems/home: the repo-built packages). No pkgs.unstable:
# modules must work on plain nixpkgs.
final: prev: let
  stub = name: final.writeShellScriptBin name "exit 1";
  # org-pkgs' overlays.vscode-extensions: Open VSX extensions nixpkgs
  # doesn't package.
  stubExtension = publisher: name:
    final.vscode-utils.buildVscodeExtension {
      pname = "${publisher}-${name}";
      version = "0";
      src = final.emptyDirectory;
      vscodeExtPublisher = publisher;
      vscodeExtName = name;
      vscodeExtUniqueId = "${publisher}.${name}";
    };
in {
  vscode-extensions =
    prev.vscode-extensions
    // {
      jeanp413.open-remote-ssh = stubExtension "jeanp413" "open-remote-ssh";
      varlock.env-spec-language = stubExtension "varlock" "env-spec-language";
    };
  openshell = stub "openshell";
  openshell-gateway = stub "openshell-gateway";
  openshell-driver-vm = stub "openshell-driver-vm";
  code-sandbox = stub "code-sandbox";
  devenv = stub "devenv";
  headroom-sandbox = stub "headroom";
  pi-coding-agent = stub "pi";
  kimi-code = stub "kimi";
  claude-code = stub "claude";
  artifacthub-mcp = stub "artifacthub-mcp";
  kubernetes-mcp-server = stub "kubernetes-mcp-server";
}
