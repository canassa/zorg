const std = @import("std");
const builtin = @import("builtin");
const expect = std.testing.expect;

test "thread local variable" {
    if (builtin.zig_backend == .stage2_wasm) return error.SkipZigTest; // TODO
    if (builtin.zig_backend == .stage2_arm) return error.SkipZigTest; // TODO
    if (builtin.zig_backend == .stage2_sparc64) return error.SkipZigTest; // TODO
    if (builtin.zig_backend == .stage2_riscv64) return error.SkipZigTest; // TODO

    const S = struct {
        threadlocal var t: i32 = 1234;
    };
    S.t += 1;
    try expect(S.t == 1235);
}

test "pointer to thread local array" {
    if (builtin.zig_backend == .stage2_wasm) return error.SkipZigTest; // TODO
    if (builtin.zig_backend == .stage2_arm) return error.SkipZigTest; // TODO
    if (builtin.zig_backend == .stage2_sparc64) return error.SkipZigTest; // TODO
    if (builtin.zig_backend == .stage2_spirv) return error.SkipZigTest;

    const s = "Hello world";
    @memcpy(buffer[0..s.len], s);
    try std.testing.expectEqualSlices(u8, buffer[0..], s);
}

threadlocal var buffer: [11]u8 = undefined;

test "reference a global threadlocal variable" {
    if (builtin.zig_backend == .stage2_wasm) return error.SkipZigTest; // TODO
    if (builtin.zig_backend == .stage2_arm) return error.SkipZigTest; // TODO
    if (builtin.zig_backend == .stage2_sparc64) return error.SkipZigTest; // TODO
    if (builtin.zig_backend == .stage2_spirv) return error.SkipZigTest;

    try nrfx_uart_rx(&g_uart0);
}

const nrfx_uart_t = extern struct {
    p_reg: [*c]u32,
    drv_inst_idx: u8,
};

pub fn nrfx_uart_rx(p_instance: [*c]const nrfx_uart_t) !void {
    try expect(p_instance.*.p_reg == 0);
    try expect(p_instance.*.drv_inst_idx == 0xab);
}

threadlocal var g_uart0 = nrfx_uart_t{
    .p_reg = 0,
    .drv_inst_idx = 0xab,
};

threadlocal var tls_initialized: u64 = 0x123456789abcdef0;
threadlocal var tls_zero: u64 = 0;
threadlocal var tls_aligned: [8192]u8 align(4096) = @splat(0x19);

test "threadlocal variables are distinct in each thread" {
    if (builtin.single_threaded) return error.SkipZigTest;
    if (builtin.zig_backend == .stage2_x86_64 and builtin.os.tag == .macos) return error.SkipZigTest;
    if (builtin.zig_backend == .stage2_sparc64) return error.SkipZigTest; // TODO
    if (builtin.zig_backend == .stage2_spirv) return error.SkipZigTest;

    const S = struct {
        const Result = struct { address: usize = 0, ok: bool = false };
        // Keep every thread alive until all have recorded their addresses.
        var ready: std.atomic.Value(u32) = .init(0);
        var released: std.atomic.Value(bool) = .init(false);
        noinline fn member() *u8 {
            return &tls_aligned[4097];
        }
        fn worker(index: usize, result: *Result) void {
            const initial = tls_initialized == 0x123456789abcdef0 and tls_zero == 0 and
                member().* == 0x19;
            tls_initialized = 100 + index;
            tls_zero = 200 + index;
            member().* = @intCast(30 + index);
            result.* = .{
                .address = @intFromPtr(&tls_initialized),
                .ok = initial and tls_initialized == 100 + index and tls_zero == 200 + index and
                    member().* == 30 + index and
                    @intFromPtr(&tls_aligned) % 4096 == 0,
            };
            _ = ready.fetchAdd(1, .release);
            while (!released.load(.acquire)) std.atomic.spinLoopHint();
        }
    };
    tls_initialized = 0xfedcba9876543210;
    tls_zero = 999;
    S.member().* = 99;
    var results: [4]S.Result = @splat(.{});
    var threads: [4]std.Thread = undefined;
    for (&threads, 0..) |*thread, index| thread.* = try std.Thread.spawn(.{}, S.worker, .{ index, &results[index] });
    while (S.ready.load(.acquire) != threads.len) std.atomic.spinLoopHint();
    S.released.store(true, .release);
    for (threads) |thread| thread.join();
    for (results, 0..) |result, index| {
        try expect(result.ok);
        try expect(result.address != @intFromPtr(&tls_initialized));
        for (results[0..index]) |previous| try expect(previous.address != result.address);
    }
    try expect(tls_initialized == 0xfedcba9876543210 and tls_zero == 999 and S.member().* == 99);
}
