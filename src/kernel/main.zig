const std = @import("std");
const builtin = @import("builtin");
const abi = @import("abi");
const limine = @import("limine");

const acpi = @import("acpi.zig");
const addr = @import("addr.zig");
const apic = @import("apic.zig");
const arch = @import("arch.zig");
const args = @import("args.zig");
const caps = @import("caps.zig");
const init = @import("init.zig");
const logs = @import("logs.zig");
const pmem = @import("pmem.zig");
const proc = @import("proc.zig");
const spin = @import("spin.zig");
const util = @import("util.zig");

//

const conf = abi.conf;
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
    lapic_id: u32,
    apic_regs: apic.ApicRegs = .{ .none = {} },

    // FIXME: remove notify caps from here
    interrupt_handlers: [apic.IRQ_AVAIL_COUNT]apic.Handler =
        .{apic.Handler.init(null)} ** apic.IRQ_AVAIL_COUNT,
};

//

export fn _start() callconv(.C) noreturn {
    arch.earlyInit();
    main();
}

pub fn main() noreturn {
    const log = std.log.scoped(.main);

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

    log.info("kernel main", .{});
    log.info("zig version: {s}", .{builtin.zig_version_string});
    log.info("kernel version: 0.0.2{s}", .{if (builtin.is_test) "-testing" else ""});
    log.info("kernel git revision: {s}", .{comptime std.mem.trimRight(u8, @embedFile("git-rev"), "\n\r")});

    log.info("CPUID features: {}", .{arch.CpuFeatures.read()});

    log.info("initializing physical memory allocator", .{});
    pmem.init() catch |err| {
        std.debug.panic("failed to initialize PMM: {}", .{err});
    };

    log.info("initializing DWARF info", .{});
    logs.init() catch |err| {
        std.debug.panic("failed to initialize DWARF info: {}", .{err});
    };

    // boot up a few processors
    arch.smpInit();

    // set up arch specific things: GDT, TSS, IDT, syscalls, ...
    const id = arch.nextCpuId();
    log.info("initializing CPU-{}", .{id});
    arch.initCpu(id, null) catch |err| {
        std.debug.panic("failed to initialize CPU-{}: {}", .{ id, err });
    };

    log.info("parsing kernel cmdline", .{});
    const a = args.parse() catch |err| {
        std.debug.panic("failed to parse kernel cmdline: {}", .{err});
    };

    // initialize ACPI specific things: APIC, HPET, ...
    log.info("initializing ACPI for CPU-{}", .{id});
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
        @import("root").runTests() catch |err| {
            std.debug.panic("failed to run tests: {}", .{err});
        };
    }

    // initialize and execute the root process
    log.info("initializing root", .{});
    init.exec(a) catch |err| {
        std.debug.panic("failed to set up root: {}", .{err});
    };

    log.info("entering user-space", .{});
    proc.enter();
}

// the actual _smpstart is in arch/x86_64.zig
pub fn smpmain(smpinfo: *limine.SmpInfo) noreturn {
    const log = std.log.scoped(.main);

    // boot up a few processors
    arch.smpInit();

    // set up arch specific things: GDT, TSS, IDT, syscalls, ...
    const id = arch.nextCpuId();
    log.info("initializing CPU-{}", .{id});
    arch.initCpu(id, smpinfo) catch |err| {
        std.debug.panic("failed to initialize CPU-{}: {}", .{ id, err });
    };

    // initialize ACPI specific things: APIC, HPET, ...
    log.info("initializing ACPI for CPU-{}", .{id});
    acpi.init() catch |err| {
        std.debug.panic("failed to initialize ACPI CPU-{}: {any}", .{ id, err });
    };

    log.info("entering user-space", .{});
    proc.enter();
}

var syscall_stats: std.EnumArray(abi.sys.Id, std.atomic.Value(usize)) = .initFill(.init(0));

pub fn syscall(trap: *arch.SyscallRegs) void {
    const log = std.log.scoped(.syscall);
    // log.info("syscall from cpu={} ip=0x{x} sp=0x{x}", .{ arch.cpuLocal().id, trap.user_instr_ptr, trap.user_stack_ptr });
    // defer log.info("syscall done", .{});

    // TODO: once every CPU has reached this, bootloader_reclaimable memory could be freed
    // just some few things need to be copied, but the page map(s) and stack(s) are already copied

    const id = std.meta.intToEnum(abi.sys.Id, trap.syscall_id) catch {
        log.warn("invalid syscall: {x}", .{trap.syscall_id});
        trap.syscall_id = abi.sys.encode(abi.sys.Error.InvalidSyscall);
        return;
    };

    const locals = arch.cpuLocal();
    const thread = locals.current_thread.?;

    if (conf.LOG_SYSCALLS)
        log.debug("syscall: {s}      cap_id={}", .{ @tagName(id), trap.arg0 });
    defer if (conf.LOG_SYSCALLS)
        log.debug("syscall: {s} done cap_id={}", .{ @tagName(id), trap.arg0 });

    if (conf.LOG_SYSCALL_STATS) {
        _ = syscall_stats.getPtr(id).fetchAdd(1, .monotonic);

        log.debug("syscalls:", .{});
        var it = syscall_stats.iterator();
        while (it.next()) |e| {
            const v = e.value.load(.monotonic);
            log.debug(" - {}: {}", .{ e.key, v });
        }
    }

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

            trap.syscall_id = abi.sys.encode(0);
        },
        .kernelPanic => {
            if (!conf.KERNEL_PANIC_SYSCALL) {
                trap.syscall_id = abi.sys.encode(abi.sys.Error.InvalidSyscall);
                return;
            }

            @panic("manual kernel panic");
        },
        .debug => {
            if (caps.getCapability(thread, @truncate(trap.arg0))) |obj| {
                defer obj.lock.unlock();
                trap.syscall_id = abi.sys.encode(@intFromEnum(obj.type));
            } else |err| {
                if (conf.LOG_OBJ_CALLS) log.warn("obj call error: {}", .{err});
                trap.syscall_id = abi.sys.encode(err);
            }
        },
        .call => {
            if (caps.call(thread, @truncate(trap.arg0), trap)) |_| {
                trap.syscall_id = abi.sys.encode(0);
            } else |err| {
                if (conf.LOG_OBJ_CALLS) log.warn("obj call error: {}", .{err});
                trap.syscall_id = abi.sys.encode(err);
            }
        },
        .recv => {
            if (caps.recv(thread, @truncate(trap.arg0), trap)) |_| {
                trap.syscall_id = abi.sys.encode(0);
            } else |err| {
                if (conf.LOG_OBJ_CALLS) log.warn("obj call error: {}", .{err});
                trap.syscall_id = abi.sys.encode(err);
            }
        },
        .reply => {
            if (caps.reply(thread, @truncate(trap.arg0), trap)) |_| {
                trap.syscall_id = abi.sys.encode(0);
            } else |err| {
                if (conf.LOG_OBJ_CALLS) log.warn("obj call error: {}", .{err});
                trap.syscall_id = abi.sys.encode(err);
            }
        },
        .reply_recv => {
            if (caps.replyRecv(thread, @truncate(trap.arg0), trap)) |_| {
                trap.syscall_id = abi.sys.encode(0);
            } else |err| {
                if (conf.LOG_OBJ_CALLS) log.warn("obj call error: {}", .{err});
                trap.syscall_id = abi.sys.encode(err);
            }
        },
        .yield => {
            proc.yield(trap);
        },
        .stop => {
            proc.stop(thread);
        },
        .get_extra => {
            const idx: u7 = @truncate(trap.arg0);
            trap.arg0 = thread.getExtra(idx);
            trap.syscall_id = abi.sys.encode(0);
        },
        .set_extra => {
            const idx: u7 = @truncate(trap.arg0);
            const val: usize = @truncate(trap.arg1);
            thread.setExtra(idx, val, trap.arg2 != 0);
            trap.syscall_id = abi.sys.encode(0);
        },
        // else => std.debug.panic("TODO: syscall {s}", .{@tagName(id)}),
    }

    const thread_now = locals.current_thread.?;
    if (thread_now.status == .stopped or thread_now.status == .waiting) {
        proc.yield(trap);
    }
}

test "trivial test" {
    try std.testing.expect(builtin.target.cpu.arch == .x86_64);
    try std.testing.expect(builtin.target.abi == .none);
}
