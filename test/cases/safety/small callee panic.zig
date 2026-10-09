const std = @import("std");

pub fn panic(message: []const u8, stack_trace: ?*std.builtin.StackTrace, _: ?usize) noreturn {
    _ = stack_trace;
    if (std.mem.eql(u8, message, "small callee says no")) {
        std.process.exit(0);
    }
    std.process.exit(1);
}

pub fn main() !void {
    var n: u32 = 0;
    while (true) {
        n = step(n);
    }
}
fn step(n: u32) u32 {
    if (n == 3) @panic("small callee says no");
    return n + 1;
}
// run
// backend=selfhosted,llvm
// target=x86_64-linux,aarch64-linux,wasm32-wasi
