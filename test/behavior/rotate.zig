const builtin = @import("builtin");
const std = @import("std");
const expectEqual = std.testing.expectEqual;

// Rotates written with shifts and an `or`, as `std.math.rotl`/`rotr` do. The
// self-hosted backends may select a single rotate instruction for them, so
// these check widths around the register sizes and amounts around the width,
// comptime and runtime, against a reference that moves one bit at a time.

fn refRotl(comptime T: type, x: T, r: usize) T {
    const bits = @typeInfo(T).int.bits;
    if (bits == 0) return x;
    var v = x;
    for (0..r % bits) |_| {
        const top: T = v >> (bits - 1);
        v = (v << 1) | top;
    }
    return v;
}

fn pattern(comptime T: type, seed: u64) T {
    const wide: u128 = @as(u128, seed *% 0x9e3779b97f4a7c15) << 64 | (seed *% 0xc2b2ae3d27d4eb4f +% 1);
    return @truncate(wide);
}

noinline fn runtimeRotl(comptime T: type, x: T, r: usize) T {
    return std.math.rotl(T, x, r);
}

noinline fn runtimeRotr(comptime T: type, x: T, r: usize) T {
    return std.math.rotr(T, x, r);
}

fn checkWidth(comptime T: type) !void {
    const bits = @typeInfo(T).int.bits;
    const amounts = [_]usize{ 0, 1, 2, bits / 2 - 1, bits / 2, bits - 2, bits - 1, bits, bits + 1, 2 * bits - 1, 2 * bits, 2 * bits + 1 };
    for (0..2) |seed| {
        const x = pattern(T, seed);
        for (amounts) |r| {
            try expectEqual(refRotl(T, x, r), runtimeRotl(T, x, r));
            try expectEqual(refRotl(T, x, (bits - r % bits) % bits), runtimeRotr(T, x, r));
        }
        inline for (.{ 0, 1, bits / 2, bits -| 1, bits, bits + 1, 2 * bits }) |cr| {
            try expectEqual(refRotl(T, x, cr), std.math.rotl(T, x, cr));
            try expectEqual(refRotl(T, x, (bits - cr % bits) % bits), std.math.rotr(T, x, cr));
        }
    }
}

test "rotates around the register widths" {
    inline for (.{ u3, u8, u16, u31, u32, u33, u63, u64, u65, u128 }) |T|
        try checkWidth(T);
}

noinline fn rotl5(x: u64) u64 {
    return x << 5 | x >> 59;
}

noinline fn rotr7(x: u32) u32 {
    return x << 25 | x >> 7;
}

noinline fn notRotate(x: u64) u64 {
    return x << 5 | x >> 58;
}

noinline fn notRotateOperands(x: u64, y: u64) u64 {
    return x << 5 | y >> 59;
}

noinline fn rotlBy(x: u64, r: u6) u64 {
    return x << r | x >> (0 -% r);
}

noinline fn rotrBy(x: u32, r: u5) u32 {
    return x >> r | x << (1 +% ~r);
}

noinline fn shiftReused(x: u64, out: *u64) u64 {
    const hi = x << 13;
    out.* = hi;
    return hi | x >> 51;
}

noinline fn hashBytes(bytes: []const u8) u64 {
    var h: u64 = 0;
    for (bytes) |b| h = (std.math.rotl(u64, h, 5) ^ b) *% 0x517cc1b727220a95;
    return h;
}

test "rotate idioms written out" {
    const x: u64 = 0x8123456789abcdef;
    try expectEqual(refRotl(u64, x, 5), rotl5(x));
    try expectEqual(refRotl(u32, 0x80000001, 25), rotr7(0x80000001));
    try expectEqual((x << 5) | (x >> 58), notRotate(x));
    try expectEqual((x << 5) | (@as(u64, 0xff00) >> 59), notRotateOperands(x, 0xff00));
    for (0..64) |r| {
        try expectEqual(refRotl(u64, x, r), rotlBy(x, @intCast(r)));
    }
    for (0..32) |r| {
        try expectEqual(refRotl(u32, 0xdeadbeef, (32 - r) % 32), rotrBy(0xdeadbeef, @intCast(r)));
    }
    var out: u64 = 0;
    try expectEqual(refRotl(u64, x, 13), shiftReused(x, &out));
    try expectEqual(x << 13, out);
    var h: u64 = 0;
    for ("rotate me") |b| h = (refRotl(u64, h, 5) ^ b) *% 0x517cc1b727220a95;
    try expectEqual(h, hashBytes("rotate me"));
}

noinline fn sipRounds(words: []const u64) u64 {
    var v0: u64 = 0x736f6d6570736575;
    var v1: u64 = 0x646f72616e646f6d;
    var v2: u64 = 0x6c7967656e657261;
    var v3: u64 = 0x7465646279746573;
    for (words) |m| {
        v3 ^= m;
        v0 +%= v1;
        v1 = (v1 << 13) | (v1 >> 51);
        v1 ^= v0;
        v0 = (v0 << 32) | (v0 >> 32);
        v2 +%= v3;
        v3 = (v3 >> 48) | (v3 << 16);
        v3 ^= v2;
        v1 = (v1 << 17) | (v1 >> 46);
        v0 ^= m;
    }
    return v0 ^ v1 ^ v2 ^ v3;
}

test "rotates of locals read twice" {
    var v0: u64 = 0x736f6d6570736575;
    var v1: u64 = 0x646f72616e646f6d;
    var v2: u64 = 0x6c7967656e657261;
    var v3: u64 = 0x7465646279746573;
    const words = [_]u64{ 1, 0xffff_ffff_0000_0000, 0x8000_0000_0000_0001 };
    for (words) |m| {
        v3 ^= m;
        v0 +%= v1;
        v1 = refRotl(u64, v1, 13);
        v1 ^= v0;
        v0 = refRotl(u64, v0, 32);
        v2 +%= v3;
        v3 = refRotl(u64, v3, 16);
        v3 ^= v2;
        v1 = (v1 << 17) | (v1 >> 46);
        v0 ^= m;
    }
    try expectEqual(v0 ^ v1 ^ v2 ^ v3, sipRounds(&words));
}
