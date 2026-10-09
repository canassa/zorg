const std = @import("std");

pub fn panic(message: []const u8, stack_trace: ?*std.builtin.StackTrace, _: ?usize) noreturn {
    _ = stack_trace;
    if (std.mem.eql(u8, message, "index out of bounds: index 4, len 4")) {
        std.process.exit(0);
    }
    std.process.exit(1);
}

pub fn main() !void {
    var x: u8 = 250;
    _ = &x;
    // The callee's arithmetic is unchecked, so it must not panic with "integer overflow".
    std.mem.doNotOptimizeAway(uncheckedAdd(x, 10));
    // The caller's own operations are still checked.
    const arr = [_]u8{ 1, 2, 3, 4 };
    var i: usize = 4;
    _ = &i;
    std.mem.doNotOptimizeAway(arr[i]);
    return error.TestFailed;
}
fn uncheckedAdd(a: u8, b: u8) u8 {
    @setRuntimeSafety(false);
    return a + b;
}
// run
// backend=selfhosted,llvm
// target=x86_64-linux,aarch64-linux,wasm32-wasi
