//! Small, ordinary (non-`inline`) callees called from many contexts.
//!
//! A backend or AIR pass that automatically inlines small functions copies the
//! callee's body into the caller. Every test here must give the same result
//! whether or not that happens, so these tests pin down the cases a body copy
//! can get wrong: argument remapping, return paths, result locations, defer,
//! error handling, callee locals, recursion, function identity and safety.

const std = @import("std");
const builtin = @import("builtin");
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualSlices = std.testing.expectEqualSlices;
const expectError = std.testing.expectError;

/// Hides a value from comptime evaluation at the call site.
fn rt(comptime T: type, v: T) T {
    var x = v;
    _ = &x;
    return x;
}

/// Backends that do not support every type used by a test (wide integers,
/// f16/f128, vectors, bit pointers) yet. Unrelated to inlining.
fn skipLimitedBackends() !void {
    switch (builtin.zig_backend) {
        .stage2_arm, .stage2_sparc64, .stage2_riscv64, .stage2_spirv => return error.SkipZigTest,
        else => {},
    }
}

// Arguments

fn sub(a: u32, b: u32) u32 {
    return a - b;
}

fn mix(a: u32, b: u32) u32 {
    return a *% 3 +% b;
}

test "same argument passed twice" {
    const x = rt(u32, 7);
    try expectEqual(@as(u32, 0), sub(x, x));
    try expectEqual(@as(u32, 28), mix(x, x));
}

test "arguments are not swapped" {
    const a = rt(u32, 10);
    const b = rt(u32, 3);
    try expectEqual(@as(u32, 7), sub(a, b));
    try expectEqual(@as(u32, 33), mix(a, b));
    try expectEqual(@as(u32, 19), mix(b, a));
}

fn copyAndBump(a: u32) u32 {
    var local = a;
    local += 1;
    local *= 2;
    return local;
}

test "callee copy of an argument does not write back to the caller" {
    var x = rt(u32, 5);
    try expectEqual(@as(u32, 12), copyAndBump(x));
    try expectEqual(@as(u32, 5), x);
    x = copyAndBump(x);
    try expectEqual(@as(u32, 12), x);
}

fn addInto(a: *u32, b: *u32) void {
    a.* += b.*;
    b.* += a.*;
}

test "two pointer arguments that alias" {
    var x: u32 = rt(u32, 1);
    addInto(&x, &x);
    try expectEqual(@as(u32, 4), x);

    var y: u32 = rt(u32, 1);
    var z: u32 = rt(u32, 10);
    addInto(&y, &z);
    try expectEqual(@as(u32, 11), y);
    try expectEqual(@as(u32, 21), z);
}

fn storeThenReturnByValue(p: *u32, v: u32) u32 {
    p.* = 100;
    return v;
}

test "by-value argument is a snapshot of a local the callee writes through a pointer" {
    var x: u32 = rt(u32, 5);
    try expectEqual(@as(u32, 5), storeThenReturnByValue(&x, x));
    try expectEqual(@as(u32, 100), x);
}

fn readTwiceAroundStore(p: *u32) [2]u32 {
    const before = p.*;
    p.* = before * 10;
    return .{ before, p.* };
}

test "pointer to a caller local is read and written by the callee" {
    var x: u32 = rt(u32, 4);
    const r = readTwiceAroundStore(&x);
    try expectEqual(@as(u32, 4), r[0]);
    try expectEqual(@as(u32, 40), r[1]);
    try expectEqual(@as(u32, 40), x);
}

fn next(counter: *u32) u32 {
    counter.* += 1;
    return counter.*;
}

fn useThreeTimes(a: u32) u32 {
    return a + a * a;
}

test "argument with side effects is evaluated once" {
    var c: u32 = 0;
    try expectEqual(@as(u32, 2), useThreeTimes(next(&c)));
    try expectEqual(@as(u32, 1), c);
    try expectEqual(@as(u32, 6), useThreeTimes(next(&c)));
    try expectEqual(@as(u32, 2), c);
}

fn pair(a: u32, b: u32) [2]u32 {
    return .{ a, b };
}

test "arguments are evaluated left to right" {
    var c: u32 = 0;
    const p = pair(next(&c), next(&c));
    try expectEqual(@as(u32, 1), p[0]);
    try expectEqual(@as(u32, 2), p[1]);
}

test "callee result used as argument of the same callee" {
    const a = rt(u32, 100);
    try expectEqual(@as(u32, 90), sub(sub(a, 4), sub(a, 94)));
    try expectEqual(@as(u32, 3 * (3 * 2 + 1) + (3 * 1 + 2)), mix(mix(2, 1), mix(1, 2)));
}

const Small = struct { a: u8, b: u16, c: u32 };

fn sumSmall(s: Small) u32 {
    return @as(u32, s.a) + s.b + s.c;
}

fn bumpSmallCopy(s: Small) Small {
    var t = s;
    t.a += 1;
    t.b += 1;
    t.c += 1;
    return t;
}

test "struct passed by value" {
    var s: Small = .{ .a = 1, .b = 2, .c = 3 };
    try expectEqual(@as(u32, 6), sumSmall(s));
    const t = bumpSmallCopy(s);
    try expectEqual(@as(u8, 1), s.a);
    try expectEqual(@as(u8, 2), t.a);
    try expectEqual(@as(u32, 9), sumSmall(t));
    s.c = 100;
    try expectEqual(@as(u32, 4), t.c);
}

fn manyArgs(a: u8, b: u16, c: u32, d: u64, e: i8, f: i16, g: i32, h: i64, i: u8, j: u64, k: u32) i64 {
    return @as(i64, a) + b + c + @as(i64, @intCast(d)) + e + f + g + h + i + @as(i64, @intCast(j)) + k;
}

test "more arguments than argument registers" {
    try expectEqual(@as(i64, 1 + 2 + 3 + 4 - 5 - 6 - 7 - 8 + 9 + 10 + 11), manyArgs(
        rt(u8, 1),
        rt(u16, 2),
        rt(u32, 3),
        rt(u64, 4),
        rt(i8, -5),
        rt(i16, -6),
        rt(i32, -7),
        rt(i64, -8),
        rt(u8, 9),
        rt(u64, 10),
        rt(u32, 11),
    ));
}

fn ignoresArgs(a: u32, b: *u32, c: []const u8) u32 {
    _ = a;
    _ = b;
    _ = c;
    return 42;
}

test "unused arguments with side effects are still evaluated" {
    var c: u32 = 0;
    var x: u32 = 0;
    try expectEqual(@as(u32, 42), ignoresArgs(next(&c), &x, "abc"));
    try expectEqual(@as(u32, 1), c);
}

fn zeroBitArgs(a: void, b: u0, c: struct {}, d: u32) u32 {
    _ = a;
    _ = c;
    return @as(u32, b) + d;
}

test "zero-bit arguments" {
    try expectEqual(@as(u32, 9), zeroBitArgs({}, 0, .{}, rt(u32, 9)));
}

// Return paths

fn firstIndexOf(haystack: []const u8, needle: u8) ?usize {
    for (haystack, 0..) |c, i| {
        if (c == needle) return i;
    }
    return null;
}

test "return from inside a for loop" {
    const s: []const u8 = rt([]const u8, "hello");
    try expectEqual(@as(?usize, 2), firstIndexOf(s, 'l'));
    try expectEqual(@as(?usize, 0), firstIndexOf(s, 'h'));
    try expectEqual(@as(?usize, null), firstIndexOf(s, 'z'));
}

fn findInGrid(grid: []const [3]u8, needle: u8) u32 {
    var row: u32 = 0;
    outer: while (row < grid.len) : (row += 1) {
        var col: u32 = 0;
        while (col < 3) : (col += 1) {
            if (grid[row][col] == 0) continue :outer;
            if (grid[row][col] == needle) return row * 10 + col;
        }
    }
    return 999;
}

test "return from inside nested labeled loops" {
    const grid = [_][3]u8{ .{ 1, 2, 3 }, .{ 0, 7, 7 }, .{ 4, 7, 6 } };
    try expectEqual(@as(u32, 21), findInGrid(&grid, rt(u8, 7)));
    try expectEqual(@as(u32, 1), findInGrid(&grid, rt(u8, 2)));
    try expectEqual(@as(u32, 999), findInGrid(&grid, rt(u8, 9)));
}

test "callee with labeled loops called inside a caller loop with the same labels" {
    const grid = [_][3]u8{ .{ 1, 2, 3 }, .{ 4, 5, 6 } };
    var total: u32 = 0;
    outer: for (0..7) |n| {
        var k: u32 = 0;
        while (k < 2) : (k += 1) {
            if (n == 3) continue :outer;
            if (n == 6) break :outer;
            total += findInGrid(&grid, @intCast(n + 1));
        }
    }
    // n = 0,1,2,4,5 each counted twice: needles 1,2,3,5,6 -> 0,1,2,11,12
    try expectEqual(@as(u32, 2 * (0 + 1 + 2 + 11 + 12)), total);
}

const Op = enum { add, sub, mul, neg, nop };

fn apply(op: Op, a: i32, b: i32) i32 {
    switch (op) {
        .add => return a + b,
        .sub => {
            if (a < b) return -1;
            return a - b;
        },
        .mul => {
            const r = a * b;
            return r;
        },
        .neg => return -a,
        .nop => {},
    }
    return a;
}

test "return from inside switch prongs" {
    try expectEqual(@as(i32, 7), apply(rt(Op, .add), 3, 4));
    try expectEqual(@as(i32, -1), apply(rt(Op, .sub), 3, 4));
    try expectEqual(@as(i32, 1), apply(rt(Op, .sub), 5, 4));
    try expectEqual(@as(i32, 12), apply(rt(Op, .mul), 3, 4));
    try expectEqual(@as(i32, -3), apply(rt(Op, .neg), 3, 4));
    try expectEqual(@as(i32, 3), apply(rt(Op, .nop), 3, 4));
}

fn classify(x: i32) u8 {
    const r: u8 = blk: {
        if (x < 0) {
            if (x < -100) return 'N';
            break :blk 'n';
        }
        if (x == 0) break :blk 'z';
        if (x > 100) return 'P';
        break :blk 'p';
    };
    return r;
}

test "return from inside a labeled block" {
    try expectEqual(@as(u8, 'N'), classify(rt(i32, -101)));
    try expectEqual(@as(u8, 'n'), classify(rt(i32, -1)));
    try expectEqual(@as(u8, 'z'), classify(rt(i32, 0)));
    try expectEqual(@as(u8, 'p'), classify(rt(i32, 1)));
    try expectEqual(@as(u8, 'P'), classify(rt(i32, 101)));
}

fn earlyVoid(p: *u32, stop: bool) void {
    p.* += 1;
    if (stop) return;
    p.* += 10;
}

test "early return from a void callee" {
    var x: u32 = 0;
    earlyVoid(&x, rt(bool, true));
    try expectEqual(@as(u32, 1), x);
    earlyVoid(&x, rt(bool, false));
    try expectEqual(@as(u32, 12), x);
}

fn isEven(x: u32) bool {
    return x % 2 == 0;
}

fn below(i: u32, n: u32) bool {
    return i < n;
}

test "callee result used directly as a branch and loop condition" {
    var evens: u32 = 0;
    var i: u32 = 0;
    while (below(i, rt(u32, 11))) : (i += 1) {
        if (isEven(i)) evens += 1;
    }
    try expectEqual(@as(u32, 6), evens);
    try expect(isEven(rt(u32, 4)) and !isEven(rt(u32, 5)));
    try expect(!isEven(rt(u32, 4)) or isEven(rt(u32, 6)));
}

fn collatzSteps(start: u64) u32 {
    var n = start;
    var steps: u32 = 0;
    while (true) {
        if (n == 1) return steps;
        n = if (n % 2 == 0) n / 2 else 3 * n + 1;
        steps += 1;
    }
}

test "return from an infinite loop" {
    try expectEqual(@as(u32, 0), collatzSteps(rt(u64, 1)));
    try expectEqual(@as(u32, 111), collatzSteps(rt(u64, 27)));
}

fn whileElse(xs: []const u32, limit: u32) u32 {
    var i: usize = 0;
    return while (i < xs.len) : (i += 1) {
        if (xs[i] > limit) break xs[i];
    } else 0;
}

test "loop with break value and else used as the return value" {
    const xs = [_]u32{ 1, 5, 9, 2 };
    try expectEqual(@as(u32, 5), whileElse(&xs, rt(u32, 4)));
    try expectEqual(@as(u32, 0), whileElse(&xs, rt(u32, 9)));
}

fn returnsArgument(x: u64) u64 {
    return x;
}

fn returnsConstant() u64 {
    return 0xdead_beef_cafe_f00d;
}

test "trivial callees" {
    try expectEqual(@as(u64, 77), returnsArgument(rt(u64, 77)));
    try expectEqual(@as(u64, 0xdead_beef_cafe_f00d), returnsConstant());
    try expectEqual(@as(u64, 0xdead_beef_cafe_f00d + 1), returnsConstant() + returnsArgument(1));
}

// Results returned through memory (ret_ptr)

const Big = struct {
    a: u64,
    b: u64,
    c: [6]u64,
};

fn makeBig(seed: u64) Big {
    var r: Big = undefined;
    r.a = seed;
    r.b = r.a + 1;
    for (&r.c, 0..) |*e, i| e.* = r.b + i;
    return r;
}

fn sumBig(b: Big) u64 {
    var s = b.a + b.b;
    for (b.c) |e| s += e;
    return s;
}

test "large struct result built field by field and read back in the callee" {
    const b = makeBig(rt(u64, 10));
    try expectEqual(@as(u64, 10), b.a);
    try expectEqual(@as(u64, 11), b.b);
    try expectEqual(@as(u64, 16), b.c[5]);
    try expectEqual(@as(u64, 10 + 11 + 11 + 12 + 13 + 14 + 15 + 16), sumBig(b));
}

fn swapBig(b: Big) Big {
    var r = b;
    r.a = b.b;
    r.b = b.a;
    std.mem.reverse(u64, &r.c);
    return r;
}

test "large struct x = f(x)" {
    var x = makeBig(rt(u64, 1));
    x = swapBig(x);
    try expectEqual(@as(u64, 2), x.a);
    try expectEqual(@as(u64, 1), x.b);
    try expectEqual(@as(u64, 7), x.c[0]);
    try expectEqual(@as(u64, 2), x.c[5]);
    x = swapBig(swapBig(x));
    try expectEqual(@as(u64, 2), x.a);
    try expectEqual(@as(u64, 7), x.c[0]);
}

fn swapBigPtr(p: *const Big) Big {
    return .{ .a = p.b, .b = p.a, .c = p.c };
}

test "large struct x = f(&x)" {
    var x = makeBig(rt(u64, 1));
    const y = swapBigPtr(&x);
    try expectEqual(@as(u64, 2), y.a);
    try expectEqual(@as(u64, 1), y.b);
    try expectEqual(@as(u64, 1), x.a);
    x = swapBigPtr(&x);
    try expectEqual(@as(u64, 2), x.a);
    try expectEqual(@as(u64, 1), x.b);
}

fn bigFromBranches(sel: u8) Big {
    if (sel == 0) return makeBig(100);
    var r = makeBig(200);
    if (sel == 1) {
        r.a = 1;
        return r;
    }
    r.c[0] = 0;
    return r;
}

test "large struct returned from several return statements" {
    try expectEqual(@as(u64, 100), bigFromBranches(rt(u8, 0)).a);
    const one = bigFromBranches(rt(u8, 1));
    try expectEqual(@as(u64, 1), one.a);
    try expectEqual(@as(u64, 201), one.c[0]);
    const two = bigFromBranches(rt(u8, 2));
    try expectEqual(@as(u64, 200), two.a);
    try expectEqual(@as(u64, 0), two.c[0]);
}

test "large struct result stored through a pointer and into an array element" {
    var arr: [3]Big = undefined;
    for (&arr, 0..) |*e, i| e.* = makeBig(rt(u64, i * 10));
    try expectEqual(@as(u64, 20), arr[2].a);
    try expectEqual(@as(u64, 16), arr[1].c[5]);
    const p = &arr[1];
    p.* = makeBig(arr[0].b);
    try expectEqual(@as(u64, 1), arr[1].a);
    try expectEqual(@as(u64, 20), arr[2].a);
}

const Wrapper = struct { inner: Big, tag: u8 };

test "large struct result written into a field of a bigger aggregate" {
    var w: Wrapper = .{ .inner = makeBig(0), .tag = 9 };
    w.inner = swapBig(w.inner);
    try expectEqual(@as(u8, 9), w.tag);
    try expectEqual(@as(u64, 1), w.inner.a);
    w = .{ .inner = makeBig(w.inner.a), .tag = w.tag + 1 };
    try expectEqual(@as(u8, 10), w.tag);
    try expectEqual(@as(u64, 1), w.inner.a);
    try expectEqual(@as(u64, 2), w.inner.b);
}

fn bigArray(n: u32) [32]u32 {
    var r: [32]u32 = undefined;
    for (&r, 0..) |*e, i| e.* = n * @as(u32, @intCast(i));
    return r;
}

fn reverseArray(a: [32]u32) [32]u32 {
    var r: [32]u32 = undefined;
    for (a, 0..) |e, i| r[31 - i] = e;
    return r;
}

test "large array result and x = f(x)" {
    var a = bigArray(rt(u32, 3));
    try expectEqual(@as(u32, 93), a[31]);
    a = reverseArray(a);
    try expectEqual(@as(u32, 93), a[0]);
    try expectEqual(@as(u32, 0), a[31]);
}

fn mutateAndReturn(p: *Big, v: u64) Big {
    p.a = v;
    return p.*;
}

test "result location and pointer argument name the same memory" {
    var x = makeBig(rt(u64, 5));
    x = mutateAndReturn(&x, 77);
    try expectEqual(@as(u64, 77), x.a);
    try expectEqual(@as(u64, 6), x.b);
}

fn bigErr(fail: bool) !Big {
    if (fail) return error.Nope;
    return makeBig(3);
}

fn bigOpt(present: bool) ?Big {
    if (!present) return null;
    return makeBig(4);
}

test "large struct inside an error union and an optional" {
    try expectEqual(@as(u64, 3), (try bigErr(rt(bool, false))).a);
    try expectError(error.Nope, bigErr(rt(bool, true)));
    try expectEqual(@as(u64, 4), bigOpt(rt(bool, true)).?.a);
    try expect(bigOpt(rt(bool, false)) == null);
}

// defer and errdefer

const Log = struct {
    buf: [16]u8 = undefined,
    len: usize = 0,

    fn push(l: *Log, c: u8) void {
        l.buf[l.len] = c;
        l.len += 1;
    }

    fn items(l: *const Log) []const u8 {
        return l.buf[0..l.len];
    }
};

fn deferOnEveryExit(log: *Log, path: u8) u32 {
    log.push('a');
    defer log.push('z');
    if (path == 0) return 0;
    defer log.push('y');
    if (path == 1) return 1;
    {
        defer log.push('x');
        if (path == 2) return 2;
    }
    log.push('b');
    return 3;
}

test "defer runs in reverse order on every return path" {
    inline for (.{ .{ 0, "az" }, .{ 1, "ayz" }, .{ 2, "axyz" }, .{ 3, "axbyz" } }) |c| {
        var log: Log = .{};
        try expectEqual(@as(u32, c[0]), deferOnEveryExit(&log, rt(u8, c[0])));
        try expectEqualSlices(u8, c[1], log.items());
    }
}

fn returnValueBeforeDefer(p: *u32) u32 {
    defer p.* += 1;
    return p.*;
}

test "return value is computed before defer runs" {
    var x: u32 = rt(u32, 10);
    try expectEqual(@as(u32, 10), returnValueBeforeDefer(&x));
    try expectEqual(@as(u32, 11), x);
    try expectEqual(@as(u32, 11), returnValueBeforeDefer(&x) * 1);
    try expectEqual(@as(u32, 12), x);
}

fn errdeferOnlyOnError(log: *Log, fail: u8) !u32 {
    log.push('a');
    errdefer log.push('e');
    defer log.push('d');
    if (fail == 1) return error.First;
    errdefer log.push('s');
    if (fail == 2) return error.Second;
    return 7;
}

test "errdefer runs only on error returns" {
    {
        var log: Log = .{};
        try expectEqual(@as(u32, 7), try errdeferOnlyOnError(&log, rt(u8, 0)));
        try expectEqualSlices(u8, "ad", log.items());
    }
    {
        var log: Log = .{};
        try expectError(error.First, errdeferOnlyOnError(&log, rt(u8, 1)));
        try expectEqualSlices(u8, "ade", log.items());
    }
    {
        var log: Log = .{};
        try expectError(error.Second, errdeferOnlyOnError(&log, rt(u8, 2)));
        try expectEqualSlices(u8, "asde", log.items());
    }
}

fn mayFail(x: u32) !u32 {
    if (x == 0) return error.Zero;
    return x * 2;
}

fn errdeferWithTry(log: *Log, x: u32) !u32 {
    errdefer log.push('E');
    defer log.push('D');
    const y = try mayFail(x);
    log.push('k');
    return y + 1;
}

test "errdefer runs when try propagates an error" {
    {
        var log: Log = .{};
        try expectEqual(@as(u32, 11), try errdeferWithTry(&log, rt(u32, 5)));
        try expectEqualSlices(u8, "kD", log.items());
    }
    {
        var log: Log = .{};
        try expectError(error.Zero, errdeferWithTry(&log, rt(u32, 0)));
        try expectEqualSlices(u8, "DE", log.items());
    }
}

fn deferInLoop(log: *Log, n: u8) void {
    var i: u8 = 0;
    while (i < n) : (i += 1) {
        defer log.push('0' + i);
        if (i == 2) continue;
        if (i == 4) break;
        log.push('.');
    }
}

test "defer inside a loop body runs on continue and break" {
    var log: Log = .{};
    deferInLoop(&log, rt(u8, 7));
    try expectEqualSlices(u8, ".0.12.34", log.items());
}

test "defer callee called inside a caller with its own defers" {
    var log: Log = .{};
    {
        defer log.push('C');
        _ = deferOnEveryExit(&log, rt(u8, 1));
        log.push('-');
    }
    try expectEqualSlices(u8, "ayz-C", log.items());
}

// Errors

const E = error{ A, B, C };

fn pickError(sel: u8) E!u8 {
    return switch (sel) {
        0 => error.A,
        1 => error.B,
        2 => error.C,
        else => sel,
    };
}

test "error union result with every error and the payload" {
    try expectError(error.A, pickError(rt(u8, 0)));
    try expectError(error.B, pickError(rt(u8, 1)));
    try expectError(error.C, pickError(rt(u8, 2)));
    try expectEqual(@as(u8, 3), try pickError(rt(u8, 3)));
}

fn catchAndMap(sel: u8) u8 {
    return pickError(sel) catch |err| switch (err) {
        error.A => 100,
        error.B => 101,
        error.C => return 200,
    };
}

test "catch with switch on the error, including a return from the catch" {
    try expectEqual(@as(u8, 100), catchAndMap(rt(u8, 0)));
    try expectEqual(@as(u8, 101), catchAndMap(rt(u8, 1)));
    try expectEqual(@as(u8, 200), catchAndMap(rt(u8, 2)));
    try expectEqual(@as(u8, 9), catchAndMap(rt(u8, 9)));
}

fn level3(x: u32) !u32 {
    if (x > 100) return error.TooBig;
    return x + 1;
}

fn level2(x: u32) !u32 {
    return (try level3(x)) * 2;
}

fn level1(x: u32) anyerror!u32 {
    const y = try level2(x);
    if (y == 4) return error.Four;
    return y;
}

test "try through a chain of callees with error set coercion" {
    try expectEqual(@as(u32, 22), try level1(rt(u32, 10)));
    try expectError(error.TooBig, level1(rt(u32, 101)));
    try expectError(error.Four, level1(rt(u32, 1)));
}

fn errorOnly(b: bool) anyerror {
    return if (b) error.Yes else error.No;
}

test "callee returning a bare error value" {
    try expect(errorOnly(rt(bool, true)) == error.Yes);
    try expect(errorOnly(rt(bool, false)) == error.No);
}

fn voidOrError(fail: bool) !void {
    if (fail) return error.Failed;
}

test "error union with void payload" {
    try voidOrError(rt(bool, false));
    try expectError(error.Failed, voidOrError(rt(bool, true)));
    var hit = false;
    voidOrError(rt(bool, true)) catch {
        hit = true;
    };
    try expect(hit);
}

fn wideErr(x: u128) !u128 {
    if (x == 0) return error.Zero;
    return x << 64 | x;
}

test "error union with a u128 payload" {
    try skipLimitedBackends();
    try expectEqual(@as(u128, 0x5_0000_0000_0000_0005), try wideErr(rt(u128, 5)));
    try expectError(error.Zero, wideErr(rt(u128, 0)));
}

fn ifErr(sel: u8) u32 {
    if (pickError(sel)) |v| {
        return v;
    } else |err| {
        return if (err == error.B) 1000 else 2000;
    }
}

test "if with error capture on a callee result" {
    try expectEqual(@as(u32, 5), ifErr(rt(u8, 5)));
    try expectEqual(@as(u32, 1000), ifErr(rt(u8, 1)));
    try expectEqual(@as(u32, 2000), ifErr(rt(u8, 2)));
}

// Optionals

fn optInt(x: u32) ?u32 {
    if (x % 3 == 0) return null;
    return x;
}

fn optPtr(p: *u32, give: bool) ?*u32 {
    return if (give) p else null;
}

fn optSlice(s: []const u8) ?[]const u8 {
    if (s.len == 0) return null;
    return s[1..];
}

fn sumOrElse(xs: []const u32) u32 {
    var s: u32 = 0;
    for (xs) |x| s += optInt(x) orelse 100;
    return s;
}

test "optional results: int, pointer and slice" {
    try expectEqual(@as(?u32, null), optInt(rt(u32, 3)));
    try expectEqual(@as(?u32, 4), optInt(rt(u32, 4)));
    var x: u32 = 1;
    optPtr(&x, rt(bool, true)).?.* = 9;
    try expectEqual(@as(u32, 9), x);
    try expect(optPtr(&x, rt(bool, false)) == null);
    try expectEqualSlices(u8, "bc", optSlice(rt([]const u8, "abc")).?);
    try expect(optSlice(rt([]const u8, "")) == null);
    try expectEqual(@as(u32, 1 + 2 + 100 + 4), sumOrElse(&.{ 1, 2, 3, 4 }));
}

fn unwrapOrReturn(x: u32) u32 {
    const v = optInt(x) orelse return 0;
    return v + 1;
}

test "orelse return inside a callee" {
    try expectEqual(@as(u32, 0), unwrapOrReturn(rt(u32, 6)));
    try expectEqual(@as(u32, 8), unwrapOrReturn(rt(u32, 7)));
}

// Slices and pointers

fn sumSlice(xs: []const u32) u32 {
    var s: u32 = 0;
    for (xs) |x| s += x;
    return s;
}

fn middle(xs: []u32) []u32 {
    return xs[1 .. xs.len - 1];
}

test "slice into caller memory returned by a callee" {
    var arr = [_]u32{ 1, 2, 3, 4, 5 };
    const m = middle(&arr);
    try expectEqual(@as(usize, 3), m.len);
    m[0] = 20;
    try expectEqual(@as(u32, 20), arr[1]);
    try expectEqual(@as(u32, 1 + 20 + 3 + 4 + 5), sumSlice(&arr));
    try expectEqual(@as(u32, 27), sumSlice(middle(&arr)));
    try expectEqual(@as(u32, 3), sumSlice(middle(middle(&arr))));
}

fn cStrLen(s: [*:0]const u8) usize {
    var i: usize = 0;
    while (s[i] != 0) i += 1;
    return i;
}

fn fillAndCopy(dst: []u8, src: []const u8, fill: u8) void {
    @memset(dst, fill);
    @memcpy(dst[0..src.len], src);
}

test "sentinel pointer and memset/memcpy on caller buffers" {
    try expectEqual(@as(usize, 5), cStrLen(rt([*:0]const u8, "hello")));
    var buf: [8]u8 = undefined;
    fillAndCopy(&buf, rt([]const u8, "abc"), '-');
    try expectEqualSlices(u8, "abc-----", &buf);
}

fn advance(p: [*]const u16, n: usize) [*]const u16 {
    return p + n;
}

test "many-item pointer arithmetic" {
    const arr = [_]u16{ 10, 20, 30, 40 };
    const p = advance(&arr, rt(usize, 2));
    try expectEqual(@as(u16, 30), p[0]);
    try expectEqual(@as(u16, 40), advance(p, 1)[0]);
}

// Packed structs

const Flags = packed struct(u16) {
    a: bool,
    b: u3,
    c: u7,
    d: u5,
};

fn setC(f: *Flags, v: u7) void {
    f.c = v;
}

fn bumpB(b: *align(2:1:2) u3) void {
    b.* +%= 1;
}

fn flagsFrom(raw: u16) Flags {
    return @bitCast(raw);
}

fn flagsToggle(f: Flags) Flags {
    var r = f;
    r.a = !f.a;
    r.d = f.d +% 1;
    return r;
}

test "packed struct by pointer, by value and as a result" {
    var f: Flags = .{ .a = true, .b = 7, .c = 0, .d = 31 };
    setC(&f, rt(u7, 100));
    try expectEqual(@as(u7, 100), f.c);
    try expectEqual(@as(u3, 7), f.b);
    try expectEqual(@as(u5, 31), f.d);
    const g = flagsToggle(f);
    try expectEqual(false, g.a);
    try expectEqual(@as(u5, 0), g.d);
    try expectEqual(@as(u7, 100), g.c);
    try expectEqual(@as(u16, 0xffff), @as(u16, @bitCast(flagsFrom(rt(u16, 0xffff)))));
    try expectEqual(@as(u3, 0b101), flagsFrom(rt(u16, 0b1010)).b);
}

test "pointer to a packed struct bit field passed to a callee" {
    try skipLimitedBackends();
    var f: Flags = .{ .a = false, .b = 6, .c = 1, .d = 2 };
    bumpB(&f.b);
    try expectEqual(@as(u3, 7), f.b);
    bumpB(&f.b);
    try expectEqual(@as(u3, 0), f.b);
    try expectEqual(@as(u7, 1), f.c);
    try expectEqual(@as(u5, 2), f.d);
    try expectEqual(false, f.a);
}

// Vectors

fn vadd(a: @Vector(4, u32), b: @Vector(4, u32)) @Vector(4, u32) {
    return a +% b;
}

fn vsum(a: @Vector(4, u32)) u32 {
    return @reduce(.Add, a);
}

fn vselectMax(a: @Vector(4, i32), b: @Vector(4, i32)) @Vector(4, i32) {
    return @select(i32, a > b, a, b);
}

fn vscale(a: @Vector(4, f32), s: f32) @Vector(4, f32) {
    return a * @as(@Vector(4, f32), @splat(s));
}

test "vector arguments and results" {
    try skipLimitedBackends();
    const a: @Vector(4, u32) = rt(@Vector(4, u32), .{ 1, 2, 3, 4 });
    const b: @Vector(4, u32) = rt(@Vector(4, u32), .{ 10, 20, 30, 0xffff_ffff });
    const c = vadd(a, b);
    try expectEqual(@as(u32, 11), c[0]);
    try expectEqual(@as(u32, 3), c[3]);
    try expectEqual(@as(u32, 11 + 22 + 33 + 3), vsum(c));
    try expectEqual(@as(u32, 20), vsum(vadd(a, a)));
    const m = vselectMax(rt(@Vector(4, i32), .{ -1, 5, 0, 9 }), rt(@Vector(4, i32), .{ 1, 4, 0, -9 }));
    try expectEqual(@Vector(4, i32){ 1, 5, 0, 9 }, m);
    const s = vscale(rt(@Vector(4, f32), .{ 1, 2, 3, 4 }), rt(f32, 0.5));
    try expectEqual(@Vector(4, f32){ 0.5, 1, 1.5, 2 }, s);
}

// Floats

fn f16ops(a: f16, b: f16) f16 {
    return a * b + a - b;
}

fn f32ops(a: f32, b: f32) f32 {
    return (a + b) / (a - b);
}

fn f64ops(a: f64, b: f64, c: f64) f64 {
    return @mulAdd(f64, a, b, c);
}

fn f128ops(a: f128, b: f128) f128 {
    return a * b - a / b;
}

fn mixedFloats(a: f16, b: f32, c: f64, d: f128, i: u32) f64 {
    return @as(f64, a) + b + c + @as(f64, @floatCast(d)) + @as(f64, @floatFromInt(i));
}

test "float arguments and results: f16, f32, f64" {
    try skipLimitedBackends();
    try expectEqual(@as(f16, 3 * 2 + 3 - 2), f16ops(rt(f16, 3), rt(f16, 2)));
    try expectEqual(@as(f32, 3), f32ops(rt(f32, 4), rt(f32, 2)));
    try expectEqual(@as(f64, 2.5 * 4 + 1), f64ops(rt(f64, 2.5), rt(f64, 4), rt(f64, 1)));
}

test "f128 arguments and results" {
    try skipLimitedBackends();
    try expectEqual(@as(f128, 8 * 2 - 4), f128ops(rt(f128, 8), rt(f128, 2)));
    try expectEqual(@as(f128, 0.25 * 0.5 - 0.5), f128ops(rt(f128, 0.25), rt(f128, 0.5)));
}

test "mixed float and integer arguments" {
    try skipLimitedBackends();
    try expectEqual(@as(f64, 0.5 + 1.5 + 2 + 3 + 4), mixedFloats(rt(f16, 0.5), rt(f32, 1.5), rt(f64, 2), rt(f128, 3), rt(u32, 4)));
}

// Wide integers

fn mul128(a: u128, b: u128) u128 {
    return a *% b;
}

fn divmod128(a: u128, b: u128) [2]u128 {
    return .{ a / b, a % b };
}

fn ops256(a: i256, b: i256) i256 {
    return (a - b) * 3 + (a >> 100);
}

test "u128 arithmetic in a callee" {
    try skipLimitedBackends();
    const a = rt(u128, 0x1234_5678_9abc_def0_1122_3344);
    try expectEqual(@as(u128, 0x1234_5678_9abc_def0_1122_3344) *% 0x10000, mul128(a, rt(u128, 0x10000)));
    const dm = divmod128(a, rt(u128, 1_000_000_007));
    try expectEqual(@as(u128, 0x1234_5678_9abc_def0_1122_3344 / 1_000_000_007), dm[0]);
    try expectEqual(@as(u128, 0x1234_5678_9abc_def0_1122_3344 % 1_000_000_007), dm[1]);
}

test "i256 arithmetic in a callee" {
    try skipLimitedBackends();
    const a: i256 = rt(i256, -(1 << 200) + 12345);
    const b: i256 = rt(i256, 1 << 130);
    const expected: i256 = comptime (-(1 << 200) + 12345 - (1 << 130)) * 3 + ((-(1 << 200) + 12345) >> 100);
    try expectEqual(expected, ops256(a, b));
}

// Unions

const Shape = union(enum) {
    circle: f32,
    rect: struct { w: u32, h: u32 },
    none,
    big: [5]u64,
};

fn area(s: Shape) u64 {
    switch (s) {
        .circle => |r| return @intFromFloat(r * r * 3),
        .rect => |d| {
            if (d.w == 0) return 0;
            return @as(u64, d.w) * d.h;
        },
        .none => return 1,
        .big => |a| {
            var t: u64 = 0;
            for (a) |e| t += e;
            return t;
        },
    }
}

fn makeShape(sel: u8) Shape {
    return switch (sel) {
        0 => .{ .circle = 2 },
        1 => .{ .rect = .{ .w = 3, .h = 4 } },
        2 => .none,
        else => .{ .big = .{ 1, 2, 3, 4, sel } },
    };
}

fn growShape(s: *Shape) void {
    switch (s.*) {
        .circle => |*r| r.* *= 2,
        .rect => |*d| d.w += 1,
        .none => s.* = .{ .circle = 1 },
        .big => |*a| a[0] = 100,
    }
}

test "tagged union argument, result and pointer" {
    try expectEqual(@as(u64, 12), area(makeShape(rt(u8, 0))));
    try expectEqual(@as(u64, 12), area(makeShape(rt(u8, 1))));
    try expectEqual(@as(u64, 1), area(makeShape(rt(u8, 2))));
    try expectEqual(@as(u64, 1 + 2 + 3 + 4 + 9), area(makeShape(rt(u8, 9))));
    var s = makeShape(rt(u8, 2));
    growShape(&s);
    try expectEqual(@as(u64, 3), area(s));
    s = makeShape(rt(u8, 1));
    growShape(&s);
    try expectEqual(@as(u64, 16), area(s));
    s = makeShape(rt(u8, 7));
    growShape(&s);
    try expectEqual(@as(u64, 100 + 2 + 3 + 4 + 7), area(s));
}

const Bare = extern union { i: u32, f: f32, b: [4]u8 };

fn bareBits(f: f32) Bare {
    return .{ .f = f };
}

test "extern union result" {
    try expectEqual(@as(u32, 0x3f80_0000), bareBits(rt(f32, 1.0)).i);
}

// Callee locals

var escaped: ?*u32 = null;

fn bumpEscaped() void {
    escaped.?.* += 1;
}

fn localEscapes(v: u32) u32 {
    var local = v;
    escaped = &local;
    bumpEscaped();
    escaped = null;
    return local;
}

test "address of a callee local escapes through a global" {
    try expectEqual(@as(u32, 2 + 11), localEscapes(rt(u32, 1)) + localEscapes(rt(u32, 10)));
    var total: u32 = 0;
    for (0..4) |i| total += localEscapes(@intCast(i));
    try expectEqual(@as(u32, 1 + 2 + 3 + 4), total);
}

fn countUp(n: u32) u32 {
    var c: u32 = 0;
    var i: u32 = 0;
    while (i < n) : (i += 1) c += 1;
    return c;
}

test "callee local is reinitialized on every call from a caller loop" {
    var results: [5]u32 = undefined;
    for (&results, 0..) |*r, i| r.* = countUp(@intCast(i));
    try expectEqualSlices(u32, &.{ 0, 1, 2, 3, 4 }, &results);
}

fn twoLocals(a: u32, b: u32) bool {
    var x = a;
    var y = b;
    const px = &x;
    const py = &y;
    px.* += py.*;
    py.* += 1;
    return px != py and x == a + b and y == b + 1;
}

test "distinct callee locals have distinct addresses" {
    try expect(twoLocals(rt(u32, 1), rt(u32, 2)));
    try expect(twoLocals(rt(u32, 5), rt(u32, 5)));
}

fn alignedLocal(v: u8) usize {
    var buf: [16]u8 align(64) = undefined;
    @memset(&buf, v);
    std.mem.doNotOptimizeAway(&buf);
    return @intFromPtr(&buf) % 64 + buf[15] - v;
}

test "over-aligned callee local keeps its alignment" {
    var x: u8 align(1) = rt(u8, 3);
    _ = &x;
    try expectEqual(@as(usize, 0), alignedLocal(x));
    try expectEqual(@as(usize, 0), alignedLocal(x) + alignedLocal(rt(u8, 4)));
}

fn tick() u32 {
    const S = struct {
        var n: u32 = 0;
    };
    S.n += 1;
    return S.n;
}

test "container-level variable declared inside a callee is shared by all calls" {
    const base = tick();
    try expectEqual(base + 1, tick());
    try expectEqual(base + 2, tick());
    var sum: u32 = 0;
    for (0..3) |_| sum += tick();
    try expectEqual(3 * base + 3 + 4 + 5, sum);
}

var global_counter: u32 = 0;

fn exchangeGlobal(v: u32) u32 {
    const old = global_counter;
    global_counter = v;
    return old;
}

test "callee reads and writes a global around caller accesses" {
    global_counter = rt(u32, 5);
    const a = exchangeGlobal(6);
    const b = global_counter;
    const c = exchangeGlobal(global_counter + 1);
    try expectEqual(@as(u32, 5), a);
    try expectEqual(@as(u32, 6), b);
    try expectEqual(@as(u32, 6), c);
    try expectEqual(@as(u32, 7), global_counter);
}

// Function pointers and function identity

const other = @import("auto_inline/other.zig");

fn add1(x: u32) u32 {
    return x + 1;
}

fn dbl(x: u32) u32 {
    return x * 2;
}

fn applyTwice(f: *const fn (u32) u32, x: u32) u32 {
    return f(f(x));
}

fn chooseFn(b: bool) *const fn (u32) u32 {
    return if (b) &add1 else &dbl;
}

test "callee taking and returning function pointers" {
    try expectEqual(@as(u32, 7), applyTwice(&add1, rt(u32, 5)));
    try expectEqual(@as(u32, 20), applyTwice(&dbl, rt(u32, 5)));
    try expectEqual(@as(u32, 6), chooseFn(rt(bool, true))(5));
    try expectEqual(@as(u32, 10), chooseFn(rt(bool, false))(5));
    try expectEqual(@as(u32, 12), applyTwice(chooseFn(rt(bool, true)), applyTwice(&dbl, 2) + 2));
}

test "function called directly and through a pointer gives the same result" {
    const fp = rt(*const fn (u32) u32, &add1);
    try expectEqual(add1(rt(u32, 41)), fp(41));
    try expect(fp == &add1);
    try expect(@intFromPtr(fp) == @intFromPtr(&add1));
    try expect(&add1 != &dbl);
    try expect(chooseFn(rt(bool, true)) == &add1);
    try expect(chooseFn(rt(bool, false)) == &dbl);
}

test "function address is the same across files" {
    try expect(other.tripleAddress() == &other.triple);
    try expectEqual(@intFromPtr(&other.triple), @intFromPtr(other.tripleAddress()));
    try expectEqual(@as(u32, 12), other.tripleAddress()(rt(u32, 4)));
    try expectEqual(@as(u32, 13), other.callTriple(rt(u32, 4)));
    try expectEqual(@as(u32, 12), other.triple(rt(u32, 4)));
}

const table = [_]*const fn (u32) u32{ &add1, &dbl, &other.triple };

test "function pointer selected at runtime from a table" {
    var acc: u32 = 1;
    for (0..6) |i| acc = table[i % 3](acc);
    // 1 -> 2 -> 4 -> 12 -> 13 -> 26 -> 78
    try expectEqual(@as(u32, 78), acc);
}

const Callback = struct {
    f: *const fn (*u32, u32) void,
    ctx: u32,

    fn call(cb: Callback, out: *u32) void {
        cb.f(out, cb.ctx);
    }
};

fn storeSum(out: *u32, ctx: u32) void {
    out.* += ctx;
}

test "struct with a function pointer field" {
    var x: u32 = 1;
    const cb: Callback = .{ .f = &storeSum, .ctx = rt(u32, 10) };
    cb.call(&x);
    cb.call(&x);
    try expectEqual(@as(u32, 21), x);
}

const ExternSmall = extern struct { a: u8, b: u16, c: u32 };

fn cAbi(a: u32, s: ExternSmall) callconv(.c) u32 {
    return a + s.a + s.b + s.c;
}

test "C calling convention callee" {
    try expectEqual(@as(u32, 10 + 6), cAbi(rt(u32, 10), .{ .a = 1, .b = 2, .c = 3 }));
    const fp = &cAbi;
    try expectEqual(@as(u32, 1 + 6), fp(1, .{ .a = 1, .b = 2, .c = 3 }));
}

// Nesting and repetition

fn leafC(x: u32) u32 {
    return x ^ 0x55;
}

fn midB(x: u32) u32 {
    return leafC(x) + leafC(x + 1);
}

fn topA(x: u32) u32 {
    return midB(x) * 2 + leafC(x);
}

test "nested callees A calls B calls C" {
    const x = rt(u32, 7);
    const expected = ((7 ^ 0x55) + (8 ^ 0x55)) * 2 + (7 ^ 0x55);
    try expectEqual(@as(u32, expected), topA(x));
    try expectEqual(@as(u32, (expected + 1) ^ 0x55), leafC(topA(x) + 1));
}

test "same callee called many times in one expression and one caller" {
    const a = rt(u32, 3);
    const r = leafC(a) + leafC(a + 1) + leafC(leafC(a)) + leafC(a) * leafC(2);
    try expectEqual(@as(u32, (3 ^ 0x55) + (4 ^ 0x55) + 3 + (3 ^ 0x55) * (2 ^ 0x55)), r);
    var acc: u32 = 0;
    acc +%= midB(a);
    acc +%= midB(acc);
    acc +%= midB(acc);
    var expect_acc: u32 = 0;
    expect_acc +%= ((3 ^ 0x55) + (4 ^ 0x55));
    expect_acc +%= ((expect_acc ^ 0x55) + ((expect_acc + 1) ^ 0x55));
    expect_acc +%= ((expect_acc ^ 0x55) + ((expect_acc + 1) ^ 0x55));
    try expectEqual(expect_acc, acc);
}

fn hot(x: u64) u64 {
    return (x *% 6364136223846793005) +% 1442695040888963407;
}

test "callee called in a hot loop" {
    var s: u64 = rt(u64, 1);
    var i: u32 = 0;
    while (i < 10_000) : (i += 1) s = hot(s);
    var t: u64 = 1;
    i = 0;
    while (i < 10_000) : (i += 1) t = (t *% 6364136223846793005) +% 1442695040888963407;
    try expectEqual(t, s);
}

fn coldFailure(code: u32) error{Cold}!u32 {
    if (code == 0xdead) return error.Cold;
    return code;
}

fn scan(xs: []const u32) !u32 {
    var sum: u32 = 0;
    for (xs) |x| {
        if (x > 1000) {
            @branchHint(.cold);
            sum += try coldFailure(x);
        } else {
            sum += x;
        }
    }
    return sum;
}

test "callee called in a cold error branch" {
    try expectEqual(@as(u32, 1 + 2 + 2000), try scan(&.{ 1, 2, 2000 }));
    try expectError(error.Cold, scan(&.{ 1, 0xdead, 3 }));
}

fn manyLive(a: u64, b: u64) u64 {
    const x0 = a +% b;
    const x1 = a ^ b;
    const x2 = a *% 3;
    const x3 = b *% 5;
    const x4 = x0 +% x1;
    const x5 = x2 ^ x3;
    const x6 = a -% b;
    const x7 = b -% a;
    const x8 = x0 *% x1;
    const x9 = x2 +% x7;
    const x10 = x3 ^ x6;
    const x11 = x4 *% x5;
    const x12 = a | b;
    const x13 = a & b;
    const x14 = x12 -% x13;
    const x15 = x8 +% x9;
    const x16 = x10 ^ x11;
    const x17 = x14 *% 7;
    const x18 = a >> 3;
    const x19 = b << 2;
    const x20 = x18 +% x19;
    const x21 = x0 -% x20;
    const x22 = x1 +% x21;
    const x23 = x22 ^ x15;
    return x0 +% x1 +% x2 +% x3 +% x4 +% x5 +% x6 +% x7 +% x8 +% x9 +% x10 +% x11 +%
        x12 +% x13 +% x14 +% x15 +% x16 +% x17 +% x18 +% x19 +% x20 +% x21 +% x22 +% x23;
}

fn manyLiveReference(a: u64, b: u64) u64 {
    var v: [24]u64 = undefined;
    v[0] = a +% b;
    v[1] = a ^ b;
    v[2] = a *% 3;
    v[3] = b *% 5;
    v[4] = v[0] +% v[1];
    v[5] = v[2] ^ v[3];
    v[6] = a -% b;
    v[7] = b -% a;
    v[8] = v[0] *% v[1];
    v[9] = v[2] +% v[7];
    v[10] = v[3] ^ v[6];
    v[11] = v[4] *% v[5];
    v[12] = a | b;
    v[13] = a & b;
    v[14] = v[12] -% v[13];
    v[15] = v[8] +% v[9];
    v[16] = v[10] ^ v[11];
    v[17] = v[14] *% 7;
    v[18] = a >> 3;
    v[19] = b << 2;
    v[20] = v[18] +% v[19];
    v[21] = v[0] -% v[20];
    v[22] = v[1] +% v[21];
    v[23] = v[22] ^ v[15];
    var s: u64 = 0;
    for (v) |e| s +%= e;
    return s;
}

test "many live values in the callee and across the call in the caller" {
    const a = rt(u64, 0x1234_5678);
    const b = rt(u64, 0x9abc_def0_1357);
    const c0 = a +% 1;
    const c1 = b +% 2;
    const c2 = a *% b;
    const c3 = a ^ 0xffff;
    const c4 = b | 0xf0f0;
    const c5 = a -% 99;
    const c6 = b >> 7;
    const c7 = a << 9;
    const c8 = c0 +% c1;
    const c9 = c2 ^ c3;
    const c10 = c4 +% c5;
    const c11 = c6 -% c7;
    const r = manyLive(a, b) +% manyLive(b, a);
    const after = c0 +% c1 +% c2 +% c3 +% c4 +% c5 +% c6 +% c7 +% c8 +% c9 +% c10 +% c11;
    try expectEqual(manyLiveReference(a, b) +% manyLiveReference(b, a), r);
    const expected_after = (a +% 1) +% (b +% 2) +% (a *% b) +% (a ^ 0xffff) +% (b | 0xf0f0) +%
        (a -% 99) +% (b >> 7) +% (a << 9) +% ((a +% 1) +% (b +% 2)) +% ((a *% b) ^ (a ^ 0xffff)) +%
        ((b | 0xf0f0) +% (a -% 99)) +% ((b >> 7) -% (a << 9));
    try expectEqual(expected_after, after);
}

fn floatsLive(a: f64, b: f64) f64 {
    const x0 = a + b;
    const x1 = a * b;
    const x2 = a - b;
    const x3 = x0 * x1;
    const x4 = x2 * x0;
    const x5 = x3 + x4;
    const x6 = x5 - x1;
    const x7 = x6 * 0.5;
    return x0 + x1 + x2 + x3 + x4 + x5 + x6 + x7;
}

test "float values live across calls in the caller" {
    try skipLimitedBackends();
    const a = rt(f64, 1.5);
    const b = rt(f64, 2.0);
    const k0 = a * 3;
    const k1 = b * 5;
    const k2 = a + b;
    const r = floatsLive(a, b) + floatsLive(k0, k1);
    try expectEqual(@as(f64, 4.5), k0);
    try expectEqual(@as(f64, 10), k1);
    try expectEqual(@as(f64, 3.5), k2);
    // floatsLive(1.5, 2): 3.5 + 3 - 0.5 + 10.5 - 1.75 + 8.75 + 5.75 + 2.875 = 32.125
    // floatsLive(4.5, 10): 14.5 + 45 - 5.5 + 652.5 - 79.75 + 572.75 + 527.75 + 263.875 = 1991.125
    try expectEqual(@as(f64, 32.125 + 1991.125), r);
}

// Recursion

fn fib(n: u32) u32 {
    if (n < 2) return n;
    return fib(n - 1) + fib(n - 2);
}

fn isEvenRec(n: u32) bool {
    if (n == 0) return true;
    return isOddRec(n - 1);
}

fn isOddRec(n: u32) bool {
    if (n == 0) return false;
    return isEvenRec(n - 1);
}

test "self recursion" {
    try expectEqual(@as(u32, 0), fib(rt(u32, 0)));
    try expectEqual(@as(u32, 1), fib(rt(u32, 1)));
    try expectEqual(@as(u32, 55), fib(rt(u32, 10)));
    try expectEqual(@as(u32, 6765), fib(rt(u32, 20)));
}

test "mutual recursion" {
    try expect(isEvenRec(rt(u32, 10)));
    try expect(!isEvenRec(rt(u32, 7)));
    try expect(isOddRec(rt(u32, 7)));
    try expect(!isOddRec(rt(u32, 0)));
}

fn sumDownWithDefer(log: *Log, n: u8) u32 {
    if (n == 0) return 0;
    defer log.push('0' + n);
    return n + sumDownWithDefer(log, n - 1);
}

test "recursion with a defer on each level" {
    var log: Log = .{};
    try expectEqual(@as(u32, 10), sumDownWithDefer(&log, rt(u8, 4)));
    try expectEqualSlices(u8, "1234", log.items());
}

fn recurseThroughPointer(n: u32) u32 {
    if (n == 0) return 1;
    const self = rt(*const fn (u32) u32, &recurseThroughPointer);
    return 2 * self(n - 1);
}

test "recursion through a function pointer" {
    try expectEqual(@as(u32, 1024), recurseThroughPointer(rt(u32, 10)));
}

fn depthLocal(n: u32, parent: ?*const u32) u32 {
    const mine: u32 = n;
    if (n == 0) return if (parent) |p| p.* else 0;
    return depthLocal(n - 1, &mine) + mine;
}

test "recursion where each level passes the address of its own local" {
    // depthLocal(3) = depthLocal(2) + 3 = depthLocal(1) + 2 + 3 = depthLocal(0, &1) + 1 + 2 + 3 = 1 + 6
    try expectEqual(@as(u32, 7), depthLocal(rt(u32, 3), null));
}

// Generic and comptime instances

fn maxOf(comptime T: type, a: T, b: T) T {
    return if (a > b) a else b;
}

fn addAny(a: anytype, b: @TypeOf(a)) @TypeOf(a) {
    return a + b;
}

fn shiftBy(comptime n: u5, x: u32) u32 {
    return x << n;
}

fn Stack(comptime T: type) type {
    return struct {
        items: [4]T = undefined,
        len: usize = 0,

        const Self = @This();

        fn push(s: *Self, v: T) void {
            s.items[s.len] = v;
            s.len += 1;
        }

        fn pop(s: *Self) ?T {
            if (s.len == 0) return null;
            s.len -= 1;
            return s.items[s.len];
        }
    };
}

test "generic function instances" {
    try expectEqual(@as(u8, 9), maxOf(u8, rt(u8, 3), rt(u8, 9)));
    try expectEqual(@as(i64, -3), maxOf(i64, rt(i64, -3), rt(i64, -9)));
    try expectEqual(@as(f32, 2.5), maxOf(f32, rt(f32, 2.5), rt(f32, -1)));
    try expectEqual(@as(u16, 300), addAny(rt(u16, 100), 200));
    try expectEqual(@as(f64, 0.75), addAny(rt(f64, 0.5), 0.25));
    try expectEqual(@as(u32, 8), shiftBy(3, rt(u32, 1)));
    try expectEqual(@as(u32, 1 << 31), shiftBy(31, rt(u32, 1)));
}

test "methods of a generic type" {
    var s: Stack(u16) = .{};
    s.push(rt(u16, 1));
    s.push(rt(u16, 2));
    try expectEqual(@as(?u16, 2), s.pop());
    s.push(rt(u16, 3));
    try expectEqual(@as(?u16, 3), s.pop());
    try expectEqual(@as(?u16, 1), s.pop());
    try expectEqual(@as(?u16, null), s.pop());
    var t: Stack(Big) = .{};
    t.push(makeBig(rt(u64, 8)));
    try expectEqual(@as(u64, 8), t.pop().?.a);
}

// noinline, @call modifiers

noinline fn noInlineAdd(a: u32, b: u32) u32 {
    return a + b;
}

test "noinline callee and call modifiers" {
    try expectEqual(@as(u32, 5), noInlineAdd(rt(u32, 2), 3));
    try expectEqual(@as(u32, 5), @call(.never_inline, add1, .{rt(u32, 4)}));
    try expectEqual(@as(u32, 5), @call(.auto, add1, .{rt(u32, 4)}));
    try expectEqual(@as(u32, 8), @call(.always_inline, dbl, .{rt(u32, 4)}));
    try expectEqual(@as(u32, 21), @call(.never_inline, midB, .{rt(u32, 0)}) - (0x55 + (1 ^ 0x55)) + 21);
}

// @returnAddress and @frameAddress

noinline fn returnAddressOf() usize {
    return @returnAddress();
}

fn returnAddressNotNoinline() usize {
    return @returnAddress();
}

noinline fn callerOfReturnAddress() [2]usize {
    return .{ returnAddressOf(), @intFromPtr(&callerOfReturnAddress) };
}

noinline fn callerOfReturnAddressNotNoinline() [3]usize {
    return .{ returnAddressNotNoinline(), @intFromPtr(&callerOfReturnAddressNotNoinline), @returnAddress() };
}

fn returnAddressIsInside(r: [2]usize) bool {
    // The return address points into the caller, a few instructions after its entry point.
    return r[0] > r[1] and r[0] - r[1] < 4096;
}

test "@returnAddress in a noinline callee points into its caller" {
    if (builtin.cpu.arch.isWasm()) return error.SkipZigTest; // @returnAddress returns 0
    if (builtin.zig_backend == .stage2_spirv) return error.SkipZigTest;
    try expect(returnAddressIsInside(callerOfReturnAddress()));
    try expect(returnAddressOf() != 0);
}

test "@returnAddress in an ordinary callee points into its caller" {
    if (builtin.cpu.arch.isWasm()) return error.SkipZigTest; // @returnAddress returns 0
    if (builtin.zig_backend == .stage2_spirv) return error.SkipZigTest;
    try expect(returnAddressNotNoinline() != 0);
    // Optimizing backends (LLVM, C compilers) may inline such a callee, after which
    // @returnAddress refers to the caller's caller, as the language reference allows.
    // Self-hosted backends must not inline functions that use @returnAddress.
    if (builtin.zig_backend == .stage2_llvm or builtin.zig_backend == .stage2_c) return;
    const r = callerOfReturnAddressNotNoinline();
    try expect(r[0] != r[2]);
    try expect(returnAddressIsInside(r[0..2].*));
}

noinline fn frameAddressOf() usize {
    return @frameAddress();
}

fn frameAddressNotNoinline() usize {
    return @frameAddress();
}

noinline fn compareFrames() [3]usize {
    return .{ @frameAddress(), frameAddressOf(), frameAddressNotNoinline() };
}

test "@frameAddress in a callee is the callee's frame, below the caller's" {
    if (builtin.cpu.arch.isWasm()) return error.SkipZigTest;
    if (builtin.zig_backend == .stage2_spirv) return error.SkipZigTest;
    const f = compareFrames();
    try expect(f[0] != 0);
    try expect(f[1] != 0 and f[1] < f[0]);
    if (builtin.zig_backend == .stage2_llvm or builtin.zig_backend == .stage2_c) return;
    try expect(f[2] != 0 and f[2] < f[0]);
}

// Inline assembly

fn asmAdd(a: u64, b: u64) u64 {
    return switch (builtin.cpu.arch) {
        .aarch64, .aarch64_be => asm ("add %[ret], %[a], %[b]"
            : [ret] "=r" (-> u64),
            : [a] "r" (a),
              [b] "r" (b),
        ),
        .x86_64 => asm ("lea (%[a], %[b]), %[ret]"
            : [ret] "=r" (-> u64),
            : [a] "r" (a),
              [b] "r" (b),
        ),
        else => unreachable,
    };
}

fn asmStore(p: *u64, v: u64) void {
    switch (builtin.cpu.arch) {
        .aarch64, .aarch64_be => asm volatile ("str %[v], [%[p]]"
            :
            : [p] "r" (p),
              [v] "r" (v),
            : .{ .memory = true }),
        .x86_64 => asm volatile ("movq %[v], (%[p])"
            :
            : [p] "r" (p),
              [v] "r" (v),
            : .{ .memory = true }),
        else => unreachable,
    }
}

test "callee containing inline assembly" {
    switch (builtin.cpu.arch) {
        .aarch64, .aarch64_be, .x86_64 => {},
        else => return error.SkipZigTest,
    }
    if (builtin.zig_backend == .stage2_c and builtin.os.tag == .windows) return error.SkipZigTest; // MSVC doesn't support inline assembly
    try expectEqual(@as(u64, 30), asmAdd(rt(u64, 10), rt(u64, 20)));
    try expectEqual(@as(u64, 10 + 20 + 3 + 4), asmAdd(asmAdd(rt(u64, 10), 20), asmAdd(3, rt(u64, 4))));
    var x: u64 = 0;
    asmStore(&x, rt(u64, 0xfeed));
    try expectEqual(@as(u64, 0xfeed), x);
    var arr = [_]u64{ 0, 0, 0 };
    for (&arr, 0..) |*e, i| asmStore(e, asmAdd(i, 100));
    try expectEqualSlices(u64, &.{ 100, 101, 102 }, &arr);
}

// Miscellaneous

fn whereAmI() std.builtin.SourceLocation {
    return @src();
}

test "@src in a callee names the callee" {
    const loc = whereAmI();
    try expectEqualSlices(u8, "whereAmI", loc.fn_name);
}

fn zeroSized(a: u32) struct {} {
    _ = a;
    return .{};
}

fn returnsVoidAfterWork(p: *u32) void {
    p.* *= 3;
}

test "callees with zero-bit results" {
    var x: u32 = rt(u32, 2);
    _ = zeroSized(x);
    returnsVoidAfterWork(&x);
    returnsVoidAfterWork(&x);
    try expectEqual(@as(u32, 18), x);
}

fn checkedDiv(a: u32, b: u32) u32 {
    if (b == 0) unreachable;
    return a / b;
}

test "callee with an unreachable on a path that is not taken" {
    try expectEqual(@as(u32, 4), checkedDiv(rt(u32, 12), rt(u32, 3)));
}

fn tupleSwap(t: struct { u8, u64 }) struct { u64, u8 } {
    return .{ t[1], t[0] };
}

test "tuple argument and result" {
    const r = tupleSwap(.{ rt(u8, 1), rt(u64, 2) });
    try expectEqual(@as(u64, 2), r[0]);
    try expectEqual(@as(u8, 1), r[1]);
}
