const std = @import("std");
const root = @import("root");

const caps = @import("caps.zig");
const sys = @import("sys.zig");

//

pub var root_ipc: caps.Sender = .{ .cap = 0 };
pub var vm_ipc: caps.Sender = .{ .cap = 0 };
pub var vmem_handle: usize = 0;

pub fn installRuntime() void {
    @export(&_start, .{
        .name = "_start",
        .linkage = .strong,
    });
}

fn _start() callconv(.SysV) noreturn {
    std.log.info("entry", .{});
    root.main() catch |err| {
        std.debug.panic("{}", .{err});
    };

    sys.self_stop();
}
