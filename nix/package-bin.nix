{
  lib,
  stdenvNoCC,
  fetchurl,
  release,
}:

let
  system = stdenvNoCC.hostPlatform.system;
  asset = release.${system} or (throw "zorg: no prebuilt binary for ${system}");
in
stdenvNoCC.mkDerivation {
  pname = "zorg";
  inherit (release) version;

  src = fetchurl { inherit (asset) url hash; };

  dontConfigure = true;
  dontBuild = true;
  # A static musl ELF or an ad-hoc signed Mach-O: stripping or patching would
  # gain nothing on Linux and break the signature on macOS.
  dontFixup = true;

  # lib/zorg, not lib or lib/zig, so the std never collides with a zig in the
  # same profile. zorg resolves bin/zorg to the store and finds ../lib/zorg.
  installPhase = ''
    runHook preInstall
    install -Dm755 zorg $out/bin/zorg
    mkdir -p $out/lib/zorg
    cp -r lib/. $out/lib/zorg/
    install -Dm644 -t $out/share/doc/zorg LICENSE README.md
    runHook postInstall
  '';

  doInstallCheck = true;
  installCheckPhase = ''
    runHook preInstallCheck
    HOME=$TMPDIR ZORG_GLOBAL_CACHE_DIR=$TMPDIR/gc $out/bin/zorg version | grep -qF '${release.version}'
    runHook postInstallCheck
  '';

  meta = {
    description = "Zig compiler fork with a self-hosted AArch64 backend";
    homepage = "https://github.com/canassa/zorg";
    license = lib.licenses.mit;
    mainProgram = "zorg";
    platforms = [
      "aarch64-darwin"
      "x86_64-linux"
      "aarch64-linux"
    ];
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
  };
}
