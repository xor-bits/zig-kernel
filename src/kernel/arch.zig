const std = @import("std");
const builtin = @import("builtin");

const pmem = @import("pmem.zig");
const main = @import("main.zig");

pub const x86_64 = @import("arch/x86_64.zig");

//

usingnamespace x86_64;

/// Halt and Catch Fire
pub inline fn hcf() noreturn {
    if (builtin.cpu.arch == .x86_64) {
        x86_64.hcf();
    }
}

pub inline fn init() error{OutOfMemory}!void {
    const _cpu_id = cpu_id_next.fetchAdd(1, .monotonic);

    if (builtin.cpu.arch == .x86_64) {
        const cpu = try pmem.page_allocator.create(x86_64.CpuConfig);
        cpu.init(_cpu_id);
        // leak the cpu config, because GDT and IDT are permanent
    }
}
var cpu_id_next = std.atomic.Value(u32).init(0);

pub inline fn local_storage() *main.CpuLocalStorage {}

pub inline fn cpu_id() u32 {
    if (builtin.cpu.arch == .x86_64) {
        return x86_64.cpu_id();
    }
}

pub inline fn reset() void {
    if (builtin.cpu.arch == .x86_64) {
        x86_64.reset();
    }
}

pub const SyscallRegs = if (builtin.cpu.arch == .x86_64) x86_64.SyscallRegs else @compileError("todo");
