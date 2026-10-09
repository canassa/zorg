const std = @import("std");

pub fn panic(message: []const u8, stack_trace: ?*std.builtin.StackTrace, _: ?usize) noreturn {
    _ = stack_trace;
    if (std.mem.eql(u8, message, "integer overflow")) {
        std.process.exit(0);
    }
    std.process.exit(1);
}

pub fn main() !void {
    @setRuntimeSafety(false);
    var x: u8 = 250;
    _ = &x;
    const y = add(x, 10);
    if (y == 4) return error.Whatever;
    return error.TestFailed;
}
fn add(a: u8, b: u8) u8 {
    return a + b;
}
// run
// backend=selfhosted,llvm
// target=x86_64-linux,aarch64-linux,wasm32-wasi
