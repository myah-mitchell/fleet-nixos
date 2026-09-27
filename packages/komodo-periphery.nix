# Komodo Periphery, the agent Komodo Core manages a host's containers
# through, as the binary the Komodo project publishes with each release.
#
# nixpkgs builds Periphery from source, but at version 1. The fleet's Core
# is version 2, and the two speak different protocols, so the version is
# pinned here instead. To move to a newer release, change the version and
# replace the hash with the one nix prints when the old one no longer fits.
{
  lib,
  stdenv,
  fetchurl,
  autoPatchelfHook,
}:
stdenv.mkDerivation (finalAttrs: {
  pname = "komodo-periphery";
  version = "2.3.3";

  src = fetchurl {
    url = "https://github.com/moghtech/komodo/releases/download/v${finalAttrs.version}/periphery-x86_64";
    hash = "sha256-QLePN3YmeZr62DMSRqUB8HfU68+22QlolM9Vtk9tzxM=";
  };

  dontUnpack = true;

  # The binary expects its libraries where other distributions keep them.
  # The hook rewrites it to find them in the store.
  nativeBuildInputs = [ autoPatchelfHook ];
  buildInputs = [ stdenv.cc.cc.lib ];

  installPhase = ''
    runHook preInstall
    install -D -m 0755 $src $out/bin/periphery
    runHook postInstall
  '';

  meta = {
    description = "Agent that Komodo Core manages a host's containers through";
    homepage = "https://komo.do";
    license = lib.licenses.gpl3Only;
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
    platforms = [ "x86_64-linux" ];
    mainProgram = "periphery";
  };
})
