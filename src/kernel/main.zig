const std = @import("std");
const abi = @import("abi");
const limine = @import("limine");

const pmem = @import("pmem.zig");
const vmem = @import("vmem.zig");
const arch = @import("arch.zig");
const acpi = @import("acpi.zig");
const logs = @import("logs.zig");
const args = @import("args.zig");
const NumberPrefix = @import("byte_fmt.zig").NumberPrefix;

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
    // arch.x86_64.ints.int3();

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
        pmem.VirtAddr.new(abi.BOOTSTRAP_INITFS),
        .{ .bytes = kernel_args.initfs },
        .{ .user_accessible = 1, .no_execute = 1 },
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

    // NOTE: /path/to/something is a short form for fs:///path/to/something
    // TODO: kernel
    //  - HPET
    //  - scheduler
    //  - binary loader
    //  - message IPC, shared memory IPC
    //  - figure out userland interrupts (ps2 keyboard, ..)
    //  - syscalls:
    //    - syscall to exec a binary (based on a provided mem map)
    //    - syscall to create a vfs proto
    //    - syscall to accept a vfs proto cmd
    //    - syscall to return a vfs proto cmd result
    //    - syscall to read the root kernel cli arg
    //    - syscalls for unix sockets
    //
    // TODO: bootstrap/initfsd process
    //  - map initfs.tar.gz to 0x400_0000
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

pub fn syscall(trap: *arch.SyscallRegs) void {
    const log = std.log.scoped(.syscall);

    const id = std.meta.intToEnum(abi.sys.Id, trap.syscall_id) catch {
        log.warn("invalid syscall: {x}", .{trap.syscall_id});
        return;
    };
    switch (id) {
        abi.sys.Id.log => {
            // log syscall
            if (trap.arg1 >= 0x100) {
                log.warn("log syscall too long", .{});
                return;
            }

            if (trap.arg0 >= 0x8000_0000_0000 or trap.arg0 + trap.arg1 >= 0x8000_0000_0000) {
                log.warn("user space shouldn't touch higher half", .{});
                return;
            }

            // pagefaults from the kernel touching lower half should just kill the process
            // way faster and easier than testing for access
            // (no supervisor pages are ever mapped to lower half)

            const str_base: [*]const u8 = @ptrFromInt(trap.arg0);
            const str: []const u8 = str_base[0..trap.arg1];

            log.info("{s}", .{str});
        },
    }
}
