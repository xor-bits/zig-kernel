const std = @import("std");
const limine = @import("limine");

const uart = @import("uart.zig");
const fb = @import("fb.zig");
const pmem = @import("pmem.zig");
const vmem = @import("vmem.zig");
const arch = @import("arch.zig");
const acpi = @import("acpi.zig");
const NumberPrefix = @import("byte_fmt.zig").NumberPrefix;

//

pub const std_options: std.Options = .{
    .logFn = logFn,
};

fn logFn(comptime message_level: std.log.Level, comptime scope: @TypeOf(.enum_literal), comptime format: []const u8, args: anytype) void {
    const level_txt = comptime message_level.asText();
    const scope_txt = if (scope == .default) "" else " " ++ @tagName(scope);
    const fmt = "[ " ++ level_txt ++ scope_txt ++ " ]: " ++ format ++ "\n";

    uart.print(fmt, args);
    if (scope != .critical) {
        fb.print(fmt, args);
    }
}

pub fn panic(msg: []const u8, error_return_trace: ?*std.builtin.StackTrace, ret_addr: ?usize) noreturn {
    _ = error_return_trace;
    const log = std.log.scoped(.panic);

    if (ret_addr) |at| {
        log.err("CPU panicked at 0x{x}:\n{s}", .{ at, msg });
    } else {
        log.err("CPU panicked:\n{s}", .{msg});
    }

    arch.hcf();
}

//

pub export var base_revision: limine.BaseRevision = .{ .revision = 2 };
pub export var hhdm: limine.HhdmRequest = .{};

pub var hhdm_offset = std.atomic.Value(usize).init(undefined);

//

export fn _start() callconv(.C) noreturn {
    const log = std.log.scoped(.critical);

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
    arch.hcf();
}

// pub fn blackBox(comptime T: type, value: anytype) T {
//     asm volatile ("" ::: "memory");
//     return value;
// }

fn main() void {
    const log = std.log.scoped(.main);

    log.info("kernel main", .{});

    // initialize physical memory allocation
    pmem.printInfo();
    log.info("used memory: {any}B", .{
        NumberPrefix(usize, .binary).new(pmem.usedPages() << 12),
    });
    log.info("free memory: {any}B", .{
        NumberPrefix(usize, .binary).new(pmem.freePages() << 12),
    });
    log.info("total memory: {any}B", .{
        NumberPrefix(usize, .binary).new(pmem.totalPages() << 12),
    });

    // set up arch specific things: GDT, TSS, IDT, syscalls, ...
    arch.init() catch |err| {
        std.debug.panic("failed to initialize CPU: {any}", .{err});
    };
    arch.x86_64.ints.int3();

    // initialize ACPI specific things: APIC, HPET, ...
    acpi.init() catch |err| {
        std.debug.panic("failed to initialize ACPI: {any}", .{err});
    };

    // create higher half global address space
    vmem.init();

    const vmm = vmem.AddressSpace.current();

    // map bootstrap into the address space
    const bootstrap = @embedFile("bootstrap");
    log.info("bootstrap size: 0x{x}", .{bootstrap.len});
    vmm.map(
        pmem.VirtAddr.new(0x200_0000),
        .{ .bytes = bootstrap },
        .{ .writeable = 1, .user_accessible = 1 },
    );

    // map initfs.tar.gz into the address space
    // vmm.map(
    //     0x400_0000,
    //     .{ .borrow = 0 },
    //     .{ .user_accessible = 1 },
    // );

    // map a lazy heap to the address space
    vmm.map(
        pmem.VirtAddr.new(0x1000_0000),
        .{ .lazy = 0x1000_0000 },
        .{ .writeable = 1, .user_accessible = 1 },
    );
    // map a lazy stack to the address space
    vmm.map(
        pmem.VirtAddr.new(0x3000_0000),
        .{ .lazy = 0x1000_0000 },
        .{ .writeable = 1, .user_accessible = 1 },
    );

    // debug print the current address space
    vmm.printMappings();
    vmm.switchTo();

    var s = arch.SyscallRegs{
        .user_instr_ptr = 0x200_0000,
        .user_stack_ptr = 0x4000_0000,
    };
    log.info("sysret", .{});
    arch.x86_64.sysret(&s);

    log.info("done", .{});

    // NOTE: /path/to/something is a short form for fs:///path/to/something
    // TODO: kernel
    //  - virtual memory mapping
    //  - HPET
    //  - scheduler
    //  - binary loader
    //  - message IPC, shared memory IPC
    //  - figure out userland interrupts (ps2 keyboard, ..)
    //  - syscalls:
    //    - syscall for bootstrap to grow the heap
    //    - syscall to print logs
    //    - syscall to exec a binary (based on a provided mem map)
    //    - syscall to create a vfs proto
    //    - syscall to accept a vfs proto cmd
    //    - syscall to return a vfs proto cmd result
    //    - syscall to read the root kernel cli arg
    //    - syscalls for unix sockets
    //
    // TODO: bootstrap/initfsd process
    //  - map flat binary to 0x200_0000
    //  - map initfs.tar.gz to 0x400_0000
    //  - map heap to 0x1000_0000
    //  - enter bootstrap in ring3
    //  - inflate&initialize initfs in heap
    //  - create initfs:// vfs proto
    //  - exec flat binary initfs:///sbin/initd
    //  - rename to initfsd
    //  - start processing vfs proto cmds
    //
    // TODO: initfs:///sbin/initd process
    //  - launch initfs:///sbin/rngd
    //  - launch initfs:///sbin/vfsd
    //  - launch services from initfs://
    //  // - launch /bin/wm
    //
    // TODO: initfs:///sbin/rngd process
    //  - create rng:// vfs proto
    //  - start processing vfs proto cmds
    //
    // TODO: /sbin/inputd process
    //
    // TODO: /sbin/outputd process
    //
    // TODO: /sbin/kbd process
    //
    // TODO: /sbin/moused process
    //
    // TODO: /sbin/timed process
    //
    // TODO: /sbin/fbd process
    //
    // TODO: /sbin/pcid process
    //
    // TODO: /sbin/usbd process
    //
    // TODO: initfs:///sbin/vfsd process
    //  - create fs:// vfs proto
    //  - get the root device with syscall (either device or fstab for initfs:///etc/fstab)
    //  - exec required root filesystem drivers
    //  - mount root (root= kernel cli arg) to /
    //  - remount root using /etc/fstab
    //  - exec other filesystem drivers lazily
    //  - mount everything according to /etc/fstab
    //  - start processing vfs proto cmds
    //
    // TODO: initfs:///sbin/fsd.fat32
    //  - connect to the /sbin/vfsd process using a unix socket
    //  - register a fat32 filesystem
    //  - start processing cmds
}

pub fn syscall(args: *arch.SyscallRegs) void {
    const log = std.log.scoped(.syscall);
    log.info("got a syscall: {any}", .{args});
}