# The machine context every enabled agent gets as its user-level
# instructions: a plain, token-lean descriptor of the machine (no
# markdown decoration). A plain function, not a module: the leading _
# keeps import-tree off it, agents.nix calls it, and
# tests/flake-module.nix calls it on synthetic NixOS configs.
#
# Everything comes from osConfig (the NixOS config this home-manager
# user runs on; null in a standalone eval such as the OpenShell
# code-agent image):
# - hardware from hardware.facter.report, which nixpkgs reads from
#   hardware.facter.reportPath (clan sets machines/<host>/facter.json)
#   and which tests set inline;
# - where Nix builds run (local KVM, remote builders), so an agent knows
#   whether a VM test runs here or on a builder.
{
  lib,
  osConfig,
  # pkgs.stdenv.hostPlatform.system
  system,
  homeDirectory,
  # homeSpec.agents.machineContext
  mc,
  # The skills runtime is installed (skill script deps preinstalled).
  skillsRuntime,
  # homeSpec.agents.nixWorkflow.enable: opencode has no timeout setting
  # and kimi caps foreground commands, so the timeout advice goes here,
  # for every agent alike.
  nixWorkflow,
}: let
  hasOs = osConfig != null;
  hostName =
    if hasOs
    then osConfig.networking.hostName
    else "";
  hasRepo = mc.repoOwner != null && mc.repoName != null;
  # A report on disk (not one set inline by a test) is what the
  # "Machine facts" pointer refers to.
  hasFacterFile = hasOs && (osConfig.hardware.facter.reportPath or null) != null;
  report =
    if hasOs
    then osConfig.hardware.facter.report or {}
    else {};

  # Best-effort accessors: facter reports differ per machine and facter
  # version (absent keys, null values), so a missing fact is skipped
  # rather than failing the build.
  listOf = value:
    if lib.isList value
    then value
    else [];
  first = list:
    if list != []
    then lib.head list
    else null;
  attr = set: name:
    if lib.isAttrs set
    then set.${name} or null
    else null;
  get = path: lib.attrByPath path null report;
  line = prefix: parts:
    if parts == []
    then null
    else "- ${prefix}: ${lib.concatStringsSep ", " parts}";
  suffix = text: value:
    if value == null
    then null
    else "${toString value}${text}";

  cpu = first (listOf (get ["hardware" "cpu"]));
  gpu = first (listOf (get ["hardware" "graphics_card"]));
  disks = lib.unique (lib.remove null (map (d: attr d "model") (listOf (get ["hardware" "disk"]))));
  # memory_device sizes are KiB; empty DIMM slots report 0.
  dimms = lib.filter (d: lib.isAttrs d && (d.size or 0) > 0) (listOf (get ["smbios" "memory_device"]));
  memGiB = builtins.div (lib.foldl' (sum: d: sum + d.size) 0 dimms) (1024 * 1024);
  # "Micron Technology" -> "Micron": the first word is enough.
  dimmVendor = let
    vendor = attr (first dimms) "manufacturer";
  in
    if vendor == null
    then null
    else lib.head (lib.splitString " " vendor);
  hardware = lib.remove null [
    (line "CPU" (lib.remove null [(attr cpu "model_name") (suffix " threads" (attr cpu "units"))]))
    (line "GPU" (lib.remove null [(attr (attr gpu "vendor") "name") (lib.mapNullable (d: "driver ${d}") (attr gpu "driver"))]))
    (line "Memory" (lib.optional (dimms != []) "${toString memGiB} GiB${lib.optionalString (dimmVendor != null) " (${toString (lib.length dimms)}x ${dimmVendor} DIMMs)"}"))
    (line "Disk" disks)
  ];

  # NixOS has no eval-time "this is a VM" marker, so VM images set
  # mc.environment; NixOS containers are detected; bare metal emits
  # nothing.
  environment =
    if mc.environment != null
    then "Environment: ${mc.environment}"
    else if hasOs && (osConfig.boot.isContainer or false)
    then "Environment: nixos-container"
    else null;

  # Where Nix builds (and so VM tests) run. Local KVM needs both the nix
  # system feature and a loaded kvm module: nixpkgs lists "kvm" in
  # system-features by default, even without the hardware.
  nixCfg =
    if hasOs
    then osConfig.nix
    else {};
  localKvm =
    hasOs
    && lib.elem "kvm" (nixCfg.settings.system-features or [])
    && lib.any (m: lib.elem m ["kvm-amd" "kvm-intel"]) (osConfig.boot.kernelModules or []);
  builders = lib.optionals (nixCfg.distributedBuilds or false) (nixCfg.buildMachines or []);
  describeBuilder = m: "${m.hostName} (${lib.concatStringsSep ", " (
    lib.unique (lib.optional ((m.system or null) != null) m.system ++ (m.systems or []))
    ++ lib.optional (lib.elem "kvm" (m.supportedFeatures or [])) "kvm"
  )})";
  nixBuilds =
    if !hasOs
    then null
    else "Nix builds: ${
      if localKvm
      then "local KVM"
      else "no local KVM"
    }${lib.optionalString (builders != []) "; remote builders: ${lib.concatMapStringsSep ", " describeBuilder builders}"}";

  lines =
    ["Machine: ${hostName} (NixOS ${system})"]
    ++ lib.optional (environment != null) environment
    ++ lib.optional (nixBuilds != null) nixBuilds
    ++ [""]
    ++ lib.optionals (hardware != []) (["Hardware:"] ++ hardware ++ [""])
    ++ lib.optional hasRepo
    "Repo: github.com/${mc.repoOwner}/${mc.repoName}${lib.optionalString (mc.repoPath != null) " (local: ${homeDirectory}/${mc.repoPath})"}"
    ++ lib.optional hasFacterFile
    "Machine facts: machines/${hostName}/facter.json, disko.nix, configuration.nix"
    ++ [
      (
        if hasRepo
        then "Machine config is strictly read-only: changes only by repo owner ${mc.repoOwner}, or when instructed to while working in the machine repo."
        else "Machine config is strictly read-only: change it only when instructed to while working in the machine repo."
      )
      ""
      "Read a repo's AGENTS.md before working in it."
    ]
    ++ lib.optional skillsRuntime "Skill script dependencies are preinstalled; don't pip/npm install them."
    ++ lib.optional nixWorkflow "Nix builds and VM tests run long: give shell commands a timeout of up to 60 min, or run them in the background."
    ++ lib.optionals (mc.extraText != null)
    ([""] ++ lib.filter (l: l != "") (lib.splitString "\n" mc.extraText));
in {
  inherit hostName;
  # Written only where a hostname resolves (never in a standalone eval).
  enable = mc.enable && hostName != "";
  text = lib.concatStringsSep "\n" lines + "\n";
}
