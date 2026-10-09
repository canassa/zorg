const std = @import("std");

pub fn panic(message: []const u8, stack_trace: ?*std.builtin.StackTrace, _: ?usize) noreturn {
    _ = stack_trace;
    if (std.mem.eql(u8, message, "index out of bounds: index 5, len 5")) {
        std.process.exit(0);
    }
    std.process.exit(1);
}

pub fn main() !void {
    var arr = [_]u32{ 1, 2, 3, 4, 5 };
    var sum: u32 = 0;
    var i: usize = 0;
    while (i <= arr.len) : (i += 1) {
        sum += at(&arr, i);
    }
    if (sum == 0) return error.Whatever;
    return error.TestFailed;
}
fn at(xs: []const u32, i: usize) u32 {
    return xs[i];
}
// run
// backend=selfhosted,llvm
// target=x86_64-linux,aarch64-linux,wasm32-wasi
