const std = @import("std");
const abi = @import("abi");

const caps = abi.caps;

//

const log = std.log.scoped(.vm);
pub const std_options = abi.std_options;
pub const panic = abi.panic;
pub const name = "pm";
const Error = abi.sys.Error;
const LOADER_TMP: usize = 0x1000_0000_0000;
const ELF_TMP: usize = 0x2000_0000_0000;

//

pub fn main() !void {
    log.info("hello from vm", .{});

    const root = abi.rt.root_ipc;

    log.debug("requesting memory", .{});
    var msg: abi.sys.Message = .{ .arg0 = @intFromEnum(abi.RootRequest.memory) };
    try root.call(&msg);
    try abi.sys.decodeVoid(msg.arg0);
    const memory = caps.Memory{ .cap = @truncate(abi.sys.getExtra(0)) };

    log.debug("requesting self vmem", .{});
    msg = .{ .arg0 = @intFromEnum(abi.RootRequest.self_vmem) };
    try root.call(&msg);
    const self_vmem = caps.Vmem{ .cap = @truncate(abi.sys.getExtra(0)) };

    // endpoint for pm server <-> vm server communication
    log.debug("allocating vm endpoint", .{});
    const vm_recv = try memory.alloc(caps.Receiver);
    const vm_send = try vm_recv.subscribe();

    // inform the root that vm is ready
    msg = .{ .extra = 1, .arg0 = @intFromEnum(abi.RootRequest.vm_ready) };
    abi.sys.setExtra(0, vm_send.cap, true);
    try root.call(&msg);
    _ = try abi.sys.decode(msg.arg0);

    // TODO: install page fault handlers

    var system: System = .{
        .memory = memory,
        .self_vmem = self_vmem,
    };

    log.info("vm waiting for messages", .{});
    try vm_recv.recv(&msg);
    while (true) {
        processRequest(&system, &msg);
        try vm_recv.replyRecv(&msg);
    }
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

fn processRequest(system: *System, msg: *abi.sys.Message) void {
    const req = std.meta.intToEnum(abi.VmRequest, msg.arg0) catch {
        msg.arg0 = abi.sys.encode(abi.sys.Error.InvalidArgument);
        msg.extra = 0;
        return;
    };
    log.info("vm got {}", .{req});

    switch (req) {
        .new_vmem => {
            if (msg.extra != 0) {
                msg.arg0 = abi.sys.encode(abi.sys.Error.InvalidArgument);
                msg.extra = 0;
                return;
            }

            for (&system.address_spaces, 0..) |*entry, i| {
                if (entry.* != null) continue;

                const vmem = system.memory.alloc(caps.Vmem) catch |err| {
                    // FIXME: vm server is responsible for OOMs
                    std.debug.panic("vmem OOM: {}", .{err});
                };

                entry.* = .{
                    .owner = msg.cap,
                    .vmem = vmem,
                };

                msg.arg0 = abi.sys.encode(i);
                return;
            }

            msg.arg0 = abi.sys.encode(Error.Internal);
            return;
        },
        .load_elf => {
            if (msg.extra != 1) {
                msg.arg0 = abi.sys.encode(abi.sys.Error.InvalidArgument);
                msg.extra = 0;
                return;
            }
            msg.extra = 0;

            // FIXME: verify that it is a cap and not raw data
            const frame_cap: u32 = @truncate(abi.sys.getExtra(0));

            const ty = abi.sys.debug(frame_cap) catch |err| {
                msg.arg0 = abi.sys.encode(err);
                return;
            };
            if (ty != .frame) {
                abi.sys.setExtra(0, frame_cap, true);
                msg.extra = 1;
                msg.arg0 = abi.sys.encode(abi.sys.Error.InvalidArgument);
                return;
            }
            const frame = abi.caps.Frame{ .cap = frame_cap };
            // TODO: free
            // defer frame.free();

            const handle = msg.arg1;
            if (handle >= 256) {
                msg.arg0 = abi.sys.encode(abi.sys.Error.InvalidArgument);
                return;
            }
            const addr_spc = &(system.address_spaces[handle] orelse {
                msg.arg0 = abi.sys.encode(abi.sys.Error.InvalidArgument);
                return;
            });
            if (addr_spc.owner != msg.cap) {
                msg.arg0 = abi.sys.encode(abi.sys.Error.InvalidArgument);
                return;
            }

            const offset = msg.arg2;
            const length = msg.arg3;

            // FIXME: make sure the frame is actually as big as it is told to be

            system.self_vmem.map(frame, ELF_TMP, .{ .writable = true }, .{}) catch
                unreachable;

            load_elf(
                system,
                @as([*]const u8, @ptrFromInt(ELF_TMP))[offset..][0..length],
                addr_spc,
            ) catch |err| {
                log.warn("failed to load ELF: {}", .{err});
                msg.arg0 = abi.sys.encode(Error.Internal);
                return;
            };

            system.self_vmem.unmap(frame, ELF_TMP) catch
                unreachable;

            log.info("got ELF to load {}", .{.{ frame, offset, length }});

            msg.arg0 = abi.sys.encode(0);
        },
        .new_thread => {
            if (msg.extra != 0) {
                msg.arg0 = abi.sys.encode(abi.sys.Error.InvalidArgument);
                msg.extra = 0;
                return;
            }

            const handle = msg.arg1;
            if (handle >= 256) {
                msg.arg0 = abi.sys.encode(abi.sys.Error.InvalidArgument);
                return;
            }
            const addr_spc = &(system.address_spaces[handle] orelse {
                msg.arg0 = abi.sys.encode(abi.sys.Error.InvalidArgument);
                return;
            });
            if (addr_spc.owner != msg.cap) {
                msg.arg0 = abi.sys.encode(abi.sys.Error.InvalidArgument);
                return;
            }

            const thread = newThread(system, addr_spc) catch |err| {
                log.err("failed to create a new thread: {}", .{err});
                msg.arg0 = abi.sys.encode(Error.Internal);
                return;
            };

            abi.sys.setExtra(0, thread.cap, true);
            msg.extra = 1;
            msg.arg0 = abi.sys.encode(0);
            return;
        },
    }
}

// this is the real ELF loader for the os
// the bootstrap ELF loader was just a mini loader for vm
//
// this should support relocation, dynamic linking, lazy loading,
fn load_elf(system: *System, elf_bytes: []const u8, as: *AddressSpace) !void {
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
    abi.rt.install_rt();
}
