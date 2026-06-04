{
  lib,
  buildGoModule,
  fetchFromGitHub,
}:
buildGoModule rec {
  pname = "netronome";
  version = "0.11.0";

  src = fetchFromGitHub {
    owner = "autobrr";
    repo = "netronome";
    tag = "v${version}";
    hash = "sha256-gh05b9o1o09KGyXDocibopXY7FC4mq1nuM08+7cnNtM=";
  };

  vendorHash = "sha256-xokfOOxA1ZbkxzABbTEWXno6ZOTZYaWDCSgjBW99JOE=";

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
