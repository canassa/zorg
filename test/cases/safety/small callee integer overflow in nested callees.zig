const std = @import("std");

pub fn panic(message: []const u8, stack_trace: ?*std.builtin.StackTrace, _: ?usize) noreturn {
    _ = stack_trace;
    if (std.mem.eql(u8, message, "integer overflow")) {
        std.process.exit(0);
    }
    std.process.exit(1);
}

pub fn main() !void {
    if (outer(100) == 0) return error.Whatever;
    if (outer(200) == 0) return error.Whatever;
    return error.TestFailed;
}
fn outer(x: u8) u8 {
    return middle(x) +% 1;
}
fn middle(x: u8) u8 {
    return inner(x, x / 2);
}
fn inner(a: u8, b: u8) u8 {
    return a + b;
}
// run
// backend=selfhosted,llvm
// target=x86_64-linux,aarch64-linux,wasm32-wasi
