const builtin = @import("builtin");
const std = @import("std");
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

// Aggregates returned through a result pointer, loaded through pointers and
// stored to locals. The self-hosted backends keep such values in memory, load
// only the parts that are read, and may define a value directly in the local it
// is stored to, so these check every way of using one still sees the right
// bytes, including when the destination is read or overlaps the source.

fn gen(comptime T: type, seed: u32) T {
    switch (@typeInfo(T)) {
        .int => |info| {
            const wide: u64 = @as(u64, seed) *% 0x9e3779b97f4a7c15 +% seed;
            return @bitCast(@as(@Int(.unsigned, info.bits), @truncate(wide)));
        },
        .bool => return seed % 3 == 1,
        .@"enum" => return std.meta.tags(T)[seed % std.meta.tags(T).len],
        .array => |info| {
            var r: T = undefined;
            for (&r, 0..) |*e, i| e.* = gen(info.child, seed +% @as(u32, @intCast(i)) *% 7);
            return r;
        },
        .@"struct" => {
            var r: T = undefined;
            inline for (comptime std.meta.fieldNames(T), comptime std.meta.fieldTypes(T), 0..) |name, F, i|
                @field(r, name) = gen(F, seed +% @as(u32, (i + 1) * 13));
            return r;
        },
        .optional => |info| return if (seed % 4 == 0) null else gen(info.child, seed),
        else => @compileError("gen " ++ @typeName(T)),
    }
}

fn Bytes(comptime n: usize) type {
    return struct { b: [n]u8 };
}

const Kind = enum(u8) { a, b, c, d, e };

const Odd = struct { a: u8, b: u64, c: u16, d: [3]u8, e: u32, f: bool, g: Kind };

/// 8-byte fields at 4-aligned offsets, like a frame record of u32 keys.
const Ext = extern struct { a: u32, b: u64 align(4), c: u64 align(4), d: u32, e: u8, f: u8, g: u16 };

const Packed = packed struct(u256) { a: u7, b: u64, c: u100, d: bool, e: u84 };

const Nested = struct { head: Odd, mid: ?Ext, tail: [5]u16, flag: bool };

const Frame = struct { key: struct { root: u32, kind: Kind }, cursor: u32, nominal: bool, steps: struct { start: u32, len: u32 }, ground: bool, map: ?u64 };

fn Suite(comptime T: type) type {
    return struct {
        noinline fn make(seed: u32) T {
            return gen(T, seed);
        }

        noinline fn makeOpt(seed: u32) ?T {
            return if (seed == 0) null else gen(T, seed);
        }

        noinline fn makeErr(seed: u32) anyerror!T {
            if (seed == 0) return error.Zero;
            return gen(T, seed);
        }

        noinline fn pass(t: T) T {
            return t;
        }

        noinline fn again(seed: u32) T {
            return pass(make(seed));
        }

        noinline fn identity(p: *T) *T {
            return p;
        }

        noinline fn copyThrough(dst: *T, src: *const T) void {
            dst.* = src.*;
        }

        noinline fn clobber() void {
            var x: [64]u64 = undefined;
            for (&x, 0..) |*e, i| e.* = i *% 0x9e3779b97f4a7c15;
            std.mem.doNotOptimizeAway(&x);
        }

        fn expectFields(want: T, got: T) !void {
            switch (@typeInfo(T)) {
                .@"struct" => inline for (comptime std.meta.fieldNames(T)) |name|
                    try expectEqual(@field(want, name), @field(got, name)),
                else => try expectEqual(want, got),
            }
        }

        fn run() !void {
            const want = gen(T, 7);

            // An sret result read field by field, then copied.
            const a = make(7);
            try expectFields(want, a);
            const a2 = a;
            clobber();
            try expectFields(want, a2);

            // Stored to a local that is then overwritten: copies keep their value.
            var v = make(7);
            const snap = v;
            v = make(8);
            try expectFields(want, snap);
            try expectFields(gen(T, 8), v);
            v = snap;
            try expectFields(want, v);

            // Passed on and returned again.
            try expectFields(want, pass(make(7)));
            try expectFields(want, again(7));

            // Optionals and error unions of it.
            const o = makeOpt(7).?;
            try expectFields(want, o);
            try expect(makeOpt(0) == null);
            const e = try makeErr(7);
            try expectFields(want, e);
            try std.testing.expectError(error.Zero, makeErr(0));
            var n: u32 = 3;
            var last: T = undefined;
            while (makeOpt(n)) |x| : (n -= 1) last = x;
            try expectFields(gen(T, 1), last);

            // A block result stored to a local that one branch reads first.
            var w = make(9);
            var flip = false;
            for (0..4) |_| {
                w = if (flip) make(7) else blk: {
                    const old = w;
                    clobber();
                    break :blk pass(old);
                };
                flip = !flip;
            }
            try expectFields(want, w);

            // Copies through pointers, onto itself and between array elements.
            var arr: [3]T = .{ make(1), make(2), make(3) };
            arr[0] = arr[1];
            arr[1] = arr[2];
            arr[2] = arr[0];
            try expectFields(gen(T, 2), arr[0]);
            try expectFields(gen(T, 3), arr[1]);
            try expectFields(gen(T, 2), arr[2]);
            const self = &arr[1];
            copyThrough(self, self);
            arr[1] = self.*;
            try expectFields(gen(T, 3), arr[1]);
            var out: T = undefined;
            copyThrough(&out, &arr[2]);
            try expectFields(gen(T, 2), out);

            // A loaded copy read after the memory it came from changed.
            var src = make(7);
            const ptr = identity(&src);
            const loaded = ptr.*;
            src = make(11);
            try expectFields(want, loaded);
            try expectFields(gen(T, 11), src);
        }
    };
}

test "sret results, copies and stores of many sizes" {
    // Around the register sizes, the inline copy chunks and the inline move
    // and copy limits.
    inline for (.{ 1, 3, 7, 8, 9, 15, 16, 17, 31, 32, 33, 64, 127, 128, 129, 255, 256, 257 }) |n|
        try Suite(Bytes(n)).run();
}

test "sret results, copies and stores of odd layouts" {
    try Suite(Odd).run();
    try Suite(Ext).run();
    try Suite(Packed).run();
    try Suite(Nested).run();
    try Suite(Frame).run();
    try Suite([3]Odd).run();
    try Suite(?Odd).run();
    try Suite(u256).run();
    try Suite(u200).run();
    try Suite(struct { a: u8, b: [33]u8 align(1) }).run();
    try Suite(struct { a: u128, b: u8 }).run();
}

const U = union(enum) { small: u8, big: [40]u8, odd: Odd, ext: Ext };
const EU = extern union { bytes: [36]u8, ext: Ext, words: [9]u32 };

noinline fn makeU(seed: u32) U {
    return switch (seed % 4) {
        0 => .{ .small = @truncate(seed) },
        1 => .{ .big = gen([40]u8, seed) },
        2 => .{ .odd = gen(Odd, seed) },
        else => .{ .ext = gen(Ext, seed) },
    };
}

noinline fn makeEU(seed: u32) EU {
    return .{ .words = gen([9]u32, seed) };
}

noinline fn makeOptU(seed: u32) ?U {
    return if (seed == 0) null else makeU(seed);
}

noinline fn passU(u: U) U {
    return u;
}

test "sret unions, copied, stored and read" {
    for (0..8) |i| {
        const seed: u32 = @intCast(i + 1);
        const want = makeU(seed);
        const a = makeU(seed);
        try expectEqual(want, a);
        var v = makeU(seed);
        const snap = v;
        v = makeU(seed + 1);
        try expectEqual(want, snap);
        try expectEqual(makeU(seed + 1), v);
        try expectEqual(want, passU(makeOptU(seed).?));
        switch (makeU(seed)) {
            .small => |s| try expectEqual(want.small, s),
            .big => |b| try expectEqual(want.big, b),
            .odd => |o| try expectEqual(want.odd.b, o.b),
            .ext => |x| try expectEqual(want.ext.c, x.c),
        }
        const e = makeEU(seed);
        var ev = e;
        ev.words[8] +%= 1;
        try expectEqual(gen([9]u32, seed), e.words);
        try expectEqual(gen([9]u32, seed)[8] +% 1, ev.words[8]);
    }
}

const Pair = struct { x: Odd, y: Odd };

noinline fn makePair(seed: u32) Pair {
    return .{ .x = gen(Odd, seed), .y = gen(Odd, seed + 1) };
}

test "aggregates defined from the local they are stored to" {
    var p = makePair(5);
    // Each field of the new value is read from the other field of the old one.
    const swapped: Pair = .{ .x = p.y, .y = p.x };
    p = swapped;
    try expectEqual(gen(Odd, 6), p.x);
    try expectEqual(gen(Odd, 5), p.y);
    p = .{ .x = p.x, .y = p.x };
    try expectEqual(gen(Odd, 6), p.y);

    var f: Frame = gen(Frame, 3);
    const next: Frame = .{ .key = f.key, .cursor = f.cursor + 1, .nominal = !f.nominal, .steps = .{ .start = f.steps.len, .len = f.steps.start }, .ground = f.ground, .map = f.map };
    f = next;
    const g = gen(Frame, 3);
    try expectEqual(g.cursor + 1, f.cursor);
    try expectEqual(g.steps.len, f.steps.start);
    try expectEqual(g.steps.start, f.steps.len);
    try expectEqual(!g.nominal, f.nominal);

    var big: Bytes(100) = gen(Bytes(100), 1);
    var opt: ?Bytes(100) = big;
    big = opt.?;
    opt = null;
    big.b[99] +%= 1;
    try expectEqual(gen(Bytes(100), 1).b[99] +% 1, big.b[99]);
    opt = big;
    big = gen(Bytes(100), 2);
    try expectEqual(gen(Bytes(100), 1).b[0], opt.?.b[0]);
}

noinline fn mulDiv(a: u200, b: u200, c: u200) u200 {
    return a *% b / c;
}

noinline fn readBig(p: *const u200) u200 {
    return p.*;
}

test "large integer results kept in memory" {
    var a: u200 = (1 << 199) | 12345;
    const b: u200 = 0xfedcba9876543210;
    const r = mulDiv(a, b, 7);
    const r2 = r;
    a = r2 +% 1;
    try expectEqual(r +% 1, readBig(&a));
    try expectEqual(r, mulDiv((1 << 199) | 12345, 0xfedcba9876543210, 7));
    var arr: [3]u200 = .{ r, r2 >> 3, r ^ (1 << 198) };
    const x = arr[1];
    arr[1] = arr[2];
    try expectEqual(r >> 3, x);
    try expectEqual(r ^ (1 << 198), arr[1]);
    try expect(arr[0] == r and arr[0] != arr[1]);
}

const Flat = union(enum) { func: u32, app: struct { head: u32, args: u64 align(4) }, rec: [3]u32, unit };
const Content = union(enum) { flex: struct { name: u32, kind: Kind, eq: bool }, structure: Flat, alias: struct { actual: u32, args: u64 align(4) }, err };

noinline fn contentAt(contents: []const Content, i: usize) Content {
    return contents[i];
}

noinline fn describe(contents: []Content, i: usize) u64 {
    const c = contents[i];
    contents[i] = .err;
    return switch (c) {
        .flex => |f| f.name + @intFromEnum(f.kind) + @intFromBool(f.eq),
        .structure => |flat| switch (flat) {
            .func => |r| r,
            .app => |a| a.head + a.args,
            .rec => |r| r[0] + r[1] + r[2],
            .unit => 7,
        },
        .alias => |a| a.actual * a.args,
        .err => 0,
    };
}

test "union payloads read from the union's memory" {
    var contents = [_]Content{
        .{ .flex = .{ .name = 10, .kind = .c, .eq = true } },
        .{ .structure = .{ .func = 20 } },
        .{ .structure = .{ .app = .{ .head = 3, .args = 1 << 40 } } },
        .{ .structure = .{ .rec = .{ 1, 2, 3 } } },
        .{ .structure = .unit },
        .{ .alias = .{ .actual = 5, .args = 6 } },
        .err,
    };
    const expected = [_]u64{ 10 + 2 + 1, 20, 3 + (1 << 40), 6, 7, 30, 0 };
    for (expected, 0..) |e, i| {
        const c = contentAt(&contents, i);
        try expectEqual(e, describe(&contents, i));
        try expect(contents[i] == .err);
        contents[i] = c;
        try expectEqual(e, describe(&contents, i));
    }
}
