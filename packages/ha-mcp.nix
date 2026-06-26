{
  lib,
  python3Packages,
  fetchFromGitHub,
  nix-update-script,
}:
python3Packages.buildPythonApplication rec {
  pname = "ha-mcp";
  version = "7.9.0";
  pyproject = true;

  src = fetchFromGitHub {
    owner = "homeassistant-ai";
    repo = "ha-mcp";
    tag = "v${version}";
    hash = "sha256-DZ0CwgDWBRg/WWAER/nPSgYZLIYxK9iWyfAnhsuIDbw=";
    fetchSubmodules = true;
  };

  build-system = with python3Packages; [
    setuptools
  ];

  pythonRelaxDeps = true;

  dependencies = with python3Packages;
    [
      cryptography
      fastmcp
      httpx
      pydantic
      pydantic-monty
      python-dotenv
      truststore
      tzdata
      websockets
    ]
    ++ httpx.optional-dependencies.socks;

  # Tests require a running Home Assistant instance.
  doCheck = false;

  passthru.updateScript = nix-update-script {
    extraArgs = [
      "--flake"
      "--use-github-releases"
      "--version-regex=^v([0-9]+\\.[0-9]+\\.[0-9]+)$"
    ];
  };

  pythonImportsCheck = ["ha_mcp"];

  meta = {
    description = "MCP server for controlling Home Assistant via natural language";
    homepage = "https://github.com/homeassistant-ai/ha-mcp";
    changelog = "https://github.com/homeassistant-ai/ha-mcp/releases/tag/v${version}";
    license = lib.licenses.mit;
    maintainers = [lib.maintainers.jamiemagee];
    mainProgram = "ha-mcp";
  };
}
