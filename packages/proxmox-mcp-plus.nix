{
  lib,
  fetchPypi,
  python3Packages,
  rustPlatform,
  nix-update-script,
}:
python3Packages.buildPythonApplication rec {
  pname = "proxmox-mcp-plus";
  version = "0.5.23";
  pyproject = true;

  src = fetchPypi {
    pname = "proxmox_mcp_plus";
    inherit version;
    hash = "sha256-WH74+wNv+7F/yn9ro9bqGReJGa1Xd8xja2Vp7s8/JDc=";
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

  passthru.updateScript = nix-update-script {
    extraArgs = [
      "--flake"
    ];
  };

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
