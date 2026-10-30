{lib, ...}: {
  # ------ Home-manager Modules ------ #
  flake.homeModules.headroom = {
    pkgs,
    config,
    ...
  }: let
    cfg = config.homeSpec.programs.headroom;
  in {
    options.homeSpec.programs.headroom = {
      enable = lib.mkEnableOption "headroom context compression layer";
      package = lib.mkOption {
        type = lib.types.package;
        default = pkgs.headroom-slim;
        defaultText = lib.literalExpression "pkgs.headroom-slim";
        description = "The headroom package to install.";
      };
      proxy = {
        enable = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = "Whether to run headroom proxy as a systemd user service.";
        };
        port = lib.mkOption {
          type = lib.types.port;
          default = 8787;
          description = "Port to run the headroom proxy server on.";
        };
        host = lib.mkOption {
          type = lib.types.str;
          default = "127.0.0.1";
          description = "Host to bind the headroom proxy server to.";
        };
        mode = lib.mkOption {
          type = lib.types.enum ["cache" "token"];
          default = "cache";
          description = "Optimization mode: 'cache' (preserves prompt-caching prefix) or 'token' (aggressive rewrite).";
        };
        memory = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = ''
            Enable persistent cross-session memory. Off by default: the
            proxy-injected memory tools have no executor in opencode (its
            client rejects unknown tools), so the flag only benefits
            Claude-Code-style clients; it also pulls embedding models at
            startup.
          '';
        };
        learn = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = "Enable live traffic learning.";
        };
        # The proxy carries ONE upstream per wire pipeline. Pin them
        # explicitly when routing agents whose providers are not the
        # pipeline defaults (Anthropic defaults to api.anthropic.com):
        # host kimi-code rides the OpenAI pipeline to Moonshot's managed
        # service, and pi's kimi-coding provider overrides per request.
        anthropicApiUrl = lib.mkOption {
          type = with lib.types; nullOr str;
          default = null;
          description = "--anthropic-api-url for 'headroom proxy' (Anthropic wire upstream); null = headroom's default (api.anthropic.com).";
        };
        openaiApiUrl = lib.mkOption {
          type = with lib.types; nullOr str;
          default = null;
          description = "--openai-api-url for 'headroom proxy' (OpenAI wire upstream); null = headroom's default. Set to the kimi-code managed service URL (https://api.kimi.ai/coding/v1) when routing kimi-code through the proxy.";
        };
        extraArgs = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [];
          description = "Extra command-line arguments to pass to 'headroom proxy'.";
        };
      };
    };

    config = lib.mkIf cfg.enable {
      home.packages = [cfg.package];

      # When opencode is also enabled, surface headroom on its PATH
      programs.opencode = lib.mkIf (config.programs.opencode.enable or false) {
        extraPackages = [cfg.package];
      };

      systemd.user.services.headroom-proxy = lib.mkIf cfg.proxy.enable {
        Unit = {
          Description = "Headroom Context Optimization Proxy";
          After = ["network.target"];
        };
        Install = {
          WantedBy = ["default.target"];
        };
        Service = {
          Type = "simple";
          Restart = "always";
          RestartSec = "3s";
          ExecStart = lib.concatStringsSep " " ([
              "${lib.getExe cfg.package}"
              "proxy"
              "--host"
              cfg.proxy.host
              "--port"
              (toString cfg.proxy.port)
              "--mode"
              cfg.proxy.mode
            ]
            ++ lib.optionals (cfg.proxy.anthropicApiUrl != null) [
              "--anthropic-api-url"
              cfg.proxy.anthropicApiUrl
            ]
            ++ lib.optionals (cfg.proxy.openaiApiUrl != null) [
              "--openai-api-url"
              cfg.proxy.openaiApiUrl
            ]
            ++ lib.optional cfg.proxy.memory "--memory"
            ++ lib.optional cfg.proxy.learn "--learn"
            ++ cfg.proxy.extraArgs);
        };
      };
    };
  };
}
