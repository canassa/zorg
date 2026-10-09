const std = @import("std");

pub fn panic(message: []const u8, stack_trace: ?*std.builtin.StackTrace, _: ?usize) noreturn {
    _ = stack_trace;
    if (std.mem.eql(u8, message, "integer overflow")) {
        std.process.exit(0);
    }
    std.process.exit(1);
}

pub fn main() !void {
    var total: u8 = 0;
    var i: u8 = 0;
    while (i < 10) : (i += 1) {
        total = add(total, 30);
    }
    return error.TestFailed;
}
fn add(a: u8, b: u8) u8 {
    return a + b;
}
// run
// backend=selfhosted,llvm
// target=x86_64-linux,aarch64-linux,wasm32-wasi
