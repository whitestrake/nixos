{
  pkgs,
  stdenv,
  nix-update-script,
  unstablePkgs ? pkgs,
  ...
}:
unstablePkgs.beszel.overrideAttrs (oldAttrs: let
  version = "0.18.7";
  src = pkgs.fetchFromGitHub {
    owner = "henrygd";
    repo = "beszel";
    tag = "v${version}";
    hash = "sha256-pVZ1ru9++BypZ3EwoE8clqJowXj1/CMiJxKaC+UY9VE=";
  };
  npmDepsHash = "sha256-mYAD8FrQwa+F/VgGxFpe8vqucfZaM0PmY+gJJqw1IKk=";
  webui = oldAttrs.webui.overrideAttrs {
    inherit version src;
    npmDeps = oldAttrs.webui.npmDeps.overrideAttrs {
      outputHash = npmDepsHash;
    };
  };
in {
  inherit version src webui;
  vendorHash = "sha256-TVpZbK9V9/GqpVFcjF7QGD5XJJHzRgjVXZOImHQTR1k=";

  passthru =
    (oldAttrs.passthru or {})
    // {
      inherit webui;
      updateScript = nix-update-script {
        extraArgs = [
          "--flake"
          "--subpackage"
          "webui"
        ];
      };
    };

  # Re-set the testing build tag lost through overrideAttrs; required for
  # internal/tests helpers (//go:build testing) used by hub api_test.go.
  tags = ["testing"];

  # Upstream nixpkgs does not test on Darwin; many tests require network
  # access or GPU tools unavailable in the sandbox.
  doCheck = !stdenv.hostPlatform.isDarwin;

  checkFlags = let
    skippedTests = [
      "TestCollectorStartHelpers/nvtop_collector"
      "TestApiRoutesAuthentication/GET_/update_-_shouldn't_exist_without_CHECK_UPDATES_env_var"
      "TestConfigSyncWithTokens"
      "TestServiceUpdateCPUPercent/subsequent_call_calculates_CPU_percentage"
    ];
  in [
    "-skip=^${builtins.concatStringsSep "$|^" skippedTests}$"
    "-tags=testing"
  ];
})
