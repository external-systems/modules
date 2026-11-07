# VM tests (org-pkgs flakeModules.vmTests, through flakeModules.default):
# vm-tests/*.nix become legacyPackages.<system>.vmTests.<name>, run by hand
# with `vm-test`, never in checks or CI. Every node gets this flake's
# NixOS modules (all off until a hostSpec toggle) and the clan stub, so a
# test enables one module the way a machine would.
{self, ...}: {
  vmTests.defaults = [
    self.nixosModules.default
    ./clan-stub.nix
  ];
}
