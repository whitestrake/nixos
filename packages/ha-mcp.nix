{
  lib,
  python3Packages,
  unstablePkgs,
  fetchFromGitHub,
  nix-update-script,
}: let
  # ha-mcp 8.5.0 needs httpx2 >= 2.5.0 for EventSource. Use the complete
  # unstable Python package set to avoid mixing interpreters and dependencies,
  # and return to stable automatically once its pinned httpx2 catches up.
  pythonPackages =
    if lib.versionAtLeast python3Packages.httpx2.version "2.5.0"
    then python3Packages
    else unstablePkgs.python3Packages;
in
  pythonPackages.buildPythonApplication rec {
    pname = "ha-mcp";
    version = "8.5.0";
    pyproject = true;

    src = fetchFromGitHub {
      owner = "homeassistant-ai";
      repo = "ha-mcp";
      tag = "v${version}";
      hash = "sha256-jbwV5uX6gHEislpraewKesnjVamCwYihOGA667DSaog=";
      fetchSubmodules = true;
    };

    build-system = with pythonPackages; [
      setuptools
    ];

    nativeCheckInputs = with pythonPackages; [
      pytestCheckHook
      pytest-asyncio
      pytest-timeout
    ];

    pythonRelaxDeps = true;

    dependencies = with pythonPackages;
      [
        cryptography
        fastmcp
        griffelib
        httpx
        httpx2
        pydantic
        pydantic-monty
        python-dotenv
        truststore
        tzdata
        websockets
      ]
      ++ httpx.optional-dependencies.socks;

    postInstall = ''
      test -f "$out/${pythonPackages.python.sitePackages}/ha_mcp/resources/skills-vendor/skills/home-assistant-best-practices/SKILL.md"
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
