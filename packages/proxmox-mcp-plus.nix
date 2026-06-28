{
  lib,
  fetchPypi,
  python3Packages,
  nix-update-script,
}:
python3Packages.buildPythonApplication rec {
  pname = "proxmox-mcp-plus";
  version = "0.5.8";
  pyproject = true;

  src = fetchPypi {
    pname = "proxmox_mcp_plus";
    inherit version;
    hash = "sha256-cI3eu43kiEcdlPRTJNPZa2hWY4ZSNPM+9RGCBd5Eco8=";
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
      requests
      uvicorn
    ]
    ++ uvicorn.optional-dependencies.standard;

  pythonRelaxDeps = [
    "paramiko"
  ];

  # This deployment uses the native stdio MCP server. Upstream declares mcpo
  # unconditionally for the OpenAPI proxy, but the stdio entrypoint does not
  # import it and nixpkgs does not currently package it.
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
