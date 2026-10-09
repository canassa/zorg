const builtin = @import("builtin");
const std = @import("std");
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

test "if statements" {
    shouldBeEqual(1, 1);
    firstEqlThird(2, 1, 2);
}
fn shouldBeEqual(a: i32, b: i32) void {
    if (a != b) {
        unreachable;
    } else {
        return;
    }
}
fn firstEqlThird(a: i32, b: i32, c: i32) void {
    if (a == b) {
        unreachable;
    } else if (b == c) {
        unreachable;
    } else if (a == c) {
        return;
    } else {
        unreachable;
    }
}

test "else if expression" {
    try expect(elseIfExpressionF(1) == 1);
}
fn elseIfExpressionF(c: u8) u8 {
    if (c == 0) {
        return 0;
    } else if (c == 1) {
        return 1;
    } else {
        return @as(u8, 2);
    }
}

// #2297
var global_with_val: anyerror!u32 = 0;
var global_with_err: anyerror!u32 = error.SomeError;

test "unwrap mutable global var" {
    if (builtin.zig_backend == .stage2_spirv) return error.SkipZigTest;
    if (builtin.zig_backend == .stage2_sparc64) return error.SkipZigTest; // TODO

    if (global_with_val) |v| {
        try expect(v == 0);
    } else |_| {
        unreachable;
    }
    if (global_with_err) |_| {
        unreachable;
    } else |e| {
        try expect(e == error.SomeError);
    }
}

test "labeled break inside comptime if inside runtime if" {
    var answer: i32 = 0;
    var c = true;
    _ = &c;
    if (c) {
        answer = if (true) blk: {
            break :blk @as(i32, 42);
        };
    }
    try expect(answer == 42);
}

test "const result loc, runtime if cond, else unreachable" {
    const Num = enum { One, Two };

    var t = true;
    _ = &t;
    const x = if (t) Num.Two else unreachable;
    try expect(x == .Two);
}

test "if copies its payload" {
    if (builtin.zig_backend == .stage2_arm) return error.SkipZigTest;
    if (builtin.zig_backend == .stage2_sparc64) return error.SkipZigTest; // TODO

    const S = struct {
        fn doTheTest() !void {
            var tmp: ?i32 = 10;
            if (tmp) |value| {
                // Modify the original variable
                tmp = null;
                try expect(value == 10);
            } else unreachable;
        }
    };
    try S.doTheTest();
    try comptime S.doTheTest();
}

test "if prongs cast to expected type instead of peer type resolution" {
    const S = struct {
        fn doTheTest(f: bool) !void {
            var x: i32 = 0;
            x = if (f) 1 else 2;
            try expect(x == 2);

            var b = true;
            _ = &b;
            const y: i32 = if (b) 1 else 2;
            try expect(y == 1);
        }
    };
    try S.doTheTest(false);
    try comptime S.doTheTest(false);
}

test "if peer expressions inferred optional type" {
    if (builtin.zig_backend == .stage2_arm) return error.SkipZigTest;
    if (builtin.zig_backend == .stage2_sparc64) return error.SkipZigTest; // TODO
    if (builtin.zig_backend == .stage2_spirv) return error.SkipZigTest;

    var self: []const u8 = "abcdef";
    var index: usize = 0;
    _ = .{ &self, &index };
    const left_index = (index << 1) + 1;
    const right_index = left_index + 1;
    const left = if (left_index < self.len) self[left_index] else null;
    const right = if (right_index < self.len) self[right_index] else null;
    try expect(left_index < self.len);
    try expect(right_index < self.len);
    try expect(left.? == 98);
    try expect(right.? == 99);
}

test "if-else expression with runtime condition result location is inferred optional" {
    if (builtin.zig_backend == .stage2_arm) return error.SkipZigTest;
    if (builtin.zig_backend == .stage2_sparc64) return error.SkipZigTest; // TODO

    const A = struct { b: u64, c: u64 };
    var d: bool = true;
    _ = &d;
    const e = if (d) A{ .b = 15, .c = 30 } else null;
    try expect(e != null);
}

test "result location with inferred type ends up being pointer to comptime_int" {
    var a: ?u32 = 1234;
    var b: u32 = 2000;
    _ = .{ &a, &b };
    const c = if (a) |d| blk: {
        if (d < b) break :blk @as(u32, 1);
        break :blk 0;
    } else @as(u32, 0);
    try expect(c == 1);
}

test "if-@as-if chain" {
    var fast = true;
    var very_fast = false;
    _ = .{ &fast, &very_fast };

    const num_frames = if (fast)
        @as(u32, if (very_fast) 16 else 4)
    else
        1;

    try expect(num_frames == 4);
}

fn returnTrue() bool {
    return true;
}

test "if value shouldn't be load-elided if used later (structs)" {

    const Foo = struct { x: i32 };

    var a = Foo{ .x = 1 };
    var b = Foo{ .x = 1 };

    const c = if (@call(.never_inline, returnTrue, .{})) a else b;
    // The second variable is superfluous with the current
    // state of codegen optimizations, but in future
    // "if (smthg) a else a" may be optimized simply into "a".

    a.x = 2;
    b.x = 3;

    try std.testing.expectEqual(c.x, 1);
}

test "if value shouldn't be load-elided if used later (optionals)" {

    var a: ?i32 = 1;
    var b: ?i32 = 1;

    const c = if (@call(.never_inline, returnTrue, .{})) a else b;

    a = 2;
    b = 3;

    try std.testing.expectEqual(c, 1);
}

test "variable type inferred from if expression" {
    var a = if (true) {
        return;
    } else true;
    _ = &a;
    return error.TestFailed;
}

test "a conditional branch taken while every integer register holds a live value" {
    const Ctx = struct { a: u64, b: u64 };
    const Fields = struct { f0: u64, f1: u64, f2: u64, f3: u64, f4: u64, f5: u64, f6: u64, f7: u64, f8: u64, f9: u64, f10: u64, f11: u64, f12: u64, f13: u64, f14: u64, f15: u64, f16: u64, f17: u64, f18: u64, f19: u64, f20: u64, f21: u64, f22: u64, f23: u64, f24: u64, f25: u64, f26: u64, f27: u64, f28: u64 };
    const Out = struct { f0: u64, f1: u64, f2: u64, f3: u64, f4: u64, f5: u64, f6: u64, f7: u64, f8: u64, f9: u64, f10: u64, f11: u64, f12: u64, f13: u64, f14: u64, f15: u64, f16: u64, f17: u64, f18: u64, f19: u64, f20: u64, f21: u64, f22: u64, f23: u64, f24: u64, f25: u64, f26: u64, f27: u64, f28: u64, p: ?*const Ctx };
    const E = struct { f0: u64, f1: u64, f2: u64, f3: u64, f4: u64, f5: u64, f6: u64, f7: u64, f8: u64, f9: u64, f10: u64, f11: u64, f12: u64, f13: u64, f14: u64, f15: u64, f16: u64, f17: u64, f18: u64, f19: u64, f20: u64, f21: u64, f22: u64, f23: u64, f24: u64, f25: u64, f26: u64, f27: u64, f28: u64, dbg: ?Ctx };
    const S = struct {
        noinline fn consume(o: Out) u64 {
            var sum: u64 = 0;
            inline for (comptime std.meta.fieldNames(Fields), 1..) |name, i| sum +%= @field(o, name) * i;
            return sum +% (if (o.p) |c| c.a else 1000);
        }
        noinline fn pick(e: *const E) u64 {
            return consume(.{ .f0 = e.f0, .f1 = e.f1, .f2 = e.f2, .f3 = e.f3, .f4 = e.f4, .f5 = e.f5, .f6 = e.f6, .f7 = e.f7, .f8 = e.f8, .f9 = e.f9, .f10 = e.f10, .f11 = e.f11, .f12 = e.f12, .f13 = e.f13, .f14 = e.f14, .f15 = e.f15, .f16 = e.f16, .f17 = e.f17, .f18 = e.f18, .f19 = e.f19, .f20 = e.f20, .f21 = e.f21, .f22 = e.f22, .f23 = e.f23, .f24 = e.f24, .f25 = e.f25, .f26 = e.f26, .f27 = e.f27, .f28 = e.f28, .p = if (e.dbg) |*c| c else null });
        }
    };
    var e: E = undefined;
    inline for (comptime std.meta.fieldNames(Fields), 0..) |name, i| @field(e, name) = i * 3 + 1;
    e.dbg = .{ .a = 3, .b = 4 };
    try expectEqual(@as(u64, 24798), S.pick(&e));
    e.dbg = null;
    try expectEqual(@as(u64, 25795), S.pick(&e));
}

test "if with a long else branch" {
    if (builtin.zig_backend == .stage2_wasm) return error.SkipZigTest; // TODO
    if (builtin.zig_backend == .stage2_arm) return error.SkipZigTest; // TODO
    if (builtin.zig_backend == .stage2_sparc64) return error.SkipZigTest; // TODO
    if (builtin.zig_backend == .stage2_spirv) return error.SkipZigTest;
    if (builtin.zig_backend == .stage2_c and builtin.os.tag == .windows) return error.SkipZigTest; // MSVC doesn't support inline assembly

    const S = struct {
        noinline fn select(first: bool) u32 {
            @setEvalBranchQuota(20000);
            const result: u32 = if (first) result: {
                asm volatile ("nop");
                break :result 7;
            } else result: {
                inline for (0..9000) |_| asm volatile ("nop");
                break :result 42;
            };
            asm volatile ("nop");
            return result;
        }
    };
    var condition = false;
    const ptr: *volatile bool = &condition;
    try expect(S.select(ptr.*) == 42);
    ptr.* = true;
    try expect(S.select(ptr.*) == 7);
}
