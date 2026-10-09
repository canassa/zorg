//! Comparisons feeding conditional branches: integers of each register class
//! (narrow, 32-bit, 33 to 64-bit, two and four limbs) against registers and
//! immediates at the encoding boundaries, floats with NaN, optional and
//! pointer null checks, and compares whose bool is also used elsewhere. The
//! expected results are computed at comptime.

const std = @import("std");
const builtin = @import("builtin");
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

const int_types = .{ u1, i1, i7, u8, i16, u31, i32, u32, i33, u63, i64, u64, i65, u127, i128, u256 };

/// 12-bit immediates and their shifted and negated forms, 16-bit move
/// chunks, a bitmask immediate and the 32-bit limits.
const int_candidates = [_]comptime_int{
    0,           1,  4095,  4096,  4097,  0xfff000,  0xfff001,   0x1000000,  0xffff,     0x10000,
    0xff0,       -1, -4095, -4096, -4097, -0xfff000, 0x7fffffff, 0x80000000, 0xffffffff, 0x100000000,
    -0x80000000,
};

fn intValues(comptime T: type) []const T {
    comptime {
        var values: []const T = &.{};
        for (int_candidates) |candidate| {
            if (std.math.cast(T, candidate)) |value| values = values ++ .{value};
        }
        values = values ++ .{ std.math.minInt(T), std.math.maxInt(T) };
        if (@bitSizeOf(T) > 1) values = values ++ .{ std.math.minInt(T) + 1, std.math.maxInt(T) - 1 };
        const final = values;
        return final;
    }
}

/// Every operator, each through its own conditional branch.
fn branchMask(comptime T: type, x: T, y: T) u12 {
    var mask: u12 = 0;
    if (x < y) mask |= 1 << 0;
    if (x <= y) mask |= 1 << 1;
    if (x == y) mask |= 1 << 2;
    if (x >= y) mask |= 1 << 3;
    if (x > y) mask |= 1 << 4;
    if (x != y) mask |= 1 << 5;
    // Branch to the else side instead of over a single instruction.
    if (!(x < y)) mask |= 1 << 6 else mask ^= 1 << 7;
    if (!(x == y)) mask |= 1 << 8 else mask ^= 1 << 9;
    if (!(x > y)) mask |= 1 << 10 else mask ^= 1 << 11;
    return mask;
}

/// The same operators against a comptime-known operand on either side.
fn immMask(comptime T: type, comptime c: T, x: T) u12 {
    var mask: u12 = 0;
    if (x < c) mask |= 1 << 0;
    if (x <= c) mask |= 1 << 1;
    if (x == c) mask |= 1 << 2;
    if (x >= c) mask |= 1 << 3;
    if (x > c) mask |= 1 << 4;
    if (x != c) mask |= 1 << 5;
    if (c < x) mask |= 1 << 6;
    if (c <= x) mask |= 1 << 7;
    if (c == x) mask |= 1 << 8;
    if (c >= x) mask |= 1 << 9;
    if (c > x) mask |= 1 << 10;
    if (c != x) mask |= 1 << 11;
    return mask;
}

/// Loop conditions and early exits.
fn countBelow(comptime T: type, values: []const T, limit: T) usize {
    var count: usize = 0;
    var index: usize = 0;
    while (index < values.len) : (index += 1) {
        if (values[index] >= limit) continue;
        count += 1;
    }
    return count;
}

fn checkIntRegisters(comptime T: type) !void {
    const values = comptime intValues(T);
    const expected = comptime expected: {
        @setEvalBranchQuota(1_000_000);
        var table: [values.len][values.len]u12 = undefined;
        for (values, 0..) |x, i| for (values, 0..) |y, j| {
            table[i][j] = branchMask(T, x, y);
        };
        break :expected table;
    };
    var runtime_values = values[0..values.len].*;
    _ = &runtime_values;
    for (runtime_values, 0..) |x, i| for (runtime_values, 0..) |y, j| {
        try expectEqual(expected[i][j], branchMask(T, x, y));
    };
    for (runtime_values) |limit| {
        const expected_count = expected_count: {
            var count: usize = 0;
            for (runtime_values) |value| count += @intFromBool(value < limit);
            break :expected_count count;
        };
        try expectEqual(expected_count, countBelow(T, &runtime_values, limit));
    }
}

fn checkIntImmediates(comptime T: type) !void {
    const values = comptime intValues(T);
    var runtime_values = values[0..values.len].*;
    _ = &runtime_values;
    inline for (values) |c| {
        const expected = comptime expected: {
            @setEvalBranchQuota(1_000_000);
            var row: [values.len]u12 = undefined;
            for (values, 0..) |x, i| row[i] = immMask(T, c, x);
            break :expected row;
        };
        for (runtime_values, 0..) |x, i| try expectEqual(expected[i], immMask(T, c, x));
    }
}

test "integer compares feeding branches, register operands" {
    if (builtin.zig_backend == .stage2_spirv) return error.SkipZigTest;
    inline for (int_types) |T| try checkIntRegisters(T);
}

test "integer compares feeding branches, immediate operands" {
    if (builtin.zig_backend == .stage2_spirv) return error.SkipZigTest;
    inline for (int_types) |T| try checkIntImmediates(T);
}

test "bool compares feeding branches" {
    const values = [_]bool{ false, true };
    var runtime_values = values;
    _ = &runtime_values;
    for (runtime_values) |x| for (runtime_values) |y| {
        var mask: u4 = 0;
        if (x == y) mask |= 1;
        if (x != y) mask |= 2;
        if (x == true) mask |= 4;
        if (y != false) mask |= 8;
        try expectEqual(@as(u4, @intFromBool(x == y)) | @as(u4, @intFromBool(x != y)) << 1 |
            @as(u4, @intFromBool(x)) << 2 | @as(u4, @intFromBool(y)) << 3, mask);
    };
}

fn floatValues(comptime T: type) []const T {
    return &.{
        -std.math.inf(T), -std.math.floatMax(T), -4096.0,              -1.5,                      -std.math.floatMin(T), -0.0,
        0.0,              std.math.floatMin(T),  std.math.floatTrueMin(T), 1.0,                   1.5,                   4096.0,
        std.math.floatMax(T), std.math.inf(T),   std.math.nan(T),       -std.math.nan(T),
    };
}

fn floatImmMask(comptime T: type, comptime c: T, x: T) u12 {
    return immMask(T, c, x);
}

fn checkFloat(comptime T: type) !void {
    const values = comptime floatValues(T);
    const expected = comptime expected: {
        @setEvalBranchQuota(1_000_000);
        var table: [values.len][values.len]u12 = undefined;
        for (values, 0..) |x, i| for (values, 0..) |y, j| {
            table[i][j] = branchMask(T, x, y);
        };
        break :expected table;
    };
    var runtime_values = values[0..values.len].*;
    _ = &runtime_values;
    for (runtime_values, 0..) |x, i| for (runtime_values, 0..) |y, j| {
        try expectEqual(expected[i][j], branchMask(T, x, y));
    };
    inline for (.{ 0.0, -0.0, 1.0, -1.5, 4096.0 }) |c_lit| {
        const c: T = c_lit;
        const expected_row = comptime expected_row: {
            @setEvalBranchQuota(1_000_000);
            var row: [values.len]u12 = undefined;
            for (values, 0..) |x, i| row[i] = floatImmMask(T, c, x);
            break :expected_row row;
        };
        for (runtime_values, 0..) |x, i| try expectEqual(expected_row[i], floatImmMask(T, c, x));
    }
}

test "float compares feeding branches, including NaN" {
    if (builtin.zig_backend == .stage2_spirv) return error.SkipZigTest;
    try checkFloat(f16);
    try checkFloat(f32);
    try checkFloat(f64);
    if (builtin.zig_backend == .stage2_c) return; // f80/f128 support varies
    try checkFloat(f80);
    try checkFloat(f128);
}

fn optionalMask(opt: ?u32, opt_ptr: ?*const u32, opt_slice: ?[]const u8, ptr: *const u32, other: *const u32) u8 {
    var mask: u8 = 0;
    if (opt == null) mask |= 1 << 0;
    if (opt) |value| mask |= @as(u8, @intFromBool(value == 7)) << 1;
    if (opt_ptr == null) mask |= 1 << 2;
    if (opt_ptr != null) mask |= 1 << 3;
    if (opt_slice) |slice| mask |= @as(u8, @intFromBool(slice.len == 3)) << 4;
    if (ptr == other) mask |= 1 << 5;
    if (ptr != other) mask |= 1 << 6;
    if (opt_ptr == ptr) mask |= 1 << 7;
    return mask;
}

test "optional and pointer null checks feeding branches" {
    if (builtin.zig_backend == .stage2_spirv) return error.SkipZigTest;
    const a: u32 = 1;
    const b: u32 = 2;
    var opt: ?u32 = null;
    var opt_ptr: ?*const u32 = null;
    var opt_slice: ?[]const u8 = null;
    _ = .{ &opt, &opt_ptr, &opt_slice };
    try expectEqual(@as(u8, 0b0100_0101), optionalMask(opt, opt_ptr, opt_slice, &a, &b));
    opt = 7;
    opt_ptr = &a;
    opt_slice = "abc";
    try expectEqual(@as(u8, 0b1011_1010), optionalMask(opt, opt_ptr, opt_slice, &a, &a));
    opt = 0;
    opt_ptr = &b;
    opt_slice = "";
    try expectEqual(@as(u8, 0b0100_1000), optionalMask(opt, opt_ptr, opt_slice, &a, &b));
}

fn errorMask(eu: anyerror!u32, small: error{A}!u8, big: anyerror![3]u64) u8 {
    var mask: u8 = 0;
    if (eu) |value| mask |= @as(u8, @intFromBool(value == 5)) else |_| mask |= 1 << 1;
    if (small) |_| mask |= 1 << 2 else |_| {}
    if (big) |value| mask |= @as(u8, @intFromBool(value[2] == 9)) << 3 else |err| mask |= @as(u8, @intFromBool(err == error.B)) << 4;
    const is_err = if (eu) |_| false else |_| true;
    if (is_err) mask |= 1 << 5;
    return mask;
}

test "error union checks feeding branches" {
    var eu: anyerror!u32 = 5;
    var small: error{A}!u8 = error.A;
    var big: anyerror![3]u64 = error.B;
    _ = .{ &eu, &small, &big };
    try expectEqual(@as(u8, 0b01_0001), errorMask(eu, small, big));
    eu = error.C;
    small = 0;
    big = .{ 1, 2, 9 };
    try expectEqual(@as(u8, 0b10_1110), errorMask(eu, small, big));
}

fn boolUsedAfter(x: u32, y: u32) u32 {
    const less = x < y;
    var result: u32 = 0;
    if (less) result = 10 else result = 20;
    return result + @intFromBool(less);
}

fn boolUsedInThen(x: i64, y: i64) u32 {
    const less = x < y;
    if (less) return 100 + @as(u32, @intFromBool(less));
    return 200;
}

fn boolUsedInElse(x: i64, y: i64) u32 {
    const less = x < y;
    if (less) return 100;
    return 200 + @as(u32, @intFromBool(less)) + @as(u32, @intFromBool(!less)) * 2;
}

var stored_bool: bool = undefined;

fn boolStored(x: u16, y: u16) u32 {
    const equal = x == y;
    stored_bool = equal;
    if (equal) return 1;
    return 2;
}

fn boolSelect(x: i8, y: i8, a: u64, b: u64) u64 {
    return if (x > y) a else b;
}

test "compare whose bool is also used outside the branch" {
    try expectEqual(@as(u32, 11), boolUsedAfter(1, 2));
    try expectEqual(@as(u32, 20), boolUsedAfter(2, 2));
    try expectEqual(@as(u32, 101), boolUsedInThen(-5, 3));
    try expectEqual(@as(u32, 200), boolUsedInThen(5, 3));
    try expectEqual(@as(u32, 100), boolUsedInElse(-5, 3));
    try expectEqual(@as(u32, 202), boolUsedInElse(5, 3));
    try expectEqual(@as(u32, 1), boolStored(9, 9));
    try expect(stored_bool);
    try expectEqual(@as(u32, 2), boolStored(9, 8));
    try expect(!stored_bool);
    try expectEqual(@as(u64, 0xaaaa), boolSelect(-1, -2, 0xaaaa, 0xbbbb));
    try expectEqual(@as(u64, 0xbbbb), boolSelect(-2, -1, 0xaaaa, 0xbbbb));
}

var side_effects: u32 = 0;

fn sideEffect(result: bool) bool {
    side_effects += 1;
    return result;
}

fn andOr(x: u32, y: u32, z: u32) u8 {
    var mask: u8 = 0;
    if (x < y and sideEffect(y < z)) mask |= 1;
    if (x < y or sideEffect(y < z)) mask |= 2;
    if (x == 0 and y == 0) mask |= 4;
    if (x == 0 or y > 4095) mask |= 8;
    if ((x < y and y < z) or x == z) mask |= 16;
    return mask;
}

test "and/or of compares feeding branches, short-circuit side effects" {
    side_effects = 0;
    try expectEqual(@as(u8, 1 | 2 | 16), andOr(1, 2, 3));
    try expectEqual(@as(u32, 1), side_effects);
    side_effects = 0;
    try expectEqual(@as(u8, 0), andOr(3, 2, 1));
    try expectEqual(@as(u32, 1), side_effects);
    side_effects = 0;
    try expectEqual(@as(u8, 2 | 8), andOr(0, 5000, 1));
    try expectEqual(@as(u32, 1), side_effects);
    side_effects = 0;
    try expectEqual(@as(u8, 4 | 8 | 16), andOr(0, 0, 0));
    try expectEqual(@as(u32, 1), side_effects);
}

fn manyLive(values: *const [24]u64, x: u64, y: u64) u64 {
    var v: [24]u64 = undefined;
    inline for (&v, values) |*dst, src| dst.* = src *% 3;
    // Every value is live across the compare and branch and used on both paths.
    var sum: u64 = 0;
    if (x < y) {
        inline for (v) |value| sum +%= value;
        sum +%= 1;
    } else {
        inline for (v) |value| sum ^= value;
        sum +%= 2;
    }
    inline for (v) |value| sum +%= value *% 5;
    return sum;
}

fn manyLiveZero(values: *const [24]u64, x: u32, p: ?*const u64) u64 {
    var v: [24]u64 = undefined;
    inline for (&v, values) |*dst, src| dst.* = src *% 7;
    var sum: u64 = 0;
    if (x == 0) {
        inline for (v) |value| sum +%= value;
    } else {
        inline for (v) |value| sum ^= value;
    }
    if (p) |ptr| {
        inline for (v) |value| sum +%= value ^ ptr.*;
    } else {
        inline for (v) |value| sum -%= value;
    }
    inline for (v) |value| sum +%= value *% 5;
    return sum;
}

test "zero test and branch under register pressure" {
    var values: [24]u64 = undefined;
    for (&values, 0..) |*value, i| value.* = i * 0x7654321 + 3;
    const k: u64 = 0x1111;
    for ([_]u32{ 0, 1 }) |x| for ([_]?*const u64{ null, &k }) |p| {
        var expected: u64 = 0;
        for (values) |value| {
            if (x == 0) expected +%= value *% 7 else expected ^= value *% 7;
        }
        for (values) |value| {
            if (p) |ptr| expected +%= (value *% 7) ^ ptr.* else expected -%= value *% 7;
        }
        for (values) |value| expected +%= value *% 7 *% 5;
        try expectEqual(expected, manyLiveZero(&values, x, p));
    };
}

test "compare and branch under register pressure" {
    var values: [24]u64 = undefined;
    for (&values, 0..) |*value, i| value.* = i * 0x1234567 + 1;
    var expected_lt: u64 = 0;
    var expected_ge: u64 = 0;
    for (values) |value| {
        expected_lt +%= value *% 3;
        expected_ge ^= value *% 3;
    }
    expected_lt +%= 1;
    expected_ge +%= 2;
    for (values) |value| {
        expected_lt +%= value *% 3 *% 5;
        expected_ge +%= value *% 3 *% 5;
    }
    try expectEqual(expected_lt, manyLive(&values, 1, 2));
    try expectEqual(expected_ge, manyLive(&values, 2, 2));
}
