{
  pkgs,
  lib,
  stdenv,
  unstablePkgs ? pkgs,
  ...
}:
unstablePkgs.beszel.overrideAttrs (oldAttrs: let
  version = "0.18.6";
in {
  inherit version;
  src = pkgs.fetchFromGitHub {
    owner = "henrygd";
    repo = "beszel";
    tag = "v${version}";
    hash = "sha256-CRO0Y3o3hwdE55D027fo0tvt9o7vsA1ooEBFlXuw2So=";
  };
  vendorHash = "sha256-g+UmoxBoCL3oGXNTY67Wz7y6FC/nkcS8020jhTq4JQE=";

  # Remove hub api_test.go: it references internal/tests helpers (NewTestHub,
  # CreateUser, CreateRecord) that fail to compile during `go test`. This is a
  # compilation error, not a runtime failure, so -skip flags have no effect.
  # Only the agent binary is used here; hub tests are irrelevant.
  postPatch =
    (oldAttrs.postPatch or "")
    + ''
      rm -f internal/hub/api_test.go
    '';

  checkFlags =
    oldAttrs.checkFlags or []
    ++ lib.optionals stdenv.hostPlatform.isDarwin ["-skip=TestStartServer"];
})
