{
  config,
  inputs,
  ...
}: {
  flake-file.inputs.nix-mcp.url = "github:stubbedev/nix-mcp";

  den.aspects.dev-tools = {
    os = {pkgs, ...}: {
      environment.systemPackages = with pkgs; [
        alejandra
        nil
        actionlint
        yamlfmt
        mdformat
        sops
        age
        nixos-rebuild
        nix-update
      ];
    };

    wsl-host = {pkgs, ...}: {
      environment.systemPackages = [
        pkgs.bubblewrap
      ];

      # Codex Desktop for Windows assumes these FHS entrypoints exist when
      # launching commands inside a WSL agent.
      systemd.tmpfiles.rules = [
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
      mcpServiceUrl = name: "https://mcp-${name}.${host.tailnetSuffix}/mcp";
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
          nixos = {
            command = "${inputs.nix-mcp.packages.${host.system}.nix-mcp}/bin/nix-mcp";
            env.PATH = lib.makeBinPath [pkgs.nix];
          };
          homeassistant.url = mcpServiceUrl "homeassistant";
          komodo.url = mcpServiceUrl "komodo";
          proxmox.url = mcpServiceUrl "proxmox";
          grafana = {
            url = "https://mcp.grafana.com/mcp";
            headers.X-Grafana-URL = "https://whitestrake.grafana.net/";
          };
          tailscale.url = mcpServiceUrl "tailscale";
          cloudflare.url = "https://mcp.cloudflare.com/mcp";
          github.url = "https://api.githubcopilot.com/mcp/insiders";
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
    };
  };

  # Export the aspect under a namespace
  den.ful.whitestrake.dev-tools = config.den.aspects.dev-tools;
}
