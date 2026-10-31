# MkDocs documentation site + reveal.js slides.
# Build: nix build .#documentation / .#slides (or `docs-build`), then
#        open result/index.html in a browser; no server needed
# Preview: devenv up, or the `docs` / `slides` devenv scripts
{inputs, ...}: {
  imports = [inputs.presenting.flakeModules.default];

  perSystem = {
    documentation = {
      mkdocs-root = ./.;
      # Broken links / missing nav pages fail the build instead of warning.
      strict = true;
    };

    presenting.slides = {
      dir = ./slides;
      # The serve app looks for live files by this name from the CWD.
      serveDirName = "documentation/slides";
    };
  };
}
