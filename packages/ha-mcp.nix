{
  lib,
  python3Packages,
  fetchFromGitHub,
  nix-update-script,
}:
python3Packages.buildPythonApplication rec {
  pname = "ha-mcp";
  version = "8.4.3";
  pyproject = true;

  src = fetchFromGitHub {
    owner = "homeassistant-ai";
    repo = "ha-mcp";
    tag = "v${version}";
    hash = "sha256-qS18zj3QT/GuaRq2Xulwao2ONHnlgw4lUDixY2hrP+M=";
    fetchSubmodules = true;
  };

  build-system = with python3Packages; [
    setuptools
  ];

  nativeCheckInputs = with python3Packages; [
    pytestCheckHook
    pytest-asyncio
    pytest-timeout
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

  postInstall = ''
    test -f "$out/${python3Packages.python.sitePackages}/ha_mcp/resources/skills-vendor/skills/home-assistant-best-practices/SKILL.md"
  '';

  doCheck = true;
  enabledTestPaths = [
    "tests/src/unit/test_resources.py"
    "tests/src/unit/test_skill_loader.py"
  ];

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
