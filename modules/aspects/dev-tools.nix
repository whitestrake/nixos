{
  config,
  inputs,
  ...
}: {
  flake-file.inputs.deploy-rs-async.url = "github:serokell/deploy-rs/refs/pull/271/merge";
  flake-file.inputs.mcp-nixos-pr.url = "github:utensils/mcp-nixos/refs/pull/159/merge";

  den.aspects.dev-tools = {
    os = {
      host,
      pkgs,
      ...
    }: {
      environment.systemPackages = with pkgs; [
        alejandra
        nil
        actionlint
        yamlfmt
        mdformat
        sops
        age
        deploy-rs
        nixos-rebuild
        nix-update
      ];
      environment.shellAliases.deploy-rs-async = let
        system = host.system;
        deploy-rs-async = inputs.deploy-rs-async.packages.${system}.deploy-rs;
      in "${deploy-rs-async}/bin/deploy --remote-build";
    };

    nixos = {
      config,
      lib,
      pkgs,
      ...
    }: {
      environment.systemPackages = lib.optionals (config.wsl.enable or false) [
        pkgs.bubblewrap
      ];

      # Codex currently assumes these FHS entrypoints exist when launching
      # commands inside a WSL agent.
      systemd.tmpfiles.rules = lib.optionals (config.wsl.enable or false) [
        "L+ /usr/bin/bash - - - - /run/current-system/sw/bin/bash"
        "L+ /usr/bin/env - - - - /run/current-system/sw/bin/env"
      ];
    };

    provides.whitestrake.os = {
      user,
      config,
      ...
    }: {
      sops.secrets = {
        githubToken = {};
        komodoURL.owner = user.userName;
        komodoKey.owner = user.userName;
        komodoSecret.owner = user.userName;
        homeAssistantURL.owner = user.userName;
        homeAssistantToken.owner = user.userName;
      };
      sops.templates."gh-hosts" = {
        owner = user.userName;
        content = ''
          github.com:
            oauth_token: ${config.sops.placeholder.githubToken}
            git_protocol: https
            user: whitestrake
        '';
      };

      environment.etc."codex/config.toml".source =
        config.home-manager.users.${user.userName}
        .home.file.".codex/whitestrake.config.toml".source;
    };

    provides.whitestrake.homeManager = {
      host,
      lib,
      pkgs,
      config,
      osConfig,
      ...
    }: let
      mcp-nixos = inputs.mcp-nixos-pr.packages.${host.system}.mcp-nixos;
      homeassistant-mcp = pkgs.unstable.ha-mcp;
      komodo-mcp = pkgs.myPkgs.komodo-mcp-server;

      codexMcpServers =
        lib.mapAttrs (
          name: server:
            lib.hm.mcp.transformMcpServer {
              inherit server;
              exclude = [
                "headers"
                "type"
              ];
              extraTransforms = [
                (s: s // lib.optionalAttrs (s.headers or {} != {}) {http_headers = s.headers;})
                lib.hm.mcp.addType
                (lib.hm.mcp.wrapEnvFilesCommand {inherit pkgs name;})
              ];
            }
        )
        config.programs.mcp.servers;
    in {
      programs.mcp = {
        enable = true;
        servers = {
          nixos.command = "${mcp-nixos}/bin/mcp-nixos";

          homeassistant = {
            command = "${homeassistant-mcp}/bin/ha-mcp";
            env = {
              HOMEASSISTANT_URL.file = osConfig.sops.secrets.homeAssistantURL.path;
              HOMEASSISTANT_TOKEN.file = osConfig.sops.secrets.homeAssistantToken.path;
            };
          };

          komodo = {
            command = "${komodo-mcp}/bin/komodo-mcp-server";
            env = {
              KOMODO_URL.file = osConfig.sops.secrets.komodoURL.path;
              KOMODO_API_KEY.file = osConfig.sops.secrets.komodoKey.path;
              KOMODO_API_SECRET.file = osConfig.sops.secrets.komodoSecret.path;
            };
          };
        };
      };

      programs.codex = {
        enable = true;
        package = pkgs.myPkgs.codex;
        enableMcpIntegration = false;
      };

      programs.antigravity-cli = {
        enable = true;
        package = pkgs.unstable.antigravity-cli;
        enableMcpIntegration = true;
      };

      programs.antigravity = {
        enable = (lib.systems.elaborate host.system).isDarwin;
        package = null;
        profiles.default.enableMcpIntegration = true;
      };

      programs.gh = {
        enable = true;
        gitCredentialHelper.enable = true;
      };

      home.file = {
        ".config/gh/hosts.yml".source =
          config.lib.file.mkOutOfStoreSymlink
          osConfig.sops.templates."gh-hosts".path;

        ".codex/whitestrake.config.toml".source =
          (pkgs.formats.toml {}).generate
          "codex-whitestrake-config" {
            personality = "pragmatic";
            approval_policy = "on-request";
            approvals_reviewer = "auto_review";
            tui = {
              status_line = [
                "model-with-reasoning"
                "project-name"
                "context-remaining"
                "five-hour-limit"
                "weekly-limit"
                "task-progress"
                "run-state"
              ];
            };
            mcp_servers = codexMcpServers;
          };
      };

      home.packages = [
        mcp-nixos
        homeassistant-mcp
        komodo-mcp
      ];
    };
  };

  # Export the aspect under a namespace
  den.ful.whitestrake.dev-tools = config.den.aspects.dev-tools;
}
