{
  lib,
  fetchPypi,
  nix-update,
  python3,
  python3Packages,
  rustPlatform,
  writeShellApplication,
}:
python3Packages.buildPythonApplication rec {
  pname = "proxmox-mcp-plus";
  version = "0.5.21";
  pyproject = true;

  src = fetchPypi {
    pname = "proxmox_mcp_plus";
    inherit version;
    hash = "sha256-YiXgtz4IlgdL0ntlyj43xH+tS1tDRlBnNsPZhXG/QlU=";
  };

  build-system = with python3Packages; [
    hatchling
  ];

  dependencies = with python3Packages;
    [
      anyio
      fastapi
      mcp
      paramiko
      proxmoxer
      pydantic
      (
        # Remove the fallback once nixpkgs provides Monty >= 0.0.22.
        if lib.versionAtLeast pydantic-monty.version "0.0.22"
        then pydantic-monty
        else let
          version = "0.0.22";
          src = pydantic-monty.src.override {
            tag = "v${version}";
            hash = "sha256-ZlCj71rUXOeTbE29mas2K+xcSowvZY1dpzuYacMzTkU=";
          };
          cargoDeps = rustPlatform.fetchCargoVendor {
            pname = "pydantic-monty";
            inherit version src;
            hash = "sha256-hLZnEUCR5PAZ71qt1UFnkDdFandKzTQXvINNUdpDbAQ=";
          };
          client = pydantic-monty.overridePythonAttrs (_: {
            pname = "pydantic-monty-client";
            inherit version src cargoDeps;
            # The metapackage check below exercises the client with its worker.
            doCheck = false;
          });
          runtime = buildPythonPackage {
            pname = "pydantic-monty-runtime";
            inherit version src cargoDeps;
            pyproject = true;
            nativeBuildInputs = [
              rustPlatform.cargoSetupHook
              rustPlatform.maturinBuildHook
            ];
            maturinBuildFlags = ["-m" "crates/monty-runtime/Cargo.toml"];
            doCheck = false;
          };
        in
          buildPythonPackage {
            pname = "pydantic-monty";
            inherit version src;
            pyproject = true;
            build-system = [hatchling];
            postUnpack = "sourceRoot+=/packages/pydantic-monty";
            dependencies = [client runtime];
            nativeCheckInputs = [runtime];
            installCheckPhase = ''
              runHook preInstallCheck
              ${python.interpreter} - <<'PYTHON'
              from pydantic_monty import Monty
              with Monty() as pool, pool.checkout() as session:
                  assert session.feed_run("1 + 2") == 3
              PYTHON
              runHook postInstallCheck
            '';
            pythonImportsCheck = ["pydantic_monty"];
          }
      )
      requests
      uvicorn
    ]
    ++ uvicorn.optional-dependencies.standard;

  pythonRelaxDeps = [
    "paramiko"
    # Accept newer nixpkgs releases; the dependency selection enforces the floor.
    "pydantic-monty"
  ];

  # This deployment uses the native MCP server entrypoint. Upstream declares mcpo
  # unconditionally for the OpenAPI proxy, but the MCP entrypoint does not import
  # it and nixpkgs does not currently package it.
  pythonRemoveDeps = [
    "mcpo"
  ];

  # Upstream's unit and integration tests are not included in the PyPI sdist,
  # and the live checks require a Proxmox environment.
  doCheck = false;

  # Update only to the newest release whose declared dependencies the evaluated
  # package set satisfies on every system.
  passthru.updateScript = lib.getExe (writeShellApplication {
    name = "update-proxmox-mcp-plus";
    runtimeInputs = [nix-update (python3.withPackages (ps: [ps.packaging]))];
    text = ''
      context="$(mktemp)"
      trap 'rm -f "$context"' EXIT
      nix eval --json .#packages \
        --apply 'systems: builtins.mapAttrs (system: packages: let p = packages.proxmox-mcp-plus; in { version = p.version; python = (builtins.head p.dependencies).pythonModule.version; dependencies = map (d: { name = d.pname or d.name; version = d.version or null; }) p.dependencies; relax = p.pythonRelaxDeps or []; remove = p.pythonRemoveDeps or []; }) systems' \
        > "$context"
      selected="$(python3 ${../.github/scripts/select_proxmox_mcp_plus.py} "$context")"
      if [ -n "$selected" ]; then
        nix-update --flake --version "$selected" proxmox-mcp-plus
      fi
    '';
  });

  pythonImportsCheck = [
    "proxmox_mcp"
  ];

  meta = {
    description = "Enhanced Proxmox MCP server";
    homepage = "https://github.com/RekklesNA/ProxmoxMCP-Plus";
    changelog = "https://github.com/RekklesNA/ProxmoxMCP-Plus/releases/tag/v${version}";
    license = lib.licenses.mit;
    mainProgram = "proxmox-mcp-plus";
  };
}
