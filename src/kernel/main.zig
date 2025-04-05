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
const caps = @import("caps.zig");

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

    current_thread: ?*caps.Thread = null,
    id: u32,
};

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

    main();
}

fn main() noreturn {
    const log = std.log.scoped(.main);

    log.info("kernel main", .{});
    log.info("zig version: {s}", .{builtin.zig_version_string});
    log.info("kernel version: 0.0.2", .{});
    log.info("kernel git revision: {s}", .{std.mem.trimRight(u8, @embedFile("git-rev"), "\n\r")});

    // set up arch specific things: GDT, TSS, IDT, syscalls, ...
    log.info("initializing CPU", .{});
    const id = arch.next_cpu_id();
    arch.init_cpu(id) catch |err| {
        std.debug.panic("failed to initialize CPU-{}: {}", .{ id, err });
    };

    // initialize ACPI specific things: APIC, HPET, ...
    log.info("initializing ACPI", .{});
    acpi.init() catch |err| {
        std.debug.panic("failed to initialize ACPI: {any}", .{err});
    };

    // set things (like the global kernel address space) up for the capability system
    caps.init() catch |err| {
        std.debug.panic("failed to initialize CPU-{}: {}", .{ id, err });
    };

    // initialize and execute the bootstrap process
    log.info("initializing bootstrap", .{});
    init.exec() catch |err| {
        std.debug.panic("failed to set up init process: {}", .{err});
    };
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

            if (trap.arg0 == 0) {
                log.warn("log syscall string from nullptr", .{});
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
        .send => {
            const cap_ptr = trap.arg0;

            const locals = arch.cpu_local();
            const thread = locals.current_thread.?;

            thread.caps.ptr().caps[cap_ptr].call(
                thread,
                .{
                    .arg0 = trap.arg1,
                    .arg1 = trap.arg2,
                    .arg2 = trap.arg3,
                    .arg3 = trap.arg4,
                    .arg4 = trap.arg5,
                },
            ) catch |err| {
                trap.syscall_id = abi.sys.encode(err);
                return;
            };

            trap.syscall_id = abi.sys.encode(0);
        },
        .recv => {},
        .yield => {
            // proc.yield(current_pid, trap);
        },
        // else => std.debug.panic("TODO: syscall {s}", .{@tagName(id)}),
    }
}
