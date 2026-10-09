const std = @import("std");

pub fn panic(message: []const u8, stack_trace: ?*std.builtin.StackTrace, _: ?usize) noreturn {
    _ = stack_trace;
    if (std.mem.eql(u8, message, "attempt to use null value")) {
        std.process.exit(0);
    }
    std.process.exit(1);
}

pub fn main() !void {
    const xs = [_]?u32{ 1, 2, null };
    var sum: u32 = 0;
    for (xs) |x| sum += unwrap(x);
    if (sum == 0) return error.Whatever;
    return error.TestFailed;
}
fn unwrap(x: ?u32) u32 {
    return x.?;
}
// run
// backend=selfhosted,llvm
// target=x86_64-linux,aarch64-linux,wasm32-wasi
