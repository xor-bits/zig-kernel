const std = @import("std");
const abi = @import("abi");
const limine = @import("limine");

const acpi = @import("acpi.zig");
const arch = @import("arch.zig");
const args = @import("args.zig");
const lazy = @import("lazy.zig");
const logs = @import("logs.zig");
const pmem = @import("pmem.zig");
const proc = @import("proc.zig");
const ring = @import("ring.zig");
const spin = @import("spin.zig");
const util = @import("util.zig");
const vmem = @import("vmem.zig");

//

pub const std_options = logs.std_options;
pub const panic = logs.panic;

//

pub export var base_revision: limine.BaseRevision = .{ .revision = 2 };
pub export var hhdm: limine.HhdmRequest = .{};

pub var hhdm_offset = std.atomic.Value(usize).init(undefined);

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

    const kernel_args = args.parse() catch |err| {
        std.debug.panic("invalid kernel cmdline: {any}", .{err});
    };

    // initialize physical memory allocation
    pmem.printInfo();
    log.info("used memory: {any}B", .{
        util.NumberPrefix(usize, .binary).new(pmem.usedPages() << 12),
    });
    log.info("free memory: {any}B", .{
        util.NumberPrefix(usize, .binary).new(pmem.freePages() << 12),
    });
    log.info("total memory: {any}B", .{
        util.NumberPrefix(usize, .binary).new(pmem.totalPages() << 12),
    });

    // set up arch specific things: GDT, TSS, IDT, syscalls, ...
    arch.init() catch |err| {
        std.debug.panic("failed to initialize CPU: {any}", .{err});
    };
    // arch.x86_64.ints.int3();

    // initialize ACPI specific things: APIC, HPET, ...
    acpi.init() catch |err| {
        std.debug.panic("failed to initialize ACPI: {any}", .{err});
    };

    // create higher half global address space
    vmem.init();

    const vmm = vmem.AddressSpace.new();

    // map bootstrap into the address space
    const bootstrap = @embedFile("bootstrap");
    log.info("bootstrap size: 0x{x}", .{bootstrap.len});
    vmm.map(
        pmem.VirtAddr.new(abi.BOOTSTRAP_EXE),
        .{ .bytes = bootstrap },
        .{ .writeable = 1, .user_accessible = 1 },
    );
    // map a lazy heap to the address space
    vmm.map(
        pmem.VirtAddr.new(abi.BOOTSTRAP_HEAP),
        .{ .lazy = abi.BOOTSTRAP_HEAP_SIZE },
        .{ .writeable = 1, .user_accessible = 1, .no_execute = 1 },
    );
    // map a lazy stack to the address space
    vmm.map(
        pmem.VirtAddr.new(abi.BOOTSTRAP_STACK),
        .{ .lazy = abi.BOOTSTRAP_STACK_SIZE },
        .{ .writeable = 1, .user_accessible = 1, .no_execute = 1 },
    );
    // map initfs.tar.gz to the address space
    if (std.mem.isAligned(@intFromPtr(kernel_args.initfs.ptr), 0x1000) and std.mem.isAligned(kernel_args.initfs.len, 0x1000)) {
        log.info("TODO: initfs is alredy page aligned, skipping copy", .{});
    }
    vmm.map(
        pmem.VirtAddr.new(0x5000_0000),
        .{ .bytes = kernel_args.initfs },
        .{ .user_accessible = 1, .no_execute = 1 },
    );

    // debug print the current address space
    vmm.printMappings();
    vmm.switchTo();

    // initialize the bootstrap process
    const current = proc.find(0);
    current.lock.lock();
    current.addr_space = vmm;
    current.is_system = true;
    current.trap = arch.SyscallRegs{
        .user_instr_ptr = 0x200_0000,
        .user_stack_ptr = abi.BOOTSTRAP_STACK + abi.BOOTSTRAP_STACK_SIZE,
        .arg0 = abi.BOOTSTRAP_INITFS,
        .arg1 = kernel_args.initfs.len,
    };
    current.lock.unlock();

    var junk = arch.SyscallRegs{};
    proc.lockAndSwitchTo(0, &junk);

    log.info("kernel init done", .{});
    proc.returnEarly(0);
}

pub const Protocol = struct {
    name: [16:0]u8,
    owner: usize,
    handle: usize,
};

var protos = std.AutoHashMap([16:0]u8, Protocol);

pub fn syscall(trap: *arch.SyscallRegs) void {
    const log = std.log.scoped(.syscall);

    const current_pid = proc.currentPid().?;
    const current_proc = proc.find(current_pid);

    // TODO: once every CPU has reached this, bootloader_reclaimable memory could be freed
    // just some few things need to be copied, but the page map(s) and stack(s) are already copied

    if (trap.syscall_id >= 0x8000_0000 and !current_proc.is_system) {
        // only system processes should use system syscalls
        return;
    }

    const id = std.meta.intToEnum(abi.sys.Id, trap.syscall_id) catch {
        log.warn("invalid syscall: {x}", .{trap.syscall_id});
        return;
    };
    switch (id) {
        abi.sys.Id.log => {
            // log syscall
            if (trap.arg1 > 0x1000) {
                log.warn("log syscall too long", .{});
                return;
            }

            const msg = untrustedSlice(u8, trap.arg0, trap.arg1) catch |err| {
                log.warn("user space sent a bad syscall: {}", .{err});
                return;
            };

            log.info("{s}", .{std.mem.trimRight(u8, msg, "\n")});
        },
        abi.sys.Id.yield => {
            const next_pid = proc.nextPid(current_pid) orelse return;

            // save the previous process
            proc.unlockAndYield(trap);

            // FIXME: page fault now could lead to a race condition

            // switch to the next process
            proc.lockAndSwitchTo(next_pid, trap);
        },
        abi.sys.Id.vfs_proto_create => {
            const name = untrustedSlice(u8, trap.arg0, trap.arg1) catch |err| {
                log.warn("user space sent a bad syscall: {}", .{err});
                return;
            };
            _ = name; // autofix
        },
        abi.sys.Id.system_map => {
            const target_pid = trap.arg0;
            const maps = untrustedSlice(abi.sys.Map, trap.arg1, trap.arg2) catch |err| {
                log.warn("user space sent a bad syscall: {}", .{err});
                return;
            };

            const target_proc = proc.find(target_pid);
            if (target_proc.addr_space == null) {
                target_proc.addr_space = vmem.AddressSpace.new();
            }
            const vmm = &target_proc.addr_space.?;

            for (maps) |map| {
                isInLowerHalf(u8, map.dst, map.src.length()) catch |err| {
                    log.warn("user space sent a bad syscall: {}", .{err});
                    return;
                };

                var src: vmem.MapSource = undefined;
                if (map.src.asBytes()) |bytes| {
                    src = .{ .bytes = bytes };
                } else if (map.src.asLazy()) |bytes| {
                    src = .{ .lazy = bytes };
                } else {
                    log.warn("user space sent a bad syscall: invalid map source", .{});
                    return;
                }

                vmm.map(pmem.VirtAddr.new(map.dst), src, .{
                    .user_accessible = 1,
                    .writeable = @intFromBool(map.flags.write),
                    .no_execute = @intFromBool(!map.flags.execute),
                });
            }

            vmm.printMappings();
        },
        abi.sys.Id.system_exec => {
            log.info("exec pid: {} ip: {} sp: {}", .{ trap.arg0, trap.arg1, trap.arg2 });

            const target_pid = trap.arg0;
            const ip = trap.arg1;
            const sp = trap.arg2;

            const target_proc = proc.find(target_pid);

            target_proc.lock.lock();
            if (target_proc.addr_space == null) {
                std.debug.panic("addr_space null after system_exec", .{});
            }
            target_proc.trap = arch.SyscallRegs{
                .user_instr_ptr = ip,
                .user_stack_ptr = sp,
            };
            target_proc.status = .ready;
            target_proc.lock.unlock();

            proc.pushReady(target_pid);
        },
        // else => std.debug.panic("TODO", .{}),
    }
}

fn isInLowerHalf(comptime T: type, bottom: usize, length: usize) error{ Overflow, IsHigherHalf }!void {
    const byte_len = @mulWithOverflow(@sizeOf(T), length);
    if (byte_len[1] != 0) {
        return error.Overflow;
    }

    const top = @addWithOverflow(bottom, byte_len[0]);
    if (top[1] != 0) {
        return error.Overflow;
    }

    if (top[0] >= 0x8000_0000_0000) {
        return error.IsHigherHalf;
    }
}

fn untrustedSlice(comptime T: type, bottom: usize, length: usize) error{ Overflow, IsHigherHalf }![]T {
    try isInLowerHalf(T, bottom, length);

    // pagefaults from the kernel touching lower half should just kill the process,
    // way faster and easier than testing for access
    // (no supervisor pages are ever mapped to lower half)

    const first: [*]T = @ptrFromInt(bottom);
    return first[0..length];
}
