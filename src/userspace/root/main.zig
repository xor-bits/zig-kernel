const std = @import("std");
const abi = @import("abi");

const initfsd = @import("initfsd.zig");

const log = std.log.scoped(.root);
const Error = abi.sys.Error;
const caps = abi.caps;

//

pub const std_options = abi.std_options;
pub const panic = abi.panic;
pub const name = "root";

//

/// elf loader temporary mapping location
pub const LOADER_TMP = 0x2000_0000_0000;
/// uncompressed initfs.tar location
pub const INITFS_TAR = 0x3000_0000_0000;
pub const FRAMEBUFFER = 0x4000_0000_0000;
pub const BACKBUFFER = 0x4100_0000_0000;
pub const FRAMEBUFFER_INFO = 0x4200_0000_0000;
pub const INITFS_TMP = 0x5000_0000_0000;
pub const INITFS_LIST = 0x5800_0000_0000;
pub const STACK_SIZE = 0x40000;
pub const STACK_TOP = 0x8000_0000_0000 - 0x2000;
pub const STACK_BOTTOM = STACK_TOP - STACK_SIZE;
pub const INITFS_STACK_TOP = STACK_BOTTOM - 0x2000;
pub const INITFS_STACK_BOTTOM = INITFS_STACK_TOP - STACK_SIZE;
pub const SPINNER_STACK_TOP = INITFS_STACK_BOTTOM - 0x2000;
pub const SPINNER_STACK_BOTTOM = SPINNER_STACK_TOP - STACK_SIZE;
/// boot info location
pub const BOOT_INFO = 0x8000_0000_0000 - 0x1000;

//

pub var self_memory_lock: abi.lock.YieldMutex = .new();
pub var self_vmem_lock: abi.lock.YieldMutex = .new();

//

pub fn main() !void {
    log.info("I am root", .{});

    const len = try abi.sys.frameGetSize(abi.caps.ROOT_BOOT_INFO.cap);

    _ = try abi.caps.ROOT_SELF_VMEM.map(
        abi.caps.ROOT_BOOT_INFO,
        0,
        BOOT_INFO,
        len,
        .{},
        .{},
    );
    log.info("boot info mapped", .{});

    try initfsd.init();

    const boot_info = @as(*const volatile abi.BootInfo, @ptrFromInt(BOOT_INFO)).*;

    var system: System = .{};
    system.devices.set(.hpet, .{
        .mmio_frame = boot_info.hpet,
        .info_frame = .{},
    });
    system.devices.set(.framebuffer, .{
        .mmio_frame = boot_info.framebuffer,
        .info_frame = boot_info.framebuffer_info,
    });
    system.devices.set(.mcfg, .{
        .mmio_frame = boot_info.mcfg,
        .info_frame = boot_info.mcfg_info,
    });

    try initfsd.wait();

    var servers = std.ArrayList(abi.loader.Elf).init(abi.mem.slab_allocator);
    try servers.append(try abi.loader.Elf.init(try binBytes("/sbin/pm")));

    for (servers.items) |*server| {
        const manifest = (try server.manifest()).?;

        log.info("name: {s}", .{manifest.getName()});
        log.info("imports:", .{});
        var imports = try server.imports();
        while (try imports.next()) |imp|
            log.info(" - {}({}) @0x{x}: {s}", .{ imp.val.ty, imp.val.handle, imp.addr, imp.val.getName() });
        log.info("exports:", .{});
        var exports = try server.exports();
        while (try exports.next()) |exp|
            log.info(" - {}({}) @0x{x}: {s}", .{ exp.val.ty, exp.val.handle, exp.addr, exp.val.getName() });
    }

    // log.info("finding manifest", .{});
    // const index = std.mem.indexOf(u8, pm, std.mem.asBytes(&[4]usize{
    //     0x5b9061e5c940d983,
    //     0xc47d27b79d2c8bb9,
    //     0x40299f5bb0c53988,
    //     0x3e49068027c442fb,
    // }));
    // log.info("found manifest: {any}", .{index});

    // const v = std.mem.bytesAsValue(Manifest, pm[index.?..]);
    // log.info("found manifest: {s}", .{v.name});

    // virtual memory manager (system) (server)
    // maps new processes to memory and manages page faults,
    // heaps, lazy alloc, shared memory, swapping, etc.
    // system.servers.getPtr(.vm).bin = try binBytes("/sbin/vm");

    // process manager (system) (server)
    // manages unix-like process stuff like permissions, cli args, etc.
    // system.servers.getPtr(.pm).bin = try binBytes("/sbin/pm");

    // resource manager (system) (server)
    // manages ioports, irqs, device memory, etc. should also manage physical memory
    // system.servers.getPtr(.rm).bin = try binBytes("/sbin/rm");

    // virtual filesystem (system) (server)
    // manages the main VFS tree, everything mounted into it and file descriptors
    // system.servers.getPtr(.vfs).bin = try binBytes("/sbin/vfs");

    // timer (system) (server)
    // manages timer drivers and accepts sleep, sleepDeadline and timestamp calls
    // system.servers.getPtr(.timer).bin = try binBytes("/sbin/timer");

    // input (system) (server)
    // manages input drivers
    // system.servers.getPtr(.input).bin = try binBytes("/sbin/input");

    // const vm = system.servers.getPtr(.vm);
    // vm.thread = try execVm(vm.bin, vm_sender);
    // vm.endpoint = vm_sender.cap;

    // TODO: wait for crashed servers
}

fn binBytes(path: []const u8) ![]const u8 {
    return initfsd.readFile(initfsd.openFile(path) orelse {
        log.err("missing critical system binary: '{s}'", .{path});
        return error.MissingSystem;
    });
}

const Server = struct {
    /// server thread
    thread: caps.Thread = .{},
    /// server ELF binary
    bin: []const u8 = "",
    /// receiver for making new senders to the server
    receiver: caps.Receiver = .{},
};

const System = struct {
    devices: std.EnumArray(abi.DeviceKind, abi.Device) = .initFill(.{}),

    servers: std.EnumArray(abi.ServerKind, Server) = .initFill(.{}),
};

fn execVm(elf_bytes: []const u8, sender: abi.caps.Sender) !caps.Thread {
    var elf = std.io.fixedBufferStream(elf_bytes);

    var crc: u32 = 0;
    for (elf_bytes) |b| {
        crc = @addWithOverflow(crc, @as(u32, b))[0];
    }
    log.info("xor crc of is {d}", .{crc});

    const header = try std.elf.Header.read(&elf);
    var program_headers = header.program_header_iterator(&elf);

    const new_vmem = try caps.Vmem.create();

    var heap_bottom: usize = 0;

    // var frames: std.BoundedArray(u32, 1000) = .init(0);
    // frames.append(item: T);

    while (try program_headers.next()) |program_header| {
        if (program_header.p_type != std.elf.PT_LOAD) {
            continue;
        }

        if (program_header.p_memsz == 0) {
            continue;
        }

        const bytes: []const u8 = elf.buffer[program_header.p_offset..][0..program_header.p_filesz];

        const rights = abi.sys.Rights{
            .writable = program_header.p_flags & std.elf.PF_W != 0,
            .executable = program_header.p_flags & std.elf.PF_X != 0,
        };

        const segment_vaddr_bottom = std.mem.alignBackward(usize, program_header.p_vaddr, 0x1000);
        const segment_vaddr_top = std.mem.alignForward(usize, program_header.p_vaddr + program_header.p_memsz, 0x1000);
        const segment_data_bottom_offset = program_header.p_vaddr - segment_vaddr_bottom;
        // const data_vaddr_bottom = program_header.p_vaddr;
        // const data_vaddr_top = data_vaddr_bottom + program_header.p_filesz;
        // const zero_vaddr_bottom = std.mem.alignForward(usize, data_vaddr_top, 0x1000);
        // const zero_vaddr_top = segment_vaddr_top;

        heap_bottom = @max(heap_bottom, segment_vaddr_top + 0x1000);

        // log.info("flags: {}, segment_vaddr_bottom=0x{x} segment_vaddr_top=0x{x} data_vaddr_bottom=0x{x} data_vaddr_top=0x{x}", .{
        //     rights,
        //     segment_vaddr_bottom,
        //     segment_vaddr_top,
        //     data_vaddr_bottom,
        //     data_vaddr_top,
        // });

        // FIXME: potential alignment errors when segments are bigger than 2MiB,
        // because frame caps use huge and giant pages automatically

        const size = segment_vaddr_top - segment_vaddr_bottom;
        self_memory_lock.lock();
        defer self_memory_lock.unlock();
        const frame = try caps.Frame.create(size);

        // TODO: Frame.write instead of Vmem.map + memcpy + Vmem.unmap
        try abi.caps.ROOT_SELF_VMEM.map(
            frame,
            0,
            LOADER_TMP,
            size,
            .{ .writable = true },
            .{},
        );

        // log.info("copying to [ 0x{x}..0x{x} ]", .{
        //     segment_vaddr_bottom + segment_data_bottom_offset,
        //     segment_vaddr_bottom + segment_data_bottom_offset + program_header.p_filesz,
        // });
        abi.util.copyForwardsVolatile(u8, @as(
            [*]volatile u8,
            @ptrFromInt(LOADER_TMP + segment_data_bottom_offset),
        )[0..program_header.p_filesz], bytes);

        try abi.caps.ROOT_SELF_VMEM.unmap(
            LOADER_TMP,
            size,
        );

        try new_vmem.map(
            frame,
            0,
            segment_vaddr_bottom,
            size,
            rights,
            .{},
        );
    }

    // map a stack
    // log.info("mapping a stack", .{});
    const stack = try caps.Frame.create(1024 * 256);
    try new_vmem.map(
        stack,
        0,
        0x7FFF_FFF0_0000,
        1024 * 256,
        .{ .writable = true },
        .{},
    );
    // try new_vmem.map(
    //     stack_copy,
    //     0x7FFF_FFE0_0000,
    //     .{ .writable = true },
    //     .{},
    // );

    // map an initial heap
    // log.info("mapping a heap", .{});
    const heap = try caps.Frame.create(1024 * 256);
    try new_vmem.map(
        heap,
        0,
        heap_bottom,
        1024 * 256,
        .{ .writable = true },
        .{},
    );

    const new_proc = try caps.Process.create(new_vmem);
    _ = sender;
    // const sender_there = new_proc.pushCapability(sender.cap);

    // log.info("creating a new thread", .{});
    const new_thread = try caps.Thread.create(new_proc);

    try new_thread.setPrio(0);
    try new_thread.writeRegs(&.{
        // .arg0 = sender_there,
        .user_instr_ptr = header.entry,
        .user_stack_ptr = 0x7FFF_FFF4_0000 - 0x100,
    });

    // log.info("ip=0x{x} sp=0x{x}", .{ header.entry, 0x7FFF_FFF4_0000 });

    log.info("everything ready, exec", .{});
    try new_thread.start();

    return new_thread;
}

pub extern var __stack_end: u8;
pub extern var __thread_stack_end: u8;

pub export fn _start() linksection(".text._start") callconv(.Naked) noreturn {
    asm volatile (
        \\ jmp zigMain
        :
        : [sp] "{rsp}" (&__stack_end),
    );
}

export fn zigMain() noreturn {
    // switch to a bigger stack (256KiB, because the initfs deflate takes up over 128KiB on its own)
    mapStack() catch |err| {
        std.debug.panic("not enough memory for a stack: {}", .{err});
    };

    asm volatile (
        \\ jmp zigMainRealstack
        :
        : [sp] "{rsp}" (STACK_TOP),
    );
    unreachable;
}

fn mapStack() !void {
    log.info("mapping stack", .{});

    const frame = try caps.Frame.create(1024 * 256);
    _ = try caps.ROOT_SELF_VMEM.map(
        frame,
        0,
        STACK_BOTTOM,
        1024 * 256,
        .{ .writable = true },
        .{},
    );

    log.info("stack mapping complete 0x{x}..0x{x}", .{ STACK_BOTTOM, STACK_TOP });
}

export fn zigMainRealstack() noreturn {
    main() catch |err| {
        std.debug.panic("{}", .{err});
    };
    abi.sys.self_stop();
}
