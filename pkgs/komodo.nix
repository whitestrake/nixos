{pkgs}:
pkgs.komodo.overrideAttrs (oldAttrs: rec {
  version = "1.19.5";
  src = pkgs.fetchFromGitHub {
    owner = "moghtech";
    repo = "komodo";
    tag = "v${version}";
    hash = "sha256-dLBgdcrIp5QM2TVIa86qX7m1c5n+qOIQJtqJPGvIZ+0=";
  };
  cargoDeps = oldAttrs.cargoDeps.overrideAttrs {
    inherit src;
    outputHash = "sha256-jf/Jp28g3inGn5jQp3cACdhl//tbXTMc1vP1K3g/CyQ=";
  };
})
