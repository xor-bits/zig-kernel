const std = @import("std");
const root = @import("root");

const sys = @import("sys.zig");

//

pub fn install_rt() void {
    @export(&_start, .{
        .name = "_start",
        .linkage = .strong,
    });
}

fn _start() callconv(.C) noreturn {
    root.main() catch |err| {
        std.debug.panic("{}", .{err});
    };

    while (true) {
        sys.yield();
    }
}
