{inputs, ...}: {
  flake-file.inputs.mcp-nixos-pr.url = "github:utensils/mcp-nixos/refs/pull/159/merge";

  den.aspects.mcp-host.nixos = {
    config,
    host,
    lib,
    pkgs,
    ...
  }: let
    tailscale = "${config.services.tailscale.package}/bin/tailscale";
    tailnetServiceHost = name: "mcp-${name}.${host.tailnetSuffix}";

    services = {
      homeassistant = {
        port = 8761;
        command = "${pkgs.myPkgs.ha-mcp}/bin/ha-mcp-web";
        env = {
          MCP_HOST = "127.0.0.1";
          MCP_PORT = "8761";
          MCP_SECRET_PATH = "/mcp";
        };
        secrets = {
          HOMEASSISTANT_URL = "homeAssistantURL";
          HOMEASSISTANT_TOKEN = "homeAssistantToken";
        };
      };

      komodo = {
        port = 8762;
        command = "${pkgs.myPkgs.komodo-mcp-server}/bin/komodo-mcp-server";
        env = {
          MCP_TRANSPORT = "http";
          MCP_BIND_HOST = "127.0.0.1";
          MCP_PORT = "8762";
          MCP_ALLOWED_HOSTS = "${tailnetServiceHost "komodo"},${tailnetServiceHost "komodo"}:443,localhost,127.0.0.1";
          MCP_TRUST_PROXY = "loopback";
        };
        secrets = {
          KOMODO_URL = "komodoURL";
          KOMODO_API_KEY = "komodoKey";
          KOMODO_API_SECRET = "komodoSecret";
        };
      };

      proxmox = {
        port = 8763;
        command = "${pkgs.myPkgs.proxmox-mcp-plus}/bin/proxmox-mcp-plus";
        env = {
          MCP_HOST = "127.0.0.1";
          MCP_PORT = "8763";
          MCP_TRANSPORT = "STREAMABLE_HTTP";
          MCP_ALLOWED_HOSTS = "${tailnetServiceHost "proxmox"},${tailnetServiceHost "proxmox"}:*,localhost,localhost:*,127.0.0.1,127.0.0.1:*";
          MCP_ALLOWED_ORIGINS = "https://${tailnetServiceHost "proxmox"}";
          MCP_DNS_REBINDING_PROTECTION = "true";
          PROXMOX_HOST = "pve.${host.tailnetSuffix}";
          PROXMOX_USER = "mcp@pve";
          PROXMOX_TOKEN_NAME = "mcp-pve";
          PROXMOX_PORT = "443";
          PROXMOX_VERIFY_SSL = "true";
        };
        runtimeEnv = {
          PROXMOX_JOBS_SQLITE_PATH = "$STATE_DIRECTORY/jobs.sqlite3";
        };
        secrets = {
          PROXMOX_TOKEN_VALUE = "proxmoxMcpToken";
        };
      };

      nixos = {
        port = 8764;
        command = "${inputs.mcp-nixos-pr.packages.${host.system}.mcp-nixos}/bin/mcp-nixos";
        env = {
          MCP_NIXOS_TRANSPORT = "http";
          MCP_NIXOS_HOST = "127.0.0.1";
          MCP_NIXOS_PORT = "8764";
          MCP_NIXOS_PATH = "/mcp";
        };
      };
    };

    # systemd credentials let root-owned sops files stay root-only while each
    # DynamicUser service receives private read-only copies at runtime.
    credentialFiles = service:
      lib.mapAttrs (_envVar: secretName: config.sops.secrets.${secretName}.path)
      (service.secrets or {});

    # Each service declares the sops secrets it consumes; derive the sops secret
    # declarations from that same metadata so secret rotation restarts exactly
    # the affected MCP backend.
    secretRestartUnits =
      lib.foldlAttrs
      (
        acc: serviceName: service:
          lib.foldlAttrs
          (
            innerAcc: _envVar: secretName:
              innerAcc
              // {
                ${secretName}.restartUnits =
                  (innerAcc.${secretName}.restartUnits or [])
                  ++ ["mcp-host-${serviceName}.service"];
              }
          )
          acc
          (service.secrets or {})
      )
      {}
      services;

    # Credentials and fixed runtime settings are exported in the script rather
    # than Environment= so secret values never appear in evaluated unit attrs.
    readFileExports = name: service:
      lib.concatStrings (
        lib.mapAttrsToList (var: _path: ''
          if ${var}="$(${pkgs.coreutils}/bin/cat "$CREDENTIALS_DIRECTORY/${var}")"; then
            export ${var}
          else
            printf '[mcp-host-${name}] Failed to read credential %s\n' \
              ${lib.escapeShellArg var} >&2
            exit 1
          fi
        '') (credentialFiles service)
      );

    # Non-secret values stay in the unit script so the service definition remains
    # inspectable without revealing the sops-managed credential contents.
    envExports = service:
      lib.concatStrings (
        lib.mapAttrsToList (var: value: ''
          export ${var}=${lib.escapeShellArg value}
        '') (service.env or {})
      );

    # These values intentionally reference systemd-provided runtime variables
    # such as $STATE_DIRECTORY, so they are emitted without Nix shell escaping.
    runtimeEnvExports = service:
      lib.concatStrings (
        lib.mapAttrsToList (var: value: ''
          export ${var}="${value}"
        '') (service.runtimeEnv or {})
      );

    loadCredentials = service:
      lib.mapAttrsToList (var: path: "${var}:${path}") (credentialFiles service);

    mkMcpUnit = name: service: {
      description = "MCP host bridge for ${name}";
      wantedBy = ["multi-user.target"];
      after = ["network-online.target"];
      wants = ["network-online.target"];
      serviceConfig = {
        DynamicUser = true;
        LoadCredential = loadCredentials service;
        StateDirectory = "mcp-host-${name}";
        StateDirectoryMode = "0700";
        WorkingDirectory = "%S/mcp-host-${name}";
        Restart = "always";
        RestartSec = "5s";
      };
      script = ''
        export HOME="$STATE_DIRECTORY"
        ${readFileExports name service}
        ${envExports service}
        ${runtimeEnvExports service}
        exec ${lib.escapeShellArg service.command}
      '';
    };

    mkTailscaleUnit = name: service: let
      mcpUnit = "mcp-host-${name}.service";
      tailscaleService = "svc:mcp-${name}";
      localTarget = "http://127.0.0.1:${toString service.port}";
      lockFile = "/run/tailscale-serve-mcp.lock";
      startScript = pkgs.writeShellScript "tailscale-serve-mcp-${name}-start" ''
        ${pkgs.util-linux}/bin/flock ${lib.escapeShellArg lockFile} ${pkgs.bash}/bin/bash -euc ${lib.escapeShellArg ''
          ${tailscale} serve clear ${lib.escapeShellArg tailscaleService} || true
          ${tailscale} serve --service=${lib.escapeShellArg tailscaleService} --https=443 ${lib.escapeShellArg localTarget}
          ${tailscale} serve advertise ${lib.escapeShellArg tailscaleService}
        ''}
      '';
      stopScript = pkgs.writeShellScript "tailscale-serve-mcp-${name}-stop" ''
        ${pkgs.util-linux}/bin/flock ${lib.escapeShellArg lockFile} ${pkgs.bash}/bin/bash -euc ${lib.escapeShellArg ''
          ${tailscale} serve clear ${lib.escapeShellArg tailscaleService} || true
        ''}
      '';
    in {
      description = "Advertise ${tailscaleService} through Tailscale Services";
      wantedBy = ["multi-user.target"];
      after = [
        "tailscaled.service"
        "tailscaled-autoconnect.service"
        mcpUnit
      ];
      wants = ["tailscaled.service"];
      requires = [mcpUnit];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        # Tailscale serve updates are optimistic writes to one shared config;
        # serialize the whole clear/serve/advertise transaction to avoid etag
        # races when systemd starts multiple MCP advertisements in parallel.
        ExecStart = startScript;
        ExecStop = stopScript;
      };
    };
  in {
    assertions = [
      {
        assertion = config.services.tailscale.enable;
        message = "den.aspects.mcp-host requires services.tailscale.enable because it advertises Tailscale Services.";
      }
    ];

    sops.secrets = secretRestartUnits;

    systemd.services =
      lib.mapAttrs' (name: service: lib.nameValuePair "mcp-host-${name}" (mkMcpUnit name service)) services
      // lib.mapAttrs' (name: service: lib.nameValuePair "tailscale-serve-mcp-${name}" (mkTailscaleUnit name service)) services;
  };
}
