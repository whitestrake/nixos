{
  pkgs,
  lib,
  stdenv,
  ...
}:
pkgs.beszel.overrideAttrs (oldAttrs: let
  version = "0.18.4";
in {
  inherit version;
  src = pkgs.fetchFromGitHub {
    owner = "henrygd";
    repo = "beszel";
    tag = "v${version}";
    hash = "sha256-Ugxy23bLrKIDclrYRFJc6Nq4Ak2S3OLeyMaxuRkS/tY=";
  };
  vendorHash = "sha256-O5gFpQ90AQFSAidPTWPrODZ4LWuwrOMpzEH/8HrjBig=";

  # Add checkFlags specifically for Darwin to bypass sandbox network restrictions
  checkFlags =
    oldAttrs.checkFlags or []
    ++ lib.optionals stdenv.hostPlatform.isDarwin [
      "-skip=TestStartServer"
    ];
})
