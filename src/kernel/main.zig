const std = @import("std");
const builtin = @import("builtin");
const abi = @import("abi");
const limine = @import("limine");

const acpi = @import("acpi.zig");
const arch = @import("arch.zig");
const args = @import("args.zig");
const addr = @import("addr.zig");
const logs = @import("logs.zig");
const spin = @import("spin.zig");
const util = @import("util.zig");
const init = @import("init.zig");

//

pub const std_options = logs.std_options;
pub const panic = logs.panic;

//

pub export var base_revision: limine.BaseRevision = .{ .revision = 2 };
pub export var hhdm: limine.HhdmRequest = .{};
pub export var smp: limine.SmpRequest = .{};
pub var cpus_initialized: std.atomic.Value(usize) = .{ .raw = 0 };
pub var all_cpus_ininitalized: std.atomic.Value(bool) = .{ .raw = false };

pub var hhdm_offset = std.atomic.Value(usize).init(undefined);

pub const CpuLocalStorage = struct {
    // used to read the pointer to this struct through GS
    self_ptr: *CpuLocalStorage,

    cpu_config: arch.CpuConfig,

    current_pid: ?usize = null,
    id: u32,
};

/// forms a tree of capabilities
pub const Capabilities = struct {
    // N capabilities based on how many can fit in a page
    caps: [0x1000 / @sizeOf(Object)]Object,
};

pub const BootInfo = struct {};

/// raw physical memory that can be used to allocate
/// things like more `CapabilityNode`s or things
pub const Memory = struct {};

/// thread information
pub const Thread = struct {
    trap: arch.SyscallRegs,
    caps: Capability(Capabilities),
    vmem: Capability(PageTableLevel4),
    priority: u2,
};

/// a `Thread` points to this
pub const PageTableLevel4 = struct {};
/// a `PageTableLevel4` points to multiple of these
pub const PageTableLevel3 = struct {};
/// a `PageTableLevel3` points to multiple of these
pub const PageTableLevel2 = struct {};
/// a `PageTableLevel2` points to multiple of these
pub const PageTableLevel1 = struct {};
/// a `PageTableLevel1` points to multiple of these
///
/// raw physical memory again, but now mappable
/// (and can't be used to allocate things)
pub const Frame = struct {};

pub fn Capability(comptime T: type) type {
    return struct {
        paddr: usize,

        pub fn ptr(self: @This()) *T {
            // recursive mapping instead of HHDM later (maybe)
            self.paddr;
        }
    };
}

pub const Object = struct {
    paddr: usize,
    type: enum {
        capabilities,
        boot_info,
        memory,
        thread,
        page_table_level_4,
        page_table_level_3,
        page_table_level_2,
        page_table_level_1,
        frame,
    },
};

fn debug_type(comptime T: type) void {
    std.log.info("{s}: size={} align={}", .{ @typeName(T), @sizeOf(T), @alignOf(T) });
}

//

export fn _start() callconv(.C) noreturn {
    const log = std.log.scoped(.critical);

    // interrupts are always disabled in the kernel
    // there is just one exception to this:
    // waiting while the CPU is out of tasks
    //
    // initializing GDT also requires interrupts to be disabled
    arch.x86_64.ints.disable();

    // crash if bootloader is unsupported
    if (!base_revision.is_supported()) {
        log.err("bootloader unsupported", .{});
        arch.hcf();
    }

    const hhdm_response = hhdm.response orelse {
        log.err("no HHDM", .{});
        arch.hcf();
    };
    hhdm_offset.store(hhdm_response.offset, .seq_cst);
    @fence(.seq_cst);

    main();
}

fn main() noreturn {
    const log = std.log.scoped(.main);

    log.info("kernel main", .{});
    log.info("zig version: {s}", .{builtin.zig_version_string});
    log.info("kernel version: 0.0.2", .{});
    log.info("kernel git revision: {s}", .{std.mem.trimRight(u8, @embedFile("git-rev"), "\n\r")});

    debug_type(Object);
    debug_type(Capabilities);
    std.log.info("Capabilities: len={}", .{@as(Capabilities, undefined).caps.len});
    debug_type(Thread);
    debug_type(Frame);

    init.init() catch |err| {
        std.debug.panic("failed to set up init process: {}", .{err});
    };

    const kernel_args = args.parse() catch |err| {
        std.debug.panic("invalid kernel cmdline: {}", .{err});
    };
    _ = kernel_args;

    while (true) {}
}

pub fn syscall(trap: *arch.SyscallRegs) void {
    const log = std.log.scoped(.syscall);

    // TODO: once every CPU has reached this, bootloader_reclaimable memory could be freed
    // just some few things need to be copied, but the page map(s) and stack(s) are already copied

    const id = std.meta.intToEnum(abi.sys.Id, trap.syscall_id) catch {
        log.warn("invalid syscall: {x}", .{trap.syscall_id});
        trap.syscall_id = abi.sys.encode(abi.sys.Error.UnknownProtocol);
        return;
    };

    // log.debug("syscall: {s}", .{@tagName(id)});
    // defer log.debug("syscall done", .{});
    switch (id) {
        .log => {
            // FIXME: disable on release builds

            // log syscall
            if (trap.arg1 > 0x1000) {
                log.warn("log syscall too long", .{});
                trap.syscall_id = abi.sys.encode(abi.sys.Error.InvalidArgument);
                return;
            }

            const end = std.math.add(u64, trap.arg0, trap.arg1) catch {
                log.warn("log syscall string outside of 64 bit range", .{});
                trap.syscall_id = abi.sys.encode(abi.sys.Error.InvalidArgument);
                return;
            };

            if (end >= 0x8000_0000_0000) {
                log.warn("log syscall string outside of user space", .{});
                trap.syscall_id = abi.sys.encode(abi.sys.Error.InvalidAddress);
                return;
            }

            const msg = @as([*]const u8, @ptrFromInt(trap.arg0))[0..trap.arg1];

            var lines = std.mem.splitAny(u8, msg, "\n\r");
            while (lines.next()) |line| {
                if (line.len == 0) {
                    continue;
                }
                _ = log.info("{s}", .{line});
            }
        },
        .yield => {
            // proc.yield(current_pid, trap);
        },
        else => std.debug.panic("TODO", .{}),
    }
}
