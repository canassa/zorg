const builtin = @import("builtin");
const std = @import("std");
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

// Addresses of locals, locals under register pressure, large frames and
// arguments read after calls. The self-hosted backends keep the addresses of
// stack slots as constants and fold them into memory operands, so these check
// that every way of using such an address still sees the same memory.

noinline fn bump(p: *u64, by: u64) void {
    p.* +%= by;
}

noinline fn identity(p: *u64) *u64 {
    return p;
}

noinline fn clobber() void {
    var x: [8]u64 = undefined;
    for (&x, 0..) |*e, i| e.* = i *% 0x9e3779b97f4a7c15;
    std.mem.doNotOptimizeAway(&x);
}

test "many locals live across calls" {
    var l0: u64 = 1;
    var l1: u64 = 2;
    var l2: u64 = 3;
    var l3: u64 = 4;
    var l4: u64 = 5;
    var l5: u64 = 6;
    var l6: u64 = 7;
    var l7: u64 = 8;
    var l8: u64 = 9;
    var l9: u64 = 10;
    var l10: u64 = 11;
    var l11: u64 = 12;
    var l12: u64 = 13;
    var l13: u64 = 14;
    var l14: u64 = 15;
    var l15: u64 = 16;
    var l16: u64 = 17;
    var l17: u64 = 18;
    var l18: u64 = 19;
    var l19: u64 = 20;
    var l20: u64 = 21;
    var l21: u64 = 22;
    var l22: u64 = 23;
    var l23: u64 = 24;
    var l24: u64 = 25;
    var l25: u64 = 26;
    var l26: u64 = 27;
    var l27: u64 = 28;
    var l28: u64 = 29;
    var l29: u64 = 30;
    const ptrs = [_]*u64{
        &l0,  &l1,  &l2,  &l3,  &l4,  &l5,  &l6,  &l7,  &l8,  &l9,
        &l10, &l11, &l12, &l13, &l14, &l15, &l16, &l17, &l18, &l19,
        &l20, &l21, &l22, &l23, &l24, &l25, &l26, &l27, &l28, &l29,
    };
    var round: u64 = 0;
    while (round < 3) : (round += 1) {
        bump(&l0, 100);
        bump(&l7, 100);
        clobber();
        bump(&l15, 100);
        bump(&l29, 100);
        l3 += l0 + l29;
        l21 = l21 * 2 + l15;
        clobber();
        bump(identity(&l11), l3);
    }
    try expectEqual(@as(u64, 301), l0);
    try expectEqual(@as(u64, 308), l7);
    try expectEqual(@as(u64, 316), l15);
    try expectEqual(@as(u64, 330), l29);
    try expectEqual(@as(u64, 4 + 231 + 431 + 631), l3);
    try expectEqual(@as(u64, ((22 * 2 + 116) * 2 + 216) * 2 + 316), l21);
    try expectEqual(@as(u64, 12 + 235 + 666 + 1297), l11);
    var sum: u64 = 0;
    for (ptrs) |p| sum += p.*;
    try expectEqual(l0 + l1 + l2 + l3 + l4 + l5 + l6 + l7 + l8 + l9 +
        l10 + l11 + l12 + l13 + l14 + l15 + l16 + l17 + l18 + l19 +
        l20 + l21 + l22 + l23 + l24 + l25 + l26 + l27 + l28 + l29, sum);
}

const Pair = struct { a: u32, b: u64, c: [3]u16 };

noinline fn storeAddress(dst: **u64, src: *u64) void {
    dst.* = src;
}

test "addresses of locals stored, compared and passed" {
    var x: u64 = 5;
    var y: u64 = 6;
    var holder: *u64 = &x;
    try expect(holder == &x);
    storeAddress(&holder, &y);
    try expect(holder == &y);
    try expect(holder != &x);
    holder.* += 1;
    try expectEqual(@as(u64, 7), y);
    try expectEqual(@intFromPtr(&x), @intFromPtr(identity(&x)));
    const addr = @intFromPtr(&x);
    clobber();
    try expectEqual(addr, @intFromPtr(&x));
    const lo: u32 = @truncate(addr);
    const hi: u32 = @truncate(addr >> 32);
    try expectEqual(addr, @as(u64, hi) << 32 | lo);
    const Halves = packed struct(u64) { lo: u32, hi: u32 };
    const halves: Halves = @bitCast(@intFromPtr(&y));
    try expectEqual(@intFromPtr(&y), @as(u64, halves.hi) << 32 | halves.lo);

    var pair: Pair = .{ .a = 1, .b = 2, .c = .{ 3, 4, 5 } };
    const pb = &pair.b;
    const pc = &pair.c[2];
    pb.* += 40;
    pc.* += 50;
    try expectEqual(@as(u64, 42), pair.b);
    try expectEqual(@as(u16, 55), pair.c[2]);
    try expectEqual(@intFromPtr(&pair) + @offsetOf(Pair, "b"), @intFromPtr(pb));

    var opt: ?u64 = 9;
    const payload = &opt.?;
    payload.* += 1;
    try expectEqual(@as(?u64, 10), opt);

    var slice: []const u8 = "hello";
    const len_ptr = &slice.len;
    len_ptr.* = 4;
    try std.testing.expectEqualStrings("hell", slice);
}

fn Big(comptime n: usize) type {
    return struct { bytes: [n]u8 };
}

noinline fn fillBig(p: []u8, seed: u8) void {
    for (p, 0..) |*b, i| b.* = seed +% @as(u8, @truncate(i));
}

noinline fn manyArgs(a0: u64, a1: u64, a2: u64, a3: u64, a4: u64, a5: u64, a6: u64, a7: u64, a8: u64, a9: u64, a10: u32, a11: u8) u64 {
    var big: [40000]u8 = undefined;
    fillBig(&big, @truncate(a0));
    var after: u64 = a9;
    bump(&after, a8);
    var aligned: u64 align(64) = a10;
    bump(&aligned, a11);
    clobber();
    return a0 + a1 + a2 + a3 + a4 + a5 + a6 + a7 + a8 + a9 + a10 + a11 + big[0] + big[39999] + after + aligned;
}

test "large frames" {
    var a: [5000]u64 = undefined;
    var b: u64 = 7;
    var c: [3]u32 = .{ 1, 2, 3 };
    for (&a, 0..) |*e, i| e.* = i;
    bump(&b, a[4999]);
    c[2] += @truncate(a[1234]);
    var big: Big(70000) = undefined;
    fillBig(&big.bytes, 3);
    var tail: u16 = 0x1234;
    var tail2: u8 = 0x56;
    tail +%= big.bytes[69999];
    tail2 +%= big.bytes[40000];
    clobber();
    try expectEqual(@as(u64, 7 + 4999), b);
    try expectEqual(@as(u32, 3 + 1234), c[2]);
    try expectEqual(@as(u16, 0x1234) + (3 +% @as(u8, @truncate(69999))), tail);
    try expectEqual(@as(u8, 0x56 +% (3 +% @as(u8, @truncate(40000)))), tail2);
    try expectEqual(@as(u64, 4999 * 5000 / 2), sum: {
        var s: u64 = 0;
        for (a) |e| s += e;
        break :sum s;
    });
    const r = manyArgs(1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12);
    try expectEqual(@as(u64, 1 + 2 + 3 + 4 + 5 + 6 + 7 + 8 + 9 + 10 + 11 + 12 + 1 + (1 +% @as(u8, @truncate(39999))) + 19 + 23), r);
}

noinline fn leafArgs(a: u64, b: u32, c: u8, d: bool, e: i16) i64 {
    var r: i64 = @intCast(a);
    r += b;
    if (d) r -= c;
    r *= e;
    if (d) r += c;
    return r + @as(i64, @intCast(a)) - b;
}

noinline fn nonLeafArgs(a: u64, b: u32, c: u8, d: bool, e: i16, s: []const u8) i64 {
    clobber();
    var r: i64 = @intCast(a);
    clobber();
    r += b;
    clobber();
    if (d) r -= c;
    clobber();
    r *= e;
    clobber();
    if (d) r += c;
    return r + @as(i64, @intCast(a)) - b + @as(i64, @intCast(s.len)) + s[s.len - 1];
}

test "arguments read after calls" {
    try expectEqual(@as(i64, (10 + 20 - 3) * -2 + 3 + 10 - 20), leafArgs(10, 20, 3, true, -2));
    try expectEqual(@as(i64, (10 + 20) * 4 + 10 - 20), leafArgs(10, 20, 3, false, 4));
    try expectEqual(@as(i64, (10 + 20 - 3) * -2 + 3 + 10 - 20 + 3 + 'c'), nonLeafArgs(10, 20, 3, true, -2, "abc"));
    try expectEqual(@as(i64, (10 + 20) * 4 + 10 - 20 + 1 + 'z'), nonLeafArgs(10, 20, 3, false, 4, "z"));
}

test "pointers to locals escaping through a loop" {
    var a: u64 = 1;
    var b: u64 = 2;
    var c: [4]u64 = .{ 10, 20, 30, 40 };
    var ptrs: [8]*u64 = undefined;
    var i: usize = 0;
    while (i < ptrs.len) : (i += 1) {
        const p = if (i % 3 == 0) &a else if (i % 3 == 1) &b else &c[i % 4];
        ptrs[i] = p;
        p.* += i;
        clobber();
    }
    try expectEqual(@as(u64, 1 + 0 + 3 + 6), a);
    try expectEqual(@as(u64, 2 + 1 + 4 + 7), b);
    try expectEqual([4]u64{ 10, 20 + 5, 30 + 2, 40 }, c);
    try expect(ptrs[0] == &a and ptrs[3] == &a and ptrs[1] == &b and ptrs[2] == &c[2] and ptrs[5] == &c[1]);
    var cursor: *u64 = &c[0];
    var n: usize = 0;
    while (n < 3) : (n += 1) {
        cursor.* += 100;
        cursor = if (cursor == &c[0]) &c[3] else &c[0];
    }
    try expectEqual([4]u64{ 210, 25, 32, 140 }, c);
}

const Result = struct { x: u64, y: [5]u32, z: u8 };

noinline fn makeResult(seed: u64) Result {
    var r: Result = undefined;
    r.x = seed;
    for (&r.y, 0..) |*e, i| e.* = @truncate(seed + i);
    bump(&r.x, 1);
    r.z = @truncate(r.x);
    return r;
}

test "result location in the caller's or the callee's frame" {
    const r = makeResult(40);
    try expectEqual(@as(u64, 41), r.x);
    try expectEqual([5]u32{ 40, 41, 42, 43, 44 }, r.y);
    try expectEqual(@as(u8, 41), r.z);
}

const Blob = struct { words: [12]u64, tail: [5]u8 };

noinline fn copyThrough(dst: *Blob, src: *const Blob) void {
    dst.* = src.*;
}

test "copies between locals, near and far" {
    var a: Blob = undefined;
    for (&a.words, 0..) |*w, i| w.* = i * 3;
    a.tail = .{ 1, 2, 3, 4, 5 };
    var b: Blob = a;
    b.words[11] += 1;
    var pad: [40000]u8 = undefined;
    fillBig(&pad, 9);
    var c: Blob = b;
    var d: Blob = undefined;
    const pc = &c;
    const pd = &d;
    pd.* = pc.*;
    pd.tail[4] +%= pad[39999];
    clobber();
    var e: Blob = undefined;
    copyThrough(&e, &d);
    try expectEqual(@as(u64, 33 + 1), e.words[11]);
    try expectEqual(@as(u64, 15), e.words[5]);
    try expectEqual(@as(u8, 5 +% 9 +% @as(u8, @truncate(39999))), e.tail[4]);
    try expectEqual(a.words[0..11].*, e.words[0..11].*);
    try expectEqual(@as(u64, 33), a.words[11]);
}

const Vec3 = struct { x: f64, y: f64, z: f64 };

noinline fn floatArgs(a: f64, b: f32, v: Vec3, w: Vec3, n: u8, m: u64) f64 {
    clobber();
    const first = a * b + v.x;
    clobber();
    return first + v.y * w.z + v.z - w.x + w.y + @as(f64, @floatFromInt(n)) + @as(f64, @floatFromInt(m));
}

noinline fn eightArgs(a0: u64, a1: u32, a2: u16, a3: u8, a4: i64, a5: i32, a6: i16, a7: i8) i64 {
    clobber();
    var r: i64 = a4;
    clobber();
    r += @intCast(a0 + a1 + a2 + a3);
    clobber();
    return r + a5 + a6 + a7 - @as(i64, a3) + a3;
}

test "register arguments live across calls" {
    try expectEqual(@as(f64, 2.0 * 1.5 + 1 + 2 * 6 + 3 - 4 + 5 + 7 + 8), floatArgs(2.0, 1.5, .{ .x = 1, .y = 2, .z = 3 }, .{ .x = 4, .y = 5, .z = 6 }, 7, 8));
    try expectEqual(@as(i64, -5 + 1 + 2 + 3 + 4 - 6 - 7 - 8), eightArgs(1, 2, 3, 4, -5, -6, -7, -8));
}
