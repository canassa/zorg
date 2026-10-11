//! Fills and copies of aggregates across many struct layouts, checking every
//! element. A backend that copies an aggregate part by part can get one
//! layout right and another wrong, or the first element of a slice right and
//! the rest wrong; the layouts here are generated at comptime from a fixed
//! seed: fields of 1 to 16 bytes, odd sizes, padding gaps, optionals.

const std = @import("std");
const builtin = @import("builtin");
const expect = std.testing.expect;

const LayoutBools3 = extern struct { bool0: bool, bool1: bool, bool2: bool };
const LayoutHue = enum(u8) { hue_low = 3, hue_mid = 7, hue_high = 250 };

/// Field types an extern struct can hold.
const extern_fields = [_]type{
    u8, u16, u32, u64, u128, bool, f32, f64, [3]u8, [5]u8, [6]u8, [7]u8, [2]u32, LayoutBools3, LayoutHue,
};
/// Plus types only an auto-layout struct can hold.
const auto_fields = extern_fields ++ [_]type{ ?u8, ?u32, ?u64, ?LayoutBools3, ?[5]u8 };

/// A layout: field types and, for extern structs, which fields start a new
/// 8-byte word (a padding gap before them).
fn Layout(comptime layout: std.lang.Type.ContainerLayout, comptime types: []const type, comptime gaps: []const bool) type {
    var names: [types.len][]const u8 = undefined;
    var attrs: [types.len]std.lang.Type.Struct.FieldAttributes = undefined;
    for (&names, &attrs, 0..) |*name, *attr, i| {
        name.* = std.fmt.comptimePrint("f{d}", .{i});
        attr.* = .{ .@"align" = if (gaps[i]) @max(8, @alignOf(types[i])) else null };
    }
    return @Struct(layout, null, &names, types[0..types.len], &attrs);
}

const Lcg = struct {
    state: u64,
    fn next(lcg: *Lcg, bound: usize) usize {
        lcg.state = lcg.state *% 6364136223846793005 +% 1442695040888963407;
        return @intCast((lcg.state >> 33) % bound);
    }
};

/// Hand-picked layouts, then generated ones.
const layouts = layouts: {
    @setEvalBranchQuota(100_000);
    var list: []const type = &.{
        // A 3-byte field and, a word later, a 1-byte one.
        Layout(.@"extern", &.{ u64, u64, LayoutBools3, u8, u64 }, &.{ false, false, false, true, false }),
        // An optional aggregate between slices' worth of words, as in a
        // compiler's per-module slot.
        Layout(.auto, &.{ u64, u64, u64, u64, ?LayoutBools3, ?u32, bool, bool, u64 }, &.{ false, false, false, false, false, false, false, false, false }),
        Layout(.@"extern", &.{ [7]u8, u8 }, &.{ false, true }),
        Layout(.@"extern", &.{ u8, u128, [3]u8 }, &.{ false, false, false }),
    };
    var lcg: Lcg = .{ .state = 0x5eed_1a40 };
    for (0..28) |n| {
        const is_extern = n % 2 == 0;
        const pool: []const type = if (is_extern) &extern_fields else &auto_fields;
        const len = 1 + lcg.next(8);
        var types: [len]type = undefined;
        var gaps: [len]bool = undefined;
        for (&types, &gaps) |*t, *g| {
            t.* = pool[lcg.next(pool.len)];
            g.* = is_extern and lcg.next(4) == 0;
        }
        const final_types = types;
        const final_gaps = gaps;
        list = list ++ [_]type{Layout(if (is_extern) .@"extern" else .auto, &final_types, &final_gaps)};
    }
    break :layouts list;
};

/// A value of `T` that depends on `seed` in every field, and differs between
/// fields.
inline fn make(comptime T: type, seed: u64) T {
    switch (@typeInfo(T)) {
        .int => return @truncate(@as(u128, seed *% 0x9e3779b97f4a7c15) << 64 | (seed ^ 0xa5a5_5a5a_0f0f_f0f1)),
        .bool => return seed & 4 != 0,
        .float => return @floatFromInt(@as(u16, @truncate(seed))),
        .@"enum" => return switch (seed % 3) {
            0 => .hue_low,
            1 => .hue_mid,
            else => .hue_high,
        },
        .array => |array| {
            var result: T = undefined;
            inline for (&result, 0..) |*element, i| element.* = make(array.child, seed +% (i + 1) *% 0x1000193);
            return result;
        },
        .optional => |optional| return if (seed % 5 == 0) null else make(optional.child, seed >> 1),
        .@"struct" => |info| {
            var result: T = undefined;
            inline for (info.field_names, info.field_types, 0..) |name, Field, i| {
                @field(result, name) = make(Field, seed *% (2 * i + 3) +% i);
            }
            return result;
        },
        else => @compileError("unsupported field type " ++ @typeName(T)),
    }
}

fn eql(comptime T: type, a: T, b: T) bool {
    switch (@typeInfo(T)) {
        .int, .bool, .float, .@"enum" => return a == b,
        .array => {
            for (a, b) |x, y| if (!eql(@TypeOf(x), x, y)) return false;
            return true;
        },
        .optional => |optional| {
            if (a == null or b == null) return a == null and b == null;
            return eql(optional.child, a.?, b.?);
        },
        .@"struct" => |info| {
            inline for (info.field_names, info.field_types) |name, Field| {
                if (!eql(Field, @field(a, name), @field(b, name))) return false;
            }
            return true;
        },
        else => @compileError("unsupported field type " ++ @typeName(T)),
    }
}

fn Ops(comptime T: type) type {
    return struct {
        /// The fill is built here, so its parts can be in registers.
        noinline fn memsetMade(slice: []T, seed: u64) void {
            @memset(slice, make(T, seed));
        }
        noinline fn memsetValue(slice: []T, value: T) void {
            @memset(slice, value);
        }
        noinline fn memsetArray(array: *[7]T, seed: u64) void {
            @memset(array, make(T, seed));
        }
        noinline fn memsetOptional(slice: []?T, value: ?T) void {
            @memset(slice, value);
        }
        noinline fn splat(seed: u64) [7]T {
            return @splat(make(T, seed));
        }
        noinline fn memcpy(dst: []T, src: []const T) void {
            @memcpy(dst, src);
        }
        noinline fn copyEach(dst: []T, src: []const T) void {
            for (dst, src) |*d, s| d.* = s;
        }
        noinline fn identity(value: T) T {
            return value;
        }
        noinline fn swap(pair: *[2]T) void {
            const first = pair[0];
            pair[0] = pair[1];
            pair[1] = first;
        }
    };
}

/// Every wrong result is reported, so one run names all the failing layouts.
var failures: usize = 0;

fn check(comptime T: type, comptime index: usize, op: []const u8, ok: bool) !void {
    if (!ok) {
        std.debug.print("layout {d} ({d} bytes), {s}: wrong element\n", .{ index, @sizeOf(T), op });
        failures += 1;
    }
}

fn checkLayout(comptime T: type, comptime index: usize, seed: u64) !void {
    const O = Ops(T);
    const value = make(T, seed);
    const other = make(T, seed +% 0x51);
    var storage: [7]T = undefined;
    var count: usize = undefined;
    const runtime_count: *volatile usize = &count;

    for ([_]usize{ 0, 1, 2, 7 }) |len| {
        runtime_count.* = len;
        @memset(std.mem.asBytes(&storage), 0xaa);
        O.memsetMade(storage[0..runtime_count.*], seed);
        for (storage[0..len]) |e| try check(T, index, "@memset of a fill built in place", eql(T, e, value));

        @memset(std.mem.asBytes(&storage), 0xaa);
        O.memsetValue(storage[0..runtime_count.*], other);
        for (storage[0..len]) |e| try check(T, index, "@memset of a fill passed in", eql(T, e, other));

        var optionals: [7]?T = undefined;
        @memset(std.mem.asBytes(&optionals), 0xaa);
        O.memsetOptional(optionals[0..runtime_count.*], value);
        for (optionals[0..len]) |e| try check(T, index, "@memset of an optional", e != null and eql(T, e.?, value));
        O.memsetOptional(optionals[0..runtime_count.*], null);
        for (optionals[0..len]) |e| try check(T, index, "@memset of an optional to null", e == null);

        var source: [7]T = undefined;
        for (&source, 0..) |*s, i| s.* = make(T, seed +% i *% 0x77);
        @memset(std.mem.asBytes(&storage), 0xaa);
        O.memcpy(storage[0..runtime_count.*], source[0..runtime_count.*]);
        for (storage[0..len], source[0..len]) |e, s| try check(T, index, "@memcpy", eql(T, e, s));

        @memset(std.mem.asBytes(&storage), 0xaa);
        O.copyEach(storage[0..runtime_count.*], source[0..runtime_count.*]);
        for (storage[0..len], source[0..len]) |e, s| try check(T, index, "element copy loop", eql(T, e, s));
    }

    @memset(std.mem.asBytes(&storage), 0xaa);
    O.memsetArray(&storage, seed);
    for (storage) |e| try check(T, index, "@memset of an array", eql(T, e, value));

    const splatted = O.splat(seed);
    for (splatted) |e| try check(T, index, "@splat", eql(T, e, value));

    try check(T, index, "pass and return by value", eql(T, O.identity(value), value));

    var pair: [2]T = .{ value, other };
    O.swap(&pair);
    try check(T, index, "swap", eql(T, pair[0], other) and eql(T, pair[1], value));
}

test "aggregate fills and copies across struct layouts" {
    if (builtin.zig_backend == .stage2_spirv) return error.SkipZigTest;
    if (builtin.zig_backend == .stage2_arm) return error.SkipZigTest; // TODO
    if (builtin.zig_backend == .stage2_sparc64) return error.SkipZigTest; // TODO

    var seed: u64 = 0x1234_5678_9abc_def1;
    const runtime_seed: *volatile u64 = &seed;
    failures = 0;
    inline for (layouts, 0..) |T, index| try checkLayout(T, index, runtime_seed.*);
    try expect(failures == 0);
}
