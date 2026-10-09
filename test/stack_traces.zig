const std = @import("std");
const Context = @import("tests.zig").StackTracesContext;

pub fn addCases(cases: *Context, params: *const Context.CaseParameters, target: *const std.Target) void {
    cases.addCase(.{
        .params = params,
        .target = target,
        .name = "simple panic",
        .source =
        \\pub fn main() void {
        \\    foo();
        \\}
        \\fn foo() void {
        \\    @panic("oh no");
        \\}
        \\
        ,
        .unwind = .any,
        .expect_panic = true,
        .expect =
        \\panic: oh no
        \\source.zig:5:5: [address] in foo
        \\    @panic("oh no");
        \\    ^
        \\source.zig:2:8: [address] in main
        \\    foo();
        \\       ^
        \\
        ,
        .expect_strip =
        \\panic: oh no
        \\???:?:?: [address] in source.foo
        \\???:?:?: [address] in source.main
        \\
        ,
    });

    cases.addCase(.{
        .params = params,
        .target = target,
        .name = "simple panic with no unwind strategy",
        .source =
        \\pub fn main() void {
        \\    foo();
        \\}
        \\fn foo() void {
        \\    @panic("oh no");
        \\}
        \\
        ,
        .unwind = .none,
        .expect_panic = true,
        .expect = "panic: oh no",
        .expect_strip = "panic: oh no",
    });

    cases.addCase(.{
        .params = params,
        .target = target,
        .name = "panic in inlined callees",
        .source =
        \\pub fn main() void {
        \\    foo();
        \\}
        \\inline fn foo() void {
        \\    bar();
        \\}
        \\inline fn bar() void {
        \\    @panic("oh no");
        \\}
        \\
        ,
        .unwind = .any,
        .expect_panic = true,
        .expect =
        \\panic: oh no
        \\source.zig:8:5: [address] in bar
        \\    @panic("oh no");
        \\    ^
        \\source.zig:5:8: [address] in foo
        \\    bar();
        \\       ^
        \\source.zig:2:8: [address] in main
        \\    foo();
        \\       ^
        \\
        ,
        .expect_strip =
        \\panic: oh no
        \\???:?:?: [address] in source.main
        \\
        ,
    });

    cases.addCase(.{
        .params = params,
        .target = target,
        .name = "dump current trace",
        .source =
        \\pub fn main() void {
        \\    foo(bar());
        \\}
        \\fn bar() void {
        \\    qux(123);
        \\}
        \\fn foo(_: void) void {}
        \\fn qux(x: u32) void {
        \\    std.debug.dumpCurrentStackTrace(.{});
        \\    _ = x;
        \\}
        \\const std = @import("std");
        \\
        ,
        .unwind = .safe,
        .expect_panic = false,
        .expect =
        \\source.zig:9:36: [address] in qux
        \\    std.debug.dumpCurrentStackTrace(.{});
        \\                                   ^
        \\source.zig:5:8: [address] in bar
        \\    qux(123);
        \\       ^
        \\source.zig:2:12: [address] in main
        \\    foo(bar());
        \\           ^
        \\
        ,
        .expect_strip =
        \\???:?:?: [address] in source.qux
        \\???:?:?: [address] in source.bar
        \\???:?:?: [address] in source.main
        \\
        ,
    });

    cases.addCase(.{
        .params = params,
        .target = target,
        .name = "dump current trace with no unwind strategy",
        .source =
        \\pub fn main() void {
        \\    foo(bar());
        \\}
        \\fn bar() void {
        \\    qux(123);
        \\}
        \\fn foo(_: void) void {}
        \\fn qux(x: u32) void {
        \\    std.debug.print("pre\n", .{});
        \\    std.debug.dumpCurrentStackTrace(.{});
        \\    std.debug.print("post\n", .{});
        \\    _ = x;
        \\}
        \\const std = @import("std");
        \\
        ,
        .unwind = .no_safe,
        .expect_panic = false,
        .expect = "pre\npost\n",
        .expect_strip = "pre\npost\n",
    });

    cases.addCase(.{
        .params = params,
        .target = target,
        .name = "dump captured trace",
        .source =
        \\pub fn main() void {
        \\    var stack_trace_buf: [8]usize = undefined;
        \\    dumpIt(&captureIt(&stack_trace_buf));
        \\}
        \\fn captureIt(buf: []usize) std.debug.StackTrace {
        \\    return captureItInner(buf);
        \\}
        \\fn dumpIt(st: *const std.debug.StackTrace) void {
        \\    std.debug.dumpStackTrace(st);
        \\}
        \\fn captureItInner(buf: []usize) std.debug.StackTrace {
        \\    return std.debug.captureCurrentStackTrace(.{}, buf);
        \\}
        \\const std = @import("std");
        \\
        ,
        .unwind = .safe,
        .expect_panic = false,
        .expect =
        \\source.zig:12:46: [address] in captureItInner
        \\    return std.debug.captureCurrentStackTrace(.{}, buf);
        \\                                             ^
        \\source.zig:6:26: [address] in captureIt
        \\    return captureItInner(buf);
        \\                         ^
        \\source.zig:3:22: [address] in main
        \\    dumpIt(&captureIt(&stack_trace_buf));
        \\                     ^
        \\
        ,
        .expect_strip =
        \\???:?:?: [address] in source.captureItInner
        \\???:?:?: [address] in source.captureIt
        \\???:?:?: [address] in source.main
        \\
        ,
    });

    cases.addCase(.{
        .params = params,
        .target = target,
        .name = "dump captured trace with no unwind strategy",
        .source =
        \\pub fn main() void {
        \\    var stack_trace_buf: [8]usize = undefined;
        \\    dumpIt(&captureIt(&stack_trace_buf));
        \\}
        \\fn captureIt(buf: []usize) std.debug.StackTrace {
        \\    return captureItInner(buf);
        \\}
        \\fn dumpIt(st: *const std.debug.StackTrace) void {
        \\    std.debug.dumpStackTrace(st);
        \\}
        \\fn captureItInner(buf: []usize) std.debug.StackTrace {
        \\    return std.debug.captureCurrentStackTrace(.{}, buf);
        \\}
        \\const std = @import("std");
        \\
        ,
        .unwind = .no_safe,
        .expect_panic = false,
        .expect = "(empty stack trace)\n",
        .expect_strip = "(empty stack trace)\n",
    });

    cases.addCase(.{
        .params = params,
        .target = target,
        .name = "dump captured trace on thread",
        .source =
        \\pub fn main() !void {
        \\    var stack_trace_buf: [8]usize = undefined;
        \\    const t = try std.Thread.spawn(.{}, threadMain, .{&stack_trace_buf});
        \\    t.join();
        \\}
        \\fn threadMain(stack_trace_buf: []usize) void {
        \\    dumpIt(&captureIt(stack_trace_buf));
        \\}
        \\fn captureIt(buf: []usize) std.debug.StackTrace {
        \\    return captureItInner(buf);
        \\}
        \\fn dumpIt(st: *const std.debug.StackTrace) void {
        \\    std.debug.dumpStackTrace(st);
        \\}
        \\fn captureItInner(buf: []usize) std.debug.StackTrace {
        \\    return std.debug.captureCurrentStackTrace(.{}, buf);
        \\}
        \\const std = @import("std");
        \\
        ,
        .unwind = .safe,
        .expect_panic = false,
        .expect =
        \\source.zig:16:46: [address] in captureItInner
        \\    return std.debug.captureCurrentStackTrace(.{}, buf);
        \\                                             ^
        \\source.zig:10:26: [address] in captureIt
        \\    return captureItInner(buf);
        \\                         ^
        \\source.zig:7:22: [address] in threadMain
        \\    dumpIt(&captureIt(stack_trace_buf));
        \\                     ^
        \\
        ,
        .expect_strip =
        \\???:?:?: [address] in source.captureItInner
        \\???:?:?: [address] in source.captureIt
        \\???:?:?: [address] in source.threadMain
        \\
        ,
    });

    // A small, ordinary callee is a candidate for automatic inlining by the
    // compiler. Whether or not that happens, the trace must show the callee's
    // line first and then the line of the call that failed.
    cases.addCase(.{
        .params = params,
        .target = target,
        .name = "panic in small callee called twice",
        .source =
        \\pub fn main() void {
        \\    var x: u32 = 1;
        \\    _ = &x;
        \\    _ = check(x);
        \\    _ = check(x - 1);
        \\}
        \\fn check(x: u32) u32 {
        \\    if (x == 0) @panic("zero");
        \\    return x;
        \\}
        \\
        ,
        .unwind = .any,
        .expect_panic = true,
        .expect =
        \\panic: zero
        \\source.zig:8:17: [address] in check
        \\    if (x == 0) @panic("zero");
        \\                ^
        \\source.zig:5:14: [address] in main
        \\    _ = check(x - 1);
        \\             ^
        \\
        ,
        .expect_strip =
        \\panic: zero
        \\???:?:?: [address] in source.check
        \\???:?:?: [address] in source.main
        \\
        ,
    });

    cases.addCase(.{
        .params = params,
        .target = target,
        .name = "integer overflow in nested small callees",
        .source =
        \\pub fn main() void {
        \\    var x: u8 = 200;
        \\    _ = &x;
        \\    _ = outer(x);
        \\}
        \\fn outer(x: u8) u8 {
        \\    return inner(x, x);
        \\}
        \\fn inner(a: u8, b: u8) u8 {
        \\    return a + b;
        \\}
        \\
        ,
        .unwind = .any,
        .expect_panic = true,
        .expect =
        \\panic: integer overflow
        \\source.zig:10:14: [address] in inner
        \\    return a + b;
        \\             ^
        \\source.zig:7:17: [address] in outer
        \\    return inner(x, x);
        \\                ^
        \\source.zig:4:14: [address] in main
        \\    _ = outer(x);
        \\             ^
        \\
        ,
        .expect_strip =
        \\panic: integer overflow
        \\???:?:?: [address] in source.inner
        \\???:?:?: [address] in source.outer
        \\???:?:?: [address] in source.main
        \\
        ,
    });

    cases.addCase(.{
        .params = params,
        .target = target,
        .name = "index out of bounds in small callee called from a loop",
        .source =
        \\pub fn main() void {
        \\    const xs = [_]u32{ 1, 2, 3 };
        \\    var sum: u32 = 0;
        \\    for (0..4) |i| {
        \\        sum += at(&xs, i);
        \\    }
        \\    if (sum == 0) unreachable;
        \\}
        \\fn at(xs: []const u32, i: usize) u32 {
        \\    return xs[i];
        \\}
        \\
        ,
        .unwind = .any,
        .expect_panic = true,
        .expect =
        \\panic: index out of bounds: index 3, len 3
        \\source.zig:10:14: [address] in at
        \\    return xs[i];
        \\             ^
        \\source.zig:5:18: [address] in main
        \\        sum += at(&xs, i);
        \\                 ^
        \\
        ,
        .expect_strip =
        \\panic: index out of bounds: index 3, len 3
        \\???:?:?: [address] in source.at
        \\???:?:?: [address] in source.main
        \\
        ,
    });

    cases.addCase(.{
        .params = params,
        .target = target,
        .name = "simple inline panic",
        // The main function has two inline calls to ensure
        // that inlinees in PDBs are properly deduplicated.
        .source =
        \\pub fn main() void {
        \\    foo(false);
        \\    foo(true);
        \\}
        \\inline fn foo(b: bool) void {
        \\    if (b) @panic("oh no");
        \\}
        \\
        ,
        .unwind = .any,
        .expect_panic = true,
        .expect = switch (target.os.tag) {
            // LLVM doesn't emit column info in the binary annotations for inlinee callees in PDBs,
            // so the first location has only a row.
            .windows =>
            \\panic: oh no
            \\source.zig:6: [address] in foo
            \\    if (b) @panic("oh no");
            \\
            \\source.zig:3:8: [address] in main
            \\    foo(true);
            \\       ^
            \\
            ,
            // On all other platforms, we resolve the innermost inline callee but we don't yet
            // resolve the inline callers.
            else =>
            \\panic: oh no
            \\source.zig:6:12: [address] in foo
            \\    if (b) @panic("oh no");
            \\           ^
            ,
        },
        .expect_strip = switch (target.os.tag) {
            .windows =>
            \\panic: oh no
            \\???:?:?: [address] in source.foo
            \\???:?:?: [address] in source.main
            \\
            ,
            else =>
            \\panic: oh no
            \\???:?:?: [address] in source.foo
            \\
            ,
        },
    });

    // Make sure all inline calls are resolved and in the right order!
    cases.addCase(.{
        .params = params,
        .target = target,
        .name = "nested inline panic",
        .source =
        \\pub fn main() void {
        \\    foo();
        \\}
        \\inline fn foo() void {
        \\    bar();
        \\}
        \\inline fn bar() void {
        \\    baz();
        \\}
        \\inline fn baz() void {
        \\    @panic("oh no");
        \\}
        \\
        ,
        .unwind = .any,
        .expect_panic = true,
        // This switch serves a similar purpose as in "inline panic".
        .expect = switch (target.os.tag) {
            .windows =>
            \\panic: oh no
            \\source.zig:11: [address] in baz
            \\    @panic("oh no");
            \\
            \\source.zig:8: [address] in bar
            \\    baz();
            \\
            \\source.zig:5: [address] in foo
            \\    bar();
            \\
            \\source.zig:2:8: [address] in main
            \\    foo();
            \\       ^
            \\
            ,
            else =>
            \\panic: oh no
            \\source.zig:11:5: [address] in baz
            \\    @panic("oh no");
            \\    ^
            ,
        },
        .expect_strip = switch (target.os.tag) {
            .windows =>
            \\panic: oh no
            \\???:?:?: [address] in baz
            \\???:?:?: [address] in bar
            \\???:?:?: [address] in foo
            \\???:?:?: [address] in main
            \\
            ,
            else =>
            \\panic: oh no
            \\???:?:?: [address] in baz
            \\
            ,
        },
    });
}
