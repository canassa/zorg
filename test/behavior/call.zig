const builtin = @import("builtin");
const std = @import("std");
const assert = std.debug.assert;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

test "super basic invocations" {
    const foo = struct {
        fn foo() i32 {
            return 1234;
        }
    }.foo;
    try expect(@call(.auto, foo, .{}) == 1234);
    comptime assert(@call(.always_inline, foo, .{}) == 1234);
    {
        // comptime call without comptime keyword
        const result = @call(.compile_time, foo, .{}) == 1234;
        comptime assert(result);
    }
}

test "basic invocations" {
    if (builtin.zig_backend == .stage2_arm) return error.SkipZigTest; // TODO
    if (builtin.zig_backend == .stage2_sparc64) return error.SkipZigTest; // TODO
    if (builtin.zig_backend == .stage2_spirv) return error.SkipZigTest;

    if (builtin.zig_backend == .stage2_c and builtin.os.tag == .windows) return error.SkipZigTest; // MSVC doesn't support tail call modifiers

    const foo = struct {
        fn foo(_: i32) i32 {
            return 1234;
        }
    }.foo;
    try expect(@call(.auto, foo, .{1}) == 1234);
    comptime {
        // comptime calls with supported modifiers
        try expect(@call(.auto, foo, .{2}) == 1234);
        try expect(@call(.no_suspend, foo, .{3}) == 1234);
        try expect(@call(.always_tail, foo, .{4}) == 1234);
        try expect(@call(.always_inline, foo, .{5}) == 1234);
    }
    // comptime call without comptime keyword
    const result = @call(.compile_time, foo, .{6}) == 1234;
    comptime assert(result);
    // runtime calls of comptime-known function
    try expect(@call(.no_suspend, foo, .{7}) == 1234);
    try expect(@call(.never_tail, foo, .{8}) == 1234);
    try expect(@call(.never_inline, foo, .{9}) == 1234);
    // CBE does not support attributes on runtime functions
    if (builtin.zig_backend != .stage2_c) {
        // runtime calls of non comptime-known function
        var alias_foo = &foo;
        _ = &alias_foo;
        try expect(@call(.no_suspend, alias_foo, .{10}) == 1234);
        try expect(@call(.never_tail, alias_foo, .{11}) == 1234);
        try expect(@call(.never_inline, alias_foo, .{12}) == 1234);
    }
}

test "tuple parameters" {
    if (builtin.zig_backend == .stage2_arm) return error.SkipZigTest; // TODO
    if (builtin.zig_backend == .stage2_sparc64) return error.SkipZigTest; // TODO
    if (builtin.zig_backend == .stage2_spirv) return error.SkipZigTest;

    const add = struct {
        fn add(a: i32, b: i32) i32 {
            return a + b;
        }
    }.add;
    var a: i32 = 12;
    var b: i32 = 34;
    _ = .{ &a, &b };
    try expect(@call(.auto, add, .{ a, 34 }) == 46);
    try expect(@call(.auto, add, .{ 12, b }) == 46);
    try expect(@call(.auto, add, .{ a, b }) == 46);
    try expect(@call(.auto, add, .{ 12, 34 }) == 46);
    if (false) {
        comptime assert(@call(.auto, add, .{ 12, 34 }) == 46); // TODO
    }
    try expect(comptime @call(.auto, add, .{ 12, 34 }) == 46);
    {
        const separate_args0 = .{ a, b };
        const separate_args1 = .{ a, 34 };
        const separate_args2 = .{ 12, 34 };
        const separate_args3 = .{ 12, b };
        try expect(@call(.always_inline, add, separate_args0) == 46);
        try expect(@call(.always_inline, add, separate_args1) == 46);
        try expect(@call(.always_inline, add, separate_args2) == 46);
        try expect(@call(.always_inline, add, separate_args3) == 46);
    }
}

test "result location of function call argument through runtime condition and struct init" {
    if (builtin.zig_backend == .stage2_arm) return error.SkipZigTest; // TODO
    if (builtin.zig_backend == .stage2_sparc64) return error.SkipZigTest; // TODO

    const E = enum { a, b };
    const S = struct {
        e: E,
    };
    const namespace = struct {
        fn foo(s: S) !void {
            try expect(s.e == .b);
        }
    };
    var runtime = true;
    _ = &runtime;
    try namespace.foo(.{
        .e = if (!runtime) .a else .b,
    });
}

test "function call with 40 arguments" {
    if (builtin.zig_backend == .stage2_sparc64) return error.SkipZigTest; // TODO
    if (builtin.zig_backend == .stage2_riscv64) return error.SkipZigTest;

    const S = struct {
        fn doTheTest(thirty_nine: i32) !void {
            const result = add(
                0,
                1,
                2,
                3,
                4,
                5,
                6,
                7,
                8,
                9,
                10,
                11,
                12,
                13,
                14,
                15,
                16,
                17,
                18,
                19,
                20,
                21,
                22,
                23,
                24,
                25,
                26,
                27,
                28,
                29,
                30,
                31,
                32,
                33,
                34,
                35,
                36,
                37,
                38,
                thirty_nine,
                40,
            );
            try expect(result == 820);
            try expect(thirty_nine == 39);
        }

        fn add(
            a0: i32,
            a1: i32,
            a2: i32,
            a3: i32,
            a4: i32,
            a5: i32,
            a6: i32,
            a7: i32,
            a8: i32,
            a9: i32,
            a10: i32,
            a11: i32,
            a12: i32,
            a13: i32,
            a14: i32,
            a15: i32,
            a16: i32,
            a17: i32,
            a18: i32,
            a19: i32,
            a20: i32,
            a21: i32,
            a22: i32,
            a23: i32,
            a24: i32,
            a25: i32,
            a26: i32,
            a27: i32,
            a28: i32,
            a29: i32,
            a30: i32,
            a31: i32,
            a32: i32,
            a33: i32,
            a34: i32,
            a35: i32,
            a36: i32,
            a37: i32,
            a38: i32,
            a39: i32,
            a40: i32,
        ) i32 {
            return a0 +
                a1 +
                a2 +
                a3 +
                a4 +
                a5 +
                a6 +
                a7 +
                a8 +
                a9 +
                a10 +
                a11 +
                a12 +
                a13 +
                a14 +
                a15 +
                a16 +
                a17 +
                a18 +
                a19 +
                a20 +
                a21 +
                a22 +
                a23 +
                a24 +
                a25 +
                a26 +
                a27 +
                a28 +
                a29 +
                a30 +
                a31 +
                a32 +
                a33 +
                a34 +
                a35 +
                a36 +
                a37 +
                a38 +
                a39 +
                a40;
        }
    };
    try S.doTheTest(39);
}

test "arguments to comptime parameters generated in comptime blocks" {
    const S = struct {
        fn fortyTwo() i32 {
            return 42;
        }

        fn foo(comptime x: i32) void {
            if (x != 42) @compileError("bad");
        }
    };
    S.foo(S.fortyTwo());
}

test "forced tail call" {
    if (builtin.zig_backend == .stage2_arm) return error.SkipZigTest; // TODO
    if (builtin.zig_backend == .stage2_wasm) return error.SkipZigTest; // TODO
    if (builtin.zig_backend == .stage2_x86_64) return error.SkipZigTest; // TODO
    if (builtin.zig_backend == .stage2_sparc64) return error.SkipZigTest; // TODO
    if (builtin.zig_backend == .stage2_spirv) return error.SkipZigTest;
    if (builtin.zig_backend == .stage2_riscv64) return error.SkipZigTest;

    if (builtin.zig_backend == .stage2_llvm or builtin.zig_backend == .stage2_c) {
        if (builtin.cpu.arch.isMIPS() or builtin.cpu.arch.isPowerPC() or builtin.cpu.arch.isWasm()) {
            return error.SkipZigTest;
        }
    }

    if (builtin.zig_backend == .stage2_c and builtin.os.tag == .windows) return error.SkipZigTest; // MSVC doesn't support always tail calls

    const S = struct {
        fn fibonacciTailInternal(n: u16, a: u16, b: u16) u16 {
            if (n == 0) return a;
            if (n == 1) return b;
            return @call(
                .always_tail,
                fibonacciTailInternal,
                .{ n - 1, b, a + b },
            );
        }

        fn fibonacciTail(n: u16) u16 {
            return fibonacciTailInternal(n, 0, 1);
        }
    };
    try expect(S.fibonacciTail(10) == 55);
}

test "inline call preserves tail call" {
    if (builtin.zig_backend == .stage2_arm) return error.SkipZigTest; // TODO
    if (builtin.zig_backend == .stage2_wasm) return error.SkipZigTest; // TODO
    if (builtin.zig_backend == .stage2_x86_64) return error.SkipZigTest; // TODO
    if (builtin.zig_backend == .stage2_sparc64) return error.SkipZigTest; // TODO
    if (builtin.zig_backend == .stage2_spirv) return error.SkipZigTest;
    if (builtin.zig_backend == .stage2_riscv64) return error.SkipZigTest;

    if (builtin.zig_backend == .stage2_llvm or builtin.zig_backend == .stage2_c) {
        if (builtin.cpu.arch.isMIPS() or builtin.cpu.arch.isPowerPC() or builtin.cpu.arch.isWasm()) {
            return error.SkipZigTest;
        }
    }

    if (builtin.zig_backend == .stage2_c and builtin.os.tag == .windows) return error.SkipZigTest; // MSVC doesn't support always tail calls

    const max_depth = 1000;
    const S = struct {
        var a: u16 = 0;
        fn foo() void {
            return bar();
        }

        inline fn bar() void {
            if (a == max_depth) return;
            // Stack overflow if not tail called
            var buf: [100_000]u16 = undefined;
            buf[a] = a;
            a += 1;
            return @call(.always_tail, foo, .{});
        }
    };
    S.foo();
    try expect(S.a == max_depth);
}

test "inline call doesn't re-evaluate non generic struct" {
    if (builtin.zig_backend == .stage2_arm) return error.SkipZigTest; // TODO
    if (builtin.zig_backend == .stage2_spirv) return error.SkipZigTest;

    const S = struct {
        fn foo(f: struct { a: u8, b: u8 }) !void {
            try expect(f.a == 123);
            try expect(f.b == 45);
        }
    };
    const ArgTuple = std.meta.ArgsTuple(@TypeOf(S.foo));
    try @call(.always_inline, S.foo, ArgTuple{.{ .a = 123, .b = 45 }});
    try comptime @call(.always_inline, S.foo, ArgTuple{.{ .a = 123, .b = 45 }});
}

test "Enum constructed by @Enum passed as generic argument" {
    const S = struct {
        const E = std.meta.FieldEnum(struct {
            prev_pos: bool,
            pos: bool,
            vel: bool,
            damp_vel: bool,
            acc: bool,
            rgba: bool,
            prev_scale: bool,
            scale: bool,
            prev_rotation: bool,
            rotation: bool,
            angular_vel: bool,
            alive: bool,
        });
        fn foo(comptime a: E, b: u32) !void {
            try expect(@backingInt(a) == b);
        }
    };
    inline for (@typeInfo(S.E).@"enum".field_names, 0..) |_, i| {
        try S.foo(@as(S.E, @fromBackingInt(@intCast(i))), i);
    }
}

test "generic function with generic function parameter" {
    const S = struct {
        fn f(comptime a: fn (anytype) anyerror!void, b: anytype) anyerror!void {
            try a(b);
        }
        fn g(a: anytype) anyerror!void {
            try expect(a == 123);
        }
    };
    try S.f(S.g, 123);
}

test "recursive inline call with comptime known argument" {
    const S = struct {
        inline fn foo(x: i32) i32 {
            if (x <= 0) {
                return 0;
            } else {
                return x * 2 + foo(x - 1);
            }
        }
    };

    try expect(S.foo(4) == 20);
}

test "inline while with @call" {
    if (builtin.zig_backend == .stage2_arm) return error.SkipZigTest; // TODO
    if (builtin.zig_backend == .stage2_spirv) return error.SkipZigTest;

    const S = struct {
        fn inc(a: *u32) void {
            a.* += 1;
        }
    };
    var a: u32 = 0;
    comptime var i = 0;
    inline while (i < 10) : (i += 1) {
        @call(.auto, S.inc, .{&a});
    }
    try expect(a == 10);
}

test "method call as parameter type" {
    const S = struct {
        fn foo(x: anytype, y: @TypeOf(x).Inner()) @TypeOf(y) {
            return y;
        }
        fn Inner() type {
            return u64;
        }
    };
    try expectEqual(@as(u64, 123), S.foo(S{}, 123));
    try expectEqual(@as(u64, 500), S.foo(S{}, 500));
}

test "non-anytype generic parameters provide result type" {
    if (builtin.zig_backend == .stage2_arm) return error.SkipZigTest; // TODO
    if (builtin.zig_backend == .stage2_sparc64) return error.SkipZigTest; // TODO

    const S = struct {
        fn f(comptime T: type, y: T) !void {
            try expectEqual(@as(T, 123), y);
        }

        fn g(x: anytype, y: @TypeOf(x)) !void {
            try expectEqual(@as(@TypeOf(x), 0x222), y);
        }
    };

    var rt_u16: u16 = 123;
    var rt_u32: u32 = 0x10000222;
    _ = .{ &rt_u16, &rt_u32 };

    try S.f(u8, @intCast(rt_u16));
    try S.f(u8, @intCast(123));

    try S.g(rt_u16, @truncate(rt_u32));
    try S.g(rt_u16, @truncate(0x10000222));

    try comptime S.f(u8, @intCast(123));
    try comptime S.g(@as(u16, undefined), @truncate(0x99990222));
}

test "argument to generic function has correct result type" {
    if (builtin.zig_backend == .stage2_arm) return error.SkipZigTest; // TODO
    if (builtin.zig_backend == .stage2_sparc64) return error.SkipZigTest; // TODO

    const S = struct {
        fn foo(_: anytype, e: enum { a, b }) bool {
            return e == .b;
        }

        fn doTheTest() !void {
            var t = true;
            _ = &t;

            // Since the enum literal passes through a runtime conditional here, these can only
            // compile if RLS provides the correct result type to the argument
            try expect(foo({}, if (!t) .a else .b));
            try expect(!foo("dummy", if (t) .a else .b));
            try expect(foo({}, if (t) .b else .a));
            try expect(!foo(123, if (t) .a else .a));
            try expect(foo(123, if (t) .b else .b));
        }
    };

    try S.doTheTest();
    try comptime S.doTheTest();
}

test "call inline fn through pointer" {
    if (builtin.zig_backend == .stage2_spirv) return error.SkipZigTest;

    const S = struct {
        inline fn foo(x: u8) !void {
            try expect(x == 123);
        }
    };
    const f = &S.foo;
    try f(123);
}

test "call function in comptime field" {
    if (builtin.zig_backend == .stage2_arm) return error.SkipZigTest; // TODO

    const S = struct {
        comptime capacity: fn () u64 = capacity_,
        fn capacity_() u64 {
            return 64;
        }
    };
    try std.testing.expect((S{}).capacity() == 64);
}

test "call function pointer in comptime field" {
    if (builtin.zig_backend == .stage2_arm) return error.SkipZigTest; // TODO
    if (builtin.zig_backend == .stage2_sparc64) return error.SkipZigTest; // TODO
    if (builtin.zig_backend == .stage2_spirv) return error.SkipZigTest;

    const Auto = struct {
        auto: [max_len]u8 = undefined,
        offset: u64 = 0,

        comptime capacityFn: *const fn () u64 = capacity,

        const max_len: u64 = 32;

        fn capacity() u64 {
            return max_len;
        }
    };

    const a: Auto = .{ .offset = 16, .capacityFn = Auto.capacity };
    try std.testing.expect(a.capacityFn() == 32);
    try std.testing.expect((a.capacityFn)() == 32);
}

test "generic function pointer can be called" {
    if (builtin.zig_backend == .stage2_spirv) return error.SkipZigTest;

    const S = struct {
        var ok = false;
        fn foo(x: anytype) void {
            ok = x;
        }
    };
    const x = &S.foo;
    x(true);
    try expect(S.ok);
}

test "value returned from comptime function is comptime known" {
    const S = struct {
        fn fieldCount(comptime T: type) switch (@typeInfo(T)) {
            .@"struct" => comptime_int,
            else => unreachable,
        } {
            return switch (@typeInfo(T)) {
                .@"struct" => |info| info.field_names.len,
                else => unreachable,
            };
        }
    };
    const fields_len = S.fieldCount(@TypeOf(.{}));
    comptime assert(fields_len == 0);
}

test "registers get overwritten when ignoring return" {
    if (builtin.zig_backend == .stage2_arm) return error.SkipZigTest;
    if (builtin.cpu.arch != .x86_64 or builtin.os.tag != .linux) return error.SkipZigTest;

    const S = struct {
        fn open() usize {
            return 42;
        }
        fn write(fd: usize, a: [*]const u8, len: usize) usize {
            return syscall4(.WRITE, fd, @intFromPtr(a), len);
        }
        fn syscall4(_: enum { WRITE }, _: usize, _: usize, _: usize) usize {
            return 23;
        }
        fn close(fd: usize) usize {
            if (fd != 42)
                unreachable;
            return 0;
        }
    };

    const fd = S.open();
    _ = S.write(fd, "a", 1);
    _ = S.close(fd);
}

test "call with union with zero sized field is not memorized incorrectly" {
    const U = union(enum) {
        T: type,
        N: void,
        fn S(comptime query: @This()) type {
            return struct {
                fn tag() type {
                    return query.T;
                }
            };
        }
    };
    const s1 = U.S(U{ .T = u32 }).tag();
    try std.testing.expectEqual(u32, s1);

    const s2 = U.S(U{ .T = u64 }).tag();
    try std.testing.expectEqual(u64, s2);
}

test "function call with cast to anyopaque pointer" {
    if (builtin.zig_backend == .stage2_arm) return error.SkipZigTest; // TODO
    if (builtin.zig_backend == .stage2_sparc64) return error.SkipZigTest; // TODO
    if (builtin.zig_backend == .stage2_spirv) return error.SkipZigTest;

    const Foo = struct {
        y: u8,
        var foo: @This() = undefined;
        const t = &foo;

        fn bar(pointer: ?*anyopaque) void {
            _ = pointer;
        }
    };
    Foo.bar(Foo.t);
}

test "arguments pointed to on stack into tailcall" {
    if (builtin.zig_backend == .stage2_riscv64) return error.SkipZigTest;
    if (builtin.zig_backend == .stage2_x86_64) return error.SkipZigTest;
    if (builtin.zig_backend == .stage2_spirv) return error.SkipZigTest;
    if (builtin.zig_backend == .stage2_c and builtin.os.tag == .windows) return error.SkipZigTest; // MSVC doesn't support always tail calls

    switch (builtin.cpu.arch) {
        .wasm32,
        .wasm64,
        .mips,
        .mipsel,
        .mips64,
        .mips64el,
        .powerpc,
        .powerpcle,
        .powerpc64,
        .powerpc64le,
        => return error.SkipZigTest,
        else => {},
    }

    const S = struct {
        var base: usize = undefined;
        var result_off: [7]usize = undefined;
        var result_len: [7]usize = undefined;
        var result_index: usize = 0;

        noinline fn insertionSort(data: []u64) void {
            result_off[result_index] = @intFromPtr(data.ptr) - base;
            result_len[result_index] = data.len;
            result_index += 1;
            if (data.len > 1) {
                var least_i: usize = 0;
                var i: usize = 1;
                while (i < data.len) : (i += 1) {
                    if (data[i] < data[least_i])
                        least_i = i;
                }
                std.mem.swap(u64, &data[0], &data[least_i]);

                // there used to be a bug where
                // `data[1..]` is created on the stack
                // and pointed to by the first argument register
                // then stack is invalidated by the tailcall and
                // overwritten by callee
                // https://github.com/ziglang/zig/issues/9703
                return @call(.always_tail, insertionSort, .{data[1..]});
            }
        }
    };

    var data = [_]u64{ 1, 6, 2, 7, 1, 9, 3 };
    S.base = @intFromPtr(&data);
    S.insertionSort(data[0..]);
    try expect(S.result_len[0] == 7);
    try expect(S.result_len[1] == 6);
    try expect(S.result_len[2] == 5);
    try expect(S.result_len[3] == 4);
    try expect(S.result_len[4] == 3);
    try expect(S.result_len[5] == 2);
    try expect(S.result_len[6] == 1);

    try expect(S.result_off[0] == 0);
    try expect(S.result_off[1] == 8);
    try expect(S.result_off[2] == 16);
    try expect(S.result_off[3] == 24);
    try expect(S.result_off[4] == 32);
    try expect(S.result_off[5] == 40);
    try expect(S.result_off[6] == 48);
}

test "tail call function pointer" {
    if (builtin.zig_backend == .stage2_arm) return error.SkipZigTest; // TODO
    if (builtin.zig_backend == .stage2_wasm) return error.SkipZigTest; // TODO
    if (builtin.zig_backend == .stage2_x86_64) return error.SkipZigTest; // TODO
    if (builtin.zig_backend == .stage2_sparc64) return error.SkipZigTest; // TODO
    if (builtin.zig_backend == .stage2_spirv) return error.SkipZigTest;
    if (builtin.zig_backend == .stage2_riscv64) return error.SkipZigTest;

    if (builtin.zig_backend == .stage2_llvm or builtin.zig_backend == .stage2_c) {
        if (builtin.cpu.arch.isMIPS() or builtin.cpu.arch.isPowerPC() or builtin.cpu.arch.isWasm()) {
            return error.SkipZigTest;
        }
    }

    if (builtin.zig_backend == .stage2_c and builtin.os.tag == .windows) return error.SkipZigTest; // MSVC doesn't support always tail calls

    const S = struct {
        fn foo(n: u8) void {
            if (n == 0) return;
            const other: *const fn (u8) void = &bar;
            return @call(.always_tail, other, .{n - 1});
        }
        fn bar(n: u8) void {
            var other: *const fn (u8) void = undefined;
            other = &foo; // runtime-known pointer
            return @call(.always_tail, other, .{n});
        }
    };

    S.foo(100);
}

test "tail call with potentially extended types" {
    if (builtin.zig_backend == .stage2_wasm) return error.SkipZigTest; // TODO
    if (builtin.zig_backend == .stage2_x86_64) return error.SkipZigTest; // TODO
    if (builtin.zig_backend == .stage2_spirv) return error.SkipZigTest;

    if (builtin.zig_backend == .stage2_llvm or builtin.zig_backend == .stage2_c) {
        if (builtin.cpu.arch.isMIPS() or builtin.cpu.arch.isPowerPC() or builtin.cpu.arch.isWasm()) {
            return error.SkipZigTest;
        }
    }

    if (builtin.zig_backend == .stage2_c and builtin.os.tag == .windows) return error.SkipZigTest; // MSVC doesn't support always tail calls

    const S = struct {
        fn Test(comptime Return: type) type {
            return struct {
                fn callee(@"u8": u8, @"i8": i8, @"u16": u16, @"i16": i16) callconv(.c) Return {
                    return @intCast(@as(i32, @"u8") + @as(i32, @"i8") + @as(i32, @"u16") + @as(i32, @"i16"));
                }
                fn caller(@"u8": u8, @"i8": i8, @"u16": u16, @"i16": i16) callconv(.c) Return {
                    return @call(.always_tail, callee, .{ @"u8", @"i8", @"u16", @"i16" });
                }
            };
        }
    };
    try std.testing.expect(S.Test(u8).caller(1, -2, 3, 4) == 6);
    try std.testing.expect(S.Test(i8).caller(5, -6, 7, -8) == -2);
    try std.testing.expect(S.Test(u16).caller(9, 10, 11, 12) == 42);
    try std.testing.expect(S.Test(i16).caller(13, 14, 15, -16) == 26);
}

test "pass a tagged union whose fields split differently by value" {
    if (builtin.zig_backend == .stage2_arm) return error.SkipZigTest; // TODO
    if (builtin.zig_backend == .stage2_sparc64) return error.SkipZigTest; // TODO
    if (builtin.zig_backend == .stage2_spirv) return error.SkipZigTest;

    const S = struct {
        const Value = union(enum) {
            triple: [3]u32,
            byte: u8,
        };
        noinline fn consume(value: Value, marker: u32) u32 {
            return switch (value) {
                .triple => |words| words[0] + words[1] + words[2] + marker,
                .byte => |byte| @as(u32, byte) + marker,
            };
        }
    };
    var seed: u32 = 11;
    const pointer: *volatile u32 = &seed;
    var stored: S.Value = .{ .triple = .{ pointer.*, 22, 33 } };
    const union_pointer: *volatile S.Value = &stored;
    const first = union_pointer.*;
    const checksum = S.consume(first, 7);
    try expect(switch (first) {
        .triple => |words| words[0] == 11 and words[2] == 33,
        .byte => false,
    });
    try expect(checksum == 73);
    union_pointer.* = .{ .byte = @truncate(pointer.*) };
    const second = union_pointer.*;
    const byte_checksum = S.consume(second, 7);
    try expect(switch (second) {
        .triple => false,
        .byte => |byte| byte == 11,
    });
    try expect(byte_checksum == 18);
}

test "pass a two-register composite after seven integer arguments" {
    if (builtin.zig_backend == .stage2_arm) return error.SkipZigTest; // TODO
    if (builtin.zig_backend == .stage2_sparc64) return error.SkipZigTest; // TODO
    if (builtin.zig_backend == .stage2_spirv) return error.SkipZigTest;

    const S = struct {
        const Container = union(enum) { first: *u64, second: *u64 };
        noinline fn exhausted(a: u64, b: u64, c: u64, d: u64, e: u64, f: u64, g: u64, container: Container, tail: *u64) u64 {
            const payload = switch (container) {
                .first => |ptr| ptr.*,
                .second => |ptr| ptr.* + 1,
            };
            return a + b + c + d + e + f + g + payload + tail.*;
        }
        fn call(tail: *u64, second: bool) u64 {
            const container: Container = if (second) .{ .second = tail } else .{ .first = tail };
            return exhausted(1, 2, 3, 4, 5, 6, 7, container, tail);
        }
    };
    var tail: u64 = 1000;
    try expect(S.call(&tail, false) == 2028);
    try expect(S.call(&tail, true) == 2029);
}

test "pass a slice on the stack after ten integer arguments" {
    if (builtin.zig_backend == .stage2_arm) return error.SkipZigTest; // TODO
    if (builtin.zig_backend == .stage2_sparc64) return error.SkipZigTest; // TODO
    if (builtin.zig_backend == .stage2_spirv) return error.SkipZigTest;

    const S = struct {
        noinline fn consume(a0: u64, a1: u64, a2: u64, a3: u64, a4: u64, a5: u64, a6: u64, a7: u64, a8: u64, a9: u64, bytes: []const u8) u64 {
            var sum = a0 + a1 + a2 + a3 + a4 + a5 + a6 + a7 + a8 + a9;
            for (bytes) |byte| sum += byte;
            return sum;
        }
    };
    var source = [_]u64{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 };
    const ptr: *volatile [10]u64 = &source;
    var bytes = [_]u8{ 11, 12, 13 };
    try expect(S.consume(ptr[0], ptr[1], ptr[2], ptr[3], ptr[4], ptr[5], ptr[6], ptr[7], ptr[8], ptr[9], &bytes) == 91);
}

test "return a multi-field aggregate indirectly from a loop" {
    if (builtin.zig_backend == .stage2_arm) return error.SkipZigTest; // TODO
    if (builtin.zig_backend == .stage2_sparc64) return error.SkipZigTest; // TODO
    if (builtin.zig_backend == .stage2_spirv) return error.SkipZigTest;

    const S = struct {
        const Item = struct { a: u64, b: u32, c: u8 };
        const List = std.MultiArrayList(Item);
        noinline fn makeSlice(list: List) List.Slice {
            return list.slice();
        }
    };
    var storage: [128]u8 align(16) = undefined;
    const list: S.List = .{ .bytes = &storage, .len = 3, .capacity = 5 };
    const slice = S.makeSlice(list);
    try expect(slice.len == 3 and slice.capacity == 5);
    try expect(@intFromPtr(slice.ptrs[0]) == @intFromPtr(&storage));
    try expect(@intFromPtr(slice.ptrs[1]) == @intFromPtr(&storage) + 5 * 8);
    try expect(@intFromPtr(slice.ptrs[2]) == @intFromPtr(&storage) + 5 * 12);
}

test "pass and return aggregates split across registers" {
    if (builtin.zig_backend == .stage2_arm) return error.SkipZigTest; // TODO
    if (builtin.zig_backend == .stage2_sparc64) return error.SkipZigTest; // TODO
    if (builtin.zig_backend == .stage2_spirv) return error.SkipZigTest;
    if (builtin.zig_backend == .stage2_riscv64) return error.SkipZigTest;

    const S = struct {
        const Wrapper = struct { slice: []const u8 };
        const Result = union(enum) { bytes: [32]u8, number: u64 };
        noinline fn sum(x: Wrapper) u64 {
            var total: u64 = 0;
            for (x.slice) |byte| total += byte;
            return total;
        }
        noinline fn optional(x: ?f128) ?f128 {
            if (x) |value| return value;
            return null;
        }
        noinline fn unionBytes(x: [31]u8) Result {
            var result: Result = .{ .bytes = undefined };
            result.bytes[0..31].* = x;
            result.bytes[31] = 199;
            return result;
        }
        noinline fn arrayBytes(bytes: [200]u8) [200]u8 {
            return bytes;
        }
    };
    const text: []const u8 = "abc";
    try expect(S.sum(.{ .slice = text }) == 'a' + 'b' + 'c');
    try expect(S.optional(null) == null);
    try expect(S.optional(1.25).? == 1.25);
    var bytes: [31]u8 = undefined;
    for (&bytes, 0..) |*byte, i| byte.* = 3 + @as(u8, @intCast(i));
    const result = S.unionBytes(bytes);
    var total: u64 = 0;
    for (result.bytes) |byte| total += byte;
    try expect(total == 31 * 3 + 30 * 31 / 2 + 199);
    var large: [200]u8 = undefined;
    for (&large, 0..) |*byte, i| byte.* = @intCast(i);
    const copied = S.arrayBytes(large);
    for (copied, 0..) |byte, i| try expect(byte == i);
}

test "pass and return a struct whose fields leave its second eight bytes padding" {
    if (builtin.zig_backend == .stage2_arm) return error.SkipZigTest; // TODO
    if (builtin.zig_backend == .stage2_sparc64) return error.SkipZigTest; // TODO
    if (builtin.zig_backend == .stage2_spirv) return error.SkipZigTest;
    if (builtin.zig_backend == .stage2_riscv64) return error.SkipZigTest;

    const S = struct {
        const Aligned = extern struct { a: u8 align(16) };
        noinline fn bump(x: Aligned, after: u64) Aligned {
            return .{ .a = x.a + @as(u8, @intCast(after)) };
        }
    };
    try expect(S.bump(.{ .a = 41 }, 1).a == 42);
}

test "struct and tuple arguments of an integer followed by floats" {
    const S = struct {
        const IntFloat = struct { a: u32, b: f32 };
        const IntFloats = struct { a: u32, b: f32, c: f32, d: f32 };
        const IntDouble = extern struct { a: u64, b: f64 };
        noinline fn intFloat(p: IntFloat) u64 {
            return @as(u64, p.a) * 1000 + @as(u64, @intFromFloat(p.b));
        }
        noinline fn intFloats(p: IntFloats) u64 {
            return @as(u64, p.a) * 1000 + @as(u64, @intFromFloat(p.b + p.c + p.d));
        }
        noinline fn intDouble(p: IntDouble) callconv(.c) u64 {
            return p.a * 1000 + @as(u64, @intFromFloat(p.b));
        }
        noinline fn tuple(p: struct { u16, f16 }) u64 {
            return @as(u64, p[0]) * 1000 + @as(u64, @intFromFloat(p[1]));
        }
    };
    try expect(S.intFloat(.{ .a = 3, .b = 7.5 }) == 3007);
    try expect(S.intFloats(.{ .a = 3, .b = 0.5, .c = -0.0, .d = 3.5 }) == 3004);
    try expect(S.intDouble(.{ .a = 3, .b = 7.5 }) == 3007);
    try expect(S.tuple(.{ 3, 7.5 }) == 3007);
    var a: u32 = 4;
    var b: f32 = 8.5;
    var c: f64 = 9.5;
    var d: f16 = 2.5;
    _ = .{ &a, &b, &c, &d };
    try expect(S.intFloat(.{ .a = a, .b = b }) == 4008);
    try expect(S.intFloats(.{ .a = a, .b = b, .c = b, .d = 1.0 }) == 4018);
    try expect(S.intDouble(.{ .a = a, .b = c }) == 4009);
    try expect(S.tuple(.{ @intCast(a), d }) == 4002);
}

test "float results passed in general registers as fields of a struct" {
    const S = struct {
        const IntDouble = struct { a: u64, b: f64 };
        const IntHalf = struct { a: u16, b: f16 };
        noinline fn intDouble(p: IntDouble) u64 {
            return p.a * 1000 + @as(u64, @intFromFloat(p.b));
        }
        noinline fn intHalf(p: IntHalf) u64 {
            return @as(u64, p.a) * 1000 + @as(u64, @intFromFloat(p.b));
        }
        noinline fn tuple(p: struct { u32, f32 }) u64 {
            return @as(u64, p[0]) * 1000 + @as(u64, @intFromFloat(p[1]));
        }
    };
    var a: u32 = 4;
    var b: f32 = 8.5;
    var c: f64 = 2.25;
    _ = .{ &a, &b, &c };
    try expect(S.intDouble(.{ .a = a, .b = b }) == 4008);
    try expect(S.intDouble(.{ .a = a, .b = c + 1.0 }) == 4003);
    try expect(S.intDouble(.{ .a = a, .b = @sqrt(c) }) == 4001);
    try expect(S.intHalf(.{ .a = @intCast(a), .b = @floatCast(b) }) == 4008);
    try expect(S.intHalf(.{ .a = @intCast(a), .b = @floatFromInt(a) }) == 4004);
    try expect(S.tuple(.{ a, b * 2 }) == 4017);
    try expect(S.tuple(.{ a, @floatCast(c) }) == 4002);
}

test "stack arguments staged while the argument registers hold arguments and every other register is live" {
    const S = struct {
        const Pair = struct { a: u64, b: u32 };
        noinline fn sink(
            r0: u64,
            r1: u64,
            r2: u64,
            r3: u64,
            r4: u64,
            r5: u64,
            r6: u64,
            r7: u64,
            s0: u64,
            s1: u64,
            s2: u64,
            s3: u64,
            s4: u64,
            s5: u64,
            s6: u64,
            s7: u64,
            s8: u64,
            s9: u64,
            s10: u64,
            s11: u64,
            pair: Pair,
            last: u64,
        ) u64 {
            return r0 + r1 + r2 + r3 + r4 + r5 + r6 + r7 + s0 + s1 + s2 + s3 + s4 + s5 + s6 + s7 +
                s8 + s9 + s10 + s11 + pair.a + pair.b + last;
        }
        noinline fn caller(p: *const [32]u64, pair: *const Pair) u64 {
            // Live across the call: they take the callee-saved registers.
            const c0 = p[0] *% 3;
            const c1 = p[1] *% 3;
            const c2 = p[2] *% 3;
            const c3 = p[3] *% 3;
            const c4 = p[4] *% 3;
            const c5 = p[5] *% 3;
            const c6 = p[6] *% 3;
            const c7 = p[7] *% 3;
            const c8 = p[8] *% 3;
            const c9 = p[9] *% 3;
            const c10 = p[10] *% 3;
            const c11 = p[11] *% 3;
            // Arguments, each in its own register until the call.
            const v0 = p[12] +% 1;
            const v1 = p[13] +% 1;
            const v2 = p[14] +% 1;
            const v3 = p[15] +% 1;
            const v4 = p[16] +% 1;
            const v5 = p[17] +% 1;
            const v6 = p[18] +% 1;
            const v7 = p[19] +% 1;
            const v8 = p[20] +% 1;
            const v9 = p[21] +% 1;
            const v10 = p[22] +% 1;
            const v11 = p[23] +% 1;
            const w0 = p[24] +% 2;
            const w1 = p[25] +% 2;
            const w2 = p[26] +% 2;
            const w3 = p[27] +% 2;
            const w4 = p[28] +% 2;
            const w5 = p[29] +% 2;
            const w6 = p[30] +% 2;
            const w7 = p[31] +% 2;
            // `pair` is copied to the stack through a scratch register.
            const r = sink(v0, v1, v2, v3, v4, v5, v6, v7, v8, v9, v10, v11, w0, w1, w2, w3, w4, w5, w6, w7, pair.*, w0);
            return r +% c0 +% c1 +% c2 +% c3 +% c4 +% c5 +% c6 +% c7 +% c8 +% c9 +% c10 +% c11;
        }
    };
    var values: [32]u64 = undefined;
    for (&values, 0..) |*v, i| v.* = i;
    const pair: S.Pair = .{ .a = 100, .b = 200 };
    var expected: u64 = 0;
    for (values[0..12]) |v| expected += v * 3;
    for (values[12..24]) |v| expected += v + 1;
    for (values[24..32]) |v| expected += v + 2;
    expected += 300 + values[24] + 2;
    try expect(S.caller(&values, &pair) == expected);
}
