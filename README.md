<h1 align="center">
  <br>
  <a href="https://github.com/canassa/zorg">
    <picture>
      <source srcset="branding/zorg.avif" type="image/avif">
      <img src="branding/zorg.svg" alt="Zorg" width="384">
    </picture>
  </a>
  <br>
  Zorg
  <br>
</h1>

<h4 align="center">Zig, but with fewer humans and more evil robots 🤖</h4>

<p align="center">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue.svg" alt="License: MIT"></a>
  <a href="https://codeberg.org/ziglang/zig"><img src="https://img.shields.io/badge/fork%20of-Zig-f7a41d.svg" alt="Fork of Zig"></a>
  <img src="https://img.shields.io/badge/robots-welcome-red.svg" alt="Robots welcome">
</p>

<p align="center">
  <a href="#work-done-so-far">Work Done So Far</a> •
  <a href="#why">Why</a> •
  <a href="#contributing">Contributing</a> •
  <a href="#credits">Credits</a> •
  <a href="#license">License</a>
</p>

**Zorg** is a fork of [Zig](https://ziglang.org/) 0.17. I made it because I needed a working
AArch64 backend.

Zorg picks up Zig's experimental self-hosted AArch64 backend and takes it to the point where it
can compile Zig itself.

## Work Done So Far

* The self-hosted AArch64 backend can compile Zig itself (self-hosting).
* Many bug fixes in the AArch64 backend, each covered by a behavior test.
* Faster compiled binaries: from 32% of LLVM's speed to 51% (see below).

The speed numbers come from running a Zorg-compiled version of
[Beni](https://github.com/canassa/beni) against an LLVM-compiled one on the same workload.

## Why

Zig's self-hosted backend is built for development. It compiles extremely fast, which keeps
iteration times low (great for agentic work! 🤖). The downside is that its output isn't
optimized, so the binaries are slow, and slow binaries mean slow tests and slow CI/CD pipelines.

Zorg keeps the fast compile times and makes the output faster by adding several optimizations,
such as automatic inlining of small functions, keeping locals in registers instead of on the
stack, and inlining small memory copies.

## Contributing

Just open a pull request. AI contributions are welcome. Resistance is futile 🤖

One rule: every bug fix comes with a failing test first.

## Credits

Zorg is a fork of [Zig](https://ziglang.org/), created by Andrew Kelley and the
Zig contributors. All the hard work upstream is theirs.

## License

MIT. See [LICENSE](LICENSE).

The original Zig code is Copyright (c) Zig contributors and is distributed under
the MIT License. Third-party code bundled in `lib/` keeps its own license; see the
license files in each directory.

Zorg is an independent project. It is not affiliated with, endorsed by, or
sponsored by the Zig Software Foundation. The name "Zig" is used here only to
describe where this fork comes from.
