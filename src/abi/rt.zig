const std = @import("std");
const root = @import("root");

const caps = @import("caps.zig");
const sys = @import("sys.zig");

//

pub var root_ipc: caps.Sender = .{ .cap = 0 };

pub fn installRuntime() void {
    @export(&_start, .{
        .name = "_start",
        .linkage = .strong,
    });
}

fn _start(rdi: u64) callconv(.SysV) noreturn {
    root_ipc = .{ .cap = @truncate(rdi) };

    root.main() catch |err| {
        std.debug.panic("{}", .{err});
    };

    while (true) {
        sys.yield();
    }
}
