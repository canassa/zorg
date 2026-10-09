const std = @import("std");
const builtin = @import("builtin");
const expect = std.testing.expect;
const assert = std.debug.assert;

test "memcpy and memset intrinsics" {
    if (builtin.zig_backend == .stage2_arm) return error.SkipZigTest;
    if (builtin.zig_backend == .stage2_sparc64) return error.SkipZigTest; // TODO
    if (builtin.zig_backend == .stage2_spirv) return error.SkipZigTest;

    try testMemcpyMemset();
    try comptime testMemcpyMemset();
}

fn testMemcpyMemset() !void {
    var foo: [20]u8 = undefined;
    var bar: [20]u8 = undefined;

    @memset(&foo, 'A');
    @memcpy(&bar, &foo);

    try expect(bar[0] == 'A');
    try expect(bar[11] == 'A');
    try expect(bar[19] == 'A');
}

test "@memcpy with both operands single-ptr-to-array, one is null-terminated" {
    if (builtin.zig_backend == .stage2_arm) return error.SkipZigTest;
    if (builtin.zig_backend == .stage2_sparc64) return error.SkipZigTest;
    if (builtin.zig_backend == .stage2_spirv) return error.SkipZigTest;

    try testMemcpyBothSinglePtrArrayOneIsNullTerminated();
    try comptime testMemcpyBothSinglePtrArrayOneIsNullTerminated();
}

fn testMemcpyBothSinglePtrArrayOneIsNullTerminated() !void {
    var buf: [100]u8 = undefined;
    const suffix = "hello";
    @memcpy(buf[buf.len - suffix.len ..], suffix);
    try expect(buf[95] == 'h');
    try expect(buf[96] == 'e');
    try expect(buf[97] == 'l');
    try expect(buf[98] == 'l');
    try expect(buf[99] == 'o');
}

test "@memcpy dest many pointer" {
    if (builtin.zig_backend == .stage2_arm) return error.SkipZigTest;
    if (builtin.zig_backend == .stage2_sparc64) return error.SkipZigTest;
    if (builtin.zig_backend == .stage2_spirv) return error.SkipZigTest;

    try testMemcpyDestManyPtr();
    try comptime testMemcpyDestManyPtr();
}

fn testMemcpyDestManyPtr() !void {
    var str = "hello".*;
    var buf: [5]u8 = undefined;
    var len: usize = 5;
    _ = &len;
    @memcpy(@as([*]u8, @ptrCast(&buf)), @as([*]const u8, @ptrCast(&str))[0..len]);
    try expect(buf[0] == 'h');
    try expect(buf[1] == 'e');
    try expect(buf[2] == 'l');
    try expect(buf[3] == 'l');
    try expect(buf[4] == 'o');
}

test "@memcpy C pointer" {
    if (builtin.zig_backend == .stage2_arm) return error.SkipZigTest;
    if (builtin.zig_backend == .stage2_sparc64) return error.SkipZigTest;
    if (builtin.zig_backend == .stage2_spirv) return error.SkipZigTest;

    try testMemcpyCPointer();
    try comptime testMemcpyCPointer();
}

fn testMemcpyCPointer() !void {
    const src = "hello";
    var buf: [5]u8 = undefined;
    @memcpy(@as([*c]u8, &buf), src);
    try expect(buf[0] == 'h');
    try expect(buf[1] == 'e');
    try expect(buf[2] == 'l');
    try expect(buf[3] == 'l');
    try expect(buf[4] == 'o');
}

test "@memcpy slice" {
    if (builtin.zig_backend == .stage2_arm) return error.SkipZigTest;
    if (builtin.zig_backend == .stage2_sparc64) return error.SkipZigTest;
    if (builtin.zig_backend == .stage2_spirv) return error.SkipZigTest;

    try testMemcpySlice();
    try comptime testMemcpySlice();
}

fn testMemcpySlice() !void {
    var buf: [5]u8 = undefined;
    const dst: []u8 = &buf;
    const src: []const u8 = "hello";
    @memcpy(dst, src);
    try expect(buf[0] == 'h');
    try expect(buf[1] == 'e');
    try expect(buf[2] == 'l');
    try expect(buf[3] == 'l');
    try expect(buf[4] == 'o');
}

comptime {
    const S = struct {
        buffer: [8]u8 = undefined,
        fn set(self: *@This(), items: []const u8) void {
            @memcpy(self.buffer[0..items.len], items);
        }
    };

    var s = S{};
    s.set("hello");
    if (!std.mem.eql(u8, s.buffer[0..5], "hello")) @compileError("bad");
}

test "@memcpy comptime-only type" {
    const in: [4]type = .{ u8, u16, u32, u64 };
    comptime var out: [4]type = undefined;
    @memcpy(&out, &in);

    comptime assert(out[0] == u8);
    comptime assert(out[1] == u16);
    comptime assert(out[2] == u32);
    comptime assert(out[3] == u64);
}

test "@memcpy zero-bit type with aliasing" {
    if (builtin.zig_backend == .stage2_spirv) return error.SkipZigTest;

    const S = struct {
        fn doTheTest() void {
            var buf: [3]void = @splat({});
            const slice: []void = &buf;
            // These two pointers are the same, but it's still not considered aliasing because
            // the input and output slices both correspond to zero bits of memory.
            @memcpy(slice, slice);
            comptime assert(buf[0] == {});
            comptime assert(buf[1] == {});
            comptime assert(buf[2] == {});
        }
    };
    S.doTheTest();
    comptime S.doTheTest();
}

test "@memcpy with sentinel" {
    if (builtin.zig_backend == .stage2_spirv) return error.SkipZigTest;

    const S = struct {
        fn doTheTest() void {
            const field_name = @typeInfo(struct { a: u32 }).@"struct".field_names[0];
            var buffer: [field_name.len]u8 = undefined;
            @memcpy(&buffer, field_name);
        }
    };

    S.doTheTest();
    comptime S.doTheTest();
}

test "@memcpy no sentinel source into sentinel destination" {
    const S = struct {
        fn doTheTest() void {
            const src: []const u8 = &.{ 1, 2, 3 };
            comptime var dest_buf: [3:0]u8 = @splat(0);
            const dest: [:0]u8 = &dest_buf;
            @memcpy(dest, src);
        }
    };

    S.doTheTest();
    comptime S.doTheTest();
}

test "@memcpy a global array" {
    const S = struct {
        var array_u8: [1]u8 = .{1};
        const slice_u8: []u8 = &array_u8;
        var array_u32: [1]u32 = .{10};
        const slice_u32: []u32 = &array_u32;
    };

    try expect(S.array_u8[0] == 1);
    @memcpy(&S.array_u8, &[1]u8{2});
    try expect(S.array_u8[0] == 2);
    @memcpy(&S.array_u8, &[1]u8{S.array_u8[0] + 1});
    try expect(S.array_u8[0] == 3);
    @memcpy(S.slice_u8, &[1]u8{4});
    try expect(S.array_u8[0] == 4);
    @memcpy(S.slice_u8, &[1]u8{S.array_u8[0] + 1});
    try expect(S.array_u8[0] == 5);

    try expect(S.array_u32[0] == 10);
    @memcpy(&S.array_u32, &[1]u32{20});
    try expect(S.array_u32[0] == 20);
    @memcpy(&S.array_u32, &[1]u32{S.array_u32[0] + 10});
    try expect(S.array_u32[0] == 30);
    @memcpy(S.slice_u32, &[1]u32{40});
    try expect(S.array_u32[0] == 40);
    @memcpy(S.slice_u32, &[1]u32{S.array_u32[0] + 10});
    try expect(S.array_u32[0] == 50);
}

const fixed_copy_sizes = [_]usize{ 1, 3, 7, 8, 9, 15, 16, 17, 24, 31, 32, 33, 48, 52, 63, 64, 65, 100, 127, 128, 129, 255, 256, 257 };

fn fillPattern(bytes: []u8, seed: u8) void {
    for (bytes, 0..) |*byte, i| byte.* = @as(u8, @truncate(i *% 13)) +% seed;
}

fn FixedCopy(comptime n: usize) type {
    return struct {
        const Bytes = extern struct { bytes: [n]u8 };
        const Words = extern struct { words: [n / 8]u64, tail: [n % 8]u8 };
        const Misaligned = extern struct { pad: u8, value: Words align(1), after: u8 };
        const Union = union { bytes: [n]u8, word: u64 };

        noinline fn copyBytes(dst: *Bytes, src: *const Bytes) void {
            dst.* = src.*;
        }
        noinline fn copyWords(dst: *Words, src: *const Words) void {
            dst.* = src.*;
        }
        noinline fn copyMisaligned(dst: *align(1) Words, src: *align(1) const Words) void {
            dst.* = src.*;
        }
        noinline fn copyUnion(dst: *Union, src: *const Union) void {
            dst.* = src.*;
        }
        noinline fn copyArray(dst: *[n]u8, src: *const [n]u8) void {
            @memcpy(dst, src);
        }
        noinline fn returnBytes(src: *const Bytes) Bytes {
            const local = src.*;
            return local;
        }

        fn check() !void {
            var src: Bytes = undefined;
            var dst: Bytes = undefined;
            fillPattern(&src.bytes, 1);
            @memset(&dst.bytes, 0);
            copyBytes(&dst, &src);
            try std.testing.expectEqualSlices(u8, &src.bytes, &dst.bytes);

            fillPattern(&src.bytes, 2);
            dst = returnBytes(&src);
            try std.testing.expectEqualSlices(u8, &src.bytes, &dst.bytes);

            fillPattern(&src.bytes, 3);
            @memset(&dst.bytes, 0);
            copyArray(&dst.bytes, &src.bytes);
            try std.testing.expectEqualSlices(u8, &src.bytes, &dst.bytes);

            var words_src: Words = undefined;
            var words_dst: Words = undefined;
            fillPattern(std.mem.asBytes(&words_src), 4);
            @memset(std.mem.asBytes(&words_dst), 0);
            copyWords(&words_dst, &words_src);
            try std.testing.expectEqualSlices(u64, &words_src.words, &words_dst.words);
            try std.testing.expectEqualSlices(u8, &words_src.tail, &words_dst.tail);

            var mis_src: Misaligned = undefined;
            var mis_dst: Misaligned = undefined;
            fillPattern(std.mem.asBytes(&mis_src), 5);
            @memset(std.mem.asBytes(&mis_dst), 0xee);
            copyMisaligned(&mis_dst.value, &mis_src.value);
            const mis_src_words = mis_src.value.words;
            const mis_dst_words = mis_dst.value.words;
            try std.testing.expectEqualSlices(u64, &mis_src_words, &mis_dst_words);
            try std.testing.expectEqualSlices(u8, &mis_src.value.tail, &mis_dst.value.tail);
            try expect(mis_dst.pad == 0xee);
            try expect(mis_dst.after == 0xee);

            var union_src: Union = .{ .bytes = undefined };
            var union_dst: Union = .{ .bytes = undefined };
            fillPattern(&union_src.bytes, 6);
            @memset(&union_dst.bytes, 0);
            copyUnion(&union_dst, &union_src);
            try std.testing.expectEqualSlices(u8, &union_src.bytes, &union_dst.bytes);

            // Neighbouring bytes are left alone.
            var buf: [n + 32]u8 = undefined;
            @memset(&buf, 0xcc);
            fillPattern(&src.bytes, 7);
            copyArray(buf[16..][0..n], &src.bytes);
            try std.testing.expectEqualSlices(u8, &src.bytes, buf[16..][0..n]);
            for (buf[0..16]) |byte| try expect(byte == 0xcc);
            for (buf[16 + n ..]) |byte| try expect(byte == 0xcc);
        }
    };
}

test "fixed-size copies around inline-copy boundaries" {
    if (builtin.zig_backend == .stage2_arm) return error.SkipZigTest;
    if (builtin.zig_backend == .stage2_sparc64) return error.SkipZigTest;
    if (builtin.zig_backend == .stage2_spirv) return error.SkipZigTest;

    inline for (fixed_copy_sizes) |n| try FixedCopy(n).check();
}

fn PayloadCopy(comptime n: usize) type {
    return struct {
        const Tagged = union(enum(u64)) { bytes: [n]u8, word: u32 };
        const Bare = union { bytes: [n]u8, word: u32 };

        noinline fn initTagged(bytes: [n]u8) Tagged {
            return .{ .bytes = bytes };
        }
        noinline fn initBare(bytes: [n]u8) Bare {
            return .{ .bytes = bytes };
        }
        noinline fn payloadTagged(u: Tagged) [n]u8 {
            return u.bytes;
        }
        noinline fn payloadBare(u: Bare) [n]u8 {
            return u.bytes;
        }
        noinline fn bitCastWords(bytes: [n]u8) [n / 4]u32 {
            return @bitCast(bytes);
        }
        noinline fn bitCastBytes(words: [n / 4]u32) [n]u8 {
            return @bitCast(words);
        }

        fn check() !void {
            var bytes: [n]u8 = undefined;
            fillPattern(&bytes, 11);
            const tagged = initTagged(bytes);
            try expect(tagged == .bytes);
            try std.testing.expectEqualSlices(u8, &bytes, &tagged.bytes);
            try std.testing.expectEqualSlices(u8, &bytes, &payloadTagged(tagged));
            const bare = initBare(bytes);
            try std.testing.expectEqualSlices(u8, &bytes, &bare.bytes);
            try std.testing.expectEqualSlices(u8, &bytes, &payloadBare(bare));
            if (n % 4 == 0) {
                const words = bitCastWords(bytes);
                for (words, 0..) |word, i| try expect(word == std.mem.readInt(u32, bytes[4 * i ..][0..4], builtin.cpu.arch.endian()));
                try std.testing.expectEqualSlices(u8, &bytes, &bitCastBytes(words));
            }
        }
    };
}

test "fixed-size union payload copies and bitcasts" {
    if (builtin.zig_backend == .stage2_arm) return error.SkipZigTest;
    if (builtin.zig_backend == .stage2_sparc64) return error.SkipZigTest;
    if (builtin.zig_backend == .stage2_spirv) return error.SkipZigTest;

    inline for (.{ 3, 4, 8, 12, 16, 17, 24, 31, 32, 33, 48, 64, 100, 127, 128, 129, 256 }) |n| try PayloadCopy(n).check();
}

fn LoadStoreCopy(comptime n: usize) type {
    return struct {
        const S = extern struct { bytes: [n]u8 };
        const Pair = extern struct { a: S, b: S };

        noinline fn swap(a: *S, b: *S) void {
            const tmp = a.*;
            a.* = b.*;
            b.* = tmp;
        }
        noinline fn self(p: *S) void {
            p.* = p.*;
        }
        noinline fn fields(pair: *Pair) void {
            pair.b = pair.a;
        }
        noinline fn rotate(items: *[3]S) void {
            const first = items[0];
            items[0] = items[1];
            items[1] = items[2];
            items[2] = first;
        }

        fn check() !void {
            var a: S = undefined;
            var b: S = undefined;
            fillPattern(&a.bytes, 21);
            fillPattern(&b.bytes, 22);
            const a0 = a;
            const b0 = b;
            swap(&a, &b);
            try std.testing.expectEqualSlices(u8, &b0.bytes, &a.bytes);
            try std.testing.expectEqualSlices(u8, &a0.bytes, &b.bytes);
            self(&a);
            try std.testing.expectEqualSlices(u8, &b0.bytes, &a.bytes);
            var pair: Pair = undefined;
            fillPattern(&pair.a.bytes, 23);
            fillPattern(&pair.b.bytes, 24);
            fields(&pair);
            try std.testing.expectEqualSlices(u8, &pair.a.bytes, &pair.b.bytes);
            var items: [3]S = undefined;
            for (&items, 0..) |*item, i| fillPattern(&item.bytes, @intCast(30 + i));
            const before = items;
            rotate(&items);
            try std.testing.expectEqualSlices(u8, &before[1].bytes, &items[0].bytes);
            try std.testing.expectEqualSlices(u8, &before[2].bytes, &items[1].bytes);
            try std.testing.expectEqualSlices(u8, &before[0].bytes, &items[2].bytes);
        }
    };
}

test "fixed-size load and store copies" {
    if (builtin.zig_backend == .stage2_arm) return error.SkipZigTest;
    if (builtin.zig_backend == .stage2_sparc64) return error.SkipZigTest;
    if (builtin.zig_backend == .stage2_spirv) return error.SkipZigTest;

    inline for (.{ 17, 24, 32, 33, 64, 100, 128, 129, 256, 257 }) |n| try LoadStoreCopy(n).check();
}

fn PressureCopy(comptime n: usize) type {
    return struct {
        const Bytes = extern struct { bytes: [n]u8 };

        noinline fn copy(dst: *Bytes, src: *const Bytes, x: f64, y: u64) !void {
            // Keep many integer and floating-point values live across the copy.
            var floats: [24]f64 = undefined;
            var ints: [20]u64 = undefined;
            inline for (&floats, 0..) |*f, i| f.* = x * @as(f64, @floatFromInt(i + 1));
            inline for (&ints, 0..) |*int, i| int.* = y *% (i + 3);
            const fl0 = floats[0];
            const fl1 = floats[1];
            const fl2 = floats[2];
            const fl3 = floats[3];
            const fl4 = floats[4];
            const fl5 = floats[5];
            const fl6 = floats[6];
            const fl7 = floats[7];
            const fl8 = floats[8];
            const fl9 = floats[9];
            const fl10 = floats[10];
            const fl11 = floats[11];
            const fl12 = floats[12];
            const fl13 = floats[13];
            const fl14 = floats[14];
            const fl15 = floats[15];
            const fl16 = floats[16];
            const fl17 = floats[17];
            const fl18 = floats[18];
            const fl19 = floats[19];
            const fl20 = floats[20];
            const fl21 = floats[21];
            const fl22 = floats[22];
            const fl23 = floats[23];
            const int0 = ints[0];
            const int1 = ints[1];
            const int2 = ints[2];
            const int3 = ints[3];
            const int4 = ints[4];
            const int5 = ints[5];
            const int6 = ints[6];
            const int7 = ints[7];
            const int8 = ints[8];
            const int9 = ints[9];
            const int10 = ints[10];
            const int11 = ints[11];
            const int12 = ints[12];
            const int13 = ints[13];
            const int14 = ints[14];
            const int15 = ints[15];
            const int16 = ints[16];
            const int17 = ints[17];
            const int18 = ints[18];
            const int19 = ints[19];

            dst.* = src.*;

            const float_sum = fl0 + fl1 + fl2 + fl3 + fl4 + fl5 + fl6 + fl7 + fl8 + fl9 + fl10 + fl11 +
                fl12 + fl13 + fl14 + fl15 + fl16 + fl17 + fl18 + fl19 + fl20 + fl21 + fl22 + fl23;
            const int_sum = int0 +% int1 +% int2 +% int3 +% int4 +% int5 +% int6 +% int7 +%
                int8 +% int9 +% int10 +% int11 +% int12 +% int13 +% int14 +% int15 +% int16 +%
                int17 +% int18 +% int19;
            try expect(float_sum == x * 300);
            try expect(int_sum == y *% 250);
        }

        fn check() !void {
            var src: Bytes = undefined;
            var dst: Bytes = undefined;
            fillPattern(&src.bytes, 9);
            @memset(&dst.bytes, 0);
            try copy(&dst, &src, 0.5, 7);
            try std.testing.expectEqualSlices(u8, &src.bytes, &dst.bytes);
        }
    };
}

test "fixed-size copies under register pressure" {
    if (builtin.zig_backend == .stage2_arm) return error.SkipZigTest;
    if (builtin.zig_backend == .stage2_sparc64) return error.SkipZigTest;
    if (builtin.zig_backend == .stage2_spirv) return error.SkipZigTest;

    inline for (.{ 17, 33, 64, 127, 128, 256 }) |n| try PressureCopy(n).check();
}

test "fixed-size copy of an indirect parameter while other parameters are live" {
    if (builtin.zig_backend == .stage2_arm) return error.SkipZigTest;
    if (builtin.zig_backend == .stage2_sparc64) return error.SkipZigTest;
    if (builtin.zig_backend == .stage2_spirv) return error.SkipZigTest;

    const Alignment = enum { left, center, right };
    const Options = struct { precision: ?usize = null, width: ?usize = null, alignment: Alignment = .right, fill: u8 = ' ' };
    const Sink = struct {
        n: usize,
        noinline fn inner(sink: *@This(), buf: []const u8, width: usize, alignment: Alignment, fill: u8) error{Width}!void {
            if (width == 99) return error.Width;
            sink.n = buf.len + width + @intFromEnum(alignment) + fill;
        }
        noinline fn outer(sink: *@This(), buf: []const u8, options: Options) error{Width}!void {
            return sink.inner(buf, options.width orelse buf.len, options.alignment, options.fill);
        }
    };
    var sink: Sink = .{ .n = 0 };
    try sink.outer("ab", .{ .alignment = .center, .fill = 3 });
    try expect(sink.n == 2 + 2 + 1 + 3);
    try sink.outer("abc", .{ .width = 10, .fill = 4 });
    try expect(sink.n == 3 + 10 + 2 + 4);
}
