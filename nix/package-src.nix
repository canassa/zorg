{
  lib,
  zig_0_17,
  self,
}:

let
  rev = self.shortRev or self.dirtyShortRev or "unknown";
  version = "0.17.1-dev+zorg.${rev}";
in
# nixpkgs' zig 0.17 build (cmake, zig1.wasm -> zig2 -> stage3), run on zorg's
# source. Its llvm-config based LLVM linking works with nixpkgs' LLVM.
zig_0_17.overrideAttrs (old: {
  pname = "zorg";
  inherit version;
  src = self;

  cmakeFlags = old.cmakeFlags ++ [ (lib.cmakeFeature "ZIG_VERSION" version) ];

  # zig2 and stage3 are zorg, which reads ZORG_*.
  preBuild = ''
    export ZIG_GLOBAL_CACHE_DIR="$TMPDIR/zig-cache"
    export ZORG_GLOBAL_CACHE_DIR="$TMPDIR/zig-cache"
  '';

  # No langref: nixpkgs builds it with stage3/bin/zig into a doc output.
  outputs = [ "out" ];
  postBuild = "";
  postInstall = "";

  installCheckPhase = ''
    runHook preInstallCheck
    HOME=$TMPDIR ZORG_GLOBAL_CACHE_DIR=$TMPDIR/gc $out/bin/zorg version | grep -qF '+zorg'
    HOME=$TMPDIR ZORG_GLOBAL_CACHE_DIR=$TMPDIR/gc $out/bin/zorg test \
      --cache-dir "$TMPDIR/zig-test-cache" -I $src/test $src/test/behavior.zig
    runHook postInstallCheck
  '';

  # nixpkgs' zig setup hook and cc wrappers call a `zig` binary.
  passthru = { };
  setupHook = null;

  meta = old.meta // {
    description = "Zig compiler fork with a self-hosted AArch64 backend, built from source";
    homepage = "https://github.com/canassa/zorg";
    mainProgram = "zorg";
    platforms = [
      "aarch64-darwin"
      "x86_64-linux"
      "aarch64-linux"
    ];
  };
})
