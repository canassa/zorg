const builtin = @import("builtin");
const std = @import("std");
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

// Arrays indexed by integers narrower than their length allows, as a radix
// sort's u8 digits index 256 counters. Sema drops a bounds check that the
// index type proves, so these check that every index still reaches the right
// element, and that checks the type does not prove still happen.

noinline fn histogram(keys: []const u64, shift: u6, counts: *[256]u32) void {
    for (keys) |k| counts[@as(u8, @truncate(k >> shift))] += 1;
}

noinline fn scatter(keys: []const u64, shift: u6, counts: *[256]u32, out: []u64) void {
    for (keys) |k| {
        const b: u8 = @truncate(k >> shift);
        out[counts[b]] = k;
        counts[b] += 1;
    }
}

noinline fn wideTable(i: u8, table: *const [300]u16) u16 {
    return table[i];
}

noinline fn nibble(i: u4, table: [16]u8) u8 {
    return table[i];
}

noinline fn halfTable(i: u8, table: []const u8) u8 {
    return table[i];
}

noinline fn compareProven(i: u8) u32 {
    const wide: usize = i;
    return if (wide < 256) 1 else unreachable;
}

noinline fn compareUnproven(i: u16) u32 {
    const wide: usize = i;
    return if (wide < 256) 1 else 2;
}

test "u8 indexes into 256 or more elements" {
    var keys: [600]u64 = undefined;
    for (&keys, 0..) |*k, i| k.* = (i *% 0x9e3779b97f4a7c15) ^ (i << 8);
    var counts: [256]u32 = @splat(0);
    histogram(&keys, 8, &counts);
    var total: u32 = 0;
    for (counts) |c| total += c;
    try expectEqual(@as(u32, keys.len), total);
    var expected: [256]u32 = @splat(0);
    for (keys) |k| expected[@as(u8, @truncate(k >> 8))] += 1;
    try expectEqual(expected, counts);

    var offsets: [256]u32 = undefined;
    var sum: u32 = 0;
    for (counts, 0..) |c, i| {
        offsets[i] = sum;
        sum += c;
    }
    var out: [600]u64 = undefined;
    scatter(&keys, 8, &offsets, &out);
    for (out[0 .. out.len - 1], out[1..]) |a, b| try expect(@as(u8, @truncate(a >> 8)) <= @as(u8, @truncate(b >> 8)));

    var table: [300]u16 = undefined;
    for (&table, 0..) |*t, i| t.* = @intCast(i * 3);
    for (0..256) |i| try expectEqual(@as(u16, @intCast(i * 3)), wideTable(@intCast(i), &table));
    var nibbles: [16]u8 = undefined;
    for (&nibbles, 0..) |*n, i| n.* = @intCast(100 + i);
    for (0..16) |i| try expectEqual(@as(u8, @intCast(100 + i)), nibble(@intCast(i), nibbles));
    var bytes: [200]u8 = undefined;
    for (&bytes, 0..) |*b, i| b.* = @truncate(i ^ 0x5a);
    for (0..200) |i| try expectEqual(@as(u8, @truncate(i ^ 0x5a)), halfTable(@intCast(i), &bytes));
    try expectEqual(@as(u32, 1), compareProven(255));
    try expectEqual(@as(u32, 1), compareUnproven(255));
    try expectEqual(@as(u32, 2), compareUnproven(256));
}
