# Docs settings that differ from the org defaults (pkgs flakeModules.docs).
# documentation/docs/*.md is the site, documentation/slides/slides.md the
# deck. Build: nix build .#documentation, open result/index.html.
{
  perSystem.docs = {
    repo = "modules";
    settings = {
      site_name = "modules";
      nav = [{Home = "index.md";}];
    };
  };
}
