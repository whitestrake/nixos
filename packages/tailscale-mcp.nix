{
  fetchurl,
  lib,
  makeWrapper,
  nodejs,
  stdenvNoCC,
}:
stdenvNoCC.mkDerivation rec {
  pname = "tailscale-mcp";
  version = "0.15.0";

  src = fetchurl {
    url = "https://registry.npmjs.org/@yawlabs/tailscale-mcp/-/tailscale-mcp-${version}.tgz";
    hash = "sha256-oDVsF532fQOv1NCa86Ggg85sIh6rtNS2UI/+8f4kMnM=";
  };

  sourceRoot = "package";
  nativeBuildInputs = [makeWrapper];

  installPhase = ''
    runHook preInstall
    mkdir -p $out/lib/tailscale-mcp $out/bin
    cp -R dist package.json README.md LICENSE $out/lib/tailscale-mcp/
    makeWrapper ${nodejs}/bin/node $out/bin/tailscale-mcp \
      --add-flags "$out/lib/tailscale-mcp/dist/index.js"
    runHook postInstall
  '';

  meta = {
    description = "Tailscale MCP server for managing your tailnet from AI assistants";
    homepage = "https://github.com/YawLabs/tailscale-mcp";
    license = lib.licenses.mit;
    mainProgram = "tailscale-mcp";
  };
}
