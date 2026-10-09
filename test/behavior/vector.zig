const std = @import("std");
const builtin = @import("builtin");
const mem = std.mem;
const math = std.math;
const assert = std.debug.assert;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

test "implicit cast vector to array - bool" {
    if (builtin.zig_backend == .stage2_spirv) return error.SkipZigTest;

    const S = struct {
        fn doTheTest() !void {
            {
                var v: @Vector(4, bool) = undefined;
                v = .{ true, false, true, false };
                const a: [4]bool = v;
                try expect(mem.eql(bool, &a, &.{ true, false, true, false }));
            }
            {
                var v: @Vector(25, bool) = undefined;
                v = .{ false, false, false, false, true, true, false, false, false, true, false, true, false, false, true, false, false, true, false, false, true, true, true, false, false };
                const a: [25]bool = v;
                try expect(mem.eql(bool, &a, &.{ false, false, false, false, true, true, false, false, false, true, false, true, false, false, true, false, false, true, false, false, true, true, true, false, false }));
            }
        }
    };
    try S.doTheTest();
    try comptime S.doTheTest();
}

test "implicit cast array to vector - bool" {
    if (builtin.zig_backend == .stage2_spirv) return error.SkipZigTest;

    const S = struct {
        fn doTheTest() !void {
            {
                var a: [4]bool = undefined;
                a = .{ true, false, false, true };
                const v: @Vector(4, bool) = a;
                try expect(mem.eql(bool, &@as([4]bool, v), &.{ true, false, false, true }));
            }
            {
                var a: [25]bool = undefined;
                a = .{ true, false, false, true, false, false, false, false, false, true, true, true, true, false, false, false, false, true, false, false, false, true, true, true, false };
                const v: @Vector(25, bool) = a;
                try expect(mem.eql(bool, &@as([25]bool, v), &.{ true, false, false, true, false, false, false, false, false, true, true, true, true, false, false, false, false, true, false, false, false, true, true, true, false }));
            }
        }
    };
    try S.doTheTest();
    try comptime S.doTheTest();
}

test "vector wrap operators" {
    if (builtin.zig_backend == .stage2_arm) return error.SkipZigTest; // TODO
    if (builtin.zig_backend == .stage2_sparc64) return error.SkipZigTest; // TODO
    if (builtin.zig_backend == .stage2_riscv64) return error.SkipZigTest;
    if (builtin.zig_backend == .stage2_spirv) return error.SkipZigTest;

    const S = struct {
        fn doTheTest() !void {
            var v: @Vector(4, i32) = [4]i32{ 2147483647, -2, 30, 40 };
            var x: @Vector(4, i32) = [4]i32{ 1, 2147483647, 3, 4 };
            try expect(mem.eql(i32, &@as([4]i32, v +% x), &[4]i32{ -2147483648, 2147483645, 33, 44 }));
            try expect(mem.eql(i32, &@as([4]i32, v -% x), &[4]i32{ 2147483646, 2147483647, 27, 36 }));
            try expect(mem.eql(i32, &@as([4]i32, v *% x), &[4]i32{ 2147483647, 2, 90, 160 }));
            var z: @Vector(4, i32) = [4]i32{ 1, 2, 3, -2147483648 };
            try expect(mem.eql(i32, &@as([4]i32, -%z), &[4]i32{ -1, -2, -3, -2147483648 }));
            _ = .{ &v, &x, &z };
        }
    };
    try S.doTheTest();
    try comptime S.doTheTest();
}

test "vector bin compares with mem.eql" {
    if (builtin.zig_backend == .stage2_arm) return error.SkipZigTest; // TODO
    if (builtin.zig_backend == .stage2_sparc64) return error.SkipZigTest; // TODO
    if (builtin.zig_backend == .stage2_riscv64) return error.SkipZigTest;
    if (builtin.zig_backend == .stage2_spirv) return error.SkipZigTest;

    const S = struct {
        fn doTheTest() !void {
            var v: @Vector(4, i32) = [4]i32{ 2147483647, -2, 30, 40 };
            var x: @Vector(4, i32) = [4]i32{ 1, 2147483647, 30, 4 };
            _ = .{ &v, &x };
            try expect(mem.eql(bool, &@as([4]bool, v == x), &[4]bool{ false, false, true, false }));
            try expect(mem.eql(bool, &@as([4]bool, v != x), &[4]bool{ true, true, false, true }));
            try expect(mem.eql(bool, &@as([4]bool, v < x), &[4]bool{ false, true, false, false }));
            try expect(mem.eql(bool, &@as([4]bool, v > x), &[4]bool{ true, false, false, true }));
            try expect(mem.eql(bool, &@as([4]bool, v <= x), &[4]bool{ false, true, true, false }));
            try expect(mem.eql(bool, &@as([4]bool, v >= x), &[4]bool{ true, false, true, true }));
        }
    };
    try S.doTheTest();
    try comptime S.doTheTest();
}

test "vector int operators" {
    if (builtin.zig_backend == .stage2_arm) return error.SkipZigTest; // TODO
    if (builtin.zig_backend == .stage2_sparc64) return error.SkipZigTest; // TODO
    if (builtin.zig_backend == .stage2_riscv64) return error.SkipZigTest;
    if (builtin.zig_backend == .stage2_spirv) return error.SkipZigTest;

    const S = struct {
        fn doTheTest() !void {
            var v: @Vector(4, i32) = [4]i32{ 10, 20, 30, 40 };
            var x: @Vector(4, i32) = [4]i32{ 1, 2, 3, 4 };
            _ = .{ &v, &x };
            try expect(mem.eql(i32, &@as([4]i32, v + x), &[4]i32{ 11, 22, 33, 44 }));
            try expect(mem.eql(i32, &@as([4]i32, v - x), &[4]i32{ 9, 18, 27, 36 }));
            try expect(mem.eql(i32, &@as([4]i32, v * x), &[4]i32{ 10, 40, 90, 160 }));
            try expect(mem.eql(i32, &@as([4]i32, -v), &[4]i32{ -10, -20, -30, -40 }));
        }
    };
    try S.doTheTest();
    try comptime S.doTheTest();
}

test "vector float operators" {
    if (builtin.zig_backend == .stage2_arm) return error.SkipZigTest; // TODO
    if (builtin.zig_backend == .stage2_sparc64) return error.SkipZigTest; // TODO
    if (builtin.zig_backend == .stage2_spirv) return error.SkipZigTest;

    const S = struct {
        fn doTheTest(T: type) !void {
            var v: @Vector(4, T) = .{ 10, 20, 30, 40 };
            var x: @Vector(4, T) = .{ 1, 2, 3, 4 };
            _ = .{ &v, &x };
            try expectEqual(v + x, .{ 11, 22, 33, 44 });
            try expectEqual(v - x, .{ 9, 18, 27, 36 });
            try expectEqual(v * x, .{ 10, 40, 90, 160 });
            if (builtin.zig_backend != .stage2_riscv64) try expectEqual(-x, .{ -1, -2, -3, -4 });
        }
    };

    try S.doTheTest(f32);
    try comptime S.doTheTest(f32);

    try S.doTheTest(f64);
    try comptime S.doTheTest(f64);

    if (builtin.zig_backend == .stage2_riscv64) return error.SkipZigTest;

    try S.doTheTest(f16);
    try comptime S.doTheTest(f16);

    try S.doTheTest(f80);
    try comptime S.doTheTest(f80);

    try S.doTheTest(f128);
    try comptime S.doTheTest(f128);
}

test "vector bit operators" {
    if (builtin.zig_backend == .stage2_arm) return error.SkipZigTest; // TODO
    if (builtin.zig_backend == .stage2_sparc64) return error.SkipZigTest; // TODO
    if (builtin.zig_backend == .stage2_riscv64) return error.SkipZigTest;
    if (builtin.zig_backend == .stage2_spirv) return error.SkipZigTest;

    const S = struct {
        fn doTheTest() !void {
            {
                var v: @Vector(4, bool) = [4]bool{ false, false, true, true };
                var x: @Vector(4, bool) = [4]bool{ true, false, true, false };
                _ = .{ &v, &x };
                try expect(mem.eql(bool, &@as([4]bool, v ^ x), &[4]bool{ true, false, false, true }));
                try expect(mem.eql(bool, &@as([4]bool, v | x), &[4]bool{ true, false, true, true }));
                try expect(mem.eql(bool, &@as([4]bool, v & x), &[4]bool{ false, false, true, false }));
            }
            {
                var v: @Vector(4, u8) = [4]u8{ 0b10101010, 0b10101010, 0b10101010, 0b10101010 };
                var x: @Vector(4, u8) = [4]u8{ 0b11110000, 0b00001111, 0b10101010, 0b01010101 };
                _ = .{ &v, &x };
                try expect(mem.eql(u8, &@as([4]u8, v ^ x), &[4]u8{ 0b01011010, 0b10100101, 0b00000000, 0b11111111 }));
                try expect(mem.eql(u8, &@as([4]u8, v | x), &[4]u8{ 0b11111010, 0b10101111, 0b10101010, 0b11111111 }));
                try expect(mem.eql(u8, &@as([4]u8, v & x), &[4]u8{ 0b10100000, 0b00001010, 0b10101010, 0b00000000 }));
            }
        }
    };
    try S.doTheTest();
    try comptime S.doTheTest();
}

test "implicit cast vector to array" {
    if (builtin.zig_backend == .stage2_arm) return error.SkipZigTest; // TODO
    if (builtin.zig_backend == .stage2_sparc64) return error.SkipZigTest; // TODO
    if (builtin.zig_backend == .stage2_riscv64) return error.SkipZigTest;
    if (builtin.zig_backend == .stage2_spirv) return error.SkipZigTest;

    const S = struct {
        fn doTheTest() !void {
            var a: @Vector(4, i32) = [_]i32{ 1, 2, 3, 4 };
            _ = &a;
            var result_array: [4]i32 = a;
            result_array = a;
            try expect(mem.eql(i32, &result_array, &[4]i32{ 1, 2, 3, 4 }));
        }
    };
    try S.doTheTest();
    try comptime S.doTheTest();
}

test "array to vector" {
    if (builtin.zig_backend == .stage2_arm) return error.SkipZigTest; // TODO
    if (builtin.zig_backend == .stage2_sparc64) return error.SkipZigTest; // TODO
    if (builtin.zig_backend == .stage2_spirv) return error.SkipZigTest;

    const S = struct {
        fn doTheTest() !void {
            var foo: f32 = 3.14;
            _ = &foo;
            const arr = [4]f32{ foo, 1.5, 0.0, 0.0 };
            const vec: @Vector(4, f32) = arr;
            try expect(mem.eql(f32, &@as([4]f32, vec), &arr));
        }
    };
    try S.doTheTest();
    try comptime S.doTheTest();
}

test "array of abi-sized integer to vector of same type" {
    if (builtin.zig_backend == .stage2_arm) return error.SkipZigTest; // TODO
    if (builtin.zig_backend == .stage2_sparc64) return error.SkipZigTest; // TODO
    if (builtin.zig_backend == .stage2_spirv) return error.SkipZigTest;

    const S = struct {
        const one: u32 = 1;
        const two: u32 = 2;

        fn doTheTest() !void {
            {
                var arr: [8]u8 = .{ 0x01, 0x23, 0x45, 0x67, 0x89, 0xAB, 0xCD, 0xEF };
                const vec: @Vector(8, u8) = arr;
                arr[0] = 0; // should not affect `vec`
                try expect(vec[0] == 0x01);
                try expect(vec[1] == 0x23);
                try expect(vec[2] == 0x45);
                try expect(vec[3] == 0x67);
                try expect(vec[4] == 0x89);
                try expect(vec[5] == 0xAB);
                try expect(vec[6] == 0xCD);
                try expect(vec[7] == 0xEF);
            }

            {
                var arr: [4]u16 = .{ 0x0123, 0x4567, 0x89AB, 0xCDEF };
                const vec: @Vector(4, u16) = arr;
                arr[0] = 0; // should not affect `vec`
                try expect(vec[0] == 0x0123);
                try expect(vec[1] == 0x4567);
                try expect(vec[2] == 0x89AB);
                try expect(vec[3] == 0xCDEF);
            }

            {
                var arr: [2]u32 = .{ 0x01234567, 0x89ABCDEF };
                const vec: @Vector(2, u32) = arr;
                arr[0] = 0; // should not affect `vec`
                try expect(vec[0] == 0x01234567);
                try expect(vec[1] == 0x89ABCDEF);
            }

            {
                var arr: [1]u64 = .{0x0123456789ABCDEF};
                const vec: @Vector(1, u64) = arr;
                arr[0] = 0; // should not affect `vec`
                try expect(vec[0] == 0x0123456789ABCDEF);
            }

            // Like the u16 case, but a non-power-of-two size.
            {
                var arr: [5]u16 = .{ 0x0123, 0x4567, 0x89AB, 0xCDEF, 0xDEAD };
                const vec: @Vector(5, u16) = arr;
                arr[0] = 0; // should not affect `vec`
                try expect(vec[0] == 0x0123);
                try expect(vec[1] == 0x4567);
                try expect(vec[2] == 0x89AB);
                try expect(vec[3] == 0xCDEF);
                try expect(vec[4] == 0xDEAD);
            }

            // Like the u32 case, but a non-power-of-two size.
            {
                var arr: [3]u32 = .{ 0x01234567, 0x89ABCDEF, 0xDEADBEEF };
                const vec: @Vector(3, u32) = arr;
                arr[0] = 0; // should not affect `vec`
                try expect(vec[0] == 0x01234567);
                try expect(vec[1] == 0x89ABCDEF);
                try expect(vec[2] == 0xDEADBEEF);
            }

            {
                var arr: [2]*const u32 = .{ &one, &two };
                const vec: @Vector(2, *const u32) = arr;
                arr[0] = &two; // should not affect `vec`
                try expect(vec[0] == &one);
                try expect(vec[1] == &two);
            }
        }
    };
    try S.doTheTest();
    try comptime S.doTheTest();
}

test "array of float to vector of same type" {
    if (builtin.zig_backend == .stage2_arm) return error.SkipZigTest; // TODO
    if (builtin.zig_backend == .stage2_sparc64) return error.SkipZigTest; // TODO
    if (builtin.zig_backend == .stage2_spirv) return error.SkipZigTest;
    if (builtin.zig_backend == .stage2_riscv64) return error.SkipZigTest; // TODO

    const S = struct {
        fn doTheTest() !void {
            {
                var arr: [4]f16 = .{ 1.5, 2.5, 3.5, 4.5 };
                const vec: @Vector(4, f16) = arr;
                arr[0] = 0; // should not affect `vec`
                try expect(vec[0] == 1.5);
                try expect(vec[1] == 2.5);
                try expect(vec[2] == 3.5);
                try expect(vec[3] == 4.5);
            }

            {
                var arr: [4]f32 = .{ 1.5, 2.5, 3.5, 4.5 };
                const vec: @Vector(4, f32) = arr;
                arr[0] = 0; // should not affect `vec`
                try expect(vec[0] == 1.5);
                try expect(vec[1] == 2.5);
                try expect(vec[2] == 3.5);
                try expect(vec[3] == 4.5);
            }

            {
                var arr: [4]f64 = .{ 1.5, 2.5, 3.5, 4.5 };
                const vec: @Vector(4, f64) = arr;
                arr[0] = 0; // should not affect `vec`
                try expect(vec[0] == 1.5);
                try expect(vec[1] == 2.5);
                try expect(vec[2] == 3.5);
                try expect(vec[3] == 4.5);
            }

            {
                var arr: [2]f80 = .{ 1.5, 2.5 };
                const vec: @Vector(2, f80) = arr;
                arr[0] = 0; // should not affect `vec`
                try expect(vec[0] == 1.5);
                try expect(vec[1] == 2.5);
            }

            {
                var arr: [2]f128 = .{ 3.5, 4.5 };
                const vec: @Vector(2, f128) = arr;
                arr[0] = 0; // should not affect `vec`
                try expect(vec[0] == 3.5);
                try expect(vec[1] == 4.5);
            }
        }
    };
    try S.doTheTest();
    try comptime S.doTheTest();
}

test "array of non-abi-sized integer to vector of same type" {
    if (builtin.zig_backend == .stage2_arm) return error.SkipZigTest; // TODO
    if (builtin.zig_backend == .stage2_sparc64) return error.SkipZigTest; // TODO

    const S = struct {
        fn doTheTest() !void {
            {
                var arr: [5]bool = .{ false, true, false, true, true };
                const vec: @Vector(5, bool) = arr;
                arr[0] = true; // should not affect `vec`
                try expect(vec[0] == false);
                try expect(vec[1] == true);
                try expect(vec[2] == false);
                try expect(vec[3] == true);
                try expect(vec[4] == true);
            }

            {
                var arr: [4]u1 = .{ 1, 0, 1, 1 };
                const vec: @Vector(4, u1) = arr;
                arr[0] = 0; // should not affect `vec`
                try expect(vec[0] == 1);
                try expect(vec[1] == 0);
                try expect(vec[2] == 1);
                try expect(vec[3] == 1);
            }

            {
                var arr: [4]u3 = .{ 0, 3, 5, 7 };
                const vec: @Vector(4, u3) = arr;
                arr[0] = 1; // should not affect `vec`
                try expect(vec[0] == 0);
                try expect(vec[1] == 3);
                try expect(vec[2] == 5);
                try expect(vec[3] == 7);
            }

            {
                var arr: [3]u24 = .{ 0x010203, 0x040506, 0xFF0000 };
                const vec: @Vector(3, u24) = arr;
                arr[0] = 0; // should not affect `vec`
                try expect(vec[0] == 0x010203);
                try expect(vec[1] == 0x040506);
                try expect(vec[2] == 0xFF0000);
            }
        }
    };
    try S.doTheTest();
    try comptime S.doTheTest();
}

test "array vector coercion - odd sizes" {
    if (builtin.zig_backend == .stage2_arm) return error.SkipZigTest; // TODO
    if (builtin.zig_backend == .stage2_sparc64) return error.SkipZigTest; // TODO
    if (builtin.zig_backend == .stage2_riscv64) return error.SkipZigTest;

    const S = struct {
        fn doTheTest() !void {
            var foo1: i48 = 124578;
            _ = &foo1;
            const vec1: @Vector(2, i48) = [2]i48{ foo1, 1 };
            const arr1: [2]i48 = vec1;
            try expect(vec1[0] == foo1 and vec1[1] == 1);
            try expect(arr1[0] == foo1 and arr1[1] == 1);

            var foo2: u4 = 5;
            _ = &foo2;
            const vec2: @Vector(2, u4) = [2]u4{ foo2, 1 };
            const arr2: [2]u4 = vec2;
            try expect(vec2[0] == foo2 and vec2[1] == 1);
            try expect(arr2[0] == foo2 and arr2[1] == 1);

            var foo3: u13 = 13;
            _ = &foo3;
            const vec3: @Vector(3, u13) = [3]u13{ foo3, 0, 1 };
            const arr3: [3]u13 = vec3;
            try expect(vec3[0] == foo3 and vec3[1] == 0 and vec3[2] == 1);
            try expect(arr3[0] == foo3 and arr3[1] == 0 and arr3[2] == 1);

            const arr4 = [4:0]u24{ foo3, foo2, 0, 1 };
            const vec4: @Vector(4, u24) = arr4;
            try expect(vec4[0] == foo3 and vec4[1] == foo2 and vec4[2] == 0 and vec4[3] == 1);
        }
    };
    try S.doTheTest();
    try comptime S.doTheTest();
}

test "array to vector with element type coercion" {
    if (builtin.zig_backend == .stage2_arm) return error.SkipZigTest; // TODO
    if (builtin.zig_backend == .stage2_sparc64) return error.SkipZigTest; // TODO
    if (builtin.zig_backend == .stage2_spirv) return error.SkipZigTest;
    if (builtin.zig_backend == .stage2_riscv64) return error.SkipZigTest;

    const S = struct {
        fn doTheTest() !void {
            var foo: f16 = 3.14;
            _ = &foo;
            const arr32 = [4]f32{ foo, 1.5, 0.0, 0.0 };
            const vec: @Vector(4, f32) = [4]f16{ foo, 1.5, 0.0, 0.0 };
            try std.testing.expect(std.mem.eql(f32, &@as([4]f32, vec), &arr32));
        }
    };
    try S.doTheTest();
    try comptime S.doTheTest();
}

test "peer type resolution with coercible element types" {
    if (builtin.zig_backend == .stage2_arm) return error.SkipZigTest; // TODO
    if (builtin.zig_backend == .stage2_sparc64) return error.SkipZigTest; // TODO

    const S = struct {
        fn doTheTest() !void {
            var b: @Vector(2, u8) = .{ 1, 2 };
            var a: @Vector(2, u16) = .{ 2, 1 };
            var t: bool = true;
            _ = .{ &a, &b, &t };
            const c = if (t) a else b;
            try std.testing.expect(@TypeOf(c) == @Vector(2, u16));
        }
    };
    try comptime S.doTheTest();
}

test "tuple to vector" {
    if (builtin.zig_backend == .stage2_spirv) return error.SkipZigTest;
    if (builtin.zig_backend == .stage2_arm) return error.SkipZigTest; // TODO
    if (builtin.zig_backend == .stage2_sparc64) return error.SkipZigTest; // TODO
    if (builtin.zig_backend == .stage2_riscv64) return error.SkipZigTest;

    const S = struct {
        fn doTheTest() !void {
            const Vec3 = @Vector(3, i32);
            var v: Vec3 = .{ 1, 0, 0 };
            for ([_]Vec3{ .{ 0, 1, 0 }, .{ 0, 0, 1 } }) |it| {
                v += it;
            }

            try std.testing.expectEqual(v, Vec3{ 1, 1, 1 });
            try std.testing.expectEqual(v, .{ 1, 1, 1 });
        }
    };
    try S.doTheTest();
    try comptime S.doTheTest();
}

test "vector casts of sizes not divisible by 8" {
    if (builtin.zig_backend == .stage2_arm) return error.SkipZigTest; // TODO
    if (builtin.zig_backend == .stage2_sparc64) return error.SkipZigTest; // TODO
    if (builtin.zig_backend == .stage2_riscv64) return error.SkipZigTest;
    if (builtin.zig_backend == .stage2_spirv) return error.SkipZigTest;

    const S = struct {
        fn doTheTest() !void {
            {
                var v: @Vector(4, u3) = [4]u3{ 5, 2, 3, 0 };
                _ = &v;
                const x: [4]u3 = v;
                try expect(mem.eql(u3, &x, &@as([4]u3, v)));
            }
            {
                var v: @Vector(4, u2) = [4]u2{ 1, 2, 3, 0 };
                _ = &v;
                const x: [4]u2 = v;
                try expect(mem.eql(u2, &x, &@as([4]u2, v)));
            }
            {
                var v: @Vector(4, u1) = [4]u1{ 1, 0, 1, 0 };
                _ = &v;
                const x: [4]u1 = v;
                try expect(mem.eql(u1, &x, &@as([4]u1, v)));
            }
            {
                var v: @Vector(4, bool) = [4]bool{ false, false, true, false };
                _ = &v;
                const x: [4]bool = v;
                try expect(mem.eql(bool, &x, &@as([4]bool, v)));
            }
        }
    };
    try S.doTheTest();
    try comptime S.doTheTest();
}

test "load vector elements via comptime index" {
    if (builtin.zig_backend == .stage2_arm) return error.SkipZigTest; // TODO
    if (builtin.zig_backend == .stage2_sparc64) return error.SkipZigTest; // TODO

    const S = struct {
        fn doTheTest() !void {
            var v: @Vector(4, i32) = [_]i32{ 1, 2, 3, undefined };
            try expect(v[0] == 1);
            try expect(v[1] == 2);
            try expect(loadv(&v[2]) == 3);
        }
        fn loadv(ptr: anytype) i32 {
            return ptr.*;
        }
    };

    try S.doTheTest();
    try comptime S.doTheTest();
}

test "store vector elements via comptime index" {
    if (builtin.zig_backend == .stage2_arm) return error.SkipZigTest; // TODO
    if (builtin.zig_backend == .stage2_sparc64) return error.SkipZigTest; // TODO

    const S = struct {
        fn doTheTest() !void {
            var v: @Vector(4, i32) = [_]i32{ 1, 5, 3, undefined };

            v[2] = 42;
            try expect(v[1] == 5);
            v[3] = -364;
            try expect(v[2] == 42);
            try expect(-364 == v[3]);

            storev(&v[0], 100);
            try expect(v[0] == 100);
        }
        fn storev(ptr: anytype, x: i32) void {
            ptr.* = x;
        }
    };

    try S.doTheTest();
    try comptime S.doTheTest();
}

test "initialize vector which is a struct field" {
    if (builtin.zig_backend == .stage2_arm) return error.SkipZigTest; // TODO
    if (builtin.zig_backend == .stage2_sparc64) return error.SkipZigTest; // TODO

    const Vec4Obj = struct {
        data: @Vector(4, f32),
    };

    const S = struct {
        fn doTheTest() !void {
            var foo = Vec4Obj{
                .data = [_]f32{ 1, 2, 3, 4 },
            };
            _ = &foo;
        }
    };
    try S.doTheTest();
    try comptime S.doTheTest();
}

test "vector comparison operators" {
    if (builtin.zig_backend == .stage2_arm) return error.SkipZigTest; // TODO
    if (builtin.zig_backend == .stage2_sparc64) return error.SkipZigTest; // TODO
    if (builtin.zig_backend == .stage2_riscv64) return error.SkipZigTest;
    if (builtin.zig_backend == .stage2_spirv) return error.SkipZigTest;

    const S = struct {
        fn doTheTest() !void {
            {
                const V = @Vector(4, bool);
                var v1: V = [_]bool{ true, false, true, false };
                var v2: V = [_]bool{ false, true, false, true };
                _ = .{ &v1, &v2 };
                try expect(mem.eql(bool, &@as([4]bool, @as(V, @splat(true))), &@as([4]bool, v1 == v1)));
                try expect(mem.eql(bool, &@as([4]bool, @as(V, @splat(false))), &@as([4]bool, v1 == v2)));
                try expect(mem.eql(bool, &@as([4]bool, @as(V, @splat(true))), &@as([4]bool, v1 != v2)));
                try expect(mem.eql(bool, &@as([4]bool, @as(V, @splat(false))), &@as([4]bool, v2 != v2)));
            }
            {
                const V = @Vector(4, bool);
                var v1: @Vector(4, u32) = @splat(0xc0ffeeee);
                var v2: @Vector(4, c_uint) = v1;
                var v3: @Vector(4, u32) = @splat(0xdeadbeef);
                _ = .{ &v1, &v2, &v3 };
                try expect(mem.eql(bool, &@as([4]bool, @as(V, @splat(true))), &@as([4]bool, v1 == v2)));
                try expect(mem.eql(bool, &@as([4]bool, @as(V, @splat(false))), &@as([4]bool, v1 == v3)));
                try expect(mem.eql(bool, &@as([4]bool, @as(V, @splat(true))), &@as([4]bool, v1 != v3)));
                try expect(mem.eql(bool, &@as([4]bool, @as(V, @splat(false))), &@as([4]bool, v1 != v2)));
            }
            {
                // Comptime-known LHS/RHS
                var v1: @Vector(4, u32) = [_]u32{ 2, 1, 2, 1 };
                _ = &v1;
                const v2: @Vector(4, u32) = @splat(2);
                const v3: @Vector(4, bool) = [_]bool{ true, false, true, false };
                try expect(mem.eql(bool, &@as([4]bool, v3), &@as([4]bool, v1 == v2)));
                try expect(mem.eql(bool, &@as([4]bool, v3), &@as([4]bool, v2 == v1)));
            }
        }
    };
    try S.doTheTest();
    try comptime S.doTheTest();
}

test "vector division operators" {
    if (builtin.zig_backend == .stage2_arm) return error.SkipZigTest; // TODO
    if (builtin.zig_backend == .stage2_sparc64) return error.SkipZigTest; // TODO
    if (builtin.zig_backend == .stage2_riscv64) return error.SkipZigTest;
    if (builtin.zig_backend == .stage2_spirv) return error.SkipZigTest;

    const S = struct {
        fn doTheTestDiv(comptime T: type, x: @Vector(4, T), y: @Vector(4, T)) !void {
            const is_signed_int = switch (@typeInfo(T)) {
                .int => |info| info.signedness == .signed,
                else => false,
            };
            if (!is_signed_int) {
                const d0 = x / y;
                inline for (@as([4]T, d0), 0..) |v, i| {
                    try expect(x[i] / y[i] == v);
                }
            }
            const d1 = @divExact(x, y);
            inline for (@as([4]T, d1), 0..) |v, i| {
                try expect(@divExact(x[i], y[i]) == v);
            }
            const d2 = @divFloor(x, y);
            inline for (@as([4]T, d2), 0..) |v, i| {
                try expect(@divFloor(x[i], y[i]) == v);
            }
            const d3 = @divCeil(x, y);
            inline for (@as([4]T, d3), 0..) |v, i| {
                try expect(@divCeil(x[i], y[i]) == v);
            }
            const d4 = @divTrunc(x, y);
            inline for (@as([4]T, d4), 0..) |v, i| {
                try expect(@divTrunc(x[i], y[i]) == v);
            }
        }

        fn doTheTestDivNoExact(comptime T: type, x: @Vector(4, T), y: @Vector(4, T)) !void {
            const is_signed_int = switch (@typeInfo(T)) {
                .int => |info| info.signedness == .signed,
                else => false,
            };
            if (!is_signed_int) {
                const d0 = x / y;
                inline for (@as([4]T, d0), 0..) |v, i| {
                    try expect(x[i] / y[i] == v);
                }
            }
            const d2 = @divFloor(x, y);
            inline for (@as([4]T, d2), 0..) |v, i| {
                try expect(@divFloor(x[i], y[i]) == v);
            }
            const d3 = @divCeil(x, y);
            inline for (@as([4]T, d3), 0..) |v, i| {
                try expect(@divCeil(x[i], y[i]) == v);
            }
            const d4 = @divTrunc(x, y);
            inline for (@as([4]T, d4), 0..) |v, i| {
                try expect(@divTrunc(x[i], y[i]) == v);
            }
        }

        fn doTheTestMod(comptime T: type, x: @Vector(4, T), y: @Vector(4, T)) !void {
            const is_signed_int = switch (@typeInfo(T)) {
                .int => |info| info.signedness == .signed,
                else => false,
            };
            if (!is_signed_int and @typeInfo(T) != .float) {
                const r0 = x % y;
                inline for (@as([4]T, r0), 0..) |v, i| {
                    try expect(x[i] % y[i] == v);
                }
            }
            const r1 = @mod(x, y);
            inline for (@as([4]T, r1), 0..) |v, i| {
                try expect(@mod(x[i], y[i]) == v);
            }
            const r2 = @rem(x, y);
            inline for (@as([4]T, r2), 0..) |v, i| {
                try expect(@rem(x[i], y[i]) == v);
            }
        }

        fn doTheTest() !void {
            try doTheTestDiv(f16, [4]f16{ 4.0, -4.0, 4.0, -4.0 }, [4]f16{ 1.0, 2.0, -1.0, -2.0 });

            try doTheTestDiv(f32, [4]f32{ 4.0, -4.0, 4.0, -4.0 }, [4]f32{ 1.0, 2.0, -1.0, -2.0 });
            try doTheTestDiv(f64, [4]f64{ 4.0, -4.0, 4.0, -4.0 }, [4]f64{ 1.0, 2.0, -1.0, -2.0 });

            try doTheTestMod(f16, [4]f16{ 4.0, -4.0, 4.0, -4.0 }, [4]f16{ 1.0, 2.0, 0.5, 3.0 });
            try doTheTestMod(f32, [4]f32{ 4.0, -4.0, 4.0, -4.0 }, [4]f32{ 1.0, 2.0, 0.5, 3.0 });
            try doTheTestMod(f64, [4]f64{ 4.0, -4.0, 4.0, -4.0 }, [4]f64{ 1.0, 2.0, 0.5, 3.0 });

            try doTheTestDiv(i8, [4]i8{ 4, -4, 4, -4 }, [4]i8{ 1, 2, -1, -2 });
            try doTheTestDiv(i16, [4]i16{ 4, -4, 4, -4 }, [4]i16{ 1, 2, -1, -2 });
            try doTheTestDiv(i32, [4]i32{ 4, -4, 4, -4 }, [4]i32{ 1, 2, -1, -2 });
            try doTheTestDiv(i64, [4]i64{ 4, -4, 4, -4 }, [4]i64{ 1, 2, -1, -2 });

            try doTheTestMod(i8, [4]i8{ 4, -4, 4, -4 }, [4]i8{ 1, 2, 4, 8 });
            try doTheTestMod(i16, [4]i16{ 4, -4, 4, -4 }, [4]i16{ 1, 2, 4, 8 });
            try doTheTestMod(i32, [4]i32{ 4, -4, 4, -4 }, [4]i32{ 1, 2, 4, 8 });
            try doTheTestMod(i64, [4]i64{ 4, -4, 4, -4 }, [4]i64{ 1, 2, 4, 8 });

            try doTheTestDiv(u8, [4]u8{ 1, 2, 4, 8 }, [4]u8{ 1, 1, 2, 4 });
            try doTheTestDiv(u16, [4]u16{ 1, 2, 4, 8 }, [4]u16{ 1, 1, 2, 4 });
            try doTheTestDiv(u32, [4]u32{ 1, 2, 4, 8 }, [4]u32{ 1, 1, 2, 4 });
            try doTheTestDiv(u64, [4]u64{ 1, 2, 4, 8 }, [4]u64{ 1, 1, 2, 4 });

            try doTheTestMod(u8, [4]u8{ 1, 2, 4, 8 }, [4]u8{ 1, 1, 2, 4 });
            try doTheTestMod(u16, [4]u16{ 1, 2, 4, 8 }, [4]u16{ 1, 1, 2, 4 });
            try doTheTestMod(u32, [4]u32{ 1, 2, 4, 8 }, [4]u32{ 1, 1, 2, 4 });
            try doTheTestMod(u64, [4]u64{ 1, 2, 4, 8 }, [4]u64{ 1, 1, 2, 4 });

            try doTheTestDivNoExact(u64, [4]u64{ 4, 5, 6, 7 }, [4]u64{ 4, 4, 4, 4 });
            try doTheTestDivNoExact(i64, [4]i64{ 4, -4, 4, -4 }, [4]i64{ 3, 3, -3, -3 });
        }
    };

    try comptime S.doTheTest();
    if (builtin.cpu.arch == .hexagon and builtin.zig_backend == .stage2_llvm) return error.SkipZigTest;
    try S.doTheTest();
}

test "vector bitwise not operator" {
    if (builtin.zig_backend == .stage2_arm) return error.SkipZigTest; // TODO
    if (builtin.zig_backend == .stage2_sparc64) return error.SkipZigTest; // TODO
    if (builtin.zig_backend == .stage2_riscv64) return error.SkipZigTest;

    const S = struct {
        fn doTheTestNot(comptime T: type, x: @Vector(4, T)) !void {
            const y = ~x;
            inline for (@as([4]T, y), 0..) |v, i| {
                try expect(~x[i] == v);
            }
        }
        fn doTheTest() !void {
            try doTheTestNot(bool, [_]bool{ true, false, true, false });

            try doTheTestNot(u8, [_]u8{ 0, 2, 4, 255 });
            try doTheTestNot(u16, [_]u16{ 0, 2, 4, 255 });
            try doTheTestNot(u32, [_]u32{ 0, 2, 4, 255 });
            try doTheTestNot(u64, [_]u64{ 0, 2, 4, 255 });

            try doTheTestNot(i8, [_]i8{ 0, 2, 4, 127 });
            try doTheTestNot(i16, [_]i16{ 0, 2, 4, 127 });
            try doTheTestNot(i32, [_]i32{ 0, 2, 4, 127 });
            try doTheTestNot(i64, [_]i64{ 0, 2, 4, 127 });
        }
    };

    try S.doTheTest();
    try comptime S.doTheTest();
}

test "vector boolean not operator" {
    if (builtin.zig_backend == .stage2_arm) return error.SkipZigTest; // TODO
    if (builtin.zig_backend == .stage2_sparc64) return error.SkipZigTest; // TODO
    if (builtin.zig_backend == .stage2_riscv64) return error.SkipZigTest;

    const S = struct {
        fn doTheTestNot(comptime T: type, x: @Vector(4, T)) !void {
            const y = !x;
            inline for (@as([4]T, y), 0..) |v, i| {
                try expect(!x[i] == v);
            }
        }
        fn doTheTest() !void {
            try doTheTestNot(bool, [_]bool{ true, false, true, false });
        }
    };

    try S.doTheTest();
    try comptime S.doTheTest();
}

test "vector shift operators" {
    if (builtin.zig_backend == .stage2_arm) return error.SkipZigTest; // TODO
    if (builtin.zig_backend == .stage2_sparc64) return error.SkipZigTest; // TODO
    if (builtin.zig_backend == .stage2_riscv64) return error.SkipZigTest;
    if (builtin.zig_backend == .stage2_spirv) return error.SkipZigTest;

    const S = struct {
        fn doTheTestShift(x: anytype, y: anytype) !void {
            const N = @typeInfo(@TypeOf(x)).array.len;
            const TX = @typeInfo(@TypeOf(x)).array.child;
            const TY = @typeInfo(@TypeOf(y)).array.child;

            const xv = @as(@Vector(N, TX), x);
            const yv = @as(@Vector(N, TY), y);

            const z0 = xv >> yv;
            for (@as([N]TX, z0), 0..) |v, i| {
                try expect(x[i] >> y[i] == v);
            }
            const z1 = xv << yv;
            for (@as([N]TX, z1), 0..) |v, i| {
                try expect(x[i] << y[i] == v);
            }
        }
        fn doTheTestShiftExact(x: anytype, y: anytype, dir: enum { Left, Right }) !void {
            const N = @typeInfo(@TypeOf(x)).array.len;
            const TX = @typeInfo(@TypeOf(x)).array.child;
            const TY = @typeInfo(@TypeOf(y)).array.child;

            const xv = @as(@Vector(N, TX), x);
            const yv = @as(@Vector(N, TY), y);

            const z = if (dir == .Left) @shlExact(xv, yv) else @shrExact(xv, yv);
            for (@as([N]TX, z), 0..) |v, i| {
                const check = if (dir == .Left) x[i] << y[i] else x[i] >> y[i];
                try expect(check == v);
            }
        }
        fn doTheTest() !void {
            try doTheTestShift([_]u8{ 0, 2, 4, math.maxInt(u8) }, [_]u3{ 2, 0, 2, 7 });
            try doTheTestShift([_]u16{ 0, 2, 4, math.maxInt(u16) }, [_]u4{ 2, 0, 2, 15 });
            try doTheTestShift([_]u24{ 0, 2, 4, math.maxInt(u24) }, [_]u5{ 2, 0, 2, 23 });
            try doTheTestShift([_]u32{ 0, 2, 4, math.maxInt(u32) }, [_]u5{ 2, 0, 2, 31 });
            try doTheTestShift([_]u64{ 0xfe, math.maxInt(u64) }, [_]u6{ 0, 63 });

            try doTheTestShift([_]i8{ 0, 2, 4, math.maxInt(i8) }, [_]u3{ 2, 0, 2, 7 });
            try doTheTestShift([_]i16{ 0, 2, 4, math.maxInt(i16) }, [_]u4{ 2, 0, 2, 7 });
            try doTheTestShift([_]i24{ 0, 2, 4, math.maxInt(i24) }, [_]u5{ 2, 0, 2, 7 });
            try doTheTestShift([_]i32{ 0, 2, 4, math.maxInt(i32) }, [_]u5{ 2, 0, 2, 7 });
            try doTheTestShift([_]i64{ 0xfe, math.maxInt(i64) }, [_]u6{ 0, 63 });

            try doTheTestShiftExact([_]u8{ 0, 1, 1 << 7, math.maxInt(u8) ^ 1 }, [_]u3{ 4, 0, 7, 1 }, .Right);
            try doTheTestShiftExact([_]u16{ 0, 1, 1 << 15, math.maxInt(u16) ^ 1 }, [_]u4{ 4, 0, 15, 1 }, .Right);
            try doTheTestShiftExact([_]u24{ 0, 1, 1 << 23, math.maxInt(u24) ^ 1 }, [_]u5{ 4, 0, 23, 1 }, .Right);
            try doTheTestShiftExact([_]u32{ 0, 1, 1 << 31, math.maxInt(u32) ^ 1 }, [_]u5{ 4, 0, 31, 1 }, .Right);
            try doTheTestShiftExact([_]u64{ 1 << 63, 1 }, [_]u6{ 63, 0 }, .Right);

            try doTheTestShiftExact([_]u8{ 0, 1, 1, math.maxInt(u8) ^ (1 << 7) }, [_]u3{ 4, 0, 7, 1 }, .Left);
            try doTheTestShiftExact([_]u16{ 0, 1, 1, math.maxInt(u16) ^ (1 << 15) }, [_]u4{ 4, 0, 15, 1 }, .Left);
            try doTheTestShiftExact([_]u24{ 0, 1, 1, math.maxInt(u24) ^ (1 << 23) }, [_]u5{ 4, 0, 23, 1 }, .Left);
            try doTheTestShiftExact([_]u32{ 0, 1, 1, math.maxInt(u32) ^ (1 << 31) }, [_]u5{ 4, 0, 31, 1 }, .Left);
            try doTheTestShiftExact([_]u64{ 1 << 63, 1 }, [_]u6{ 0, 63 }, .Left);
        }
    };

    try comptime S.doTheTest();
    if (builtin.cpu.arch == .hexagon and builtin.zig_backend == .stage2_llvm) return error.SkipZigTest;
    try S.doTheTest();
}

test "vector reduce operation" {
    if (builtin.zig_backend == .stage2_arm) return error.SkipZigTest; // TODO
    if (builtin.zig_backend == .stage2_sparc64) return error.SkipZigTest; // TODO
    if (builtin.zig_backend == .stage2_spirv) return error.SkipZigTest;
    if (builtin.zig_backend == .stage2_riscv64) return error.SkipZigTest;

    const S = struct {
        fn testReduce(comptime op: std.builtin.ReduceOp, x: anytype, expected: anytype) !void {
            const N = @typeInfo(@TypeOf(x)).array.len;
            const TX = @typeInfo(@TypeOf(x)).array.child;

            const r = @reduce(op, @as(@Vector(N, TX), x));
            switch (@typeInfo(TX)) {
                .int, .bool => try expect(expected == r),
                .float => {
                    const expected_nan = math.isNan(expected);
                    const got_nan = math.isNan(r);

                    if (expected_nan and got_nan) {
                        // Do this check explicitly as two NaN values are never
                        // equal.
                    } else {
                        const F = @TypeOf(expected);
                        const tolerance = @sqrt(math.floatEps(TX));
                        try expect(std.math.approxEqRel(F, expected, r, tolerance));
                    }
                },
                else => unreachable,
            }
        }
        fn doTheTest() !void {
            try testReduce(.Add, [4]i16{ -9, -99, -999, -9999 }, @as(i32, -11106));
            try testReduce(.Add, [4]u16{ 9, 99, 999, 9999 }, @as(u32, 11106));
            try testReduce(.Add, [4]i32{ -9, -99, -999, -9999 }, @as(i32, -11106));
            try testReduce(.Add, [4]u32{ 9, 99, 999, 9999 }, @as(u32, 11106));
            try testReduce(.Add, [4]i64{ -9, -99, -999, -9999 }, @as(i64, -11106));
            try testReduce(.Add, [4]u64{ 9, 99, 999, 9999 }, @as(u64, 11106));
            try testReduce(.Add, [4]i128{ -9, -99, -999, -9999 }, @as(i128, -11106));
            try testReduce(.Add, [4]u128{ 9, 99, 999, 9999 }, @as(u128, 11106));
            try testReduce(.Add, [4]f16{ -1.9, 5.1, -60.3, 100.0 }, @as(f16, 42.9));
            try testReduce(.Add, [4]f32{ -1.9, 5.1, -60.3, 100.0 }, @as(f32, 42.9));
            try testReduce(.Add, [4]f64{ -1.9, 5.1, -60.3, 100.0 }, @as(f64, 42.9));
            try testReduce(.Add, [4]f80{ -1.9, 5.1, -60.3, 100.0 }, @as(f80, 42.9));
            try testReduce(.Add, [4]f128{ -1.9, 5.1, -60.3, 100.0 }, @as(f128, 42.9));

            try testReduce(.And, [4]bool{ true, false, true, true }, @as(bool, false));
            try testReduce(.And, [4]u1{ 1, 0, 1, 1 }, @as(u1, 0));
            try testReduce(.And, [4]u16{ 0xffff, 0xff55, 0xaaff, 0x1010 }, @as(u16, 0x10));
            try testReduce(.And, [4]u32{ 0xffffffff, 0xffff5555, 0xaaaaffff, 0x10101010 }, @as(u32, 0x1010));
            try testReduce(.And, [4]u64{ 0xffffffff, 0xffff5555, 0xaaaaffff, 0x10101010 }, @as(u64, 0x1010));

            try testReduce(.Min, [4]i16{ -1, 2, 3, 4 }, @as(i16, -1));
            try testReduce(.Min, [4]u16{ 1, 2, 3, 4 }, @as(u16, 1));
            try testReduce(.Min, [4]i32{ 1234567, -386, 0, 3 }, @as(i32, -386));
            try testReduce(.Min, [4]u32{ 99, 9999, 9, 99999 }, @as(u32, 9));
            try testReduce(.Min, [4]i64{ 1234567, -386, 0, 3 }, @as(i64, -386));
            try testReduce(.Min, [4]u64{ 99, 9999, 9, 99999 }, @as(u64, 9));
            try testReduce(.Min, [4]i128{ 1234567, -386, 0, 3 }, @as(i128, -386));
            try testReduce(.Min, [4]u128{ 99, 9999, 9, 99999 }, @as(u128, 9));
            try testReduce(.Min, [4]f16{ -10.3, 10.0e9, 13.0, -100.0 }, @as(f16, -100.0));
            try testReduce(.Min, [4]f32{ -10.3, 10.0e9, 13.0, -100.0 }, @as(f32, -100.0));
            try testReduce(.Min, [4]f64{ -10.3, 10.0e9, 13.0, -100.0 }, @as(f64, -100.0));
            try testReduce(.Min, [4]f80{ -10.3, 10.0e9, 13.0, -100.0 }, @as(f80, -100.0));
            try testReduce(.Min, [4]f128{ -10.3, 10.0e9, 13.0, -100.0 }, @as(f128, -100.0));

            try testReduce(.Max, [4]i16{ -1, 2, 3, 4 }, @as(i16, 4));
            try testReduce(.Max, [4]u16{ 1, 2, 3, 4 }, @as(u16, 4));
            try testReduce(.Max, [4]i32{ 1234567, -386, 0, 3 }, @as(i32, 1234567));
            try testReduce(.Max, [4]u32{ 99, 9999, 9, 99999 }, @as(u32, 99999));
            try testReduce(.Max, [4]i64{ 1234567, -386, 0, 3 }, @as(i64, 1234567));
            try testReduce(.Max, [4]u64{ 99, 9999, 9, 99999 }, @as(u64, 99999));
            try testReduce(.Max, [4]i128{ 1234567, -386, 0, 3 }, @as(i128, 1234567));
            try testReduce(.Max, [4]u128{ 99, 9999, 9, 99999 }, @as(u128, 99999));
            try testReduce(.Max, [4]f16{ -10.3, 10.0e9, 13.0, -100.0 }, @as(f16, 10.0e9));
            try testReduce(.Max, [4]f32{ -10.3, 10.0e9, 13.0, -100.0 }, @as(f32, 10.0e9));
            try testReduce(.Max, [4]f64{ -10.3, 10.0e9, 13.0, -100.0 }, @as(f64, 10.0e9));
            try testReduce(.Max, [4]f80{ -10.3, 10.0e9, 13.0, -100.0 }, @as(f80, 10.0e9));
            try testReduce(.Max, [4]f128{ -10.3, 10.0e9, 13.0, -100.0 }, @as(f128, 10.0e9));

            try testReduce(.Mul, [4]i16{ -1, 2, 3, 4 }, @as(i16, -24));
            try testReduce(.Mul, [4]u16{ 1, 2, 3, 4 }, @as(u16, 24));
            try testReduce(.Mul, [4]i32{ -9, -99, -999, 999 }, @as(i32, -889218891));
            try testReduce(.Mul, [4]u32{ 1, 2, 3, 4 }, @as(u32, 24));
            try testReduce(.Mul, [4]i64{ 9, 99, 999, 9999 }, @as(i64, 8900199891));
            try testReduce(.Mul, [4]u64{ 9, 99, 999, 9999 }, @as(u64, 8900199891));
            try testReduce(.Mul, [4]i128{ -9, -99, -999, 9999 }, @as(i128, -8900199891));
            try testReduce(.Mul, [4]u128{ 9, 99, 999, 9999 }, @as(u128, 8900199891));
            try testReduce(.Mul, [4]f16{ -1.9, 5.1, -60.3, 100.0 }, @as(f16, 58430.7));
            try testReduce(.Mul, [4]f32{ -1.9, 5.1, -60.3, 100.0 }, @as(f32, 58430.7));
            try testReduce(.Mul, [4]f64{ -1.9, 5.1, -60.3, 100.0 }, @as(f64, 58430.7));
            try testReduce(.Mul, [4]f80{ -1.9, 5.1, -60.3, 100.0 }, @as(f80, 58430.7));
            try testReduce(.Mul, [4]f128{ -1.9, 5.1, -60.3, 100.0 }, @as(f128, 58430.7));

            try testReduce(.Or, [4]bool{ false, true, false, false }, @as(bool, true));
            try testReduce(.Or, [4]u1{ 0, 1, 0, 0 }, @as(u1, 1));
            try testReduce(.Or, [4]u16{ 0xff00, 0xff00, 0xf0, 0xf }, ~@as(u16, 0));
            try testReduce(.Or, [4]u32{ 0xffff0000, 0xff00, 0xf0, 0xf }, ~@as(u32, 0));
            try testReduce(.Or, [4]u64{ 0xffff0000, 0xff00, 0xf0, 0xf }, @as(u64, 0xffffffff));
            try testReduce(.Or, [4]u128{ 0xffff0000, 0xff00, 0xf0, 0xf }, @as(u128, 0xffffffff));
            try testReduce(.Or, [4]u80{ 0xffff0000, 0xff00, 0xf0, 0xf }, @as(u80, 0xffffffff));

            try testReduce(.Xor, [4]bool{ true, true, true, false }, @as(bool, true));
            try testReduce(.Xor, [4]u1{ 1, 1, 1, 0 }, @as(u1, 1));
            try testReduce(.Xor, [4]u16{ 0x0000, 0x3333, 0x8888, 0x4444 }, ~@as(u16, 0));
            try testReduce(.Xor, [4]u32{ 0x00000000, 0x33333333, 0x88888888, 0x44444444 }, ~@as(u32, 0));
            try testReduce(.Xor, [4]u64{ 0x00000000, 0x33333333, 0x88888888, 0x44444444 }, @as(u64, 0xffffffff));
            try testReduce(.Xor, [4]u128{ 0x00000000, 0x33333333, 0x88888888, 0x44444444 }, @as(u128, 0xffffffff));

            // Test the reduction on vectors containing NaNs.
            const f16_nan = math.nan(f16);
            const f32_nan = math.nan(f32);
            const f64_nan = math.nan(f64);
            const f80_nan = math.nan(f80);
            const f128_nan = math.nan(f128);

            try testReduce(.Add, [4]f16{ -1.9, 5.1, f16_nan, 100.0 }, f16_nan);
            try testReduce(.Add, [4]f32{ -1.9, 5.1, f32_nan, 100.0 }, f32_nan);
            try testReduce(.Add, [4]f64{ -1.9, 5.1, f64_nan, 100.0 }, f64_nan);
            try testReduce(.Add, [4]f80{ -1.9, 5.1, f80_nan, 100.0 }, f80_nan);
            try testReduce(.Add, [4]f128{ -1.9, 5.1, f128_nan, 100.0 }, f128_nan);

            try testReduce(.Min, [4]f16{ -1.9, 5.1, f16_nan, 100.0 }, @as(f16, -1.9));
            try testReduce(.Min, [4]f32{ -1.9, 5.1, f32_nan, 100.0 }, @as(f32, -1.9));
            try testReduce(.Min, [4]f64{ -1.9, 5.1, f64_nan, 100.0 }, @as(f64, -1.9));
            try testReduce(.Min, [4]f80{ -1.9, 5.1, f80_nan, 100.0 }, @as(f80, -1.9));
            try testReduce(.Min, [4]f128{ -1.9, 5.1, f128_nan, 100.0 }, @as(f128, -1.9));

            try testReduce(.Max, [4]f16{ -1.9, 5.1, f16_nan, 100.0 }, @as(f16, 100.0));
            try testReduce(.Max, [4]f32{ -1.9, 5.1, f32_nan, 100.0 }, @as(f32, 100.0));
            try testReduce(.Max, [4]f64{ -1.9, 5.1, f64_nan, 100.0 }, @as(f64, 100.0));
            try testReduce(.Max, [4]f80{ -1.9, 5.1, f80_nan, 100.0 }, @as(f80, 100.0));
            try testReduce(.Max, [4]f128{ -1.9, 5.1, f128_nan, 100.0 }, @as(f128, 100.0));

            try testReduce(.Mul, [4]f16{ -1.9, 5.1, f16_nan, 100.0 }, f16_nan);
            try testReduce(.Mul, [4]f32{ -1.9, 5.1, f32_nan, 100.0 }, f32_nan);
            try testReduce(.Mul, [4]f64{ -1.9, 5.1, f64_nan, 100.0 }, f64_nan);
            try testReduce(.Mul, [4]f80{ -1.9, 5.1, f80_nan, 100.0 }, f80_nan);
            try testReduce(.Mul, [4]f128{ -1.9, 5.1, f128_nan, 100.0 }, f128_nan);
        }
    };

    try S.doTheTest();
    try comptime S.doTheTest();
}

test "vector @reduce comptime" {
    if (builtin.zig_backend == .stage2_arm) return error.SkipZigTest; // TODO
    if (builtin.zig_backend == .stage2_sparc64) return error.SkipZigTest; // TODO

    const V = @Vector(4, i32);

    const value = V{ 1, -1, 1, -1 };
    const result = value > @as(V, @splat(0));
    // result is { true, false, true, false };
    comptime assert(@TypeOf(result) == @Vector(4, bool));
    const is_all_true = @reduce(.And, result);
    comptime assert(@TypeOf(is_all_true) == bool);
    try expect(is_all_true == false);
}

test "saturating add" {
    if (builtin.zig_backend == .stage2_arm) return error.SkipZigTest; // TODO
    if (builtin.zig_backend == .stage2_sparc64) return error.SkipZigTest; // TODO
    if (builtin.zig_backend == .stage2_spirv) return error.SkipZigTest;
    if (builtin.zig_backend == .stage2_riscv64) return error.SkipZigTest;

    const S = struct {
        fn doTheTest() !void {
            { // Broken out to avoid https://github.com/ziglang/zig/issues/11251
                const u8x3 = @Vector(3, u8);
                var lhs = u8x3{ 255, 254, 1 };
                var rhs = u8x3{ 1, 2, 255 };
                _ = .{ &lhs, &rhs };
                const result = lhs +| rhs;
                const expected = u8x3{ 255, 255, 255 };
                try expect(mem.eql(u8, &@as([3]u8, expected), &@as([3]u8, result)));
            }
            { // Broken out to avoid https://github.com/ziglang/zig/issues/11251
                const i8x3 = @Vector(3, i8);
                var lhs = i8x3{ 127, 126, 1 };
                var rhs = i8x3{ 1, 2, 127 };
                _ = .{ &lhs, &rhs };
                const result = lhs +| rhs;
                const expected = i8x3{ 127, 127, 127 };
                try expect(mem.eql(i8, &@as([3]i8, expected), &@as([3]i8, result)));
            }
            try testElemType(i4);
            try testElemType(u4);
            try testElemType(i8);
            try testElemType(u8);
            try testElemType(i12);
            try testElemType(u12);
            try testElemType(i16);
            try testElemType(u16);
            try testElemType(i24);
            try testElemType(u24);
            try testElemType(i32);
            try testElemType(u32);
            try testElemType(i48);
            try testElemType(u48);
            try testElemType(i64);
            try testElemType(u64);
        }
        fn testElemType(comptime Elem: type) !void {
            const min = std.math.minInt(Elem);
            const max = std.math.maxInt(Elem);

            var v: @Vector(4, Elem) = .{ 0, 1, 0, 1 };
            v +|= .{ 0, 0, 1, 1 };
            try expect(v[0] == 0);
            try expect(v[1] == 1);
            try expect(v[2] == 1);
            try expect(v[3] == 2);

            v = .{ 0, max, 1, max };
            v +|= .{ max, 0, max, 1 };
            try expect(v[0] == max);
            try expect(v[1] == max);
            try expect(v[2] == max);
            try expect(v[3] == max);

            v = .{ 1, max - 1, max / 2, max };
            v +|= .{ max - 1, 1, max / 2, max };
            try expect(v[0] == max);
            try expect(v[1] == max);
            try expect(v[2] == max - 1);
            try expect(v[3] == max);

            switch (@typeInfo(Elem).int.signedness) {
                .signed => {
                    v = .{ -1, -1, 0, -1 };
                    v +|= .{ 1, 0, -1, -1 };
                    try expect(v[0] == 0);
                    try expect(v[1] == -1);
                    try expect(v[2] == -1);
                    try expect(v[3] == -2);

                    v = .{ 0, min, -1, min };
                    v +|= .{ min, 0, min, -1 };
                    try expect(v[0] == min);
                    try expect(v[1] == min);
                    try expect(v[2] == min);
                    try expect(v[3] == min);

                    v = .{ -1, min + 1, min / 2, min };
                    v +|= .{ min + 1, -1, min / 2, min };
                    try expect(v[0] == min);
                    try expect(v[1] == min);
                    try expect(v[2] == min);
                    try expect(v[3] == min);
                },
                .unsigned => {},
            }
        }
    };
    try S.doTheTest();
    try comptime S.doTheTest();
}

test "saturating subtraction" {
    if (builtin.zig_backend == .stage2_arm) return error.SkipZigTest; // TODO
    if (builtin.zig_backend == .stage2_sparc64) return error.SkipZigTest; // TODO
    if (builtin.zig_backend == .stage2_spirv) return error.SkipZigTest;
    if (builtin.zig_backend == .stage2_riscv64) return error.SkipZigTest;

    const S = struct {
        fn doTheTest() !void {
            {
                // Broken out to avoid https://github.com/ziglang/zig/issues/11251
                const u8x3 = @Vector(3, u8);
                var lhs = u8x3{ 0, 0, 0 };
                var rhs = u8x3{ 255, 255, 255 };
                _ = .{ &lhs, &rhs };
                const result = lhs -| rhs;
                const expected = u8x3{ 0, 0, 0 };
                try expect(mem.eql(u8, &@as([3]u8, expected), &@as([3]u8, result)));
            }
            try testElemType(i4);
            try testElemType(u4);
            try testElemType(i8);
            try testElemType(u8);
            try testElemType(i12);
            try testElemType(u12);
            try testElemType(i16);
            try testElemType(u16);
            try testElemType(i24);
            try testElemType(u24);
            try testElemType(i32);
            try testElemType(u32);
            try testElemType(i48);
            try testElemType(u48);
            try testElemType(i64);
            try testElemType(u64);
        }
        fn testElemType(comptime Elem: type) !void {
            const min = std.math.minInt(Elem);
            const max = std.math.maxInt(Elem);

            var v: @Vector(4, Elem) = .{ 0, 1, 0, 1 };
            v -|= .{ 0, 0, 1, 1 };
            try expect(v[0] == 0);
            try expect(v[1] == 1);
            try expect(v[2] == @max(min, -1));
            try expect(v[3] == 0);

            v = .{ 0, max, 1, max };
            v -|= .{ max, 0, max, 1 };
            try expect(v[0] == @min(min + 1, 0));
            try expect(v[1] == max);
            try expect(v[2] == @min(min + 2, 0));
            try expect(v[3] == max - 1);

            v = .{ 1, max - 1, max / 2, max };
            v -|= .{ max - 1, 1, max / 2, max };
            try expect(v[0] == @min(min + 3, 0));
            try expect(v[1] == max - 2);
            try expect(v[2] == 0);
            try expect(v[3] == 0);

            switch (@typeInfo(Elem).int.signedness) {
                .signed => {
                    v = .{ -1, -1, 0, -1 };
                    v -|= .{ -1, 0, 1, 1 };
                    try expect(v[0] == 0);
                    try expect(v[1] == -1);
                    try expect(v[2] == -1);
                    try expect(v[3] == -2);

                    v = .{ 0, min, -1, min };
                    v -|= .{ max, 0, max, 1 };
                    try expect(v[0] == min + 1);
                    try expect(v[1] == min);
                    try expect(v[2] == min);
                    try expect(v[3] == min);

                    v = .{ -1, min + 1, min / 2, min };
                    v -|= .{ max, 1, max / 2, max };
                    try expect(v[0] == min);
                    try expect(v[1] == min);
                    try expect(v[2] == min + 1);
                    try expect(v[3] == min);
                },
                .unsigned => {},
            }
        }
    };
    try S.doTheTest();
    try comptime S.doTheTest();
}

test "saturating multiplication" {
    if (builtin.zig_backend == .stage2_arm) return error.SkipZigTest; // TODO
    if (builtin.zig_backend == .stage2_sparc64) return error.SkipZigTest; // TODO
    if (builtin.zig_backend == .stage2_spirv) return error.SkipZigTest;
    if (builtin.zig_backend == .stage2_riscv64) return error.SkipZigTest;

    const S = struct {
        fn doTheTest() !void {
            // Broken out to avoid https://github.com/ziglang/zig/issues/11251
            const u8x3 = @Vector(3, u8);
            var lhs = u8x3{ 2, 2, 2 };
            var rhs = u8x3{ 255, 255, 255 };
            _ = .{ &lhs, &rhs };
            const result = lhs *| rhs;
            const expected = u8x3{ 255, 255, 255 };
            try expect(mem.eql(u8, &@as([3]u8, expected), &@as([3]u8, result)));
        }
    };

    try S.doTheTest();
    try comptime S.doTheTest();
}

test "saturating shift-left" {
    if (builtin.zig_backend == .stage2_arm) return error.SkipZigTest; // TODO
    if (builtin.zig_backend == .stage2_sparc64) return error.SkipZigTest; // TODO
    if (builtin.zig_backend == .stage2_spirv) return error.SkipZigTest;
    if (builtin.zig_backend == .stage2_riscv64) return error.SkipZigTest;

    const S = struct {
        fn doTheTest() !void {
            // Broken out to avoid https://github.com/ziglang/zig/issues/11251
            const u8x3 = @Vector(3, u8);
            var lhs = u8x3{ 1, 1, 1 };
            var rhs = u8x3{ 255, 255, 255 };
            _ = .{ &lhs, &rhs };
            const result = lhs <<| rhs;
            const expected = u8x3{ 255, 255, 255 };
            try expect(mem.eql(u8, &@as([3]u8, expected), &@as([3]u8, result)));
        }
    };
    try S.doTheTest();
    try comptime S.doTheTest();
}

test "multiplication-assignment operator with an array operand" {
    if (builtin.zig_backend == .stage2_arm) return error.SkipZigTest; // TODO
    if (builtin.zig_backend == .stage2_sparc64) return error.SkipZigTest; // TODO
    if (builtin.zig_backend == .stage2_riscv64) return error.SkipZigTest;

    const S = struct {
        fn doTheTest() !void {
            var x: @Vector(3, i32) = .{ 1, 2, 3 };
            x *= [_]i32{ 4, 5, 6 };
            try expect(x[0] == 4);
            try expect(x[1] == 10);
            try expect(x[2] == 18);
        }
    };
    try S.doTheTest();
    try comptime S.doTheTest();
}

test "@addWithOverflow" {
    if (builtin.zig_backend == .stage2_arm) return error.SkipZigTest; // TODO
    if (builtin.zig_backend == .stage2_sparc64) return error.SkipZigTest; // TODO
    if (builtin.zig_backend == .stage2_riscv64) return error.SkipZigTest;
    if (builtin.zig_backend == .stage2_spirv) return error.SkipZigTest;

    const S = struct {
        fn doTheTest() !void {
            {
                var lhs = @Vector(4, u8){ 250, 250, 250, 250 };
                var rhs = @Vector(4, u8){ 0, 5, 6, 10 };
                _ = .{ &lhs, &rhs };
                const overflow = @addWithOverflow(lhs, rhs)[1];
                const expected: @Vector(4, u1) = .{ 0, 0, 1, 1 };
                try expectEqual(expected, overflow);
            }
            {
                var lhs = @Vector(4, i8){ -125, -125, 125, 125 };
                var rhs = @Vector(4, i8){ -3, -4, 2, 3 };
                _ = .{ &lhs, &rhs };
                const overflow = @addWithOverflow(lhs, rhs)[1];
                const expected: @Vector(4, u1) = .{ 0, 1, 0, 1 };
                try expectEqual(expected, overflow);
            }
            {
                var lhs = @Vector(4, u1){ 0, 0, 1, 1 };
                var rhs = @Vector(4, u1){ 0, 1, 0, 1 };
                _ = .{ &lhs, &rhs };
                const overflow = @addWithOverflow(lhs, rhs)[1];
                const expected: @Vector(4, u1) = .{ 0, 0, 0, 1 };
                try expectEqual(expected, overflow);
            }
            {
                var lhs = @Vector(4, u0){ 0, 0, 0, 0 };
                var rhs = @Vector(4, u0){ 0, 0, 0, 0 };
                _ = .{ &lhs, &rhs };
                const overflow = @addWithOverflow(lhs, rhs)[1];
                const expected: @Vector(4, u1) = .{ 0, 0, 0, 0 };
                try expectEqual(expected, overflow);
            }
        }
    };
    try comptime S.doTheTest();
    try S.doTheTest();
}

test "@subWithOverflow" {
    if (builtin.zig_backend == .stage2_arm) return error.SkipZigTest; // TODO
    if (builtin.zig_backend == .stage2_sparc64) return error.SkipZigTest; // TODO
    if (builtin.zig_backend == .stage2_riscv64) return error.SkipZigTest;
    if (builtin.zig_backend == .stage2_spirv) return error.SkipZigTest;

    const S = struct {
        fn doTheTest() !void {
            {
                var lhs = @Vector(2, u8){ 5, 5 };
                var rhs = @Vector(2, u8){ 5, 6 };
                _ = .{ &lhs, &rhs };
                const overflow = @subWithOverflow(lhs, rhs)[1];
                const expected: @Vector(2, u1) = .{ 0, 1 };
                try expectEqual(expected, overflow);
            }
            {
                var lhs = @Vector(4, i8){ -120, -120, 120, 120 };
                var rhs = @Vector(4, i8){ 8, 9, -7, -8 };
                _ = .{ &lhs, &rhs };
                const overflow = @subWithOverflow(lhs, rhs)[1];
                const expected: @Vector(4, u1) = .{ 0, 1, 0, 1 };
                try expectEqual(expected, overflow);
            }
        }
    };
    try comptime S.doTheTest();
    try S.doTheTest();
}

test "@mulWithOverflow" {
    if (builtin.zig_backend == .stage2_spirv) return error.SkipZigTest;
    if (builtin.zig_backend == .stage2_arm) return error.SkipZigTest; // TODO
    if (builtin.zig_backend == .stage2_sparc64) return error.SkipZigTest; // TODO
    if (builtin.zig_backend == .stage2_riscv64) return error.SkipZigTest;

    const S = struct {
        fn doTheTest() !void {
            var lhs = @Vector(4, u8){ 10, 10, 10, 10 };
            var rhs = @Vector(4, u8){ 25, 26, 0, 30 };
            _ = .{ &lhs, &rhs };
            const overflow = @mulWithOverflow(lhs, rhs)[1];
            const expected: @Vector(4, u1) = .{ 0, 1, 0, 1 };
            try expectEqual(expected, overflow);
        }
    };
    try comptime S.doTheTest();
    try S.doTheTest();
}

test "@shlWithOverflow" {
    if (builtin.zig_backend == .stage2_spirv) return error.SkipZigTest;
    if (builtin.zig_backend == .stage2_arm) return error.SkipZigTest; // TODO
    if (builtin.zig_backend == .stage2_sparc64) return error.SkipZigTest; // TODO
    if (builtin.zig_backend == .stage2_riscv64) return error.SkipZigTest;

    const S = struct {
        fn doTheTest() !void {
            var lhs = @Vector(4, u8){ 0, 1, 8, 255 };
            var rhs = @Vector(4, u3){ 7, 7, 7, 7 };
            _ = .{ &lhs, &rhs };
            const overflow = @shlWithOverflow(lhs, rhs)[1];
            const expected: @Vector(4, u1) = .{ 0, 0, 1, 1 };
            try expectEqual(expected, overflow);
        }
    };
    try S.doTheTest();
    try comptime S.doTheTest();
}

test "alignment of vectors" {
    try expect(@alignOf(@Vector(2, u8)) == switch (builtin.zig_backend) {
        else => 2,
        .stage2_c, .stage2_wasm => @alignOf(u8),
        .stage2_x86_64 => 16,
    });
    try expect(@alignOf(@Vector(2, u1)) == switch (builtin.zig_backend) {
        else => 1,
        .stage2_c, .stage2_wasm => @alignOf(u1),
        .stage2_x86_64 => 16,
    });
    try expect(@alignOf(@Vector(1, u1)) == switch (builtin.zig_backend) {
        else => 1,
        .stage2_c, .stage2_wasm => @alignOf(u1),
        .stage2_x86_64 => 16,
    });
    try expect(@alignOf(@Vector(2, u16)) == switch (builtin.zig_backend) {
        else => 4,
        .stage2_c, .stage2_wasm => @alignOf(u16),
        .stage2_x86_64 => 16,
    });
}

test "loading the second vector from a slice of vectors" {
    if (builtin.zig_backend == .stage2_arm) return error.SkipZigTest; // TODO
    if (builtin.zig_backend == .stage2_sparc64) return error.SkipZigTest; // TODO
    if (builtin.zig_backend == .stage2_spirv) return error.SkipZigTest;

    @setRuntimeSafety(false);
    var small_bases = [2]@Vector(2, u8){
        @Vector(2, u8){ 0, 1 },
        @Vector(2, u8){ 2, 3 },
    };
    const a: []const @Vector(2, u8) = &small_bases;
    const a4 = a[1][1];
    try expect(a4 == 3);
}

test "array of vectors is copied" {
    if (builtin.zig_backend == .stage2_arm) return error.SkipZigTest; // TODO
    if (builtin.zig_backend == .stage2_sparc64) return error.SkipZigTest; // TODO
    if (builtin.zig_backend == .stage2_spirv) return error.SkipZigTest;

    const Vec3 = @Vector(3, i32);
    var points = [_]Vec3{
        Vec3{ 404, -588, -901 },
        Vec3{ 528, -643, 409 },
        Vec3{ -838, 591, 734 },
        Vec3{ 390, -675, -793 },
        Vec3{ -537, -823, -458 },
        Vec3{ -485, -357, 347 },
        Vec3{ -345, -311, 381 },
        Vec3{ -661, -816, -575 },
    };
    _ = &points;
    var points2: [20]Vec3 = undefined;
    points2[0..points.len].* = points;
    try std.testing.expectEqual(points2[6], Vec3{ -345, -311, 381 });
}

test "byte vector initialized in inline function" {
    if (builtin.zig_backend == .stage2_arm) return error.SkipZigTest; // TODO
    if (builtin.zig_backend == .stage2_sparc64) return error.SkipZigTest; // TODO
    if (builtin.zig_backend == .stage2_riscv64) return error.SkipZigTest;
    if (builtin.cpu.arch == .hexagon and builtin.zig_backend == .stage2_llvm) return error.SkipZigTest;

    const S = struct {
        fn boolx4(e0: bool, e1: bool, e2: bool, e3: bool) @Vector(4, bool) {
            return .{ e0, e1, e2, e3 };
        }

        fn all(vb: @Vector(4, bool)) bool {
            return @reduce(.And, vb);
        }
    };

    try expect(S.all(S.boolx4(true, true, true, true)));
}

test "zero divisor" {
    if (builtin.zig_backend == .stage2_arm) return error.SkipZigTest; // TODO
    if (builtin.zig_backend == .stage2_sparc64) return error.SkipZigTest; // TODO

    const zeros = @Vector(2, f32){ 0.0, 0.0 };
    const ones = @Vector(2, f32){ 1.0, 1.0 };

    const v1 = zeros / ones;
    const v2 = @divExact(zeros, ones);
    const v3 = @divTrunc(zeros, ones);
    const v4 = @divFloor(zeros, ones);
    const v5 = @divCeil(zeros, ones);

    _ = v1[0];
    _ = v2[0];
    _ = v3[0];
    _ = v4[0];
    _ = v5[0];
}

test "zero multiplicand" {
    if (builtin.zig_backend == .stage2_arm) return error.SkipZigTest; // TODO
    if (builtin.zig_backend == .stage2_sparc64) return error.SkipZigTest; // TODO
    if (builtin.zig_backend == .stage2_riscv64) return error.SkipZigTest; // TODO
    if (builtin.zig_backend == .stage2_spirv) return error.SkipZigTest;

    const zeros = @Vector(2, u32){ 0.0, 0.0 };
    var ones = @Vector(2, u32){ 1.0, 1.0 };
    _ = &ones;

    _ = (ones * zeros)[0];
    _ = (zeros * zeros)[0];
    _ = (zeros * ones)[0];

    _ = (ones *| zeros)[0];
    _ = (zeros *| zeros)[0];
    _ = (zeros *| ones)[0];

    _ = (ones *% zeros)[0];
    _ = (zeros *% zeros)[0];
    _ = (zeros *% ones)[0];
}

test "@intCast to u0" {
    if (builtin.zig_backend == .stage2_arm) return error.SkipZigTest; // TODO
    if (builtin.zig_backend == .stage2_sparc64) return error.SkipZigTest; // TODO
    if (builtin.zig_backend == .stage2_riscv64) return error.SkipZigTest;
    if (builtin.cpu.arch == .hexagon and builtin.zig_backend == .stage2_llvm) return error.SkipZigTest;

    var zeros = @Vector(2, u32){ 0, 0 };
    _ = &zeros;
    const casted = @as(@Vector(2, u0), @intCast(zeros));

    _ = casted[0];
}

test "modRem with zero divisor" {
    comptime {
        var zeros = @Vector(2, u32){ 0, 0 };
        const ones = @Vector(2, u32){ 1, 1 };

        zeros %= ones;
        _ = zeros[0];
    }
}

test "array operands to shuffle are coerced to vectors" {
    if (builtin.zig_backend == .stage2_spirv) return error.SkipZigTest;
    if (builtin.zig_backend == .stage2_arm) return error.SkipZigTest; // TODO
    if (builtin.zig_backend == .stage2_sparc64) return error.SkipZigTest; // TODO
    if (builtin.zig_backend == .stage2_riscv64) return error.SkipZigTest;

    const mask = [5]i32{ -1, 0, 1, 2, 3 };

    var a = [5]u32{ 3, 5, 7, 9, 0 };
    _ = &a;
    const b = @shuffle(u32, a, @as(@Vector(5, u24), @splat(0)), mask);
    try expectEqual([_]u32{ 0, 3, 5, 7, 9 }, b);
}

test "load packed vector element" {
    if (builtin.zig_backend == .stage2_arm) return error.SkipZigTest; // TODO
    if (builtin.zig_backend == .stage2_sparc64) return error.SkipZigTest; // TODO
    if (builtin.zig_backend == .stage2_riscv64) return error.SkipZigTest;

    var x: @Vector(2, u15) = .{ 1, 4 };
    try expect((&x[0]).* == 1);
    try expect((&x[1]).* == 4);
}

test "store packed vector element" {
    if (builtin.zig_backend == .stage2_spirv) return error.SkipZigTest;
    if (builtin.zig_backend == .stage2_arm) return error.SkipZigTest; // TODO
    if (builtin.zig_backend == .stage2_sparc64) return error.SkipZigTest; // TODO
    if (builtin.zig_backend == .stage2_riscv64) return error.SkipZigTest;

    var v = @Vector(4, u1){ 1, 1, 1, 1 };
    try expectEqual(@Vector(4, u1){ 1, 1, 1, 1 }, v);
    const index: usize = 0;
    v[index] = 0;
    try expectEqual(@Vector(4, u1){ 0, 1, 1, 1 }, v);
}

test "store to vector in slice" {
    if (builtin.zig_backend == .stage2_arm) return error.SkipZigTest; // TODO
    if (builtin.zig_backend == .stage2_sparc64) return error.SkipZigTest; // TODO
    if (builtin.zig_backend == .stage2_spirv) return error.SkipZigTest;

    var v = [_]@Vector(3, f32){
        .{ 1, 1, 1 },
        .{ 0, 0, 0 },
    };
    var s: []@Vector(3, f32) = &v;
    var i: usize = 1;
    _ = &i;
    s[i] = s[0];
    try expectEqual(v[1], v[0]);
}

test "store vector with memset" {
    if (builtin.zig_backend == .stage2_arm) return error.SkipZigTest; // TODO
    if (builtin.zig_backend == .stage2_sparc64) return error.SkipZigTest; // TODO
    if (builtin.zig_backend == .stage2_spirv) return error.SkipZigTest; // TODO
    if (builtin.zig_backend == .stage2_riscv64) return error.SkipZigTest;

    var a: [5]@Vector(2, i1) = undefined;
    var b: [5]@Vector(2, u2) = undefined;
    var c: [5]@Vector(2, i4) = undefined;
    var d: [5]@Vector(2, u8) = undefined;
    var e: [5]@Vector(2, i9) = undefined;
    var ka = @Vector(2, i1){ -1, 0 };
    var kb = @Vector(2, u2){ 0, 1 };
    var kc = @Vector(2, i4){ 2, 3 };
    var kd = @Vector(2, u8){ 4, 5 };
    var ke = @Vector(2, i9){ 6, 7 };
    _ = .{ &ka, &kb, &kc, &kd, &ke };
    @memset(&a, ka);
    @memset(&b, kb);
    @memset(&c, kc);
    @memset(&d, kd);
    @memset(&e, ke);
    try std.testing.expectEqual(ka, a[0]);
    try std.testing.expectEqual(kb, b[1]);
    try std.testing.expectEqual(kc, c[2]);
    try std.testing.expectEqual(kd, d[3]);
    try std.testing.expectEqual(ke, e[4]);
}

test "addition of vectors represented as strings" {
    if (builtin.zig_backend == .stage2_spirv) return error.SkipZigTest;
    if (builtin.zig_backend == .stage2_arm) return error.SkipZigTest; // TODO

    const V = @Vector(3, u8);
    const foo: V = "foo".*;
    const bar: V = @typeName(u32).*;
    try expectEqual(V{ 219, 162, 161 }, foo + bar);
}

test "compare vectors with different element types" {
    if (builtin.zig_backend == .stage2_spirv) return error.SkipZigTest;
    if (builtin.zig_backend == .stage2_arm) return error.SkipZigTest; // TODO
    if (builtin.zig_backend == .stage2_sparc64) return error.SkipZigTest; // TODO
    if (builtin.zig_backend == .stage2_riscv64) return error.SkipZigTest;

    var a: @Vector(2, u8) = .{ 1, 2 };
    var b: @Vector(2, u9) = .{ 3, 0 };
    _ = .{ &a, &b };
    try expectEqual(@Vector(2, bool){ true, false }, a < b);
}

test "vector pointer is indexable" {
    if (builtin.zig_backend == .stage2_arm) return error.SkipZigTest; // TODO
    if (builtin.zig_backend == .stage2_sparc64) return error.SkipZigTest; // TODO

    const V = @Vector(2, u32);

    const x: V = .{ 123, 456 };
    comptime assert(@typeInfo(@TypeOf(&(&x)[0])).pointer.attrs.@"const");
    try expectEqual(@as(u32, 123), (&x)[0]);
    try expectEqual(@as(u32, 456), (&x)[1]);

    var y: V = .{ 123, 456 };
    comptime assert(!@typeInfo(@TypeOf(&(&y)[0])).pointer.attrs.@"const");
    try expectEqual(@as(u32, 123), (&y)[0]);
    try expectEqual(@as(u32, 456), (&y)[1]);

    (&y)[0] = 100;
    (&y)[1] = 200;
    try expectEqual(@as(u32, 100), (&y)[0]);
    try expectEqual(@as(u32, 200), (&y)[1]);
}

test "boolean vector with 2 or more booleans" {
    if (builtin.zig_backend == .stage2_arm) return error.SkipZigTest; // TODO
    if (builtin.zig_backend == .stage2_sparc64) return error.SkipZigTest; // TODO

    const vec1 = @Vector(2, bool){ true, true };
    _ = vec1;

    const vec2 = @Vector(3, bool){ true, true, true };
    _ = vec2;
}

test "bitcast to vector with different child type" {
    if (builtin.zig_backend == .stage2_arm) return error.SkipZigTest; // TODO
    if (builtin.zig_backend == .stage2_sparc64) return error.SkipZigTest; // TODO
    if (builtin.zig_backend == .stage2_riscv64) return error.SkipZigTest;
    if (builtin.zig_backend == .stage2_spirv) return error.SkipZigTest;

    const S = struct {
        fn doTheTest() !void {
            const VecA = @Vector(8, u16);
            const VecB = @Vector(4, u32);

            var vec_a = VecA{ 1, 1, 1, 1, 1, 1, 1, 1 };
            _ = &vec_a;
            const vec_b: VecB = @bitCast(vec_a);
            const vec_c: VecA = @bitCast(vec_b);
            try expectEqual(vec_a, vec_c);
        }
    };

    try S.doTheTest();
    try comptime S.doTheTest();
}

test "index into comptime-known vector is comptime-known" {
    const vec: @Vector(2, f16) = [2]f16{ 1.5, 3.5 };
    if (vec[0] != 1.5) @compileError("vec should be comptime");
}

test "arithmetic on zero-length vectors" {
    if (builtin.zig_backend == .stage2_arm) return error.SkipZigTest; // TODO
    if (builtin.zig_backend == .stage2_sparc64) return error.SkipZigTest; // TODO

    {
        const a = @Vector(0, i32){};
        const b = @Vector(0, i32){};
        _ = a + b;
    }
    {
        const a = @Vector(0, i32){};
        const b = @Vector(0, i32){};
        _ = a - b;
    }
}

test "@reduce on bool vector" {
    if (builtin.zig_backend == .stage2_arm) return error.SkipZigTest; // TODO

    const a = @Vector(2, bool){ true, true };
    const b = @Vector(1, bool){true};
    try std.testing.expect(@reduce(.And, a));
    try std.testing.expect(@reduce(.And, b));
}

test "bitcast vector to array of smaller vectors" {
    if (builtin.zig_backend == .stage2_arm) return error.SkipZigTest; // TODO
    if (builtin.zig_backend == .stage2_spirv) return error.SkipZigTest;

    const u8x32 = @Vector(32, u8);
    const u8x64 = @Vector(64, u8);
    const S = struct {
        fn doTheTest(input_vec: u8x64) !void {
            try compare(@bitCast(input_vec));
        }
        fn compare(chunks: [2]u8x32) !void {
            try expectEqual(@as(u8x32, @splat(1)), chunks[0]);
            try expectEqual(@as(u8x32, @splat(2)), chunks[1]);
        }
    };
    const input: u8x64 = @bitCast([2]u8x32{ @splat(1), @splat(2) });
    try S.doTheTest(input);
}

fn reduceRuntime(comptime T: type, comptime values: anytype, comptime op: std.builtin.ReduceOp) !void {
    const V = @Vector(values.len, T);
    var input: V = values;
    const ptr: *volatile V = &input;
    const value = ptr.*;
    try expect(@reduce(op, value) == comptime @reduce(op, @as(V, values)));
    inline for (0..values.len) |i| try expect(value[i] == values[i]);
}

test "@reduce runtime integer and bool vectors" {
    if (builtin.zig_backend == .stage2_arm) return error.SkipZigTest; // TODO
    if (builtin.zig_backend == .stage2_sparc64) return error.SkipZigTest; // TODO
    if (builtin.zig_backend == .stage2_spirv) return error.SkipZigTest;
    if (builtin.zig_backend == .stage2_riscv64) return error.SkipZigTest;

    inline for (.{ u3, u8, u24, u64, i7, i32, i64 }) |T| {
        const values = if (@typeInfo(T).int.signedness == .signed)
            [3]T{ math.minInt(T), -1, math.maxInt(T) }
        else
            [3]T{ math.maxInt(T), 1, math.maxInt(T) };
        inline for (.{ .And, .Or, .Xor, .Add, .Mul, .Min, .Max }) |op| {
            try reduceRuntime(T, values, op);
        }
    }
    try reduceRuntime(u8, @as([32]u8, @splat(255)), .Or);
    try reduceRuntime(u8, @as([16]u8, @splat(255)), .Add);
    try reduceRuntime(bool, @as([17]bool, @splat(false)), .Or);
    try reduceRuntime(bool, @as([17]bool, @splat(true)), .And);
    try reduceRuntime(bool, @as([16]bool, @splat(true)), .Xor);
}

fn compareRuntime(comptime T: type, comptime n: usize) !void {
    const V = @Vector(n, T);
    var left: V = undefined;
    var right: V = @splat(0);
    const lp: *volatile V = &left;
    const rp: *volatile V = &right;
    inline for (0..n) |i| lp[i] = if (@typeInfo(T).int.signedness == .signed) @as(T, i % 3) - 1 else i % 3;
    const lhs = lp.*;
    const rhs = rp.*;
    const lt: [n]bool = lhs < rhs;
    const eq: [n]bool = lhs == rhs;
    const gte: [n]bool = lhs >= rhs;
    inline for (0..n) |i| {
        const a: T = if (@typeInfo(T).int.signedness == .signed) @as(T, i % 3) - 1 else i % 3;
        try expect(lt[i] == (a < 0));
        try expect(eq[i] == (a == 0));
        try expect(gte[i] == (a >= 0));
    }
}

fn bitwiseRuntime(comptime T: type, comptime n: usize) !void {
    const V = @Vector(n, T);
    var left: V = undefined;
    var right: V = undefined;
    const lp: *volatile V = &left;
    const rp: *volatile V = &right;
    inline for (0..n) |i| {
        lp[i] = if (T == bool) i % 2 == 0 else @truncate(i * 7 + 1);
        rp[i] = if (T == bool) i % 3 == 0 else @truncate(i * 11 + 2);
    }
    const lhs = lp.*;
    const rhs = rp.*;
    const and_result: [n]T = lhs & rhs;
    const or_result: [n]T = lhs | rhs;
    const xor_result: [n]T = lhs ^ rhs;
    inline for (0..n) |i| {
        const a: T = if (T == bool) i % 2 == 0 else @truncate(i * 7 + 1);
        const b: T = if (T == bool) i % 3 == 0 else @truncate(i * 11 + 2);
        try expect(and_result[i] == a & b);
        try expect(or_result[i] == a | b);
        try expect(xor_result[i] == a ^ b);
    }
}

noinline fn castVector(comptime Dst: type, comptime Src: type, comptime n: usize, input: *const @Vector(n, Src), output: *@Vector(n, Dst)) void {
    @setRuntimeSafety(false); // every lane fits; this checks the unchecked cast
    output.* = @intCast(input.*);
}

test "runtime integer vector comparisons, bitwise operations and casts" {
    if (builtin.zig_backend == .stage2_arm) return error.SkipZigTest; // TODO
    if (builtin.zig_backend == .stage2_sparc64) return error.SkipZigTest; // TODO
    if (builtin.zig_backend == .stage2_spirv) return error.SkipZigTest;
    if (builtin.zig_backend == .stage2_riscv64) return error.SkipZigTest;

    inline for (.{ u8, u32, i16, i64 }) |T| {
        try compareRuntime(T, 3);
        try compareRuntime(T, 17);
    }
    inline for (.{ u1, u3, u8, u24, u64, bool }) |T| try bitwiseRuntime(T, 17);

    var bits: @Vector(16, u1) = @splat(0);
    const bp: *volatile @Vector(16, u1) = &bits;
    bp[14] = 1;
    bp[15] = 1;
    const input = bp.*;
    var widened: @Vector(16, u8) = undefined;
    castVector(u8, u1, 16, &input, &widened);
    const widened_array: [16]u8 = widened;
    for (widened_array, 0..) |lane, i| try expect(lane == @intFromBool(i >= 14));

    var signed: @Vector(8, i3) = .{ -4, -3, -2, -1, 0, 1, 2, 3 };
    var wide_signed: @Vector(8, i16) = undefined;
    castVector(i16, i3, 8, &signed, &wide_signed);
    const wide_signed_array: [8]i16 = wide_signed;
    for (wide_signed_array, 0..) |lane, i| try expect(lane == @as(i16, @intCast(i)) - 4);
}

const packed_vector_u7 = @Vector(3, u7){ 65, 127, 19 };
const packed_vector_i9 = @Vector(3, i9){ -1, -256, 37 };
const packed_vector_u65 = @Vector(3, u65){ (1 << 64) | 3, 19, (1 << 64) | 37 };

noinline fn copyVector(comptime n: usize, destination: *volatile @Vector(n, u8), source: *const volatile @Vector(n, u8)) void {
    destination.* = source.*;
}

fn checkVectorCopy(comptime n: usize) !void {
    var source: @Vector(n, u8) = undefined;
    var destination: @Vector(n, u8) = @splat(0);
    const sp: *volatile @Vector(n, u8) = &source;
    inline for (0..n) |i| sp[i] = @truncate(i * 7 + 11);
    copyVector(n, &destination, &source);
    const array: [n]u8 = destination;
    for (array, 0..) |byte, i| try expect(byte == @as(u8, @truncate(i * 7 + 11)));
}

test "global packed vector constants and large vector copies" {
    if (builtin.zig_backend == .stage2_arm) return error.SkipZigTest; // TODO
    if (builtin.zig_backend == .stage2_sparc64) return error.SkipZigTest; // TODO
    if (builtin.zig_backend == .stage2_spirv) return error.SkipZigTest;
    if (builtin.zig_backend == .stage2_riscv64) return error.SkipZigTest;

    const p7: *const volatile @Vector(3, u7) = &packed_vector_u7;
    try expect(p7[0] == 65 and p7[1] == 127 and p7[2] == 19);
    const p9: *const volatile @Vector(3, i9) = &packed_vector_i9;
    try expect(p9[0] == -1 and p9[1] == -256 and p9[2] == 37);
    const p65: *const volatile @Vector(3, u65) = &packed_vector_u65;
    try expect(p65[0] == (1 << 64) | 3 and p65[1] == 19 and p65[2] == (1 << 64) | 37);

    try checkVectorCopy(32);
    try checkVectorCopy(64);
}

fn addSubNotRuntime(comptime T: type, comptime n: usize, left: [n]T, right: [n]T) !void {
    var left_storage = left;
    var right_storage = right;
    const left_ptr: *volatile [n]T = &left_storage;
    const right_ptr: *volatile [n]T = &right_storage;
    const a: @Vector(n, T) = left_ptr.*;
    const b: @Vector(n, T) = right_ptr.*;
    const sum: [n]T = a +% b;
    const difference: [n]T = a -% b;
    const complement: [n]T = ~a;
    for (0..n) |i| {
        try expect(sum[i] == left[i] +% right[i]);
        try expect(difference[i] == left[i] -% right[i]);
        try expect(complement[i] == ~left[i]);
    }
}

fn VectorBetweenGuards(comptime n: usize, comptime T: type) type {
    return struct { before: u64, vector: @Vector(n, T), after: u64 };
}

fn storeVectorBetweenGuards(comptime T: type, comptime n: usize, left: [n]T, right: [n]T) !void {
    var left_storage = left;
    const left_ptr: *volatile [n]T = &left_storage;
    const a: @Vector(n, T) = left_ptr.*;
    const b: @Vector(n, T) = right;
    var wrapped: VectorBetweenGuards(n, T) = .{ .before = 0x0123456789abcdef, .vector = a, .after = 0xfedcba9876543210 };
    const wrapped_ptr: *volatile VectorBetweenGuards(n, T) = &wrapped;
    wrapped_ptr.vector = if (@typeInfo(T) == .float) a + b else a +% b;
    const sum: [n]T = wrapped_ptr.vector;
    try expect(wrapped_ptr.before == 0x0123456789abcdef and wrapped_ptr.after == 0xfedcba9876543210);
    for (0..n) |i| try expect(sum[i] == if (@typeInfo(T) == .float) left[i] + right[i] else left[i] +% right[i]);
}

test "runtime vector add, sub and not on packed and native lanes" {
    if (builtin.zig_backend == .stage2_arm) return error.SkipZigTest; // TODO
    if (builtin.zig_backend == .stage2_sparc64) return error.SkipZigTest; // TODO
    if (builtin.zig_backend == .stage2_spirv) return error.SkipZigTest;
    if (builtin.zig_backend == .stage2_riscv64) return error.SkipZigTest;

    try addSubNotRuntime(u3, 5, .{ 7, 1, 0, 6, 3 }, .{ 2, 7, 5, 2, 6 });
    try addSubNotRuntime(i7, 5, .{ -64, -2, 63, 20, -20 }, .{ -1, 63, 1, 60, -60 });
    try addSubNotRuntime(u32, 4, .{ 0xffffffff, 1, 0, 0x76543210 }, .{ 1, 0xffffffff, 9, 0x12345678 });
    try addSubNotRuntime(u64, 3, .{ 0xffffffffffffffff, 0, 0x123456789abcdef0 }, .{ 1, 9, 0x7654321001234567 });
    try storeVectorBetweenGuards(u3, 9, .{ 1, 7, 0, 5, 2, 6, 3, 4, 7 }, .{ 6, 0, 7, 2, 5, 1, 4, 3, 0 });
    try storeVectorBetweenGuards(u24, 4, .{ 0xffffff, 0x123456, 0, 0xabcdef }, .{ 1, 0xfedcba, 0x800000, 0x7fffff });
    try storeVectorBetweenGuards(i33, 3, .{ -1, 0xffffffff, -0x100000000 }, .{ 0xffffffff, -0x100000000, 1 });
    try storeVectorBetweenGuards(f16, 4, .{ 1.5, -2.25, 0, 100 }, .{ -0.5, 3.75, 0.125, 8 });
    try storeVectorBetweenGuards(f64, 3, .{ 1.5, -2.25, 1e300 }, .{ -0.5, 3.75, 1e-300 });

    var bools: [9]bool = .{ true, false, true, false, false, true, true, false, true };
    const bools_ptr: *volatile [9]bool = &bools;
    const input: @Vector(9, bool) = bools_ptr.*;
    const negated: [9]bool = !input;
    for (negated, bools) |n, b| try expect(n == !b);
}

test "error union of a bool vector returned from a call" {
    if (builtin.zig_backend == .stage2_spirv) return error.SkipZigTest;

    const S = struct {
        fn vectorOrError(fail: bool) !@Vector(3, bool) {
            if (fail) return error.Fail;
            return .{ true, false, true };
        }
    };
    var fail = false;
    _ = &fail;
    try expectEqual(@Vector(3, bool){ true, false, true }, try S.vectorOrError(fail));
    fail = true;
    try std.testing.expectError(error.Fail, S.vectorOrError(fail));
}

test "single-lane vector arguments and return values" {
    if (builtin.zig_backend == .stage2_spirv) return error.SkipZigTest;

    const S = struct {
        fn passVector(comptime T: type, v: @Vector(1, T)) @Vector(1, T) {
            return v;
        }

        fn doTheTest(comptime T: type, value: T) !void {
            var v: @Vector(1, T) = .{value};
            _ = &v;
            try expect(passVector(T, v)[0] == value);
        }
    };
    var byte: u8 = 7;
    try S.doTheTest(u8, 0xab);
    try S.doTheTest(u16, 0xabcd);
    try S.doTheTest(u32, 0xabcd_1234);
    try S.doTheTest(u64, 0xabcd_1234_5678_9abc);
    try S.doTheTest(f32, 1.5);
    try S.doTheTest(f64, -2.25);
    try S.doTheTest(*u8, &byte);
    try S.doTheTest(?*u8, null);
    try S.doTheTest(?*u8, &byte);
}

test "single-lane vectors passed as their scalar" {
    if (builtin.zig_backend == .stage2_spirv) return error.SkipZigTest;

    const S = struct {
        fn passVector(comptime T: type, v: @Vector(1, T)) @Vector(1, T) {
            return v;
        }

        fn doTheTest(comptime T: type, value: T) !void {
            var v: @Vector(1, T) = .{value};
            _ = &v;
            try expect(passVector(T, v)[0] == value);
        }
    };
    try S.doTheTest(bool, true);
    try S.doTheTest(bool, false);
    try S.doTheTest(u5, 19);
    try S.doTheTest(i128, -0x1234_5678_9abc_def0_1234);
    try S.doTheTest(f80, -1.25);
    try S.doTheTest(f128, 0.1);
}

test "error unions of vectors and floats returned in general registers" {
    if (builtin.zig_backend == .stage2_spirv) return error.SkipZigTest;

    const S = struct {
        fn valueOrError(comptime T: type, fail: bool, value: T) error{Fail}!T {
            if (fail) return error.Fail;
            return value;
        }

        fn forward(comptime T: type, fail: bool, value: T) error{ Fail, Other }!T {
            return try valueOrError(T, fail, value);
        }

        fn doTheTest(comptime T: type, value: T) !void {
            var fail = false;
            _ = &fail;
            try expectEqual(value, try forward(T, fail, value));
            fail = true;
            try std.testing.expectError(error.Fail, forward(T, fail, value));
        }
    };
    try S.doTheTest(f16, 1.5);
    try S.doTheTest(f32, -2.5);
    try S.doTheTest(f64, 3.25);
    try S.doTheTest(@Vector(2, f32), .{ 1.5, -2.5 });
    try S.doTheTest(@Vector(3, u8), .{ 1, 2, 3 });
    try S.doTheTest(@Vector(3, bool), .{ true, false, true });
    try S.doTheTest([3]bool, .{ true, false, true });
}

fn simdIntRuntime(comptime T: type, comptime n: usize) !void {
    const V = @Vector(n, T);
    const Amount = math.Log2Int(T);
    const bits = @typeInfo(T).int.bits;
    const Bits = @Int(.unsigned, bits);
    var left: [n]T = undefined;
    var right: [n]T = undefined;
    var amounts: [n]Amount = undefined;
    for (0..n) |i| {
        // Lanes that overflow, change sign and carry between bytes.
        left[i] = @bitCast(@as(Bits, @truncate(@as(u64, 0xfedcba9876543210) +% @as(u64, i) *% 0x9e3779b97f4a7c15)));
        right[i] = @bitCast(@as(Bits, @truncate(@as(u64, 0x0123456789abcdef) *% (@as(u64, i) + 3))));
        amounts[i] = @intCast((i * 5 + 1) % bits);
    }
    const left_ptr: *volatile [n]T = &left;
    const right_ptr: *volatile [n]T = &right;
    const amounts_ptr: *volatile [n]Amount = &amounts;
    var scalar: T = left[n - 1];
    var amount: Amount = @intCast(bits / 2 + 1);
    const scalar_ptr: *volatile T = &scalar;
    const amount_ptr: *volatile Amount = &amount;
    const a: V = left_ptr.*;
    const b: V = right_ptr.*;
    const by: @Vector(n, Amount) = amounts_ptr.*;
    const s = amount_ptr.*;

    const sum: [n]T = a +% b;
    const difference: [n]T = a -% b;
    const conjunction: [n]T = a & b;
    const disjunction: [n]T = a | b;
    const exclusive: [n]T = a ^ b;
    const complement: [n]T = ~a;
    const shl_constant: [n]T = a << @splat(3);
    const shr_constant: [n]T = a >> @splat(bits - 1);
    const shl_runtime: [n]T = a << @splat(s);
    const shr_runtime: [n]T = a >> @splat(s);
    const shl_lanes: [n]T = a << by;
    const shr_lanes: [n]T = a >> by;
    const rotated: [n]T = if (@typeInfo(T).int.signedness == .unsigned) math.rotr(V, a ^ b, 7) else a;
    const splatted: [n]T = @as(V, @splat(scalar_ptr.*)) +% b;
    for (0..n) |i| {
        try expect(sum[i] == left[i] +% right[i]);
        try expect(difference[i] == left[i] -% right[i]);
        try expect(conjunction[i] == left[i] & right[i]);
        try expect(disjunction[i] == left[i] | right[i]);
        try expect(exclusive[i] == left[i] ^ right[i]);
        try expect(complement[i] == ~left[i]);
        try expect(shl_constant[i] == left[i] << 3);
        try expect(shr_constant[i] == left[i] >> (bits - 1));
        try expect(shl_runtime[i] == left[i] << s);
        try expect(shr_runtime[i] == left[i] >> s);
        try expect(shl_lanes[i] == left[i] << amounts[i]);
        try expect(shr_lanes[i] == left[i] >> amounts[i]);
        if (@typeInfo(T).int.signedness == .unsigned)
            try expect(rotated[i] == math.rotr(T, left[i] ^ right[i], 7));
        try expect(splatted[i] == scalar +% right[i]);
    }
}

test "SIMD integer vector arithmetic, shifts and rotates" {
    if (builtin.zig_backend == .stage2_arm) return error.SkipZigTest; // TODO
    if (builtin.zig_backend == .stage2_sparc64) return error.SkipZigTest; // TODO
    if (builtin.zig_backend == .stage2_spirv) return error.SkipZigTest;
    if (builtin.zig_backend == .stage2_riscv64) return error.SkipZigTest;

    inline for (.{ u8, i8 }) |T| {
        try simdIntRuntime(T, 8);
        try simdIntRuntime(T, 16);
    }
    inline for (.{ u16, i16 }) |T| {
        try simdIntRuntime(T, 4);
        try simdIntRuntime(T, 8);
    }
    inline for (.{ u32, i32 }) |T| {
        try simdIntRuntime(T, 2);
        try simdIntRuntime(T, 4);
    }
    inline for (.{ u64, i64 }) |T| try simdIntRuntime(T, 2);
}
