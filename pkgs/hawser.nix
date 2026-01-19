{
  lib,
  buildGoModule,
  fetchFromGitHub,
}:
buildGoModule rec {
  pname = "hawser";
  version = "0.2.24";

  src = fetchFromGitHub {
    owner = "Finsys";
    repo = "hawser";
    tag = "v${version}";
    hash = "sha256-1MIXHORAlm9dg1wHcDv89gFP/ehRNkb/AJgQNZuwrGk=";
  };

  vendorHash = "sha256-Edr6beVlkHcHj1Jx4vxnJBeVov5sSPKO8dR1G2fQ7l8=";

  subPackages = ["cmd/hawser"];

  ldflags = [
    "-s"
    "-w"
    "-X main.version=${version}"
  ];

  meta = {
    description = "Lightweight Go agent for Dockhand Docker host management";
    homepage = "https://github.com/Finsys/hawser";
    license = lib.licenses.mit;
    mainProgram = "hawser";
  };
}
