# Eval-only stand-ins for the attributes consumers' overlays provide
# (external-systems/home: the repo-built packages). No pkgs.unstable:
# modules must work on plain nixpkgs.
final: _prev: let
  stub = name: final.writeShellScriptBin name "exit 1";
in {
  openshell = stub "openshell";
  openshell-gateway = stub "openshell-gateway";
  openshell-driver-vm = stub "openshell-driver-vm";
  code-sandbox = stub "code-sandbox";
  devenv = stub "devenv";
  headroom-slim = stub "headroom";
  pi-coding-agent = stub "pi";
  kimi-code = stub "kimi";
  claude-code = stub "claude";
  artifacthub-mcp = stub "artifacthub-mcp";
  kubernetes-mcp-server = stub "kubernetes-mcp-server";
}
