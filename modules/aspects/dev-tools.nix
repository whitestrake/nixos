{config, ...}: {
  den.aspects.dev-tools = {
    os = {pkgs, ...}: {
      environment.systemPackages = with pkgs; [
        alejandra
        nil
        actionlint
        yamlfmt
        mdformat
        nodejs
        (python3.withPackages (ps: [ps.pyyaml ps.jsonschema]))
        sops
        age
        nixos-rebuild
        nix-update
      ];
    };

    # Claude Code and Codex sandbox commands with bubblewrap; Claude Code also
    # needs socat. Desktop's bundled Claude CLI relies on these being on PATH.
    nixos = {pkgs, ...}: {
      environment.systemPackages = with pkgs; [
        bubblewrap
        socat
      ];
    };

    wsl-host = {
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
      # Komodo API credentials, readable by the user so local sessions can
      # call the API directly.
      sops.secrets = {
        githubToken = {};
        komodoURL.owner = user.userName;
        komodoKey.owner = user.userName;
        komodoSecret.owner = user.userName;
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
      lib,
      pkgs,
      config,
      osConfig,
      ...
    }: let
      json = pkgs.formats.json {};
      # Local plugin marketplace carrying a Nix language server as one plugin.
      # It is linked at a stable path so ~/.claude/settings.json, which Claude
      # rewrites at runtime, can refer to it once and follow each rebuild:
      #   claude plugin marketplace add ~/.local/share/claude-code/whitestrake-marketplace
      #   claude plugin install dev-tools@whitestrake
      # Unlike the HM --plugin-dir wrapper, this also reaches the CLI Claude
      # Desktop runs for local and SSH sessions.
      claudeMarketplace = pkgs.runCommand "claude-code-whitestrake-marketplace" {} ''
        install -Dm644 ${json.generate "marketplace.json" {
          name = "whitestrake";
          owner.name = "whitestrake";
          plugins = [
            {
              name = "dev-tools";
              source = "./dev-tools";
            }
          ];
        }} $out/.claude-plugin/marketplace.json
        install -Dm644 ${json.generate "plugin.json" {name = "dev-tools";}} \
          $out/dev-tools/.claude-plugin/plugin.json
        install -Dm644 ${json.generate "lsp.json" {
          nix = {
            command = lib.getExe pkgs.nil;
            extensionToLanguage.".nix" = "nix";
          };
        }} $out/dev-tools/.lsp.json
      '';
    in {
      xdg.dataFile."claude-code/whitestrake-marketplace".source = claudeMarketplace;

      programs.codex = {
        enable = true;
        package = pkgs.unstable.codex;
      };

      programs.claude-code = {
        enable = true;
        package = pkgs.unstable.claude-code;
      };

      programs.antigravity-cli = {
        enable = true;
        package = pkgs.unstable.antigravity-cli;
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
          };
      };
    };
  };

  # Export the aspect under a namespace
  den.ful.whitestrake.dev-tools = config.den.aspects.dev-tools;
}
