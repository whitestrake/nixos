{
  lib,
  unstablePkgs,
}: let
  # Komodo's web UI, which nixpkgs' komodo package does not build. Upstream
  # publishes it as a data-only image (FROM scratch, one layer holding /ui),
  # and Core serves those files from KOMODO_UI_PATH. The version follows
  # unstablePkgs.komodo, so Core and UI move together with flake.lock.
  pkgs = unstablePkgs;
  inherit (pkgs.komodo) version;

  image = "moghtech/komodo-ui";

  # Maintained by passthru.updateScript, which the combined update workflow
  # runs in the same run that bumps flake.lock. The pin is the image layer's
  # digest: upstream's own content address for the files.
  pinnedVersion = "2.3.3";
  layerDigest = "sha256:4058d0d3ccd489d941500ef40caf8560e4f55821abf9df962745e63a49d1e804";

  # Only the fetch's outputHash consults the pin, so evaluating .version or
  # .updateScript never fails and the update script can add a missing pin.
  pinnedHash =
    if pinnedVersion == version
    then lib.removePrefix "sha256:" layerDigest
    else throw "komodo-ui: no image pin for Komodo ${version} (pinned ${pinnedVersion}); run its update script";

  layer = pkgs.stdenvNoCC.mkDerivation {
    name = "komodo-ui-${version}-layer.tar.gz";
    nativeBuildInputs = [pkgs.curl pkgs.jq];
    # ghcr requires a bearer token even for public images; the anonymous pull
    # token needs no credentials. The blob redirects to a signed CDN URL.
    buildCommand = ''
      token="$(curl --fail --silent --show-error --retry 3 \
        "https://ghcr.io/token?scope=repository:${image}:pull" | jq -r .token)"
      curl --fail --silent --show-error --retry 3 --location \
        --header "Authorization: Bearer $token" \
        --output "$out" \
        "https://ghcr.io/v2/${image}/blobs/${layerDigest}"
    '';
    SSL_CERT_FILE = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
    impureEnvVars = lib.fetchers.proxyImpureEnvVars;
    outputHashMode = "flat";
    outputHashAlgo = "sha256";
    outputHash = pinnedHash;
  };

  updateScript = pkgs.writeShellApplication {
    name = "update-komodo-ui";
    runtimeInputs = with pkgs; [curl jq gnused];
    text = ''
      # Pins the image layer for the Komodo version nixpkgs-unstable provides,
      # never a newer one. Runs from the repository root.
      file=packages/komodo-ui.nix
      version="${version}"
      repo="${image}"

      token="$(curl --fail --silent --show-error --retry 3 \
        "https://ghcr.io/token?scope=repository:$repo:pull" | jq -r .token)"
      accept="application/vnd.oci.image.index.v1+json,application/vnd.docker.distribution.manifest.list.v2+json,application/vnd.oci.image.manifest.v1+json,application/vnd.docker.distribution.manifest.v2+json"
      manifest() {
        curl --fail --silent --show-error --retry 3 \
          --header "Authorization: Bearer $token" --header "Accept: $accept" \
          "https://ghcr.io/v2/$repo/manifests/$1"
      }

      doc="$(manifest "$version")"
      # A multi-platform index: take the linux/amd64 image. The UI is
      # architecture-independent, and attestation entries are unknown/unknown.
      if jq -e '.manifests' <<<"$doc" >/dev/null; then
        child="$(jq -r '[.manifests[] | select(.platform.os == "linux" and .platform.architecture == "amd64")][0].digest // empty' <<<"$doc")"
        if [ -z "$child" ]; then
          echo "update-komodo-ui: $repo:$version has no linux/amd64 image" >&2
          exit 1
        fi
        doc="$(manifest "$child")"
      fi

      if [ "$(jq '.layers | length' <<<"$doc")" != 1 ]; then
        echo "update-komodo-ui: expected one layer in $repo:$version" >&2
        exit 1
      fi
      digest="$(jq -r '.layers[0].digest' <<<"$doc")"
      if ! [[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]]; then
        echo "update-komodo-ui: unexpected layer digest: $digest" >&2
        exit 1
      fi

      sed -i \
        -e "s|^  pinnedVersion = \".*\";|  pinnedVersion = \"$version\";|" \
        -e "s|^  layerDigest = \".*\";|  layerDigest = \"$digest\";|" \
        "$file"
      echo "komodo-ui pinned to $repo:$version layer $digest"
    '';
  };
in
  pkgs.stdenvNoCC.mkDerivation {
    pname = "komodo-ui";
    inherit version;
    src = layer;

    dontUnpack = true;
    installPhase = ''
      runHook preInstall
      mkdir -p "$out"
      tar -xzf "$src" -C "$out" --strip-components=1 ui
      test -f "$out/index.html"
      runHook postInstall
    '';

    passthru.updateScript = [(lib.getExe updateScript)];

    meta = {
      description = "Web UI for Komodo Core, from upstream's published komodo-ui image";
      homepage = "https://komo.do";
      inherit (pkgs.komodo.meta) license;
      platforms = lib.platforms.linux;
    };
  }
