{
  description = "zorg, a Zig compiler fork with a self-hosted AArch64 backend";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs }:
    let
      # Written by .github/workflows/release.yml on every tagged release.
      release = builtins.fromJSON (builtins.readFile ./nix/release.json);
      systems = [
        "aarch64-darwin"
        "x86_64-linux"
        "aarch64-linux"
      ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f system nixpkgs.legacyPackages.${system});
    in
    {
      packages = forAllSystems (
        system: pkgs: {
          # The release tarball, the same binary Homebrew installs.
          zorg = pkgs.callPackage ./nix/package-bin.nix { inherit release; };
          # Built from this checkout. A full LLVM compiler build: slow and memory hungry.
          zorg-src = pkgs.callPackage ./nix/package-src.nix { inherit self; };
          default = self.packages.${system}.zorg;
        }
      );

      overlays.default = final: prev: {
        zorg = final.callPackage ./nix/package-bin.nix { inherit release; };
        zorg-src = final.callPackage ./nix/package-src.nix { inherit self; };
      };

      apps = forAllSystems (
        system: pkgs: {
          default = {
            type = "app";
            program = "${self.packages.${system}.zorg}/bin/zorg";
          };
        }
      );

      devShells = forAllSystems (
        system: pkgs: {
          default = pkgs.mkShell { packages = [ self.packages.${system}.zorg ]; };
        }
      );

      # Only fetches the release tarball; zorg-src stays out of `nix flake check`.
      checks = forAllSystems (
        system: pkgs: {
          zorg = pkgs.runCommand "zorg-check" { nativeBuildInputs = [ self.packages.${system}.zorg ]; } ''
            export HOME=$TMPDIR ZORG_GLOBAL_CACHE_DIR=$TMPDIR/gc
            zorg version | grep -qF '${release.version}'
            zorg env | grep -qF '/lib/zorg"'
            cat >hello.zig <<'EOF'
            const std = @import("std");
            pub fn main(init: std.process.Init) !void {
                try std.Io.File.stdout().writeStreamingAll(init.io, "ok");
            }
            EOF
            zorg build-exe hello.zig
            [ "$(./hello)" = ok ]
            touch $out
          '';
        }
      );

      formatter = forAllSystems (system: pkgs: pkgs.nixfmt);
    };
}
