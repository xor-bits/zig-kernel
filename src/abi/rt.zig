const std = @import("std");
const root = @import("root");

const caps = @import("caps.zig");
const sys = @import("sys.zig");
const thread = @import("thread.zig");

//

pub var root_ipc: caps.Sender = .{ .cap = 0 };
pub var vm_ipc: caps.Sender = .{ .cap = 0 };
pub var vmem_handle: usize = 0;

pub fn installRuntime() void {
    // ??? wtf zig
    // export fn doesnt work without this random empty function that is called in comptime
}

pub export fn _start() callconv(.SysV) noreturn {
    thread.callFn(root.main, .{});
    sys.selfStop();
}
