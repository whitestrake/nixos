{
  pkgs,
  stdenv,
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
in {
  inherit version src;
  vendorHash = "sha256-TVpZbK9V9/GqpVFcjF7QGD5XJJHzRgjVXZOImHQTR1k=";

  webui = oldAttrs.webui.overrideAttrs {
    npmDeps = oldAttrs.webui.npmDeps.overrideAttrs {
      outputHash = npmDepsHash;
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
      "TestConfigSyncWithTokens"
      "TestServiceUpdateCPUPercent"
    ];
  in ["-skip=^${builtins.concatStringsSep "$|^" skippedTests}$"];
})
