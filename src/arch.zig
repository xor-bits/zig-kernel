const std = @import("std");
const builtin = @import("builtin");

const pmem = @import("pmem.zig");

pub const x86_64 = @import("arch/x86_64.zig");

//

/// Halt and Catch Fire
pub inline fn hcf() noreturn {
    // std.log.info("{*}", .{&x86_64.interrupt});
    if (builtin.cpu.arch == .x86_64) {
        x86_64.hcf();
    }
}

pub inline fn init() error{OutOfMemory}!void {
    const cpu_id = cpu_id_next.fetchAdd(1, .monotonic);

    if (builtin.cpu.arch == .x86_64) {
        const cpu = try pmem.page_allocator.create(x86_64.CpuConfig);
        cpu.init(cpu_id);
        // leak the cpu config, because GDT and IDT are permanent
    }
}
var cpu_id_next = std.atomic.Value(usize).init(0);

pub inline fn reset() void {
    if (builtin.cpu.arch == .x86_64) {
        x86_64.reset();
    }
}
