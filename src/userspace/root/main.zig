const std = @import("std");
const abi = @import("abi");

const initfsd = @import("initfsd.zig");

const log = std.log.scoped(.root);
const Error = abi.sys.Error;

//

pub const std_options = abi.std_options;
pub const panic = abi.panic;

//

/// elf loader temporary mapping location
pub const LOADER_TMP = 0x2000_0000_0000;
/// uncompressed initfs.tar location
pub const INITFS_TAR = 0x3000_0000_0000;
pub const STACK_SIZE = 0x40000;
pub const STACK_TOP = 0x8000_0000_0000 - 0x2000;
pub const STACK_BOTTOM = STACK_TOP - STACK_SIZE;
/// boot info location
pub const BOOT_INFO = 0x8000_0000_0000 - 0x1000;

//

pub fn main() !void {
    log.info("I am root", .{});

    try map_naive(
        abi.caps.ROOT_BOOT_INFO,
        BOOT_INFO,
        .{ .writable = true },
        .{},
    );
    log.info("boot info mapped", .{});
    const boot_info = @as(*volatile abi.BootInfo, @ptrFromInt(BOOT_INFO));
    // log.info("boot info {}", .{boot_info.*});

    log.info("root binary addr: {*}", .{boot_info.rootData().ptr});
    log.info("root binary size: {}", .{boot_info.rootData().len});
    log.info("root binary path: '{s}'", .{boot_info.rootPath()});
    log.info("initfs addr: {*}", .{boot_info.initfsData().ptr});
    log.info("initfs size: {}", .{boot_info.initfsData().len});
    log.info("initfs path: '{s}'", .{boot_info.initfsPath()});

    try initfsd.init(boot_info.initfsData());

    const recv = try abi.caps.ROOT_MEMORY.alloc(abi.caps.Receiver);

    // FIXME: figure out a way to reclaim capabilities from crashed processes

    // virtual memory manager (system) (server)
    // maps new processes to memory and manages page faults,
    // heaps, lazy alloc, shared memory, swapping, etc.
    try exec_elf("/sbin/vm", try recv.subscribe());

    // process manager (system) (server)
    // manages unix-like process stuff like permissions, cli args, etc.
    // try exec_with_vm("/sbin/pm");

    // virtual filesystem (system) (server)
    // manages the main VFS tree, everything mounted into it and file descriptors
    // try exec_with_vm("/sbin/vfs");

    // init (normal) (process)
    // all the critial system servers are running, so now "normal" Linux-like init can run
    // gets a Sender capability to access the initfs part of this root process
    // just runs normal processes according to the init configuration
    // launches stuff like the window manager and virtual TTYs
    // try exec_with_vm("/sbin/init");

    var msg: abi.sys.Message = undefined;
    while (true) {
        try recv.recv(&msg);

        log.info("root received: {}", .{msg});

        try recv.reply(&msg);
    }
}

pub fn map_naive(frame: abi.caps.Frame, vaddr: usize, rights: abi.sys.Rights, flags: abi.sys.MapFlags) !void {
    try abi.caps.ROOT_SELF_VMEM.map(
        frame,
        vaddr,
        rights,
        flags,
    );
}

fn exec_elf(path: []const u8, sender: abi.caps.Sender) !void {
    const elf_file = initfsd.openFile(path).?;
    const elf_bytes = initfsd.readFile(elf_file);
    var elf = std.io.fixedBufferStream(elf_bytes);

    var crc: u32 = 0;
    for (elf_bytes) |b| {
        crc = @addWithOverflow(crc, @as(u32, b))[0];
    }
    log.info("xor crc of `{s}` is {d}", .{ path, crc });

    const header = try std.elf.Header.read(&elf);
    var program_headers = header.program_header_iterator(&elf);

    const new_vmem = try abi.caps.ROOT_MEMORY.alloc(abi.caps.Vmem);
    try new_vmem.transferCap(sender.cap);

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
        const frames = try allocVector(abi.caps.ROOT_MEMORY, size);

        try mapVector(
            &frames,
            abi.caps.ROOT_SELF_VMEM,
            LOADER_TMP,
            .{ .writable = true },
            .{},
        );

        // log.info("copying to [ 0x{x}..0x{x} ]", .{
        //     segment_vaddr_bottom + segment_data_bottom_offset,
        //     segment_vaddr_bottom + segment_data_bottom_offset + program_header.p_filesz,
        // });
        copyForwardsVolatile(
            u8,
            @as([*]volatile u8, @ptrFromInt(LOADER_TMP + segment_data_bottom_offset))[0..program_header.p_filesz],
            bytes,
        );

        try unmapVector(
            &frames,
            abi.caps.ROOT_SELF_VMEM,
            LOADER_TMP,
        );

        try mapVector(
            &frames,
            new_vmem,
            segment_vaddr_bottom,
            rights,
            .{},
        );
    }

    // map a stack
    // log.info("mapping a stack", .{});
    const stack = try abi.caps.ROOT_MEMORY.allocSized(abi.caps.Frame, .@"256KiB");
    try new_vmem.map(
        stack,
        0x7FFF_FFF0_0000,
        .{
            .writable = true,
        },
        .{},
    );

    // map an initial heap
    // log.info("mapping a heap", .{});
    const heap = try abi.caps.ROOT_MEMORY.allocSized(abi.caps.Frame, .@"256KiB");
    try new_vmem.map(
        heap,
        heap_bottom,
        .{
            .writable = true,
        },
        .{},
    );

    // log.info("creating a new thread", .{});
    const new_thread = try abi.caps.ROOT_MEMORY.alloc(abi.caps.Thread);

    try new_thread.setVmem(new_vmem);
    try new_thread.setPrio(3);
    try new_thread.writeRegs(&.{
        .arg0 = sender.cap, // set RDI to
        .user_instr_ptr = header.entry,
        .user_stack_ptr = 0x7FFF_FFF4_0000,
    });

    // log.info("ip=0x{x} sp=0x{x}", .{ header.entry, 0x7FFF_FFF4_0000 });

    log.info("everything ready, exec", .{});
    try new_thread.start();
}

const FrameVector = std.EnumArray(abi.ChunkSize, abi.caps.Frame);

fn allocVector(mem: abi.caps.Memory, size: usize) !FrameVector {
    if (size > abi.ChunkSize.@"1GiB".sizeBytes()) return error.SegmentTooBig;
    var frames: FrameVector = .initFill(.{ .cap = 0 });

    inline for (std.meta.fields(abi.ChunkSize)) |f| {
        const variant: abi.ChunkSize = @enumFromInt(f.value);
        const specific_size: usize = variant.sizeBytes();

        if (size & specific_size != 0) {
            const frame = try mem.allocSized(abi.caps.Frame, variant);
            frames.set(variant, frame);
        }
    }

    return frames;
}

fn mapVector(v: *const FrameVector, vmem: abi.caps.Vmem, _vaddr: usize, rights: abi.sys.Rights, flags: abi.sys.MapFlags) !void {
    var vaddr = _vaddr;

    var iter = @constCast(v).iterator();
    while (iter.next()) |e| {
        if (e.value.*.cap == 0) continue;

        try vmem.map(
            e.value.*,
            vaddr,
            rights,
            flags,
        );

        vaddr += e.key.sizeBytes();
    }
}

fn unmapVector(v: *const FrameVector, vmem: abi.caps.Vmem, _vaddr: usize) !void {
    var vaddr = _vaddr;

    var iter = @constCast(v).iterator();
    while (iter.next()) |e| {
        if (e.value.*.cap == 0) continue;

        try vmem.unmap(
            e.value.*,
            vaddr,
        );

        vaddr += e.key.sizeBytes();
    }
}

pub fn copyForwardsVolatile(comptime T: type, dest: []volatile T, source: []const T) void {
    for (dest[0..source.len], source) |*d, s| d.* = s;
}

pub extern var __stack_end: u8;
pub extern var __thread_stack_end: u8;

pub export fn _start() linksection(".text._start") callconv(.Naked) noreturn {
    asm volatile (
        \\ jmp zig_main
        :
        : [sp] "{rsp}" (&__stack_end),
    );
}

export fn zig_main() noreturn {
    // switch to a bigger stack (256KiB, because the initfs deflate takes up over 128KiB on its own)
    map_stack() catch |err| {
        std.debug.panic("not enough memory for a stack: {}", .{err});
    };

    asm volatile (
        \\ jmp zig_main_realstack
        :
        : [sp] "{rsp}" (STACK_TOP),
    );
    unreachable;
}

fn map_stack() !void {
    const frame = try abi.caps.ROOT_MEMORY.allocSized(abi.caps.Frame, .@"256KiB");
    // log.info("256KiB stack frame allocated", .{});
    try map_naive(frame, STACK_BOTTOM, .{ .writable = true }, .{});
    // log.info("stack mapping complete 0x{x}..0x{x}", .{ STACK_BOTTOM, STACK_TOP });
}

export fn zig_main_realstack() noreturn {
    main() catch |err| {
        std.debug.panic("{}", .{err});
    };
    while (true) {}
}
