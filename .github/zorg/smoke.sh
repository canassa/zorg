#!/usr/bin/env bash
# Smoke-tests a zorg release binary on the machine it runs on.
# Usage: smoke.sh /path/to/zorg EXPECTED_VERSION [SOURCE_TREE]
# SOURCE_TREE (default: the repo this script lives in) provides test/behavior.zig.
set -euxo pipefail

Z=$(cd "$(dirname "$1")" && pwd -P)/$(basename "$1")
WANT=$2
SRC=${3:-$(cd "$(dirname "$0")/../.." && pwd -P)}
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

arm64=false
case "$(uname -m)" in arm64 | aarch64) arm64=true ;; esac

export ZORG_GLOBAL_CACHE_DIR="$T/gc" ZORG_LOCAL_CACHE_DIR="$T/lc"
# Settings meant for an upstream zig must not reach zorg.
export ZIG_LIB_DIR=/nonexistent ZIG_GLOBAL_CACHE_DIR=/nonexistent ZIG_LOCAL_CACHE_DIR=/nonexistent

[ "$("$Z" version)" = "$WANT" ]

"$Z" env >"$T/env.zon"
grep -qF ".version = \"$WANT\"" "$T/env.zon"
grep -qF ".lib_dir = \"$(dirname "$Z")/lib\"" "$T/env.zon"
grep -qF ".global_cache_dir = \"$T/gc\"" "$T/env.zon"
grep -qF '.ZORG_GLOBAL_CACHE_DIR = ' "$T/env.zon"
(unset ZORG_GLOBAL_CACHE_DIR XDG_CACHE_HOME && HOME="$T/home" "$Z" env | grep -qF ".global_cache_dir = \"$T/home/.cache/zorg\"")

# A symlinked binary still finds the std next to the real one.
ln -s "$Z" "$T/zorg-link"
"$T/zorg-link" env | grep -qF ".lib_dir = \"$(dirname "$Z")/lib\""

cd "$T"
cat >hello.zig <<'EOF'
const std = @import("std");
pub fn main(init: std.process.Init) !void {
    try std.Io.File.stdout().writeStreamingAll(init.io, "Hello, world!");
}
EOF
for O in Debug ReleaseFast; do
    "$Z" build-exe hello.zig -fllvm -O "$O" --name "h-$O"
    [ "$("./h-$O")" = "Hello, world!" ]
done
if $arm64; then # zorg's own aarch64 backend
    for O in Debug ReleaseFast; do
        "$Z" build-exe hello.zig -fno-llvm -O "$O" --name "h-self-$O"
        [ "$("./h-self-$O")" = "Hello, world!" ]
    done
fi
for t in aarch64-macos x86_64-linux aarch64-linux x86_64-windows; do
    "$Z" build-exe hello.zig -target "$t" --name "h-$t"
done

printf '#include <stdio.h>\nint main(void) { fputs("hi", stdout); return 0; }\n' >hello.c
"$Z" cc hello.c -o hello-c
[ "$(./hello-c)" = hi ]

# The build system runs against the zorg binary that started it.
mkdir proj
(cd proj && "$Z" init && "$Z" build && "$Z" build test && [ -x zig-out/bin/proj ])

# An upstream zig on PATH is untouched.
if command -v zig >/dev/null; then
    [[ "$(zig version)" != *zorg* ]]
fi

"$Z" test "$SRC/test/behavior.zig" -fllvm
if $arm64; then
    "$Z" test "$SRC/test/behavior.zig" -fno-llvm
fi

echo "smoke: all checks passed for $WANT"
