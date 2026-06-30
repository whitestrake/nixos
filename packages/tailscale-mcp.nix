{
  fetchurl,
  lib,
  makeWrapper,
  nodejs,
  stdenvNoCC,
}:
stdenvNoCC.mkDerivation rec {
  pname = "tailscale-mcp";
  version = "0.13.2";

  src = fetchurl {
    url = "https://registry.npmjs.org/@yawlabs/tailscale-mcp/-/tailscale-mcp-${version}.tgz";
    hash = "sha512-IcHg4bzbMq4KasbPM1ZfOx4ZroJgXPO475mA1kjYna/5gI9PWMtshBMgvgIzS3QfuUjWjwsTzGMaJAF35L8k/g==";
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
