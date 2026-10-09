const std = @import("std");
const builtin = @import("builtin");
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

const is_x86_64_linux = builtin.cpu.arch == .x86_64 and builtin.os.tag == .linux;

comptime {
    if (builtin.zig_backend != .stage2_arm and
        !(builtin.zig_backend == .stage2_c and builtin.os.tag == .windows) and // MSVC doesn't support inline assembly
        is_x86_64_linux)
    {
        asm (
            \\.globl this_is_my_alias;
        );
        // test multiple asm per comptime block
        asm (
            \\.type this_is_my_alias, @function;
            \\.set this_is_my_alias, derp;
        );
    } else if (builtin.zig_backend == .stage2_spirv) {
        asm (
            \\%a = OpString "hello there"
        );
    }
}

test "module level assembly" {
    if (builtin.zig_backend == .stage2_wasm) return error.SkipZigTest; // TODO
    if (builtin.zig_backend == .stage2_x86_64) return error.SkipZigTest; // TODO
    if (builtin.zig_backend == .stage2_arm) return error.SkipZigTest; // TODO
    if (builtin.zig_backend == .stage2_sparc64) return error.SkipZigTest; // TODO

    if (builtin.zig_backend == .stage2_c and builtin.os.tag == .windows) return error.SkipZigTest; // MSVC doesn't support inline assembly

    if (is_x86_64_linux) {
        try expect(this_is_my_alias() == 1234);
    }
}

test "output constraint modifiers" {
    if (builtin.zig_backend == .stage2_wasm) return error.SkipZigTest; // TODO
    if (builtin.zig_backend == .stage2_arm) return error.SkipZigTest; // TODO
    if (builtin.zig_backend == .stage2_sparc64) return error.SkipZigTest; // TODO
    if (builtin.zig_backend == .stage2_spirv) return error.SkipZigTest;
    if (builtin.zig_backend == .stage2_riscv64) return error.SkipZigTest;

    if (builtin.zig_backend == .stage2_c and builtin.os.tag == .windows) return error.SkipZigTest; // MSVC doesn't support inline assembly

    // This is only testing compilation.
    var a: u32 = 3;
    asm volatile (""
        : [_] "=m,r" (a),
        :
        : .{});
    asm volatile (""
        : [_] "=r,m" (a),
        :
        : .{});
}

test "alternative constraints" {
    if (builtin.zig_backend == .stage2_wasm) return error.SkipZigTest; // TODO
    if (builtin.zig_backend == .stage2_arm) return error.SkipZigTest; // TODO
    if (builtin.zig_backend == .stage2_sparc64) return error.SkipZigTest; // TODO
    if (builtin.zig_backend == .stage2_spirv) return error.SkipZigTest;
    if (builtin.zig_backend == .stage2_riscv64) return error.SkipZigTest;

    if (builtin.zig_backend == .stage2_c and builtin.os.tag == .windows) return error.SkipZigTest; // MSVC doesn't support inline assembly

    // Make sure we allow commas as a separator for alternative constraints.
    var a: u32 = 3;
    asm volatile (""
        : [_] "=r,m" (a),
        : [_] "r,m" (a),
    );
}

test "sized integer/float in asm input" {
    if (builtin.zig_backend == .stage2_wasm) return error.SkipZigTest; // TODO
    if (builtin.zig_backend == .stage2_arm) return error.SkipZigTest; // TODO
    if (builtin.zig_backend == .stage2_sparc64) return error.SkipZigTest; // TODO
    if (builtin.zig_backend == .stage2_riscv64) return error.SkipZigTest;

    if (builtin.zig_backend == .stage2_c and builtin.os.tag == .windows) return error.SkipZigTest; // MSVC doesn't support inline assembly

    asm volatile (""
        :
        : [_] "m" (@as(usize, 3)),
    );
    asm volatile (""
        :
        : [_] "m" (@as(i15, -3)),
    );
    asm volatile (""
        :
        : [_] "m" (@as(u3, 3)),
    );
    asm volatile (""
        :
        : [_] "m" (@as(i3, 3)),
    );
    asm volatile (""
        :
        : [_] "m" (@as(u121, 3)),
    );
    asm volatile (""
        :
        : [_] "m" (@as(i121, 3)),
    );
    asm volatile (""
        :
        : [_] "m" (@as(f32, 3.17)),
    );
    asm volatile (""
        :
        : [_] "m" (@as(f64, 3.17)),
    );
}

test "struct/array/union types as input values" {
    if (builtin.zig_backend == .stage2_wasm) return error.SkipZigTest; // TODO
    if (builtin.zig_backend == .stage2_arm) return error.SkipZigTest; // TODO
    if (builtin.zig_backend == .stage2_sparc64) return error.SkipZigTest; // TODO
    if (builtin.zig_backend == .stage2_riscv64) return error.SkipZigTest;

    if (builtin.zig_backend == .stage2_c and builtin.os.tag == .windows) return error.SkipZigTest; // MSVC doesn't support inline assembly

    asm volatile (""
        :
        : [_] "m" (@as([1]u32, undefined)),
    ); // fails
    asm volatile (""
        :
        : [_] "m" (@as(struct { x: u32, y: u8 }, undefined)),
    ); // fails
    asm volatile (""
        :
        : [_] "m" (@as(union { x: u32, y: u8 }, undefined)),
    ); // fails
}

extern fn this_is_my_alias() i32;

export fn derp() i32 {
    return 1234;
}

test "rw constraint (x86_64)" {
    if (builtin.zig_backend == .stage2_c) return error.SkipZigTest;
    if (builtin.target.cpu.arch != .x86_64) return error.SkipZigTest;

    var res: i32 = 5;
    asm ("addl %[b], %[a]"
        : [a] "+r" (res),
        : [b] "r" (@as(i32, 13)),
        : .{ .flags = true });
    try expectEqual(@as(i32, 18), res);
}

test "asm modifiers (AArch64)" {
    if (!builtin.target.cpu.arch.isAARCH64()) return error.SkipZigTest;

    if (builtin.zig_backend == .stage2_c and builtin.os.tag == .windows) return error.SkipZigTest; // MSVC doesn't support inline assembly

    var x: u32 = 15;
    _ = &x;
    const double = asm ("add %[ret:w], %[in:w], %[in:w]"
        : [ret] "=r" (-> u32),
        : [in] "r" (x),
    );
    try expectEqual(2 * x, double);
}

fn pinCalleeSavedInput(x: u64) callconv(.c) void {
    asm volatile (""
        :
        : [x] "{x19}" (x),
    );
}

fn pinCalleeSavedInputsWithRegister(x: u64, y: u64, z: u64) callconv(.c) void {
    asm volatile (""
        :
        : [x] "{x19}" (x),
          [y] "{x20}" (y),
          [z] "{x0}" (z +% 2),
          [w] "r" (z +% 1),
    );
}

test "asm inputs pinned to callee-saved registers (AArch64)" {
    if (!builtin.target.cpu.arch.isAARCH64()) return error.SkipZigTest;

    if (builtin.zig_backend == .stage2_c and builtin.os.tag == .windows) return error.SkipZigTest; // MSVC doesn't support inline assembly

    // Both callees must preserve x19 and x20 for their caller.
    const preserved = asm volatile (
        \\mov x19, #0x1234
        \\mov x20, #0x5678
        \\mov x0, #7
        \\bl %[f]
        \\mov x0, #7
        \\mov x1, #8
        \\mov x2, #9
        \\bl %[g]
        \\add %[ret], x19, x20, lsl #16
        : [ret] "=r" (-> u64),
        : [f] "X" (&pinCalleeSavedInput),
          [g] "X" (&pinCalleeSavedInputsWithRegister),
        : .{ .memory = true, .nzcv = true, .x0 = true, .x1 = true, .x2 = true, .x3 = true, .x4 = true, .x5 = true, .x6 = true, .x7 = true, .x8 = true, .x9 = true, .x10 = true, .x11 = true, .x12 = true, .x13 = true, .x14 = true, .x15 = true, .x16 = true, .x17 = true, .x19 = true, .x20 = true, .x30 = true, .v0 = true, .v1 = true, .v2 = true, .v3 = true, .v4 = true, .v5 = true, .v6 = true, .v7 = true, .v16 = true, .v17 = true, .v18 = true, .v19 = true, .v20 = true, .v21 = true, .v22 = true, .v23 = true, .v24 = true, .v25 = true, .v26 = true, .v27 = true, .v28 = true, .v29 = true, .v30 = true, .v31 = true });
    try expectEqual(@as(u64, 0x5678_1234), preserved);
}

const AsmResult = struct { value: u64, len: u64, tag: u16 };

/// Returns `AsmResult` through the indirect result register x8 while the asm
/// takes an input in x8 and defines x0, like a Linux syscall wrapper inlined
/// into a function returning an error union by reference.
noinline fn asmUsesIndirectResultRegister(a: u64, b: u64, len: u64) AsmResult {
    const r = asm volatile ("add x0, x0, x8"
        : [ret] "={x0}" (-> u64),
        : [number] "{x8}" (@as(u64, 216)),
          [a] "{x0}" (a),
          [b] "{x1}" (b),
          [c] "{x2}" (len),
        : .{ .memory = true });
    if (r & 0xfff != 0) return .{ .value = 0, .len = 0, .tag = 1 };
    return .{ .value = r, .len = len, .tag = 0 };
}

test "asm with an x8 input in a function returning through x8 (AArch64)" {
    if (!builtin.target.cpu.arch.isAARCH64()) return error.SkipZigTest;

    if (builtin.zig_backend == .stage2_c and builtin.os.tag == .windows) return error.SkipZigTest; // MSVC doesn't support inline assembly

    const r = asmUsesIndirectResultRegister(0x10000 - 216, 5, 4096);
    try expectEqual(AsmResult{ .value = 0x10000, .len = 4096, .tag = 0 }, r);
}

test "packed output types (x86_64)" {
    if (builtin.target.cpu.arch != .x86_64) return error.SkipZigTest;
    if (builtin.zig_backend == .stage2_c and builtin.os.tag == .windows) return error.SkipZigTest; // MSVC doesn't support inline assembly

    const S = packed struct(u32) { x: u32 };
    {
        const s: S = asm volatile ("mov $123, %[ret]"
            : [ret] "=r" (-> S),
        );
        try expect(s.x == 123);
    }
    {
        var s: S = undefined;
        asm volatile ("mov $123, %[ret]"
            : [ret] "=r" (s),
        );
        try expect(s.x == 123);
    }

    const U = packed union(u32) { x: u32 };
    {
        const u: U = asm volatile ("mov $123, %[ret]"
            : [ret] "=r" (-> U),
        );
        try expect(u.x == 123);
    }
    {
        var u: U = undefined;
        asm volatile ("mov $123, %[ret]"
            : [ret] "=r" (u),
        );
        try expect(u.x == 123);
    }
}

test "abi register aliases as clobbers (RISC-V)" {
    if (!builtin.target.cpu.arch.isRISCV()) return error.SkipZigTest;
    if (builtin.zig_backend == .stage2_riscv64) return error.SkipZigTest;

    // Verify that ABI alias names are accepted as clobbers for RISC-V.
    asm volatile ("" ::: .{ .ra = true, .sp = true, .gp = true, .tp = true });
    asm volatile ("" ::: .{ .a0 = true, .a1 = true, .a2 = true, .a3 = true, .a4 = true, .a5 = true, .a6 = true, .a7 = true });
    asm volatile ("" ::: .{ .t0 = true, .t1 = true, .t2 = true, .t3 = true, .t4 = true, .t5 = true, .t6 = true });
    asm volatile ("" ::: .{ .s0 = true, .fp = true, .s1 = true, .s2 = true, .s3 = true, .s4 = true, .s5 = true, .s6 = true, .s7 = true, .s8 = true, .s9 = true, .s10 = true, .s11 = true });
    asm volatile ("" ::: .{ .fa0 = true, .fa1 = true, .ft0 = true, .fs0 = true });
}

test "asm comments and numeric local labels (AArch64)" {
    if (!builtin.target.cpu.arch.isAARCH64()) return error.SkipZigTest;
    if (builtin.zig_backend == .stage2_c and builtin.os.tag == .windows) return error.SkipZigTest; // MSVC doesn't support inline assembly

    const S = struct {
        noinline fn increment(value: u64) u64 {
            return asm volatile (
                \\// comment-only line before the instruction
                \\add %[result], %[value], #1 // trailing comment; ignored text
                \\// final comment-only line
                : [result] "=r" (-> u64),
                : [value] "r" (value),
            );
        }
        noinline fn atEnd() u64 {
            return asm volatile ("mov %[result], #42// no terminating newline"
                : [result] "=r" (-> u64),
            );
        }
        noinline fn localBranches(input: u64) u64 {
            return asm volatile (
                \\uxtw x9, %[input:w]
                \\mov %[result], #0
                \\cbz x9, 2f // label at the end of this assembly
                \\1: add %[result], %[result], #1
                \\sub w9, w9, #1
                \\cbnz w9, 1b
                \\cbnz %[result], 1f
                \\mov %[result], #99
                \\1: b 2f
                \\mov %[result], #100
                \\2:
                : [result] "=r" (-> u64),
                : [input] "r" (input),
                : .{ .x9 = true });
        }
    };
    var input: u64 = 41;
    const ptr: *volatile u64 = &input;
    try expect(S.increment(ptr.*) == 42);
    try expect(S.atEnd() == 42);
    ptr.* = 0xffff_ffff_0000_0003;
    try expect(S.localBranches(ptr.*) == 3);
    ptr.* = 0xffff_ffff_0000_0000;
    try expect(S.localBranches(ptr.*) == 0);
}

test "asm describing the highest SIMD registers in CFI (AArch64)" {
    if (!builtin.target.cpu.arch.isAARCH64()) return error.SkipZigTest;
    if (builtin.zig_backend == .stage2_c) return error.SkipZigTest;

    const S = struct {
        noinline fn boundary(value: u64) u64 {
            asm volatile (
                \\.cfi_undefined v30
                \\.cfi_undefined v31
                ::: .{ .memory = true });
            return value +% 1;
        }
    };
    try expect(S.boundary(41) == 42);
}

test "asm reading the current instruction address (AArch64)" {
    if (!builtin.target.cpu.arch.isAARCH64()) return error.SkipZigTest;
    if (builtin.zig_backend == .stage2_c and builtin.os.tag == .windows) return error.SkipZigTest; // MSVC doesn't support inline assembly

    const S = struct {
        noinline fn currentPC() usize {
            return asm volatile ("adr %[pc], ."
                : [pc] "=r" (-> usize),
            );
        }
    };
    const pc = S.currentPC();
    const function = @intFromPtr(&S.currentPC);
    try expect(pc >= function and pc - function < 256 and pc & 3 == 0);
}

test "asm with SIMD register operands (AArch64)" {
    if (!builtin.target.cpu.arch.isAARCH64()) return error.SkipZigTest;

    if (builtin.zig_backend == .stage2_c and builtin.os.tag == .windows) return error.SkipZigTest; // MSVC doesn't support inline assembly
    if (builtin.zig_backend == .stage2_aarch64) return error.SkipZigTest; // SIMD register constraints ("w", "x") and the crypto instructions are not supported by the inline assembler

    var a: @Vector(4, u32) = .{ 1, 2, 3, 4 };
    var b: @Vector(4, u32) = .{ 10, 20, 30, 40 };
    _ = .{ &a, &b };
    const sum = asm ("add %[out].4s, %[a].4s, %[b].4s"
        : [out] "=w" (-> @Vector(4, u32)),
        : [a] "w" (a),
          [b] "w" (b),
    );
    try expectEqual(@Vector(4, u32){ 11, 22, 33, 44 }, sum);

    if (!builtin.cpu.has(.aarch64, .aes)) return;
    var block: @Vector(16, u8) = @splat(0);
    _ = &block;
    const zero: @Vector(16, u8) = @splat(0);
    // SubBytes(0) is 0x63 in every byte, which MixColumns leaves unchanged.
    const round = asm (
        \\ mov   %[out].16b, %[in].16b
        \\ aese  %[out].16b, %[zero].16b
        \\ aesmc %[out].16b, %[out].16b
        : [out] "=&x" (-> @Vector(16, u8)),
        : [in] "x" (block),
          [zero] "x" (zero),
    );
    try expectEqual(@as(@Vector(16, u8), @splat(0x63)), round);
}
