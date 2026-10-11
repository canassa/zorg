# zorg

A fork of upstream Zig's `0.17.x` branch (not upstream master). The fork's own work is the
self-hosted AArch64 backend (`src/codegen/aarch64.zig`, `src/codegen/aarch64/`), the rename to
`zorg`, and release tooling. Upstream: https://codeberg.org/ziglang/zig (remote `upstream`,
push disabled).

zorg is rebased onto new upstream 0.17.x releases, so every line changed in an upstream file costs
work later. Keep those diffs small, and put fork-only things in their own files (`.github/`,
`nix/`, `flake.nix`). Never edit upstream's `ci/` or `.forgejo/`.

## The rename (easy to break)

- The binary is `zorg`, the std installs to `lib/zorg`, the global cache is `~/.cache/zorg`.
- Environment variables are read as `ZORG_*` through `std.zig.EnvVar.name()`. Always go through
  `EnvVar`; never read a `"ZIG_..."` string directly. `ZIG_PROGRESS` and `ZIG_EXE` keep their
  names on purpose (a protocol with child processes, and an output for `zorg run`/`test`).
- Every version string carries `+zorg` (`0.17.1-dev.N+zorg.<hash>` from git, `0.17.1+zorg.N` for
  releases), so zorg never reports, or shares cache entries with, an upstream version.
- Unchanged on purpose: `build.zig`, `build.zig.zon`, `.zig-cache`, `zig-out`, and the field names
  in `zorg env` (editor tooling parses them).

## Building the compiler

- Needs LLVM 22. Bootstrap with the official zig 0.17.0. The exact release build (flags, static
  LLVM bundles) is the `build` job in `.github/workflows/release.yml`.
- The bootstrap compiler is upstream zig and reads `ZIG_*`; the build runner, compiled from this
  tree's std, reads `ZORG_*`. Set both cache variables and `ZIG_LIB_DIR=$PWD/lib`; don't pass
  `--zig-lib-dir`/`--global-cache-dir` to `zig build`.
- Never build the compiler with upstream's self-hosted x86_64/aarch64 backends: memory runs away
  and has crashed the host. Use LLVM (`-Denable-llvm`) or a zorg compiler.
- Give every compiler build its own `-Dversion-string` and its own global cache dir. compiler_rt
  and other cached sub-builds are keyed by the version string, so two compilers with the same
  string silently reuse each other's output.

## Testing

- **Red test first.** Every backend bug (miscompile, crash, wrong output, assertion) first gets a
  minimal test in `test/behavior/` that fails on the affected backend and passes with LLVM. Fix
  it, then commit the test with the fix. Never hide a new failure behind a backend skip.
- Behavior tests, on an aarch64 host: `zorg test test/behavior.zig -fno-llvm`, and `-fllvm` to
  compare. For codegen changes also run with `-fstrip` (it keeps arguments in registers and
  exposes liveness bugs), with a Debug compiler: its assertions catch what a ReleaseFast
  compiler silently miscompiles.
- One std test: `zorg test lib/std/std.zig --zig-lib-dir lib --test-filter "<name>"`.
- Verify at runtime, not only that code compiles. For ABI work, test interop with LLVM-compiled
  code or `zorg cc` in both directions.
- Don't run the full `zig build test` matrix or open-ended fuzzing locally; it takes hours.

## Backend notes

- `Select.zig` selects instructions backwards over AIR. Values are split into parts that live in
  registers or stack slots (`Value.zig`: `PartIterator`, `FieldPartIterator`, `defReg`,
  `matReg`); `CallAbiIterator.zig` assigns arguments and returns; `Promotion.zig` keeps locals in
  callee-saved registers. Read these before changing selection. The struct, tuple, union, array
  and optional paths are near-copies: when you fix one, check the others.
- Unsupported shapes return `isel.fail(...)` with a clear message. An assertion that user code
  can trigger is a bug: a compile error is fine, memory corruption is not.
- The x86_64 backend (`src/codegen/x86_64/CodeGen.zig`) is the reference for features it already
  has. Port the approach, not the encodings. ABI: AAPCS64, plus Apple arm64's differences
  (variadic arguments, stack argument alignment).
- Match the surrounding style in `Select.zig`. No drive-by refactors.

## Commits and history

- Subject: one emoji plus a short summary (✨ feature, 🐛 fix, ⚡ optimization, ✅ tests,
  📝 docs, 👷 CI, ❄️ nix, 🍺 Homebrew). The body explains why, and lists what was tested with
  counts (for example behavior passed/failed before and after).
- master is published and has releases: never force-push it. Pull before pushing, because the
  release workflow commits `nix/release.json` to master.

## Releases

- Push a tag `v<build.zig version>-zorg.<n>` (for example `v0.17.1-zorg.2`); `release.yml`
  builds, smoke-tests (`.github/zorg/smoke.sh`), publishes, updates the Homebrew tap and
  `nix/release.json`. A `nightly` pre-release is rebuilt from master daily.
- The Homebrew formula comes from `.github/zorg/zorg.rb.in`. Change it there, never in
  `canassa/homebrew-zorg`.
- The LLVM bundle sha256s in `release.yml` are pinned by hand (ziglang.org publishes none);
  update them deliberately when the upstream base changes.
