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
    var res: Error!void, const memory: caps.Memory = try root.call(.memory, void{});
    try res;

    log.debug("requesting self vmem", .{});
    res, const self_vmem: caps.Vmem = try root.call(.selfVmem, void{});
    try res;

    // endpoint for pm server <-> vm server communication
    log.debug("allocating vm endpoint", .{});
    const vm_recv = try memory.alloc(caps.Receiver);
    const vm_send = try vm_recv.subscribe();
    const root_endpoint = vm_send.cap;

    // inform the root that vm is ready
    res, _ = try root.call(.serverReady, .{ abi.ServerKind.vm, vm_send });
    try res;

    // TODO: install page fault handlers

    var system: System = .{
        .recv = vm_recv,
        .memory = memory,
        .self_vmem = self_vmem,
        .root_endpoint = root_endpoint,
    };

    const server = abi.VmProtocol.Server(.{
        .Context = *System,
        .scope = if (abi.conf.LOG_SERVERS) .vm else null,
    }, .{
        .newVmem = newVmemHandler,
        .moveOwner = moveOwnerHandler,
        .loadElf = loadElfHandler,
        .mapFrame = mapFrameHandler,
        .mapDeviceFrame = mapDeviceFrameHandler,
        .mapAnon = mapAnonHandler,
        .newThread = newThreadHandler,
        .newSender = newSenderHandler,
    }).init(&system, vm_recv);

    log.info("vm waiting for messages", .{});
    try server.run();
}

const System = struct {
    recv: caps.Receiver,
    memory: caps.Memory,
    self_vmem: caps.Vmem,
    root_endpoint: u32,
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

fn moveOwnerHandler(ctx: *System, sender: u32, req: struct { usize, u32 }) struct { Error!void, void } {
    const handle = req.@"0";
    const new_owner = req.@"1";

    if (handle >= 256) {
        return .{ Error.InvalidArgument, {} };
    }
    const addr_spc = &(ctx.address_spaces[handle] orelse {
        return .{ Error.InvalidArgument, {} };
    });
    if (addr_spc.owner != sender) {
        return .{ Error.PermissionDenied, {} };
    }

    addr_spc.owner = new_owner;

    return .{ {}, {} };
}

// FIXME: named fields in req, or better: just `req: abi.VmProtocol.Request(.loadElf)`
fn loadElfHandler(ctx: *System, sender: u32, req: struct { usize, caps.Frame, usize, usize }) struct { Error!void, usize } {
    const handle = req.@"0";
    const frame = req.@"1";
    const offset = req.@"2";
    const length = req.@"3";

    // TODO: free
    // defer frame.free();

    if (handle >= 256) {
        return .{ Error.InvalidArgument, 0 };
    }
    const addr_spc = &(ctx.address_spaces[handle] orelse {
        return .{ Error.InvalidArgument, 0 };
    });
    if (addr_spc.owner != sender) {
        return .{ Error.InvalidArgument, 0 };
    }

    const frame_size = frame.sizeOf() catch |err| {
        return .{ err, 0 };
    };

    if (frame_size.sizeBytes() < offset + length) {
        return .{ Error.InvalidAddress, 0 };
    }

    ctx.self_vmem.map(frame, ELF_TMP, .{ .writable = true }, .{}) catch
        unreachable;

    const entry = loadElf(
        ctx,
        @as([*]const u8, @ptrFromInt(ELF_TMP))[offset..][0..length],
        addr_spc,
    ) catch |err| {
        log.warn("failed to load ELF: {}", .{err});
        return .{ Error.Internal, 0 };
    };

    ctx.self_vmem.unmap(frame, ELF_TMP) catch
        unreachable;

    log.debug("got ELF to load {}", .{.{ frame, offset, length }});

    return .{ void{}, entry };
}

fn mapFrameHandler(
    ctx: *System,
    sender: u32,
    req: struct { usize, caps.Frame, abi.sys.Rights, abi.sys.MapFlags },
) struct { Error!void, usize, caps.Frame } {
    const handle = req.@"0";
    const frame = req.@"1";
    const rights = req.@"2";
    const flags = req.@"3";

    if (handle >= 256) {
        return .{ Error.InvalidArgument, 0, .{} };
    }
    const addr_spc = &(ctx.address_spaces[handle] orelse {
        return .{ Error.InvalidArgument, 0, .{} };
    });
    if (addr_spc.owner != sender) {
        return .{ Error.InvalidArgument, 0, .{} };
    }
    const size = frame.sizeOf() catch |err| {
        return .{ err, 0, .{} };
    };

    addr_spc.bottom += 0x10000;
    const vaddr = addr_spc.bottom;
    addr_spc.bottom += size.sizeBytes();
    addr_spc.bottom += 0x10000;

    addr_spc.vmem.map(
        frame,
        vaddr,
        rights,
        flags,
    ) catch |err| {
        log.warn("failed to map a frame: {}", .{err});
        return .{ Error.Internal, 0, frame };
    };

    return .{ void{}, vaddr, .{} };
}

fn mapDeviceFrameHandler(
    ctx: *System,
    sender: u32,
    req: struct { usize, caps.DeviceFrame, abi.sys.Rights, abi.sys.MapFlags },
) struct { Error!void, usize, caps.DeviceFrame } {
    const handle = req.@"0";
    const frame = req.@"1";
    const rights = req.@"2";
    const flags = req.@"3";

    if (handle >= 256) {
        return .{ abi.sys.Error.InvalidArgument, 0, .{} };
    }
    const addr_spc = &(ctx.address_spaces[handle] orelse {
        return .{ abi.sys.Error.InvalidArgument, 0, .{} };
    });
    if (addr_spc.owner != sender) {
        return .{ Error.InvalidArgument, 0, .{} };
    }
    const size = frame.sizeOf() catch |err| {
        return .{ err, 0, .{} };
    };

    addr_spc.bottom += 0x10000;
    const vaddr = addr_spc.bottom;
    addr_spc.bottom += size.sizeBytes();
    addr_spc.bottom += 0x10000;

    addr_spc.vmem.mapDevice(
        frame,
        vaddr,
        rights,
        flags,
    ) catch |err| {
        log.warn("failed to map a device frame: {}", .{err});
        return .{ Error.Internal, 0, frame };
    };

    return .{ void{}, vaddr, .{} };
}

fn mapAnonHandler(
    ctx: *System,
    sender: u32,
    req: struct { usize, usize, abi.sys.Rights, abi.sys.MapFlags },
) struct { Error!void, usize } {
    const handle = req.@"0";
    const rights = req.@"2";
    const flags = req.@"3";
    const size = abi.ChunkSize.of(req.@"1") orelse {
        return .{ Error.InvalidArgument, 0 };
    };

    if (handle >= 256) {
        return .{ Error.InvalidArgument, 0 };
    }
    const addr_spc = &(ctx.address_spaces[handle] orelse {
        return .{ Error.InvalidArgument, 0 };
    });
    if (addr_spc.owner != sender) {
        return .{ Error.InvalidArgument, 0 };
    }

    const frame = ctx.memory.allocSized(caps.Frame, size) catch |err| {
        log.warn("failed to alloc a frame: {}", .{err});
        return .{ Error.Internal, 0 };
    };

    addr_spc.bottom += 0x10000;
    const vaddr = addr_spc.bottom;
    addr_spc.bottom += size.sizeBytes();
    addr_spc.bottom += 0x10000;

    addr_spc.vmem.map(
        frame,
        vaddr,
        rights,
        flags,
    ) catch |err| {
        log.warn("failed to map a frame: {}", .{err});
        return .{ Error.Internal, 0 };
    };

    return .{ void{}, vaddr };
}

fn newSenderHandler(ctx: *System, sender: u32, _: void) struct { Error!void, caps.Sender } {
    if (ctx.root_endpoint != sender)
        return .{ Error.PermissionDenied, .{} };

    const vm_sender = ctx.recv.subscribe() catch |err| {
        log.err("failed to subscribe: {}", .{err});
        return .{ err, .{} };
    };

    return .{ void{}, vm_sender };
}

fn newThreadHandler(ctx: *System, sender: u32, req: struct { usize, usize, usize }) struct { Error!void, caps.Thread } {
    const handle = req.@"0";
    const ip_override = req.@"1";
    const sp_override = req.@"2";

    if (handle >= 256) {
        return .{ Error.InvalidArgument, .{} };
    }
    const addr_spc = &(ctx.address_spaces[handle] orelse {
        return .{ Error.InvalidArgument, .{} };
    });
    if (addr_spc.owner != sender) {
        return .{ Error.InvalidArgument, .{} };
    }

    const thread = newThread(ctx, addr_spc, ip_override, sp_override) catch |err| {
        log.err("failed to create a new thread: {}", .{err});
        return .{ Error.Internal, .{} };
    };

    return .{ void{}, thread };
}

// this is the real ELF loader for the os
// the bootstrap ELF loader was just a mini loader for vm
//
// this should support relocation, dynamic linking, lazy loading,
fn loadElf(system: *System, elf_bytes: []const u8, as: *AddressSpace) !usize {
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

        // log.debug("copying to [ 0x{x}..0x{x} ] [ 0x{x}..0x{x} ]", .{
        //     segment_vaddr_bottom + segment_data_bottom_offset,
        //     segment_vaddr_bottom + segment_data_bottom_offset + program_header.p_filesz,
        //     LOADER_TMP + segment_data_bottom_offset,
        //     LOADER_TMP + segment_data_bottom_offset + program_header.p_filesz,
        // });
        abi.util.copyForwardsVolatile(
            u8,
            @as(
                [*]volatile u8,
                @ptrFromInt(LOADER_TMP + segment_data_bottom_offset),
            )[0..program_header.p_filesz],
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

    return header.entry;
}

fn newThread(system: *System, as: *AddressSpace, ip_override: usize, sp_override: usize) !caps.Thread {
    if (sp_override == 0) {
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
    }

    const thread = try system.memory.alloc(caps.Thread);
    try thread.setVmem(as.vmem);
    try thread.writeRegs(&.{
        .user_instr_ptr = if (ip_override != 0) ip_override else as.entry,
        .user_stack_ptr = if (sp_override != 0) sp_override else as.bottom - 0x10100,
    });

    return thread;
}

comptime {
    abi.rt.installRuntime();
}
