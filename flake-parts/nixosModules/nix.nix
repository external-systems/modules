{
  # inputs,
  # self,
  lib,
  ...
}: {
  # ------ NixOS Modules ------ #
  flake.nixosModules.nix = {config, ...}: let
    cfg = config.hostSpec.services.nix;
  in {
    options.hostSpec.services.nix.enable = lib.mkEnableOption "default nix configuration";

    config = lib.mkIf cfg.enable {
      nix = {
        gc = {
          automatic = true;
          dates = "weekly";
          options = "--delete-older-than 180d";
        };

        settings = {
          accept-flake-config = true;
          download-buffer-size = 524288000; # 500MB
          auto-optimise-store = true;
          trusted-users = ["root" "netsa"];
          allowed-users = ["@wheel"];

          auto-allocate-uids = true;
          system-features = ["uid-range"];

          experimental-features = [
            "nix-command"
            "flakes"
            "auto-allocate-uids"
            "cgroups"
          ];

          trusted-public-keys = [
            "openshell.cachix.org-1:OAr5MunsfH5PZvUsfD08OtGx5RtcwdNZGJdU5FqLm5w="
            "nix-cache:4FILs79Adxn/798F8qk2PC1U8HaTlaPqptwNJrXNA1g="
            "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs="
            "flox-cache-public-1:7F4OyH7ZCnFhcze3fJdfyXYLQw/aV7GEed86nQ7IsOs="
            "devenv.cachix.org-1:w1cLUi8dv3hnoSPGAuibQv+f9TZLr6cv/Hm9XgU50cw="
            "cache.geninf.io-1:uhEViaczNKSoerYM+w7uqXUzlAhnbEBKsFzgg9n3cvI="
            "cache.clan.lol-1:3KztgSAB5R1M+Dz7vzkBGzXdodizbgLXGXKXlcQLA28="
          ];

          extra-substituters = [
            "https://nix-community.cachix.org"
            "https://devenv.cachix.org"
            "https://cache.geninf.io"
          ];

          trusted-substituters = [
            "https://cache.flox.dev"
            "https://cache.clan.lol"
            "https://cache.lounge.rocks"
            "https://openshell.cachix.org"
          ];
        };
      };
    };
  };
}
