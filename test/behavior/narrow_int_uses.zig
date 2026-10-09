const builtin = @import("builtin");
const std = @import("std");
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

// Integers of at most 32 bits made by truncating or casting a wider value in
// place. The self-hosted aarch64 backend leaves the bits above 32 of such a
// register undefined (as for incoming arguments), so every use that needs them
// must extend the value itself.

noinline fn wide(x: u64) u64 {
    return x;
}

const Rec = struct { a: u32, b: u8, c: ?u32 };

noinline fn passU32(x: u32) u32 {
    return x +% 1;
}

noinline fn makeRec(a: u32, b: u8, c: u32) Rec {
    return .{ .a = a, .b = b, .c = if (c == 0) null else c };
}

test "truncated and cast integers used in wider contexts" {
    const x = wide(0xdead_beef_8000_0001);
    const t: u32 = @truncate(x);
    try expectEqual(@as(u32, 0x8000_0001), t);
    try expectEqual(@as(u64, 0x8000_0001), @as(u64, t));
    try expectEqual(@as(u64, 0x8000_0001 * 3), @as(u64, t) * 3);
    try expectEqual(@as(usize, 0x8000_0001), @as(usize, t));
    try expectEqual(@as(u6, 2), @popCount(t));
    try expectEqual(@as(u32, 0x0000_0002), t << 1);
    try expectEqual(@as(u32, 0x4000_0000), t >> 1);
    try expect(t > 0x8000_0000 and t < 0x8000_0002);
    try expectEqual(@as(f64, 2147483649.0), @as(f64, @floatFromInt(t)));
    try expectEqual(@as(u32, 0x8000_0002), passU32(t));
    const arr = [_]u8{ 1, 2, 3, 4 };
    try expectEqual(@as(u8, 2), arr[@as(u2, @truncate(t)) & 1]);

    const r = makeRec(t, @truncate(x >> 8), @truncate(x >> 32));
    try expectEqual(@as(u32, 0x8000_0001), r.a);
    try expectEqual(@as(u8, 0), r.b);
    try expectEqual(@as(?u32, 0xdead_beef), r.c);

    const small = wide(0x1234_5678_0000_00ff);
    const s: u8 = @intCast(small & 0xff);
    try expectEqual(@as(u8, 0xff), s);
    try expectEqual(@as(u64, 0xff), @as(u64, s));
    try expectEqual(@as(u32, 0xff + 1), @as(u32, s) + 1);
    const c: u32 = @intCast(small >> 40);
    try expectEqual(@as(u32, 0x12_3456), c);
    try expectEqual(@as(u64, 0x12_3456), @as(u64, c));
    const n: i32 = @intCast(@as(i64, @bitCast(wide(@bitCast(@as(i64, -5))))));
    try expectEqual(@as(i32, -5), n);
    try expectEqual(@as(i64, -5), @as(i64, n));
    try expectEqual(@as(u64, 0xffff_fffb), @as(u64, @as(u32, @bitCast(n))));

    switch (t) {
        0x8000_0001 => {},
        else => return error.TestUnexpectedResult,
    }
    var sum: u64 = 0;
    for (0..4) |i| {
        const k: u32 = @truncate(wide(0xffff_ffff_0000_0000 + i));
        sum += k;
    }
    try expectEqual(@as(u64, 0 + 1 + 2 + 3), sum);
}

test "checked narrowing then widening" {
    for ([_]u64{ 0, 1, 0x7fff_ffff, 0xffff_ffff }) |v| {
        const w = wide(v | 0);
        const n: u32 = @intCast(w);
        try expectEqual(v, @as(u64, n));
        const b: u16 = @intCast(w & 0xffff);
        try expectEqual(v & 0xffff, @as(u64, b));
        const e: enum(u32) { _ } = @fromBackingInt(@intCast(n));
        try expectEqual(v, @as(u64, @backingInt(e)));
    }
}

noinline fn mixLoaded(bytes: []const u8, halves: []const u16, words: *const [2]u32, signed: []const i16) u64 {
    var h: u64 = 0xffff_ffff_ffff_ffff;
    for (bytes) |b| h = (h ^ b) *% 0x100000001b3;
    for (halves) |x| h +%= x;
    h ^= @as(u64, words[1]) << 1;
    for (signed) |s| h +%= @as(u64, @intCast(s));
    return h;
}

test "loaded narrow integers widened in place" {
    const bytes = [_]u8{ 0xff, 0x80, 0x01 };
    const halves = [_]u16{ 0xffff, 0x8000 };
    const words = [2]u32{ 0xffff_ffff, 0x8000_0000 };
    const signed = [_]i16{ 0x7fff, 3 };
    var h: u64 = 0xffff_ffff_ffff_ffff;
    for (bytes) |b| h = (h ^ @as(u64, b)) *% 0x100000001b3;
    h +%= 0xffff + 0x8000;
    h ^= @as(u64, 0x8000_0000) << 1;
    h +%= 0x7fff + 3;
    try expectEqual(h, mixLoaded(&bytes, &halves, &words, &signed));
}

// A local stored once from a truncated value: its loads may read the stored
// value's register, whose bits above the integer are not cleared.

noinline fn storedOnceUnsigned(comptime T: type, x: u64) u64 {
    const t: T = @truncate(x);
    var local = t;
    _ = &local;
    return local;
}

noinline fn storedOnceI32(x: u64) i64 {
    const t: i32 = @bitCast(@as(u32, @truncate(x)));
    var local = t;
    _ = &local;
    return local;
}

noinline fn storedOnceI32ToU64(x: u64) u64 {
    const t: i32 = @bitCast(@as(u32, @truncate(x)));
    var local = t;
    _ = &local;
    return @intCast(local);
}

noinline fn storedOnceArgument(x: u64) u64 {
    const t: u32 = @truncate(x);
    var local = t;
    _ = &local;
    return wide(local);
}

noinline fn storedOnceInLoop(x: u64, n: usize) u64 {
    const t: u32 = @truncate(x);
    var local = t;
    _ = &local;
    var sum: u64 = 0;
    for (0..n) |_| sum +%= local;
    return sum;
}

noinline fn storedOnceIndex(x: u64, arr: []const u8) u8 {
    const t: u32 = @truncate(x);
    var local = t;
    _ = &local;
    return arr[local];
}

noinline fn storedOnceCopied(x: u64) u64 {
    const t: u32 = @truncate(x);
    var local = t;
    _ = &local;
    var other = local;
    _ = &other;
    return @as(u64, other) << 1;
}

noinline fn storedOnceField(x: u64) u64 {
    const p: struct { a: u32, b: u32 } = .{ .a = @truncate(x), .b = @truncate(x >> 8) };
    var local = p;
    _ = &local;
    return @as(u64, local.a) + @as(u64, local.b);
}

noinline fn storedOnceCallResult(x: u64) u64 {
    var local = passU32(@truncate(x));
    _ = &local;
    return local;
}

noinline fn promotedInLoop(x: u64, n: usize) u64 {
    var local: u32 = @truncate(x);
    var sum: u64 = 0;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        sum +%= local;
        local = @truncate(wide(@as(u64, local) + 0xffff_ffff_0000_0001));
    }
    return sum +% local;
}

test "stored-once locals of truncated integers widened" {
    inline for (
        .{ u32, u16, u8 },
        .{ 0xdead_beef_0000_0001, 0xdead_beef_1234_8001, 0xdead_beef_1234_8081 },
        .{ 1, 0x8001, 0x81 },
    ) |T, x, expected| try expectEqual(@as(u64, expected), storedOnceUnsigned(T, x));
    try expectEqual(@as(i64, -0x7fff_ffff), storedOnceI32(0x1234_5678_8000_0001));
    try expectEqual(@as(u64, 1), storedOnceI32ToU64(0x1234_5678_0000_0001));
    try expectEqual(@as(u64, 1), storedOnceArgument(0xdead_beef_0000_0001));
    try expectEqual(@as(u64, 3), storedOnceInLoop(0xdead_beef_0000_0001, 3));
    const arr = [_]u8{ 10, 11, 12 };
    try expectEqual(@as(u8, 12), storedOnceIndex(0xdead_beef_0000_0002, &arr));
    try expectEqual(@as(u64, 2), storedOnceCopied(0xdead_beef_0000_0001));
    try expectEqual(@as(u64, 0x0000_0001 + 0xef00_0000), storedOnceField(0xdead_beef_0000_0001));
    try expectEqual(@as(u64, 2), storedOnceCallResult(0xdead_beef_0000_0001));
    try expectEqual(@as(u64, 1 + 2 + 3), promotedInLoop(0xdead_beef_0000_0001, 2));
}
