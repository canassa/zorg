//! Integer arithmetic, logic and shifts with a comptime-known operand, at
//! the immediate encoding boundaries. The expected results are computed at
//! comptime.

const std = @import("std");
const builtin = @import("builtin");
const expectEqual = std.testing.expectEqual;

const int_types = .{ u1, i1, i7, u8, i16, u31, i32, u32, i33, u63, i64, u64, i65, u128, i128 };

/// 12-bit immediates and their shifted and negated forms, bitmask
/// immediates of several element sizes, and the 32 and 64-bit limits.
const int_candidates = [_]comptime_int{
    0,                  1,                  3,        0xff,       0xf0,       4095,       4096,       4097,        0xfff000,       0xfff001,
    0x1000000,          0x5555,             0xff00ff, 0x0f0f0f0f, 0x7fffffff, 0x80000000, 0xffffffff, 0x100000000, 0xffff0000ffff, 0x5555555555555555,
    0x8000000000000000, 0xfffffffffffff000, -1,       -4095,      -4096,      -4097,      -0xfff000,  -0x1000000,  -0x80000000,    -0x100,
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

fn Results(comptime T: type) type {
    return struct {
        wrapped: [4]T,
        with_overflow: [4]T,
        overflow: [4]u1,
        logic: [3]T,
    };
}

fn arith(comptime T: type, comptime c: T, x: T) Results(T) {
    const add = @addWithOverflow(x, c);
    const add_rev = @addWithOverflow(c, x);
    const sub = @subWithOverflow(x, c);
    const sub_rev = @subWithOverflow(c, x);
    return .{
        .wrapped = .{ x +% c, c +% x, x -% c, c -% x },
        .with_overflow = .{ add[0], add_rev[0], sub[0], sub_rev[0] },
        .overflow = .{ add[1], add_rev[1], sub[1], sub_rev[1] },
        .logic = .{ x & c, c | x, x ^ c },
    };
}

/// `arith` for the comptime reference, with the bitwise operations done
/// on the unsigned representation (comptime `|` of some negative wide
/// integers trips an assertion in the frontend).
fn expectedArith(comptime T: type, comptime c: T, comptime x: T) Results(T) {
    const U = @Int(.unsigned, @bitSizeOf(T));
    const add = @addWithOverflow(x, c);
    const add_rev = @addWithOverflow(c, x);
    const sub = @subWithOverflow(x, c);
    const sub_rev = @subWithOverflow(c, x);
    const uc: U = @bitCast(c);
    const ux: U = @bitCast(x);
    return .{
        .wrapped = .{ x +% c, c +% x, x -% c, c -% x },
        .with_overflow = .{ add[0], add_rev[0], sub[0], sub_rev[0] },
        .overflow = .{ add[1], add_rev[1], sub[1], sub_rev[1] },
        .logic = .{ @bitCast(ux & uc), @bitCast(uc | ux), @bitCast(ux ^ uc) },
    };
}

/// Safety-checked arithmetic; only called where it cannot overflow.
fn safeAdd(comptime T: type, comptime c: T, x: T) T {
    return x + c;
}

fn safeSub(comptime T: type, comptime c: T, x: T) T {
    return x - c;
}

fn checkArith(comptime T: type) !void {
    const values = comptime intValues(T);
    var runtime_values = values[0..values.len].*;
    _ = &runtime_values;
    inline for (values) |c| {
        @setEvalBranchQuota(1_000_000);
        const expected = comptime expected: {
            var row: [values.len]Results(T) = undefined;
            for (values, 0..) |x, i| row[i] = expectedArith(T, c, x);
            break :expected row;
        };
        for (runtime_values, 0..) |x, i| {
            try expectEqual(expected[i], arith(T, c, x));
            if (expected[i].overflow[0] == 0) try expectEqual(expected[i].with_overflow[0], safeAdd(T, c, x));
            if (expected[i].overflow[2] == 0) try expectEqual(expected[i].with_overflow[2], safeSub(T, c, x));
        }
    }
}

fn shifts(comptime T: type, comptime amount: std.math.Log2Int(T), x: T) [2]T {
    return .{ x << amount, x >> amount };
}

fn exactShifts(comptime T: type, comptime amount: std.math.Log2Int(T), x: T) [2]T {
    return .{ @shlExact(x >> amount, amount), @shrExact(x << amount >> amount << amount, amount) };
}

/// Shift amounts at the byte, word and limb boundaries.
fn shiftAmounts(comptime T: type) []const std.math.Log2Int(T) {
    comptime {
        var amounts: []const std.math.Log2Int(T) = &.{};
        for ([_]comptime_int{ 0, 1, 7, 8, 31, 32, 33, 63, 64, 65, @bitSizeOf(T) / 2, @bitSizeOf(T) - 2, @bitSizeOf(T) - 1 }) |candidate| {
            const amount = std.math.cast(std.math.Log2Int(T), candidate) orelse continue;
            if (candidate >= @bitSizeOf(T) or std.mem.indexOfScalar(std.math.Log2Int(T), amounts, amount) != null) continue;
            amounts = amounts ++ .{amount};
        }
        const final = amounts;
        return final;
    }
}

fn checkShifts(comptime T: type) !void {
    const values = comptime intValues(T);
    var runtime_values = values[0..values.len].*;
    _ = &runtime_values;
    inline for (comptime shiftAmounts(T)) |amount| {
        @setEvalBranchQuota(1_000_000);
        const expected = comptime expected: {
            var row: [values.len][2]T = undefined;
            for (values, 0..) |x, i| row[i] = shifts(T, amount, x);
            break :expected row;
        };
        for (runtime_values, 0..) |x, i| {
            try expectEqual(expected[i], shifts(T, amount, x));
            if (@typeInfo(T).int.signedness == .unsigned)
                try expectEqual([2]T{ expected[i][1] << amount, expected[i][0] >> amount }, exactShifts(T, amount, x));
        }
    }
}

test "integer arithmetic and logic with immediate operands" {
    if (builtin.zig_backend == .stage2_spirv) return error.SkipZigTest;
    inline for (int_types) |T| try checkArith(T);
}

test "integer shifts by comptime-known amounts at the boundaries" {
    if (builtin.zig_backend == .stage2_spirv) return error.SkipZigTest;
    inline for (int_types) |T| if (@bitSizeOf(T) > 1) try checkShifts(T);
}

fn loopWithImmediates(n: u32) u64 {
    var sum: u64 = 0;
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        if (i & 0xf0 == 0x30) continue;
        sum += (i ^ 0x5555) | 0x10000;
        sum -%= 4096;
        if (sum > 0xfff000) sum -= 0xfff000;
    }
    return sum;
}

test "loop with immediate operands" {
    const expected = comptime expected: {
        @setEvalBranchQuota(100_000);
        break :expected loopWithImmediates(1000);
    };
    try expectEqual(expected, loopWithImmediates(1000));
}
