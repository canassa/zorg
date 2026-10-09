const std = @import("std");

pub fn panic(message: []const u8, stack_trace: ?*std.builtin.StackTrace, _: ?usize) noreturn {
    _ = stack_trace;
    if (std.mem.eql(u8, message, "reached unreachable code")) {
        std.process.exit(0);
    }
    std.process.exit(1);
}

pub fn main() !void {
    _ = check(1);
    _ = check(2);
    _ = check(0);
    return error.TestFailed;
}
fn check(x: u32) u32 {
    if (x == 0) unreachable;
    return 100 / x;
}
// run
// backend=selfhosted,llvm
// target=x86_64-linux,aarch64-linux,wasm32-wasi
