{
  lib,
  buildGoModule,
  fetchFromGitHub,
}:
buildGoModule rec {
  pname = "netronome";
  version = "0.8.0";

  src = fetchFromGitHub {
    owner = "autobrr";
    repo = "netronome";
    tag = "v${version}";
    hash = "sha256-MGMHOvI+Tw92cadZXyFNXhSC+FMxCYlKwnBp1+OGaf0=";
  };

  vendorHash = "sha256-oQ72RJXJHavl/LYIGZpaqnA4VFYTLaUmYF9hijBzr0c=";

  subPackages = ["cmd/netronome"];

  tags = ["nosmart"];

  ldflags = [
    "-s"
    "-w"
    "-X main.version=${version}"
  ];

  meta = {
    description = "Modern network speed testing and monitoring tool";
    homepage = "https://github.com/autobrr/netronome";
    license = lib.licenses.gpl2Only;
    mainProgram = "netronome";
  };
}
