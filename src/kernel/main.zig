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
const proc = @import("proc.zig");
const util = @import("util.zig");
const init = @import("init.zig");
const caps = @import("caps.zig");
const pmem = @import("pmem.zig");

//

pub const std_options = logs.std_options;
pub const panic = logs.panic;

//

pub export var base_revision: limine.BaseRevision = .{ .revision = 2 };
pub export var hhdm: limine.HhdmRequest = .{};
pub var cpus_initialized: std.atomic.Value(usize) = .{ .raw = 0 };
pub var all_cpus_ininitalized: std.atomic.Value(bool) = .{ .raw = false };

pub var hhdm_offset: usize = 0xFFFF_8000_0000_0000;

pub const CpuLocalStorage = struct {
    // used to read the pointer to this struct through GS
    self_ptr: *CpuLocalStorage,

    cpu_config: arch.CpuConfig,

    current_thread: ?*caps.Thread = null,
    id: u32,
};

//

pub export fn _start() callconv(.C) noreturn {
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
    hhdm_offset = hhdm_response.offset;

    main();
}

pub fn main() noreturn {
    const log = std.log.scoped(.main);

    log.info("kernel main", .{});
    log.info("zig version: {s}", .{builtin.zig_version_string});
    log.info("kernel version: 0.0.2{s}", .{if (builtin.is_test) "-testing" else ""});
    log.info("kernel git revision: {s}", .{comptime std.mem.trimRight(u8, @embedFile("git-rev"), "\n\r")});

    log.info("initializing physical memory allocator", .{});
    pmem.init() catch |err| {
        std.debug.panic("failed to initialize PMM: {}", .{err});
    };

    // boot up a few processors
    // arch.smp_init();

    // set up arch specific things: GDT, TSS, IDT, syscalls, ...
    const id = arch.next_cpu_id();
    log.info("initializing CPU-{}", .{id});
    arch.init_cpu(id) catch |err| {
        std.debug.panic("failed to initialize CPU-{}: {}", .{ id, err });
    };

    log.info("parsing kernel cmdline", .{});
    const a = args.parse() catch |err| {
        std.debug.panic("failed to parse kernel cmdline: {}", .{err});
    };

    // initialize ACPI specific things: APIC, HPET, ...
    log.info("initializing ACPI", .{});
    acpi.init() catch |err| {
        std.debug.panic("failed to initialize ACPI CPU-{}: {any}", .{ id, err });
    };

    // set things (like the global kernel address space) up for the capability system
    log.info("initializing caps", .{});
    caps.init() catch |err| {
        std.debug.panic("failed to initialize caps: {}", .{err});
    };

    if (builtin.is_test) {
        log.info("running tests", .{});
        @import("root").run_tests() catch |err| {
            std.debug.panic("failed to run tests: {}", .{err});
        };
    }

    // initialize and execute the bootstrap process
    log.info("initializing bootstrap", .{});
    init.exec(a) catch |err| {
        std.debug.panic("failed to set up bootstrap: {}", .{err});
    };

    log.info("entering user-space", .{});
    proc_enter();
}

pub fn smpmain() noreturn {
    const log = std.log.scoped(.main);

    // boot up a few processors
    arch.smp_init();

    // set up arch specific things: GDT, TSS, IDT, syscalls, ...
    log.info("initializing CPU", .{});
    const id = arch.next_cpu_id();
    arch.init_cpu(id) catch |err| {
        std.debug.panic("failed to initialize CPU-{}: {}", .{ id, err });
    };

    // initialize ACPI specific things: APIC, HPET, ...
    log.info("initializing ACPI", .{});
    acpi.init() catch |err| {
        std.debug.panic("failed to initialize ACPI CPU-{}: {any}", .{ id, err });
    };

    log.info("entering user-space", .{});
    proc_enter();
}

fn proc_enter() noreturn {
    var trap: arch.SyscallRegs = undefined;
    proc.yield(&trap);
    arch.sysret(&trap);
}

pub fn syscall(trap: *arch.SyscallRegs) void {
    const log = std.log.scoped(.syscall);
    // log.info("syscall from cpu={} ip=0x{x} sp=0x{x}", .{ arch.cpu_local().id, trap.user_instr_ptr, trap.user_stack_ptr });

    // TODO: once every CPU has reached this, bootloader_reclaimable memory could be freed
    // just some few things need to be copied, but the page map(s) and stack(s) are already copied

    const id = std.meta.intToEnum(abi.sys.Id, trap.syscall_id) catch {
        log.warn("invalid syscall: {x}", .{trap.syscall_id});
        trap.syscall_id = abi.sys.encode(abi.sys.Error.InvalidSyscall);
        return;
    };

    const locals = arch.cpu_local();
    const thread = locals.current_thread.?;

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
        .debug => {
            const cap_id: u32 = @truncate(trap.arg0);
            if (caps.get_capability(thread, cap_id)) |obj| {
                trap.syscall_id = abi.sys.encode(@intFromEnum(obj.type));
            } else |err| {
                trap.syscall_id = abi.sys.encode(err);
            }
        },
        .call => {
            const cap_id: u32 = @truncate(trap.arg0);
            if (caps.capAssertNotNull(cap_id, trap)) return;

            trap.syscall_id = abi.sys.encode(0);
            caps.call(thread, cap_id, trap) catch |err| {
                trap.syscall_id = abi.sys.encode(err);
            };
        },
        .consume => {
            const cap_id: u32 = @truncate(trap.arg0);
            if (caps.capAssertNotNull(cap_id, trap)) return;

            trap.syscall_id = abi.sys.encode(0);
            caps.consume(thread, cap_id, trap) catch |err| {
                trap.syscall_id = abi.sys.encode(err);
            };
        },
        .recv => {
            const cap_id: u32 = @truncate(trap.arg0);
            if (caps.capAssertNotNull(cap_id, trap)) return;

            trap.syscall_id = abi.sys.encode(caps.recv(thread, cap_id, trap));
        },
        .reply => {
            const cap_id: u32 = @truncate(trap.arg0);
            if (caps.capAssertNotNull(cap_id, trap)) return;

            trap.syscall_id = abi.sys.encode(caps.reply(thread, cap_id, trap));
        },
        .yield => {
            proc.yield(trap);
        },
        // else => std.debug.panic("TODO: syscall {s}", .{@tagName(id)}),
    }

    if (thread.status == .stopped) {
        proc.yield(trap);
    }
}

test "trivial test" {
    try std.testing.expect(builtin.target.cpu.arch == .x86_64);
    try std.testing.expect(builtin.target.abi == .none);
}
