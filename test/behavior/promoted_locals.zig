//! Scalar `var` locals whose address never escapes, used in loops: loop
//! counters and accumulators of every scalar width, floats, locals live across
//! calls and nested loops, more of them than there are registers to keep them
//! in, loads used after a later store, and locals whose address is taken.
//! Expected results are computed at comptime by the same functions.

const std = @import("std");
const builtin = @import("builtin");
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

const int_types = .{ u1, i1, u7, i7, u8, i8, u16, i16, u31, i31, u32, i32, u33, i33, u48, i48, u63, i63, u64, i64 };

fn bitsOf(comptime T: type, x: u32) T {
    return @bitCast(@as(@Int(.unsigned, @bitSizeOf(T)), @truncate(x)));
}

noinline fn countAndAccumulate(comptime T: type, n: u32, step: T) struct { T, T, u32 } {
    var acc: T = 0;
    var alt: T = step;
    var count: u32 = 0;
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        acc +%= step;
        alt = (alt ^ bitsOf(T, i)) +% step;
        if (i % 3 == 0) continue;
        count += 1;
    }
    return .{ acc, alt, count };
}

test "promoted counters and accumulators of every integer width" {
    @setEvalBranchQuota(100_000);
    inline for (int_types) |T| {
        const steps = [_]T{ 0, std.math.maxInt(T), std.math.minInt(T), @truncate(5) };
        inline for (steps) |step| {
            const expected = comptime countAndAccumulate(T, 37, step);
            try expectEqual(expected, countAndAccumulate(T, 37, step));
        }
    }
}

noinline fn floatLoop(comptime T: type, n: u32, x: T) [3]T {
    var sum: T = 0;
    var prod: T = 1;
    var last: T = -x;
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        sum += x;
        prod *= 0.5;
        if (sum > last) last = sum - prod;
    }
    return .{ sum, prod, last };
}

test "promoted float accumulators" {
    @setEvalBranchQuota(100_000);
    inline for (.{ f16, f32, f64 }) |T| {
        const expected = comptime floatLoop(T, 9, 1.25);
        try expectEqual(expected, floatLoop(T, 9, 1.25));
        try expect(std.math.isNan(floatLoop(T, 3, std.math.nan(T))[0]));
    }
}

noinline fn smallTypes(n: u32) struct { bool, enum(u8) { a, b, c }, anyerror, ?*const u32, *const u32 } {
    const E = enum(u8) { a, b, c };
    const values = [_]u32{ 10, 20, 30 };
    var flag = false;
    var e: E = .a;
    var err: anyerror = error.First;
    var opt: ?*const u32 = null;
    var ptr: *const u32 = &values[0];
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        flag = !flag;
        e = switch (e) {
            .a => .b,
            .b => .c,
            .c => .a,
        };
        err = if (err == error.First) error.Second else error.First;
        opt = if (opt == null) &values[i % 3] else null;
        ptr = &values[(i + 1) % 3];
    }
    return .{ flag, @enumFromInt(@intFromEnum(e)), err, opt, ptr };
}

test "promoted bool, enum, error, optional pointer and pointer locals" {
    const r = smallTypes(7);
    try expectEqual(true, r[0]);
    try expectEqual(@as(u8, 1), @intFromEnum(r[1]));
    try expectEqual(error.Second, r[2]);
    try expectEqual(@as(u32, 10), r[3].?.*);
    try expectEqual(@as(u32, 20), r[4].*);
}

noinline fn clobber(x: u64) u64 {
    // Use plenty of registers so that caller-saved ones are overwritten.
    var a: [16]u64 = undefined;
    for (&a, 0..) |*p, j| p.* = x *% (j + 1);
    var s: u64 = 0;
    for (a) |v| s +%= v;
    return s;
}

noinline fn acrossCalls(n: u32) [4]u64 {
    var a: u64 = 1;
    var b: u64 = 2;
    var f: f64 = 0.5;
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        const old_a = a;
        a = clobber(a) +% b;
        b = old_a +% clobber(b);
        f = f * 2 + @as(f64, @floatFromInt(clobber(i) & 7));
    }
    return .{ a, b, @bitCast(f), i };
}

test "promoted locals live across calls" {
    @setEvalBranchQuota(100_000);
    const expected = comptime acrossCalls(6);
    try expectEqual(expected, acrossCalls(6));
}

noinline fn manyLocals(n: u32) u64 {
    var v0: u64 = 0;
    var v1: u64 = 1;
    var v2: u64 = 2;
    var v3: u64 = 3;
    var v4: u64 = 4;
    var v5: u64 = 5;
    var v6: u64 = 6;
    var v7: u64 = 7;
    var v8: u64 = 8;
    var v9: u64 = 9;
    var v10: u64 = 10;
    var v11: u64 = 11;
    var v12: u32 = 12;
    var v13: u16 = 13;
    var v14: u8 = 14;
    var f0: f64 = 0;
    var f1: f64 = 1;
    var f2: f64 = 2;
    var f3: f32 = 3;
    var f4: f32 = 4;
    var f5: f32 = 5;
    var f6: f64 = 6;
    var f7: f64 = 7;
    var f8: f64 = 8;
    var f9: f16 = 9;
    var f10: f64 = 10;
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        v0 +%= v1;
        v1 +%= v2 ^ v0;
        v2 = v3 *% 7 +% v1;
        v3 = v4 -% v2;
        v4 +%= v5 >> 1;
        v5 = v6 | v4;
        v6 = v7 & (v5 +% 0x1234);
        v7 +%= v8;
        v8 = v9 +% v7;
        v9 = v10 ^ v8;
        v10 = v11 +% v9;
        v11 = v0 +% v10;
        v12 = v12 *% 3 +% @as(u32, @truncate(v11));
        v13 = v13 *% 5 +% @as(u16, @truncate(v12));
        v14 = v14 *% 7 +% @as(u8, @truncate(v13));
        f0 += f1;
        f1 = f2 * 0.5 + f0;
        f2 = f1 - f3;
        f3 = f4 + 1;
        f4 = f5 * 0.25;
        f5 = f3 - f4;
        f6 += f7 * 0.125;
        f7 = f8 - f6;
        f8 = f6 + 1;
        f9 = f9 * 0.5 + 1;
        f10 = f10 - f9;
    }
    var s: u64 = v0 +% v1 +% v2 +% v3 +% v4 +% v5 +% v6 +% v7 +% v8 +% v9 +% v10 +% v11 +% v12 +% v13 +% v14;
    s +%= @intFromFloat(@abs(f0 + f1 + f2 + f3 + f4 + f5 + f6 + f7 + f8 + f9 + f10));
    return s;
}

test "more promotable locals than registers" {
    @setEvalBranchQuota(100_000);
    const expected = comptime manyLocals(10);
    try expectEqual(expected, manyLocals(10));
}

noinline fn addressTakenLater(n: u32) u32 {
    var x: u32 = 0;
    var i: u32 = 0;
    while (i < n) : (i += 1) x += i;
    const p = &x;
    p.* += 100;
    bump(&i);
    return x + i;
}

noinline fn bump(p: *u32) void {
    p.* += 1000;
}

test "locals whose address is taken later" {
    try expectEqual(@as(u32, 45 + 100 + 10 + 1000), addressTakenLater(10));
}

noinline fn oldValueAfterStore(n: u32) [4]u32 {
    var x: u32 = 1;
    var y: u32 = 2;
    var out: u32 = 0;
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        // Swap through loads that are used after the stores.
        const old_x = x;
        x = y;
        y = old_x;
        // A value computed before a load and stored after it.
        const next = x + i;
        out += x;
        x = next;
        // The loaded value used after the store and the next iteration.
        const before = y;
        y += 1;
        out += before;
        x = x;
    }
    return .{ x, y, out, i };
}

test "loads of a promoted local used after a later store" {
    @setEvalBranchQuota(100_000);
    const expected = comptime oldValueAfterStore(9);
    try expectEqual(expected, oldValueAfterStore(9));
}

noinline fn nested(n: u32) [3]u64 {
    var total: u64 = 0;
    var inner_runs: u64 = 0;
    var outer_value: u64 = 7;
    var i: u32 = 0;
    outer: while (i < n) : (i += 1) {
        const at_start = outer_value;
        var j: u32 = 0;
        while (j < n) : (j += 1) {
            if (j == i) continue :outer;
            if (j > 6) break;
            var k: u32 = 0;
            while (k < j) : (k += 1) {
                if (k == 3) break;
                total += k * at_start;
                inner_runs += 1;
            }
            if ((j ^ i) & 1 == 0) continue;
            outer_value = outer_value * 3 + j;
        }
        total += at_start;
    }
    return .{ total, inner_runs, outer_value };
}

test "promoted locals in nested loops with break and continue" {
    @setEvalBranchQuota(100_000);
    const expected = comptime nested(10);
    try expectEqual(expected, nested(10));
}

var deferred_seen: u64 = 0;
noinline fn deferAndErrdefer(n: u32, fail_at: u32) error{Failed}!u64 {
    var count: u64 = 0;
    defer deferred_seen = count;
    errdefer count += 1000;
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        defer count += 1;
        errdefer count += 100;
        if (i == fail_at) return error.Failed;
    }
    return count;
}

test "promoted locals with defer and errdefer" {
    try expectEqual(@as(u64, 5), try deferAndErrdefer(5, 99));
    try expectEqual(@as(u64, 5), deferred_seen);
    try expectEqual(error.Failed, deferAndErrdefer(5, 2));
    try expectEqual(@as(u64, 2 + 100 + 1 + 1000), deferred_seen);
}

noinline fn withAsm(n: u32) u64 {
    var a: u64 = 3;
    var b: u64 = 5;
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        a +%= b;
        if (builtin.cpu.arch == .aarch64) {
            asm volatile (
                \\ mov x19, #1
                \\ mov x20, #2
                \\ mov x21, #3
                \\ mov x22, #4
                \\ mov x23, #5
                \\ mov x24, #6
                \\ mov x25, #7
                \\ mov x26, #8
                \\ mov x27, #9
                \\ mov x28, #10
                \\ fmov d8, xzr
                \\ fmov d15, xzr
                ::: .{ .x19 = true, .x20 = true, .x21 = true, .x22 = true, .x23 = true, .x24 = true, .x25 = true, .x26 = true, .x27 = true, .x28 = true, .d8 = true, .d15 = true });
        }
        b = b *% 3;
    }
    return a +% b;
}

noinline fn withoutAsm(n: u32) u64 {
    var a: u64 = 3;
    var b: u64 = 5;
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        a +%= b;
        b = b *% 3;
    }
    return a +% b;
}

noinline fn callsAsm(n: u32) u64 {
    // This function's promoted locals must survive the callee's clobbers.
    var s: u64 = 0;
    var t: f64 = 1;
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        s +%= withAsm(i);
        t *= 1.5;
    }
    return s +% @as(u64, @intFromFloat(t));
}

test "promoted locals with inline assembly clobbering callee-saved registers" {
    if (builtin.cpu.arch != .aarch64) return error.SkipZigTest;
    try expectEqual(withoutAsm(12), withAsm(12));
    var expected: u64 = 0;
    var t: f64 = 1;
    for (0..8) |i| {
        expected +%= withoutAsm(@intCast(i));
        t *= 1.5;
    }
    try expectEqual(expected +% @as(u64, @intFromFloat(t)), callsAsm(8));
}

noinline fn fourCounters(n: u32, comptime barrier: enum { none, memory, registers }) [5]u64 {
    var a: u64 = 1;
    var b: u64 = 2;
    var c: u64 = 3;
    var d: u64 = 4;
    var f: f64 = 1;
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        a +%= b;
        b +%= c;
        c +%= d;
        d +%= a;
        f *= 1.5;
        switch (barrier) {
            .none => {},
            .memory => asm volatile ("" ::: .{ .memory = true }),
            // Names some of the registers that promotion would take.
            .registers => if (builtin.cpu.arch == .aarch64) asm volatile (
                \\ mov x28, %[v]
                \\ mov x27, x28
                \\ fmov d15, x27
                :
                : [v] "{x26}" (@as(u64, i)),
                : .{ .x27 = true, .x28 = true, .d15 = true }),
        }
    }
    return .{ a, b, c, d, @intFromFloat(f) };
}

test "promoted locals in loops with inline assembly" {
    const expected = fourCounters(20, .none);
    try expectEqual(expected, fourCounters(20, .memory));
    try expectEqual(expected, fourCounters(20, .registers));
}

fn recurse(depth: u32) u64 {
    var acc: u64 = depth;
    var f: f64 = @floatFromInt(depth);
    var i: u32 = 0;
    while (i < depth) : (i += 1) {
        acc +%= recurse(i) *% 3;
        f += 0.5;
    }
    return acc +% @as(u64, @intFromFloat(f));
}

test "promoted locals in recursive functions" {
    @setEvalBranchQuota(100_000);
    const expected = comptime recurse(7);
    try expectEqual(expected, recurse(7));
}

noinline fn undefinedThenSet(n: u32) u32 {
    var x: u32 = undefined;
    var y: u8 = undefined;
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        x = i * 2;
        y = @truncate(i);
    }
    return x + y;
}

test "promoted locals initialized with undefined" {
    try expectEqual(@as(u32, 18 + 9), undefinedThenSet(10));
}

noinline fn bitCastUse(xs: []const u64) u64 {
    // `for` compares a usize counter through a bit cast to u64.
    var i: usize = 0;
    var s: u64 = 0;
    while (i < xs.len) : (i += 1) {
        const as_u64: u64 = i;
        s += xs[i] * as_u64;
        if (as_u64 == 2) i += 1;
    }
    return s;
}

test "promoted counters used through bit casts" {
    const xs = [_]u64{ 1, 2, 3, 4, 5, 6 };
    try expectEqual(@as(u64, 0 + 2 + 6 + 20 + 30), bitCastUse(&xs));
}

noinline fn signedNarrow(n: u32) i64 {
    var a: i8 = -100;
    var b: i16 = -30000;
    var c: i32 = -2_000_000_000;
    var sum: i64 = 0;
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        a -%= 13;
        b -%= 1234;
        c -%= 123_456_789;
        // Widening must see the sign-extended narrow values.
        sum += @as(i64, a) + b + c;
    }
    return sum;
}

test "promoted narrow signed locals widen correctly" {
    @setEvalBranchQuota(100_000);
    const expected = comptime signedNarrow(50);
    try expectEqual(expected, signedNarrow(50));
}

noinline fn crossClassStores(comptime T: type, n: u32, x: T) T {
    const Bits = @Int(.unsigned, @bitSizeOf(T));
    var value: T = x;
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        // Negation and bit casts can leave a float in a general register.
        value = -value;
        value += 1;
        value = @bitCast(@as(Bits, @bitCast(value)) ^ 0);
    }
    if (n > 3) value = -value;
    return value;
}

test "promoted float locals stored from general registers" {
    @setEvalBranchQuota(100_000);
    inline for (.{ f16, f32, f64 }) |T| {
        const expected = comptime crossClassStores(T, 7, 2.5);
        try expectEqual(expected, crossClassStores(T, 7, 2.5));
    }
}

noinline fn optionalFloat(comptime T: type, n: u32, x: T) ?T {
    var value: T = x;
    var i: u32 = 0;
    while (i < n) : (i += 1) value = value * 2 + 1;
    if (n == 0) return null;
    // The optional's payload may be taken into a general register.
    return value;
}

test "promoted float locals returned in optionals" {
    @setEvalBranchQuota(100_000);
    inline for (.{ f16, f32, f64 }) |T| {
        const expected = comptime optionalFloat(T, 5, 0.75);
        try expectEqual(expected, optionalFloat(T, 5, 0.75));
        try expectEqual(@as(?T, null), optionalFloat(T, 0, 0.75));
    }
}

noinline fn keyEql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

noinline fn findLast(items: []const []const u8, key: []const u8) ?*const []const u8 {
    var found: ?*const []const u8 = null;
    for (items) |*k| {
        // The stored value is a cast of a pointer computed before the branch.
        if (keyEql(k.*, key)) found = k;
    }
    return found;
}

noinline fn sumIfCast(xs: []const u32, limit: u32) u64 {
    var total: u64 = 0;
    var last: u64 = 0;
    for (xs) |x| {
        const wide: u64 = x;
        if (x < limit) last = wide;
        total += last;
    }
    return total;
}

test "promoted locals stored conditionally from a value defined earlier" {
    const items = [_][]const u8{ "a", "bb", "c", "bb", "d" };
    try expectEqual(&items[3], findLast(&items, "bb").?);
    try expectEqual(@as(?*const []const u8, null), findLast(&items, "zz"));
    const xs = [_]u32{ 1, 9, 2, 8, 3 };
    try expectEqual(@as(u64, 1 + 1 + 2 + 2 + 3), sumIfCast(&xs, 5));
}

// Values defined outside a loop and used in it are kept in registers too.

noinline fn invariants(comptime T: type, n: u32, a: T, b: T) [2]T {
    const sum = a +% b;
    const diff = a -% b;
    const shift: u6 = @truncate(n);
    var acc: T = 0;
    var other: T = 0;
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        acc +%= sum;
        other ^= diff;
        if (i & 1 == 0) acc +%= bitsOf(T, @truncate(@as(u64, 0x1234_5678_9abc) >> shift));
    }
    return .{ acc, other +% sum };
}

test "values defined outside a loop of every integer width" {
    @setEvalBranchQuota(100_000);
    inline for (int_types) |T| {
        const a: T = comptime bitsOf(T, 0xffff_fffd);
        const b: T = comptime bitsOf(T, 1);
        const expected = comptime invariants(T, 13, a, b);
        try expectEqual(expected, invariants(T, 13, a, b));
    }
}

noinline fn floatInvariants(comptime T: type, n: u32, x: T) T {
    const scale = x * 0.5;
    const offset = x + 1;
    var acc: T = 0;
    var i: u32 = 0;
    while (i < n) : (i += 1) acc = acc * scale + offset;
    return acc + scale;
}

test "float values defined outside a loop" {
    @setEvalBranchQuota(100_000);
    inline for (.{ f16, f32, f64 }) |T| {
        const expected = comptime floatInvariants(T, 6, 1.5);
        try expectEqual(expected, floatInvariants(T, 6, 1.5));
    }
}

noinline fn identity(x: u64) u64 {
    return x;
}

noinline fn invariantsAcrossCallsAndNesting(n: u32, base: u64) [3]u64 {
    const from_call = identity(base * 3);
    const outer_only = base + 7;
    var total: u64 = 0;
    var calls: u64 = 0;
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        // Defined in the outer loop, used in the inner one.
        const per_outer = from_call +% i;
        var j: u32 = 0;
        while (j < n) : (j += 1) {
            if (j == i) continue;
            total +%= per_outer ^ identity(j);
            calls += 1;
            if (j > 5) break;
        }
        total +%= outer_only;
    }
    return .{ total, calls, from_call };
}

test "values defined outside loops live across calls and nested loops" {
    @setEvalBranchQuota(100_000);
    const expected = comptime invariantsAcrossCallsAndNesting(9, 11);
    try expectEqual(expected, invariantsAcrossCallsAndNesting(9, 11));
}

noinline fn manyInvariants(n: u32, s: u64) u64 {
    const c0 = s +% 1;
    const c1 = s *% 3;
    const c2 = s ^ 0x55;
    const c3 = s +% 100;
    const c4 = s >> 1;
    const c5 = s << 2;
    const c6 = s -% 9;
    const c7 = s | 0x1000;
    const c8 = s & 0xff;
    const c9 = s *% 7;
    const c10 = s +% 0x77;
    const c11 = ~s;
    var acc: u64 = 0;
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        acc = acc *% 31 +% (c0 ^ c1) +% (c2 *% c3) +% (c4 | c5) +% (c6 & c7) +% c8 +% (c9 ^ c10) +% c11 +% i;
    }
    return acc;
}

test "more values defined outside a loop than registers" {
    @setEvalBranchQuota(100_000);
    const expected = comptime manyInvariants(10, 12345);
    try expectEqual(expected, manyInvariants(10, 12345));
}

noinline fn switchOnInvariant(m: u8, n: u32) u32 {
    // The switch keeps its operand's register reserved while it selects the
    // other prongs, which use the operand again.
    const prev: u8 = @truncate(identity(m ^ 0x5a));
    var acc: u32 = 0;
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        switch (prev) {
            0 => acc += 100,
            1, 2 => acc += @as(u32, prev) * 2,
            3, 4 => {
                if (prev == 3) acc += 1;
                acc += prev;
            },
            else => acc += 7,
        }
    }
    return acc;
}

test "switch on a value defined outside a loop" {
    for (0..8) |k| {
        const prev: u8 = @intCast(k);
        const per: u32 = switch (prev) {
            0 => 100,
            1, 2 => @as(u32, prev) * 2,
            3, 4 => @as(u32, @intFromBool(prev == 3)) + prev,
            else => 7,
        };
        try expectEqual(per * 5, switchOnInvariant(prev ^ 0x5a, 5));
    }
}

noinline fn blockResultInvariant(n: u32, flag: bool) u64 {
    const chosen: u64 = if (flag) identity(5) else identity(9);
    const ptr: *const u64 = &chosen;
    var acc: u64 = 0;
    var i: u32 = 0;
    while (i < n) : (i += 1) acc += chosen + ptr.*;
    return acc;
}

test "block results defined outside a loop" {
    try expectEqual(@as(u64, 4 * 10), blockResultInvariant(4, true));
    try expectEqual(@as(u64, 3 * 18), blockResultInvariant(3, false));
}

noinline fn squareInvariant(n: u32, x: u32) u64 {
    const y = x + 1;
    var acc: u64 = 0;
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        // Both operands are the same value kept in a register.
        acc += y * y;
        acc += @as(u64, y) + y;
    }
    return acc;
}

test "a value defined outside a loop used twice by one instruction" {
    try expectEqual(@as(u64, 5 * (16 + 8)), squareInvariant(5, 3));
}

noinline fn sliceSum(xs: []const u32) u64 {
    var acc: u64 = 0;
    for (xs) |x| acc += x;
    return acc;
}

noinline fn sliceInvariants(a: []u64, b: []u64, rounds: u32) u64 {
    // Two slices swapped between passes, each loaded once per pass and used
    // in the inner loops, passed to calls and compared.
    var src = a;
    var dst = b;
    var round: u32 = 0;
    var checks: u64 = 0;
    while (round < rounds) : (round += 1) {
        const s = src;
        const d = dst;
        for (s, 0..) |v, i| d[d.len - 1 - i] = v *% 3 +% round;
        checks +%= sliceSum32(d) +% @intFromBool(s.ptr == a.ptr);
        src = d;
        dst = s;
    }
    var acc: u64 = checks;
    for (src) |v| acc = acc *% 31 +% v;
    return acc;
}

noinline fn sliceSum32(xs: []const u64) u64 {
    var acc: u64 = 0;
    for (xs) |x| acc +%= x;
    return acc;
}

fn sliceInvariantsExpected(rounds: u32) u64 {
    var a = [_]u64{ 1, 2, 3, 4, 5, 6, 7 };
    var b: [7]u64 = @splat(0);
    return sliceInvariants(&a, &b, rounds);
}

test "slices defined outside a loop" {
    @setEvalBranchQuota(100_000);
    const xs = [_]u32{ 3, 1, 4, 1, 5, 9, 2, 6 };
    try expectEqual(@as(u64, 31), sliceSum(&xs));
    try expectEqual(@as(u64, 0), sliceSum(xs[0..0]));
    inline for (.{ 0, 1, 4, 5 }) |rounds| {
        const expected = comptime sliceInvariantsExpected(rounds);
        try expectEqual(expected, sliceInvariantsExpected(rounds));
    }
}

// Locals stored once and then only read (parameters copied to the stack,
// `var`s never written again) read the stored value directly.

const Pair = extern struct { a: u32, b: u32, c: u64 };
const Packed = packed struct(u32) { lo: u7, mid: u13, hi: u12 };

noinline fn readOnlyParams(s: []const u8, p: Pair, k: Packed, x: u64) u64 {
    var acc: u64 = 0;
    for (s, 0..) |byte, i| {
        acc +%= byte *% (i + 1) +% p.a +% p.c;
        acc +%= identity(s.len) +% p.b;
    }
    return acc +% s[0] +% k.mid +% k.hi +% k.lo +% x;
}

noinline fn storedOnceVar(n: u32) u64 {
    var never_written_again: u64 = n * 3;
    const pair: Pair = .{ .a = n, .b = n + 1, .c = n + 2 };
    var acc: u64 = 0;
    var i: u32 = 0;
    while (i < n) : (i += 1) acc += never_written_again + pair.b + identity(pair.c);
    _ = &never_written_again;
    return acc;
}

noinline fn writeThrough(p: *u64) void {
    p.* += 1000;
}

noinline fn storedOnceEscaping(n: u32) u64 {
    // Stored once, but written through a pointer: not read-only.
    var x: u64 = n;
    writeThrough(&x);
    var y: u64 = n;
    const p = &y;
    p.* += 1;
    return x + y;
}

noinline fn storedInBranch(flag: bool, v: u64) u64 {
    var x: u64 = undefined;
    if (flag) x = v;
    if (!flag) x = v + 1;
    return x;
}

test "locals stored once and then only read" {
    @setEvalBranchQuota(100_000);
    const s = "hello";
    const p: Pair = .{ .a = 7, .b = 9, .c = 11 };
    const k: Packed = .{ .lo = 5, .mid = 4000, .hi = 3000 };
    const expected = comptime readOnlyParams(s, p, k, 13);
    try expectEqual(expected, readOnlyParams(s, p, k, 13));
    const expected_var = comptime storedOnceVar(6);
    try expectEqual(expected_var, storedOnceVar(6));
    try expectEqual(@as(u64, 2 * 5 + 1001), storedOnceEscaping(5));
    try expectEqual(@as(u64, 8), storedInBranch(true, 8));
    try expectEqual(@as(u64, 9), storedInBranch(false, 8));
}

const Mixed = extern struct { f: f32, i: u32, d: f64 };

noinline fn floatFieldsOfParam(m: Mixed, n: u32) f64 {
    var acc: f64 = 0;
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        if (m.f < 2.5) acc += m.d;
        acc += @floatFromInt(m.i);
    }
    return acc + m.f;
}

test "float fields of a parameter read from the stored value" {
    const m: Mixed = .{ .f = 1.5, .i = 3, .d = 0.25 };
    try expectEqual(@as(f64, 4 * 3.25 + 1.5), floatFieldsOfParam(m, 4));
}

const FloatOrBits = extern union { f: f64, bits: u64 };

noinline fn floatThroughUnion(u: FloatOrBits, x: f64) bool {
    // The parameter is a union in a general register; its float field is
    // compared in a vector register.
    return u.f < x and u.bits != 0;
}

test "float field of a union parameter read from the stored value" {
    try expect(floatThroughUnion(.{ .f = 1.5 }, 2.5));
    try expect(!floatThroughUnion(.{ .f = 3.5 }, 2.5));
}

// Loads analyzed while the local still looked stored once, before a later
// store showed it is not: their results are used after a store to the local.

noinline fn loadUsedAfterStore(a: u32, n: u32) u64 {
    var local: u8 = @truncate(a);
    var acc: u32 = 0;
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        const prev = local;
        local = @truncate(n +% i);
        acc +%= prev;
    }
    return @as(u64, local) + acc;
}

noinline fn loadUsedAfterStoreInInnerLoop(a: u32, c: bool, n: u32) u64 {
    var acc: u64 = 0;
    var local: u32 = a;
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        const prev = local;
        acc +%= prev;
        var j: u32 = 0;
        while (j < 3) : (j += 1) local = a;
        if (!c) local = opaque32(a) -% prev;
        local +%= 1;
    }
    return acc +% local;
}

noinline fn opaque32(x: u32) u32 {
    return x;
}

noinline fn switchOnLoadAfterStore(a: u32, n: u32) u64 {
    var local: u8 = @truncate(a);
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        const prev = local;
        local = @truncate(n);
        switch (prev) {
            0 => {},
            else => local = 7,
        }
    }
    return local;
}

test "loads of a local stored again later used after a store" {
    try expectEqual(comptime loadUsedAfterStore(0x1ff, 5), loadUsedAfterStore(0x1ff, 5));
    try expectEqual(comptime loadUsedAfterStoreInInnerLoop(5, true, 4), loadUsedAfterStoreInInnerLoop(5, true, 4));
    try expectEqual(comptime loadUsedAfterStoreInInnerLoop(1, false, 3), loadUsedAfterStoreInInnerLoop(1, false, 3));
    try expectEqual(comptime switchOnLoadAfterStore(0, 2), switchOnLoadAfterStore(0, 2));
    try expectEqual(comptime switchOnLoadAfterStore(3, 2), switchOnLoadAfterStore(3, 2));
}

// A store of a bit cast that shares an earlier value (here a parameter) into
// a promoted local: the value is not defined at the store, so it must not be
// defined in the local's register.

noinline fn storeSharedBitCast(a: u32, b: u32, c: bool, n: u32) u64 {
    var acc: u64 = 0;
    var signed: i32 = @bitCast(n);
    var byte: u8 = @truncate(b);
    var other: u32 = a;
    var wide: u64 = n;
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        const prev = other;
        var j: u32 = 0;
        while (j < 3) : (j += 1) {
            acc +%= opaque32(@as(u32, @bitCast(signed)) & opaque32(a +% j));
            acc +%= wide;
        }
        if (c) {
            signed = @bitCast(n);
        } else {
            other = a -% prev;
        }
        signed +%= 1;
        byte +%= 1;
        wide +%= 1;
    }
    return acc +% @as(u32, @bitCast(signed)) +% byte +% other +% wide;
}

test "store of a shared bit cast into a promoted local" {
    try expectEqual(comptime storeSharedBitCast(5, 9, false, 4), storeSharedBitCast(5, 9, false, 4));
    try expectEqual(comptime storeSharedBitCast(5, 9, true, 4), storeSharedBitCast(5, 9, true, 4));
    try expectEqual(comptime storeSharedBitCast(0xffff_fff0, 1, false, 3), storeSharedBitCast(0xffff_fff0, 1, false, 3));
}
