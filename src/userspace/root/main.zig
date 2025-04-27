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
        abi.ROOT_BOOT_INFO,
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

    try exec_elf("/sbin/init");

    log.info("root dead", .{});
    try abi.sys.thread_stop(abi.ROOT_SELF_THREAD);
    unreachable;
}

pub fn map_naive(obj: u32, vaddr: usize, rights: abi.sys.Rights, flags: abi.sys.MapFlags) !void {
    try abi.sys.map(
        abi.ROOT_SELF_VMEM,
        obj,
        vaddr,
        rights,
        flags,
    );
}

fn exec_elf(path: []const u8) !void {
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

    const new_vmem = try abi.sys.alloc(abi.ROOT_MEMORY, .vmem, null);

    // try abi.sys.vmem_transfer_cap(
    //     new_vmem,
    // );

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
        const frames = try allocVector(abi.ROOT_MEMORY, size);

        try mapVector(
            &frames,
            abi.ROOT_SELF_VMEM,
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
            abi.ROOT_SELF_VMEM,
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
    try abi.sys.map(
        new_vmem,
        try abi.sys.alloc(abi.ROOT_MEMORY, .frame, .@"256KiB"),
        0x7FFF_FFF0_0000,
        .{
            .writable = true,
        },
        .{},
    );

    // map an initial heap
    // log.info("mapping a heap", .{});
    try abi.sys.map(
        new_vmem,
        try abi.sys.alloc(abi.ROOT_MEMORY, .frame, .@"256KiB"),
        heap_bottom,
        .{
            .writable = true,
        },
        .{},
    );

    // log.info("creating a new thread", .{});
    const new_thread = try abi.sys.alloc(abi.ROOT_MEMORY, .thread, null);

    try abi.sys.thread_set_vmem(new_thread, new_vmem);
    try abi.sys.thread_set_prio(new_thread, 3);
    try abi.sys.thread_write_regs(new_thread, &.{
        .user_instr_ptr = header.entry,
        .user_stack_ptr = 0x7FFF_FFF4_0000,
    });

    // log.info("ip=0x{x} sp=0x{x}", .{ header.entry, 0x7FFF_FFF4_0000 });

    log.info("everything ready, exec", .{});
    try abi.sys.thread_start(new_thread);
}

const FrameVector = std.EnumArray(abi.ChunkSize, u32);

fn allocVector(mem_cap: u32, size: usize) !FrameVector {
    if (size > abi.ChunkSize.@"1GiB".sizeBytes()) return error.SegmentTooBig;
    var frames: FrameVector = .initFill(0);

    inline for (std.meta.fields(abi.ChunkSize)) |f| {
        const variant: abi.ChunkSize = @enumFromInt(f.value);
        const specific_size: usize = variant.sizeBytes();

        if (size & specific_size != 0) {
            const frame = try abi.sys.alloc(mem_cap, .frame, variant);
            frames.set(variant, frame);
        }
    }

    return frames;
}

fn mapVector(v: *const FrameVector, vmem_cap: u32, _vaddr: usize, rights: abi.sys.Rights, flags: abi.sys.MapFlags) !void {
    var vaddr = _vaddr;

    var iter = @constCast(v).iterator();
    while (iter.next()) |e| {
        if (e.value.* == 0) continue;

        try abi.sys.map(
            vmem_cap,
            e.value.*,
            vaddr,
            rights,
            flags,
        );

        vaddr += e.key.sizeBytes();
    }
}

fn unmapVector(v: *const FrameVector, vmem_cap: u32, _vaddr: usize) !void {
    var vaddr = _vaddr;

    var iter = @constCast(v).iterator();
    while (iter.next()) |e| {
        if (e.value.* == 0) continue;

        try abi.sys.unmap(
            vmem_cap,
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
    const frame = try abi.sys.alloc(abi.ROOT_MEMORY, .frame, .@"256KiB");
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
