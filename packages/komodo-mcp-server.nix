{
  lib,
  buildNpmPackage,
  fetchFromGitHub,
}:
buildNpmPackage rec {
  pname = "komodo-mcp-server";
  version = "1.4.1";

  src = fetchFromGitHub {
    owner = "MP-Tool";
    repo = "komodo-mcp-server";
    tag = version;
    hash = "sha256-HI45wEn+fdpkJPeNuO6pCh7CAwzgx3qAiKFz3aCm1YA=";
  };

  npmDepsHash = "sha256-7GqPQFtplcPXVQvsS1i+oyxu31AnPOw0wqX7jPuwBy0=";
  npmBuildScript = "build:prod";

  meta = {
    description = "Model Context Protocol Server for Komodo";
    homepage = "https://github.com/MP-Tool/komodo-mcp-server";
    license = lib.licenses.gpl3Only;
    mainProgram = "komodo-mcp-server";
  };
}
