//! Error unions returned in registers and tested by `try`, `catch` and `if`:
//! payloads of many sizes, error paths that use values defined before the
//! test (as `defer` and `errdefer` do), many values live into both paths,
//! nested `try`, `try` in loops and `try` through a pointer.

const std = @import("std");
const builtin = @import("builtin");
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectError = std.testing.expectError;

const Failure = error{ First, Second, Third };

var effects: u32 = 0;

noinline fn note(value: u64) void {
    @as(*volatile u32, &effects).* +%= @truncate(value);
}

noinline fn produce(comptime T: type, fail: ?Failure, value: T) Failure!T {
    if (fail) |err| return err;
    return value;
}

fn sample(comptime T: type) T {
    return switch (@typeInfo(T)) {
        .void => {},
        .int => @truncate(0xa1b2c3d4e5f60718293a4b5c6d7e8f90),
        .pointer => |pointer| switch (pointer.size) {
            .one => &sample_byte,
            .slice => sample_bytes[1..4],
            else => comptime unreachable,
        },
        .bool => true,
        .float => -1.5,
        else => comptime unreachable,
    };
}

var sample_byte: u8 = 0x5a;
const sample_bytes = "abcdef";

const payload_types = .{ void, bool, u8, i8, u16, i16, u32, i32, u48, u64, i64, u128, f32, f64, *u8, []const u8 };

noinline fn tryForward(comptime T: type, fail: ?Failure, value: T) Failure!T {
    return try produce(T, fail, value);
}

noinline fn tryWithDefer(comptime T: type, fail: ?Failure, value: T, tag: u64) Failure!T {
    defer note(tag);
    errdefer note(tag *% 3);
    const result = try produce(T, fail, value);
    note(tag +% 1);
    return result;
}

test "try on error unions of many payload types" {
    inline for (payload_types) |T| {
        const value = sample(T);
        try expectEqual(value, try tryForward(T, null, value));
        try expectError(error.Second, tryForward(T, error.Second, value));

        effects = 0;
        try expectEqual(value, try tryWithDefer(T, null, value, 11));
        try expectEqual(@as(u32, 23), effects);
        effects = 0;
        try expectError(error.Third, tryWithDefer(T, error.Third, value, 11));
        try expectEqual(@as(u32, 44), effects);
    }
}

noinline fn catchValue(comptime T: type, fail: ?Failure, value: T, fallback: T) T {
    return produce(T, fail, value) catch fallback;
}

noinline fn catchSwitch(fail: ?Failure, value: u32, a: u32, b: u32) u32 {
    return produce(u32, fail, value) catch |err| switch (err) {
        error.First => a,
        error.Second => b,
        error.Third => a +% b,
    };
}

noinline fn ifElse(comptime T: type, fail: ?Failure, value: T) ?Failure {
    if (produce(T, fail, value)) |payload| {
        if (payload != value) return error.First;
        return null;
    } else |err| return err;
}

test "catch and if on error unions in registers" {
    inline for (.{ u8, u16, u32, u64, u128, *u8 }) |T| {
        const value = sample(T);
        const fallback: T = if (T == *u8) &fallback_byte else 7;
        try expectEqual(value, catchValue(T, null, value, fallback));
        try expectEqual(fallback, catchValue(T, error.First, value, fallback));
        try expectEqual(@as(?Failure, null), ifElse(T, null, value));
        try expectEqual(@as(?Failure, error.Second), ifElse(T, error.Second, value));
    }
    try expectEqual(@as(u32, 5), catchSwitch(null, 5, 1, 2));
    try expectEqual(@as(u32, 1), catchSwitch(error.First, 5, 1, 2));
    try expectEqual(@as(u32, 2), catchSwitch(error.Second, 5, 1, 2));
    try expectEqual(@as(u32, 3), catchSwitch(error.Third, 5, 1, 2));
}

var fallback_byte: u8 = 0x33;

noinline fn tryVoid(fail: ?Failure) Failure!void {
    if (fail) |err| return err;
}

/// Many values live across the call and into both the error path, through
/// `errdefer`, and the success path.
noinline fn manyLive(fail_at: u32, a: u64, b: u32, c: u16, d: u8, e: u64, f: f64, g: f32) Failure!u64 {
    const x0 = a *% 3;
    const x1 = b +% 5;
    const x2 = c ^ 0x55;
    const x3 = d +% 1;
    const x4 = e -% a;
    const x5 = f * 2;
    const x6 = g + 1;
    const x7 = a ^ e;
    const x8 = b *% 7;
    const x9 = a +% b;
    errdefer note(x0 +% x1 +% x2 +% x3 +% x4 +% x7 +% x8 +% x9 +% @as(u64, @intFromFloat(x5 + x6)));
    try tryVoid(if (fail_at == 0) error.First else null);
    var sum = x0 +% x1 +% x2 +% x3;
    try tryVoid(if (fail_at == 1) error.Second else null);
    sum +%= x4 +% x7;
    const p = try produce(u32, if (fail_at == 2) error.Third else null, x1);
    sum +%= p +% x8 +% x9 +% @as(u64, @intFromFloat(x5 + x6));
    return sum;
}

test "try with many values live into both paths" {
    const args = .{ 0x123456789, 77, 0x1234, 200, 0xfedcba987654321, 2.5, 0.5 };
    const expected_note: u32 = @truncate(@call(.auto, expectedNote, args));
    for (0..3) |fail_at| {
        effects = 0;
        const result = @call(.auto, manyLive, .{@as(u32, @intCast(fail_at))} ++ args);
        try expectError(switch (fail_at) {
            0 => error.First,
            1 => error.Second,
            2 => error.Third,
            else => unreachable,
        }, result);
        try expectEqual(expected_note, effects);
    }
    effects = 0;
    try expectEqual(@call(.auto, expectedSum, args), try @call(.auto, manyLive, .{@as(u32, 3)} ++ args));
    try expectEqual(@as(u32, 0), effects);
}

fn expectedNote(a: u64, b: u32, c: u16, d: u8, e: u64, f: f64, g: f32) u64 {
    return a *% 3 +% (b +% 5) +% (c ^ 0x55) +% (d +% 1) +% (e -% a) +% (a ^ e) +% (b *% 7) +% (a +% b) +% @as(u64, @intFromFloat(f * 2 + (g + 1)));
}

fn expectedSum(a: u64, b: u32, c: u16, d: u8, e: u64, f: f64, g: f32) u64 {
    return expectedNote(a, b, c, d, e, f, g) +% (b +% 5);
}

noinline fn inner(fail: ?Failure, x: u32) Failure!u32 {
    const y = try produce(u32, fail, x +% 1);
    return y *% 2;
}

noinline fn outer(fail: ?Failure, x: u32, keep: u64) Failure!u64 {
    defer note(keep);
    const a = try inner(fail, x);
    const b = try inner(null, a);
    return keep +% a +% b;
}

test "nested try" {
    effects = 0;
    try expectEqual(@as(u64, 100 + 12 + 26), try outer(null, 5, 100));
    try expectEqual(@as(u32, 100), effects);
    effects = 0;
    try expectError(error.First, outer(error.First, 5, 100));
    try expectEqual(@as(u32, 100), effects);
}

noinline fn sumLoop(items: []const u32, fail_index: usize, base: u64) Failure!u64 {
    var total: u64 = base;
    for (items, 0..) |item, index| {
        errdefer note(index);
        total +%= try produce(u32, if (index == fail_index) error.Second else null, item);
        try tryVoid(null);
    }
    return total;
}

test "try in a loop" {
    const items = [_]u32{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 };
    effects = 0;
    try expectEqual(@as(u64, 1055), try sumLoop(&items, items.len, 1000));
    try expectEqual(@as(u32, 0), effects);
    try expectError(error.Second, sumLoop(&items, 6, 1000));
    try expectEqual(@as(u32, 6), effects);
}

noinline fn payloadPtr(comptime T: type, ptr: *Failure!T, keep: u64) Failure!*T {
    defer note(keep);
    return &(try ptr.*);
}

test "try through a pointer" {
    inline for (.{ u8, u32, u64, u128, []const u8 }) |T| {
        var value: Failure!T = sample(T);
        effects = 0;
        const ptr = try payloadPtr(T, &value, 9);
        try expectEqual(@as(u32, 9), effects);
        try expectEqual(sample(T), ptr.*);
        value = error.Third;
        try expectError(error.Third, payloadPtr(T, &value, 9));
        try expectEqual(@as(u32, 18), effects);
    }
}

noinline fn errorOnly(fail: ?Failure, a: u32, b: u32) Failure!void {
    errdefer note(a);
    try tryVoid(fail);
    note(b);
}

test "error-set-only error unions" {
    effects = 0;
    try errorOnly(null, 3, 4);
    try expectEqual(@as(u32, 4), effects);
    try expectError(error.First, errorOnly(error.First, 3, 4));
    try expectEqual(@as(u32, 7), effects);
}

noinline fn unwrapBoth(fail: ?Failure, value: u64) struct { u64, u16 } {
    const eu = produce(u64, fail, value);
    const err_int: u16 = if (eu) |_| 0 else |err| @intFromError(err);
    const payload = eu catch 1;
    return .{ payload, err_int };
}

test "error union used as a value by several unwraps" {
    const ok = unwrapBoth(null, 0x1234_5678_9abc);
    try expectEqual(@as(u64, 0x1234_5678_9abc), ok[0]);
    try expectEqual(@as(u16, 0), ok[1]);
    const bad = unwrapBoth(error.Second, 0x1234_5678_9abc);
    try expectEqual(@as(u64, 1), bad[0]);
    try expectEqual(@as(u16, @intFromError(error.Second)), bad[1]);
}
