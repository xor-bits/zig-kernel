const std = @import("std");
const abi = @import("abi");

const caps = abi.caps;

//

const log = std.log.scoped(.vm);
pub const std_options = abi.std_options;
pub const panic = abi.panic;
pub const name = "vm";
const Error = abi.sys.Error;
const LOADER_TMP: usize = 0x1000_0000_0000;
const ELF_TMP: usize = 0x2000_0000_0000;

//

pub fn main() !void {
    log.info("hello from vm", .{});

    const root = abi.RootProtocol.Client().init(abi.rt.root_ipc);

    log.debug("requesting memory", .{});
    const res0: Error!void, const memory: caps.Memory = try root.call(.memory, void{});
    try res0;

    log.debug("requesting self vmem", .{});
    const res1: Error!void, const self_vmem: caps.Vmem = try root.call(.selfVmem, void{});
    try res1;

    // endpoint for pm server <-> vm server communication
    log.debug("allocating vm endpoint", .{});
    const vm_recv = try memory.alloc(caps.Receiver);
    const vm_send = try vm_recv.subscribe();

    // inform the root that vm is ready
    const res2: struct { Error!void } = try root.call(.vmReady, .{vm_send});
    try res2.@"0";

    // TODO: install page fault handlers

    var system: System = .{
        .memory = memory,
        .self_vmem = self_vmem,
    };

    const server = abi.VmProtocol.Server(.{
        .Context = *System,
        .scope = if (abi.LOG_SERVERS) .vm else null,
    }, .{
        .newVmem = newVmemHandler,
        .loadElf = loadElfHandler,
        .newThread = newThreadHandler,
    }).init(&system, vm_recv);

    log.info("vm waiting for messages", .{});
    try server.run();
}

const System = struct {
    memory: caps.Memory,
    self_vmem: caps.Vmem,
    address_spaces: [256]?AddressSpace = .{null} ** 256,
};

const AddressSpace = struct {
    owner: u32, // cap id of the sender
    vmem: caps.Vmem,
    // all frame caps mapped to the vmem, sorted by address
    // used for finding empty slots and whatever
    // memory: []caps.Frame
    // used for allocating more stuff, like loading more ELF files or growing the heap
    bottom: usize = 0x1000,
    entry: usize = 0,
};

fn newVmemHandler(ctx: *System, sender: u32, _: void) struct { Error!void, usize } {
    for (&ctx.address_spaces, 0..) |*entry, i| {
        if (entry.* != null) continue;

        const vmem = ctx.memory.alloc(caps.Vmem) catch |err| {
            // FIXME: vm server is responsible for OOMs
            std.debug.panic("vmem OOM: {}", .{err});
        };

        entry.* = .{
            .owner = sender,
            .vmem = vmem,
        };

        return .{ void{}, i };
    }

    return .{ Error.Internal, 0 };
}

// FIXME: named fields in req, or better: just `req: abi.VmProtocol.Request(.loadElf)`
fn loadElfHandler(ctx: *System, sender: u32, req: struct { usize, caps.Frame, usize, usize }) struct { Error!void } {
    const handle = req.@"0";
    const frame = req.@"1";
    const offset = req.@"2";
    const length = req.@"3";

    // TODO: free
    // defer frame.free();

    if (handle >= 256) {
        return .{abi.sys.Error.InvalidArgument};
    }
    const addr_spc = &(ctx.address_spaces[handle] orelse {
        return .{abi.sys.Error.InvalidArgument};
    });
    if (addr_spc.owner != sender) {
        return .{abi.sys.Error.InvalidArgument};
    }

    // FIXME: make sure the frame is actually as big as it is told to be

    ctx.self_vmem.map(frame, ELF_TMP, .{ .writable = true }, .{}) catch
        unreachable;

    loadElf(
        ctx,
        @as([*]const u8, @ptrFromInt(ELF_TMP))[offset..][0..length],
        addr_spc,
    ) catch |err| {
        log.warn("failed to load ELF: {}", .{err});
        return .{Error.Internal};
    };

    ctx.self_vmem.unmap(frame, ELF_TMP) catch
        unreachable;

    log.info("got ELF to load {}", .{.{ frame, offset, length }});

    return .{void{}};
}

fn newThreadHandler(ctx: *System, sender: u32, req: struct { usize }) struct { Error!void, caps.Thread } {
    const handle = req.@"0";

    if (handle >= 256) {
        return .{ abi.sys.Error.InvalidArgument, .{} };
    }
    const addr_spc = &(ctx.address_spaces[handle] orelse {
        return .{ abi.sys.Error.InvalidArgument, .{} };
    });
    if (addr_spc.owner != sender) {
        return .{ abi.sys.Error.InvalidArgument, .{} };
    }

    const thread = newThread(ctx, addr_spc) catch |err| {
        log.err("failed to create a new thread: {}", .{err});
        return .{ Error.Internal, .{} };
    };

    return .{ void{}, thread };
}

// this is the real ELF loader for the os
// the bootstrap ELF loader was just a mini loader for vm
//
// this should support relocation, dynamic linking, lazy loading,
fn loadElf(system: *System, elf_bytes: []const u8, as: *AddressSpace) !void {
    var elf = std.io.fixedBufferStream(elf_bytes);

    const header = try std.elf.Header.read(&elf);
    var program_headers = header.program_header_iterator(&elf);

    if (header.entry != 0 and as.entry == 0) {
        as.entry = header.entry;
    }

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

        as.bottom = @max(as.bottom, segment_vaddr_top + 0x1000);

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
        const frames = try abi.util.allocVector(system.memory, size);

        try abi.util.mapVector(
            &frames,
            system.self_vmem,
            LOADER_TMP,
            .{ .writable = true },
            .{},
        );

        // log.info("copying to [ 0x{x}..0x{x} ]", .{
        //     segment_vaddr_bottom + segment_data_bottom_offset,
        //     segment_vaddr_bottom + segment_data_bottom_offset + program_header.p_filesz,
        // });
        abi.util.copyForwardsVolatile(
            u8,
            @as([*]volatile u8, @ptrFromInt(LOADER_TMP + segment_data_bottom_offset))[0..program_header.p_filesz],
            bytes,
        );

        try abi.util.unmapVector(
            &frames,
            system.self_vmem,
            LOADER_TMP,
        );

        try abi.util.mapVector(
            &frames,
            as.vmem,
            segment_vaddr_bottom,
            rights,
            .{},
        );
    }
}

fn newThread(system: *System, as: *AddressSpace) !caps.Thread {
    // map a stack
    // TODO: lazy
    const stack = try system.memory.allocSized(abi.caps.Frame, .@"256KiB");
    try as.vmem.map(
        stack,
        as.bottom + 0x10000, // 0x10000 guard(s)
        .{ .writable = true },
        .{},
    );
    as.bottom += 0x20000 + abi.ChunkSize.@"256KiB".sizeBytes();

    const thread = try system.memory.alloc(caps.Thread);
    try thread.setVmem(as.vmem);
    try thread.writeRegs(&.{
        .user_instr_ptr = as.entry,
        .user_stack_ptr = as.bottom - 0x10000,
    });

    return thread;
}

comptime {
    abi.rt.installRuntime();
}
