//! Calls whose callees a backend may inline automatically. The results must not
//! depend on whether a call was inlined, so every test here holds on every
//! backend; the self-hosted AArch64 backend's inliner is the one these shapes
//! were written against (`src/Air/Inline.zig`).

const builtin = @import("builtin");
const std = @import("std");
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectError = std.testing.expectError;

fn addOne(x: u32) u32 {
    return x + 1;
}

fn twice(x: u32) u32 {
    return addOne(addOne(x)) - 1 + addOne(0) - 1 + x;
}

test "nested small callees" {
    var x: u32 = 20;
    _ = &x;
    try expectEqual(@as(u32, 41), twice(x));
    try expectEqual(@as(u32, 21), addOne(x));
}

fn countDefers(counter: *u32, fail: bool) error{Failed}!u32 {
    defer counter.* += 1;
    errdefer counter.* += 10;
    if (fail) return error.Failed;
    return counter.* + 100;
}

test "defer and errdefer in callee on the success, error and catch paths" {
    var counter: u32 = 0;
    var fail = false;
    _ = &fail;
    try expectEqual(@as(u32, 100), try countDefers(&counter, fail));
    try expectEqual(@as(u32, 1), counter);
    fail = true;
    try expectError(error.Failed, countDefers(&counter, fail));
    try expectEqual(@as(u32, 12), counter);
    const caught = countDefers(&counter, fail) catch 7;
    try expectEqual(@as(u32, 7), caught);
    try expectEqual(@as(u32, 23), counter);
}

fn fib(n: u32) u32 {
    if (n < 2) return n;
    return fib(n - 1) + fib(n - 2);
}

fn isEven(n: u32) bool {
    if (n == 0) return true;
    return isOdd(n - 1);
}

fn isOdd(n: u32) bool {
    if (n == 0) return false;
    return isEven(n - 1);
}

test "self and mutual recursion" {
    var n: u32 = 15;
    _ = &n;
    try expectEqual(@as(u32, 610), fib(n));
    try expect(isOdd(n));
    try expect(!isEven(n));
    try expect(isEven(n + 1));
}

fn addT(comptime T: type, a: T, b: T) T {
    return a +% b;
}

fn middleComptime(a: u32, comptime k: u32, b: u32) u32 {
    return a * k + b;
}

fn doubleAny(x: anytype) @TypeOf(x) {
    return x + x;
}

test "generic, comptime and anytype instances" {
    var a: u8 = 250;
    var b: u64 = 1 << 40;
    _ = .{ &a, &b };
    try expectEqual(@as(u8, 4), addT(u8, a, 10));
    try expectEqual(@as(u64, 3 << 40), addT(u64, b, b << 1));
    try expectEqual(@as(u32, 23), middleComptime(5, 4, 3));
    try expectEqual(@as(u32, 33), middleComptime(10, 3, 3));
    try expectEqual(@as(u64, 1 << 41), doubleAny(b));
    try expectEqual(@as(i16, -6), doubleAny(@as(i16, -3)));
}

fn zeroBitParams(a: u32, v: void, b: u32, z: u0, e: struct {}, c: u32) u32 {
    _ = .{ v, z, e };
    return a * 100 + b * 10 + c;
}

fn unusedParam(a: u32, unused: u64, b: u32) u32 {
    _ = unused;
    return a - b;
}

test "zero-bit and unused parameters keep the other arguments in place" {
    var a: u32 = 1;
    var b: u32 = 2;
    var c: u32 = 3;
    _ = .{ &a, &b, &c };
    try expectEqual(@as(u32, 123), zeroBitParams(a, {}, b, 0, .{}, c));
    try expectEqual(@as(u32, 321), zeroBitParams(c, {}, b, 0, .{}, a));
    try expectEqual(@as(u32, 1), unusedParam(c, 99, b));
}

const Big = struct {
    a: [8]u64,
    tag: u8,
};

fn bumpBig(s: Big) Big {
    var r = s;
    r.a[0] += 1;
    r.a[7] = s.a[0] * 2;
    r.tag = s.tag +% 1;
    return r;
}

const Pair = struct { a: u64, b: u64, c: u64, d: u64 };

fn swapPair(p: Pair) Pair {
    return .{ .a = p.d, .b = p.c, .c = p.b, .d = p.a };
}

test "by-ref results assigned back to the argument" {
    var big: Big = .{ .a = .{ 5, 1, 2, 3, 4, 5, 6, 7 }, .tag = 255 };
    big = bumpBig(big);
    try expectEqual(@as(u64, 6), big.a[0]);
    try expectEqual(@as(u64, 10), big.a[7]);
    try expectEqual(@as(u8, 0), big.tag);
    big = bumpBig(bumpBig(big));
    try expectEqual(@as(u64, 8), big.a[0]);
    try expectEqual(@as(u64, 14), big.a[7]);

    var p: Pair = .{ .a = 1, .b = 2, .c = 3, .d = 4 };
    p = swapPair(p);
    try expectEqual(Pair{ .a = 4, .b = 3, .c = 2, .d = 1 }, p);
    p = swapPair(swapPair(p));
    try expectEqual(Pair{ .a = 4, .b = 3, .c = 2, .d = 1 }, p);
}

fn wrappingNoSafety(x: u32, y: u32) u32 {
    @setRuntimeSafety(false);
    const sum = x +% y;
    var array: [4]u32 = .{ 1, 2, 3, 4 };
    _ = &array;
    return sum + array[x & 3];
}

fn checkedAdd(x: u8, y: u8) ?u8 {
    return std.math.add(u8, x, y) catch null;
}

test "callee without runtime safety in a safe caller" {
    var x: u32 = 0xffff_fffe;
    _ = &x;
    try expectEqual(@as(u32, 3), wrappingNoSafety(x, 2));
    try expectEqual(@as(?u8, null), checkedAdd(200, 100));
    try expectEqual(@as(?u8, 250), checkedAdd(200, 50));
}

fn identityTarget(x: u32) u32 {
    return x * 3;
}

fn pointerTo() *const fn (u32) u32 {
    return &identityTarget;
}

test "function pointers to an inlined callee keep their identity" {
    var x: u32 = 7;
    _ = &x;
    // Direct calls, which may be inlined.
    try expectEqual(@as(u32, 21), identityTarget(x));
    const direct: *const fn (u32) u32 = &identityTarget;
    var through: *const fn (u32) u32 = pointerTo();
    _ = &through;
    try expect(direct == through);
    try expectEqual(@intFromPtr(direct), @intFromPtr(through));
    try expectEqual(@as(u32, 24), through(x + 1));
}

noinline fn noinlineReturnAddress() usize {
    return @returnAddress();
}

fn plainReturnAddress() usize {
    return @returnAddress();
}

fn neverInlineCallee(x: u32) u32 {
    return x ^ 0x55;
}

test "noinline, never_inline and @returnAddress callees" {
    if (builtin.zig_backend == .stage2_spirv) return error.SkipZigTest;
    if (builtin.zig_backend == .stage2_wasm) return error.SkipZigTest;
    if (builtin.zig_backend == .stage2_c) return error.SkipZigTest;

    const first = noinlineReturnAddress();
    const second = noinlineReturnAddress();
    try expect(first != 0);
    try expect(first != second);

    const third = @call(.never_inline, plainReturnAddress, .{});
    const fourth = @call(.never_inline, plainReturnAddress, .{});
    try expect(third != fourth);

    var x: u32 = 0xff;
    _ = &x;
    try expectEqual(@as(u32, 0xaa), @call(.never_inline, neverInlineCallee, .{x}));

    // A function that reads its own return address is never inlined by the
    // self-hosted AArch64 backend, so each call site reports its own address.
    // LLVM may inline it, which the language allows.
    if (builtin.zig_backend == .stage2_aarch64) {
        const fifth = plainReturnAddress();
        const sixth = plainReturnAddress();
        try expect(fifth != sixth);
    }
}

fn sumTo(n: u32) u32 {
    var total: u32 = 0;
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        if (i % 3 == 0) continue;
        total += i;
        if (total > 1000) break;
    }
    return total;
}

fn findFirst(haystack: []const u8, needle: u8) ?usize {
    for (haystack, 0..) |c, i| {
        if (c == needle) return i;
    }
    return null;
}

test "callees with loops" {
    var n: u32 = 10;
    _ = &n;
    try expectEqual(@as(u32, 27), sumTo(n));
    try expectEqual(@as(u32, 1027), sumTo(n * 10));
    var total: u32 = 0;
    for (0..5) |i| total += sumTo(@intCast(i));
    try expectEqual(@as(u32, 7), total);
    try expectEqual(@as(?usize, 3), findFirst("abcdef", 'd'));
    try expectEqual(@as(?usize, null), findFirst("abcdef", 'z'));
}

const Shape = enum { circle, square, triangle, line };

fn corners(s: Shape) u32 {
    return switch (s) {
        .circle => 0,
        .square => 4,
        .triangle => 3,
        .line => 2,
    };
}

fn classify(x: u32) u8 {
    return switch (x) {
        0 => 'z',
        1...9 => 'd',
        10, 20, 30 => 't',
        else => 'o',
    };
}

test "callees with switch" {
    var s: Shape = .triangle;
    _ = &s;
    try expectEqual(@as(u32, 3), corners(s));
    try expectEqual(@as(u32, 4), corners(.square));
    var x: u32 = 20;
    _ = &x;
    try expectEqual(@as(u8, 't'), classify(x));
    try expectEqual(@as(u8, 'd'), classify(x - 15));
    try expectEqual(@as(u8, 'z'), classify(x - 20));
    try expectEqual(@as(u8, 'o'), classify(x + 1));
}

const ParseError = error{ Empty, BadDigit, Overflow };

fn parseDigit(c: u8) ParseError!u8 {
    if (c < '0' or c > '9') return error.BadDigit;
    return c - '0';
}

fn parseNumber(s: []const u8) ParseError!u8 {
    if (s.len == 0) return error.Empty;
    var value: u8 = 0;
    for (s) |c| {
        const digit = try parseDigit(c);
        value = std.math.mul(u8, value, 10) catch return error.Overflow;
        value = std.math.add(u8, value, digit) catch return error.Overflow;
    }
    return value;
}

test "callees with error unions" {
    try expectEqual(@as(u8, 42), try parseNumber("42"));
    try expectError(error.BadDigit, parseNumber("4x"));
    try expectError(error.Empty, parseNumber(""));
    try expectError(error.Overflow, parseNumber("300"));
    const fallback = parseNumber("x") catch |err| switch (err) {
        error.BadDigit => @as(u8, 1),
        else => 2,
    };
    try expectEqual(@as(u8, 1), fallback);
}

fn firstPositive(values: []const i32) ?i32 {
    for (values) |v| if (v > 0) return v;
    return null;
}

fn derefOr(p: ?*const u32, default: u32) u32 {
    const ptr = p orelse return default;
    return ptr.*;
}

test "callees with optionals" {
    const values = [_]i32{ -3, -1, 0, 9, 4 };
    try expectEqual(@as(?i32, 9), firstPositive(&values));
    try expectEqual(@as(?i32, null), firstPositive(values[0..3]));
    const five: u32 = 5;
    try expectEqual(@as(u32, 5), derefOr(&five, 1));
    try expectEqual(@as(u32, 1), derefOr(null, 1));
}

fn middle(s: []const u16) []const u16 {
    if (s.len < 2) return s;
    return s[1 .. s.len - 1];
}

fn sumSlice(s: []const u16) u32 {
    var total: u32 = 0;
    for (s) |v| total += v;
    return total;
}

test "callees with slices" {
    const data = [_]u16{ 1, 2, 3, 4, 5 };
    var len: usize = data.len;
    _ = &len;
    const m = middle(data[0..len]);
    try expectEqual(@as(usize, 3), m.len);
    try expectEqual(@as(u32, 9), sumSlice(m));
    try expectEqual(@as(u32, 15), sumSlice(data[0..len]));
    try expectEqual(@as(u32, 1), sumSlice(middle(data[0..1])));
}

fn mix(a: u64, b: u64) u64 {
    return (a *% 0x9e37_79b9_7f4a_7c15) ^ (b +% 0x632b_e59b);
}

test "many live values across inlined bodies" {
    var seed: u64 = 12345;
    _ = &seed;
    const v0 = mix(seed, 0);
    const v1 = mix(v0, 1);
    const v2 = mix(v1, 2);
    const v3 = mix(v2, 3);
    const v4 = mix(v3, 4);
    const v5 = mix(v4, 5);
    const v6 = mix(v5, 6);
    const v7 = mix(v6, 7);
    const v8 = mix(v7, 8);
    const v9 = mix(v8, 9);
    const v10 = mix(v9, 10);
    const v11 = mix(v10, 11);
    const v12 = mix(v11, 12);
    const v13 = mix(v12, 13);
    const v14 = mix(v13, 14);
    const v15 = mix(v14, 15);
    const v16 = mix(v15, 16);
    const v17 = mix(v16, 17);
    const v18 = mix(v17, 18);
    const v19 = mix(v18, 19);
    // Every value stays live until here, more than there are callee-saved
    // registers.
    const all = [_]u64{ v0, v1, v2, v3, v4, v5, v6, v7, v8, v9, v10, v11, v12, v13, v14, v15, v16, v17, v18, v19 };
    var expected = seed;
    for (all, 0..) |v, i| {
        expected = (expected *% 0x9e37_79b9_7f4a_7c15) ^ (@as(u64, i) +% 0x632b_e59b);
        try expectEqual(expected, v);
    }
    var x: f64 = 1.5;
    _ = &x;
    const f0 = scale(x, 2);
    const f1 = scale(f0, 3);
    const f2 = scale(f1, 4);
    const f3 = scale(f2, 5);
    const f4 = scale(f3, 6);
    const f5 = scale(f4, 7);
    const f6 = scale(f5, 8);
    const f7 = scale(f6, 9);
    const f8 = scale(f7, 10);
    const f9 = scale(f8, 11);
    try expectEqual(@as(f64, 3), f0);
    try expectEqual(f0 + f1 + f2 + f3 + f4 + f5 + f6 + f7 + f8 + f9, f9 + f8 + f7 + f6 + f5 + f4 + f3 + f2 + f1 + f0);
    try expectEqual(@as(f64, 1.5 * 39916800.0), f9);
}

fn scale(x: f64, by: f64) f64 {
    return x * by;
}

fn increment(p: *u32) void {
    p.* += 1;
}

fn addThrough(p: *u32, q: *const u32) void {
    p.* += q.*;
}

test "callees writing through pointers to caller locals" {
    var a: u32 = 1;
    increment(&a);
    increment(&a);
    try expectEqual(@as(u32, 3), a);
    addThrough(&a, &a);
    try expectEqual(@as(u32, 6), a);
    var array = [_]u32{ 1, 2, 3 };
    for (&array) |*e| increment(e);
    try expectEqual([_]u32{ 2, 3, 4 }, array);
}

fn localsInLoop(i: u32) u32 {
    var buf: [4]u32 = .{ i, i + 1, i + 2, i + 3 };
    buf[i & 3] = 100;
    return buf[0] + buf[1] + buf[2] + buf[3];
}

test "callee locals are fresh on every iteration of a calling loop" {
    var total: u32 = 0;
    var i: u32 = 0;
    while (i < 8) : (i += 1) total += localsInLoop(i);
    var expected: u32 = 0;
    i = 0;
    while (i < 8) : (i += 1) {
        expected += 4 * i + 6 - (i + (i & 3)) + 100;
    }
    try expectEqual(expected, total);
}

const Counter = struct {
    count: u32 = 0,
    fn bump(self: *Counter, by: u32) void {
        self.count += by;
    }
    fn get(self: Counter) u32 {
        return self.count;
    }
};

test "methods" {
    var c: Counter = .{};
    c.bump(3);
    c.bump(4);
    try expectEqual(@as(u32, 7), c.get());
}

fn voidCallee(p: *u8) void {
    if (p.* == 0) return;
    p.* -= 1;
}

fn errorOnly(fail: bool) error{Nope}!void {
    if (fail) return error.Nope;
}

test "callees returning void and error-only unions" {
    var b: u8 = 2;
    voidCallee(&b);
    voidCallee(&b);
    voidCallee(&b);
    try expectEqual(@as(u8, 0), b);
    try errorOnly(false);
    try expectError(error.Nope, errorOnly(true));
}

fn mayPanic(x: u32) u32 {
    if (x == 12345) @panic("unexpected");
    return x + 1;
}

fn blockResult(x: u32) u32 {
    const y = blk: {
        if (x > 10) break :blk x - 10;
        if (x == 0) break :blk 99;
        break :blk x * 2;
    };
    return y + mayPanic(y);
}

test "labeled blocks and cold panic paths in callees" {
    var x: u32 = 15;
    _ = &x;
    try expectEqual(@as(u32, 11), blockResult(x));
    try expectEqual(@as(u32, 199), blockResult(x - 15));
    try expectEqual(@as(u32, 17), blockResult(x - 11));
}

threadlocal var tls_counter: u32 = 0;
var global_counter: u32 = 0;

fn bumpGlobals(by: u32) u32 {
    tls_counter += by;
    global_counter += by * 2;
    return tls_counter + global_counter;
}

test "callees touching globals and threadlocals" {
    if (builtin.zig_backend == .stage2_spirv) return error.SkipZigTest;
    tls_counter = 0;
    global_counter = 0;
    try expectEqual(@as(u32, 3), bumpGlobals(1));
    try expectEqual(@as(u32, 6), bumpGlobals(1));
}

const Flags = packed struct(u8) {
    a: bool,
    b: u3,
    c: u4,
};

fn setB(f: Flags, b: u3) Flags {
    var r = f;
    r.b = b;
    return r;
}

test "packed struct callees" {
    var f: Flags = .{ .a = true, .b = 1, .c = 9 };
    f = setB(f, 6);
    try expectEqual(@as(u8, @bitCast(Flags{ .a = true, .b = 6, .c = 9 })), @as(u8, @bitCast(f)));
}

fn vecAdd(a: @Vector(4, u32), b: @Vector(4, u32)) @Vector(4, u32) {
    return a + b;
}

test "vector callees" {
    if (builtin.zig_backend == .stage2_spirv) return error.SkipZigTest;
    var a: @Vector(4, u32) = .{ 1, 2, 3, 4 };
    _ = &a;
    const r: [4]u32 = vecAdd(a, a);
    try expectEqual([4]u32{ 2, 4, 6, 8 }, r);
}

const Tagged = union(enum) {
    int: u32,
    float: f32,
    none,
};

fn tagValue(t: Tagged) u32 {
    return switch (t) {
        .int => |v| v,
        .float => |v| @intFromFloat(v),
        .none => 0,
    };
}

fn makeTagged(x: u32) Tagged {
    if (x == 0) return .none;
    if (x % 2 == 0) return .{ .float = @floatFromInt(x) };
    return .{ .int = x };
}

test "tagged union callees" {
    var x: u32 = 4;
    _ = &x;
    try expectEqual(@as(u32, 4), tagValue(makeTagged(x)));
    try expectEqual(@as(u32, 5), tagValue(makeTagged(x + 1)));
    try expectEqual(@as(u32, 0), tagValue(makeTagged(x - 4)));
}

fn callsThroughPointer(f: *const fn (u32) u32, x: u32) u32 {
    return f(x) + 1;
}

test "callee calling a function pointer argument" {
    var x: u32 = 2;
    _ = &x;
    try expectEqual(@as(u32, 7), callsThroughPointer(&identityTarget, x));
    try expectEqual(@as(u32, 4), callsThroughPointer(&addOne, x));
}

fn deepA(x: u32) u32 {
    return deepB(x) + 1;
}
fn deepB(x: u32) u32 {
    return deepC(x) * 2;
}
fn deepC(x: u32) u32 {
    return deepD(x) + 3;
}
fn deepD(x: u32) u32 {
    return x ^ 1;
}

test "a chain of nested callees" {
    var x: u32 = 4;
    _ = &x;
    try expectEqual(@as(u32, 17), deepA(x));
    try expectEqual(@as(u32, 10), deepB(x - 1));
}
