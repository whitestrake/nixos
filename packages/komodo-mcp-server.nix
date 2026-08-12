{
  lib,
  buildNpmPackage,
  fetchFromGitHub,
}:
buildNpmPackage rec {
  pname = "komodo-mcp-server";
  version = "1.5.0";

  src = fetchFromGitHub {
    owner = "MP-Tool";
    repo = "komodo-mcp-server";
    tag = version;
    hash = "sha256-lU8zjoUn54Su1bdbvZruKhVgAKIEfZkXUMl5US3i/Ck=";
  };

  npmDepsHash = "sha256-hEJbZ+dDumkJTpxfuT4Xf1tSBAn26w5Aeoi4lwHxsyA=";
  npmBuildScript = "build:prod";

  meta = {
    description = "Model Context Protocol Server for Komodo";
    homepage = "https://github.com/MP-Tool/komodo-mcp-server";
    license = lib.licenses.gpl3Only;
    mainProgram = "komodo-mcp-server";
  };
}
