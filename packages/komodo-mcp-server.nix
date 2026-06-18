{
  lib,
  buildNpmPackage,
  fetchFromGitHub,
  nodejs_22,
}:
(buildNpmPackage.override {nodejs = nodejs_22;}) rec {
  pname = "komodo-mcp-server";
  version = "1.4.0";

  src = fetchFromGitHub {
    owner = "MP-Tool";
    repo = "komodo-mcp-server";
    tag = version;
    hash = "sha256-qjPIGJ7Hsxs/cMHifWOPAiMhLWXFWJxX4cOHbavs46A=";
  };

  npmDepsHash = "sha256-VWZFTPTbQMSPPDn8Kq34JZEZuo29BqmfY769nbNiPG4=";
  npmBuildScript = "build:prod";

  meta = {
    description = "Model Context Protocol Server for Komodo";
    homepage = "https://github.com/MP-Tool/komodo-mcp-server";
    license = lib.licenses.gpl3Only;
    mainProgram = "komodo-mcp-server";
  };
}
