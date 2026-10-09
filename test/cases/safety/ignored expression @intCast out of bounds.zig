const std = @import("std");

pub fn panic(message: []const u8, stack_trace: ?*std.builtin.StackTrace, _: ?usize) noreturn {
    _ = stack_trace;
    if (std.mem.eql(u8, message, "integer does not fit in destination type")) {
        std.process.exit(0);
    }
    std.process.exit(1);
}

pub fn main() !void {
    var x: u32 = undefined;
    x = 300;
    // We ignore this result but it should still trigger a safety panic!
    _ = @as(u8, @intCast(x));
    return error.TestFailed;
}

// run
// backend=selfhosted,llvm
// target=x86_64-linux,aarch64-linux,wasm32-wasi
