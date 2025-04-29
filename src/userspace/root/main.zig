const std = @import("std");
const abi = @import("abi");

const initfsd = @import("initfsd.zig");

const log = std.log.scoped(.root);
const Error = abi.sys.Error;
const caps = abi.caps;

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

pub fn main() !noreturn {
    log.info("I am root", .{});

    try map_naive(
        abi.caps.ROOT_BOOT_INFO,
        BOOT_INFO,
        .{ .writable = true },
        .{},
    );
    log.info("boot info mapped", .{});
    const boot_info = @as(*volatile abi.BootInfo, @ptrFromInt(BOOT_INFO));

    try initfsd.init(boot_info.initfsData());

    const recv = try abi.caps.ROOT_MEMORY.alloc(abi.caps.Receiver);

    var system: System = .{
        .vm_bin = try binBytes("/sbin/vm"),
        .pm_bin = try binBytes("/sbin/pm"),
    };

    // FIXME: figure out a way to reclaim capabilities from crashed processes

    // virtual memory manager (system) (server)
    // maps new processes to memory and manages page faults,
    // heaps, lazy alloc, shared memory, swapping, etc.
    const vm_sender = try recv.subscribe();
    system.vm, system.vm_vmem = try exec_elf(system.vm_bin, vm_sender);
    system.vm_endpoint = vm_sender.cap;

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

    log.info("root waiting for messages", .{});
    var msg: abi.sys.Message = undefined;
    try recv.recv(&msg);
    while (true) {
        // log.info("root received: {}", .{msg});
        if (try processRootRequest(recv, &system, &msg))
            try recv.replyRecv(&msg)
        else
            try recv.recv(&msg);
    }
}

fn binBytes(path: []const u8) ![]const u8 {
    return initfsd.readFile(initfsd.openFile(path) orelse {
        log.err("missing critical system binary: '{s}'", .{path});
        return error.MissingSystem;
    });
}

const System = struct {
    vm: caps.Thread = .{},
    vm_vmem: ?caps.Vmem = null,
    vm_bin: []const u8,
    vm_sender: caps.Sender = .{},
    vm_endpoint: u32 = 0,

    pm: caps.Thread = .{},
    pm_bin: []const u8,
    pm_sender: caps.Sender = .{},
    pm_endpoint: u32 = 0,
};

fn processRootRequest(
    recv: abi.caps.Receiver,
    system: *System,
    msg: *abi.sys.Message,
) !bool {
    defer log.info("processRootRequest done", .{});
    const req = std.meta.intToEnum(abi.RootRequest, msg.arg0) catch {
        msg.arg0 = abi.sys.encode(abi.sys.Error.InvalidArgument);
        return true;
    };
    log.info("root got {}", .{req});

    switch (req) {
        .memory => {
            // only system processes can get access to the physical memory allocator
            if (system.vm_endpoint != msg.cap) {
                msg.arg0 = abi.sys.encode(Error.PermissionDenied);
                msg.extra = 0;
                return true;
            }

            const memory = abi.caps.ROOT_MEMORY.alloc(abi.caps.Memory) catch |err| {
                msg.arg0 = abi.sys.encode(err);
                msg.extra = 0;
                return true;
            };

            abi.sys.setExtra(0, memory.cap, true);
            msg.extra = 1;
            msg.arg0 = abi.sys.encode(0);
        },
        .self_vmem => {
            if (system.vm_endpoint != msg.cap) {
                msg.arg0 = abi.sys.encode(Error.PermissionDenied);
                msg.extra = 0;
                return true;
            }

            const vmem = system.vm_vmem orelse {
                msg.arg0 = abi.sys.encode(Error.AlreadyMapped);
                msg.extra = 0;
                return true;
            };
            system.vm_vmem = null;

            log.info("sending {}", .{vmem.cap});
            abi.sys.setExtra(0, vmem.cap, true);
            msg.extra = 1;
            msg.arg0 = abi.sys.encode(0);
        },
        .vm_ready => {
            if (system.vm_endpoint != msg.cap) {
                msg.arg0 = abi.sys.encode(Error.PermissionDenied);
                msg.extra = 0;
                return true;
            }

            if (msg.extra != 1) {
                msg.arg0 = abi.sys.encode(Error.InvalidArgument);
                msg.extra = 0;
                return true;
            }

            // FIXME: verify that it is a cap
            system.vm_sender = .{ .cap = @truncate(abi.sys.getExtra(0)) };
            msg.extra = 0;
            msg.arg0 = abi.sys.encode(0);

            // TODO: do all this \/ from a 2nd thread

            try recv.reply(msg); // reply now but dont recv yet

            log.info("vm ready, exec pm", .{});

            // send the pm server elf file to vm server using shared memory IPC
            const frame = try abi.caps.ROOT_MEMORY.allocSized(
                abi.caps.Frame,
                abi.ChunkSize.of(system.pm_bin.len) orelse {
                    log.err("pm binary too large", .{});
                    return error.PmElfCantSend;
                },
            );

            log.info("mapping shared mem", .{});
            try abi.caps.ROOT_SELF_VMEM.map(
                frame,
                LOADER_TMP,
                .{ .writable = true },
                .{},
            );
            log.info("copying shared mem", .{});
            abi.util.copyForwardsVolatile(
                u8,
                @as([*]volatile u8, @ptrFromInt(LOADER_TMP))[0..system.pm_bin.len],
                system.pm_bin,
            );
            log.info("unmapping shared mem", .{});
            try abi.caps.ROOT_SELF_VMEM.unmap(
                frame,
                LOADER_TMP,
            );

            log.info("creating new vmem", .{});
            var exec_msg: abi.sys.Message = .{
                .extra = 0,
                .arg0 = @intFromEnum(abi.VmRequest.new_vmem),
            };
            try system.vm_sender.call(&exec_msg);

            const pm_vm_handle = try abi.sys.decode(exec_msg.arg0);

            log.info("sending shared mem", .{});
            exec_msg = .{
                .extra = 1,
                .arg0 = @intFromEnum(abi.VmRequest.load_elf),
                .arg1 = pm_vm_handle,
                .arg2 = 0,
                .arg3 = system.pm_bin.len,
            };
            abi.sys.setExtra(0, frame.cap, true);
            try system.vm_sender.call(&exec_msg);
            _ = try abi.sys.decode(exec_msg.arg0);

            log.info("new pm thread", .{});
            exec_msg = .{
                .extra = 0,
                .arg0 = @intFromEnum(abi.VmRequest.new_thread),
                .arg1 = pm_vm_handle,
            };
            try system.vm_sender.call(&exec_msg);
            const thread: caps.Thread = .{ .cap = @truncate(abi.sys.getExtra(0)) };
            _ = try abi.sys.decode(exec_msg.arg0);

            log.info("start pm", .{});
            try thread.setPrio(0);
            try thread.start();

            return false; // false => no reply
        },
        .pm_ready => {
            if (system.vm_endpoint != msg.cap) {
                msg.arg0 = abi.sys.encode(Error.PermissionDenied);
                msg.extra = 0;
                return true;
            }

            if (msg.extra != 1) {
                msg.arg0 = abi.sys.encode(Error.InvalidArgument);
                msg.extra = 0;
                return true;
            }

            // FIXME: verify that it is a cap
            system.vm_sender = .{ .cap = @truncate(abi.sys.getExtra(0)) };
            msg.extra = 0;
            msg.arg0 = abi.sys.encode(0);

            // TODO: do all this \/ from a 2nd thread

            try recv.reply(msg); // reply now but dont recv yet
        },
        .vm, .pm, .vfs => {
            msg.arg0 = abi.sys.encode(Error.Unimplemented);
            msg.extra = 0;
            return true;
        },
    }

    return true;
}

pub fn map_naive(frame: abi.caps.Frame, vaddr: usize, rights: abi.sys.Rights, flags: abi.sys.MapFlags) !void {
    try abi.caps.ROOT_SELF_VMEM.map(
        frame,
        vaddr,
        rights,
        flags,
    );
}

fn exec_elf(elf_bytes: []const u8, sender: abi.caps.Sender) !struct { caps.Thread, caps.Vmem } {
    var elf = std.io.fixedBufferStream(elf_bytes);

    var crc: u32 = 0;
    for (elf_bytes) |b| {
        crc = @addWithOverflow(crc, @as(u32, b))[0];
    }
    log.info("xor crc of is {d}", .{crc});

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
        const frames = try abi.util.allocVector(abi.caps.ROOT_MEMORY, size);

        try abi.util.mapVector(
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
        abi.util.copyForwardsVolatile(
            u8,
            @as([*]volatile u8, @ptrFromInt(LOADER_TMP + segment_data_bottom_offset))[0..program_header.p_filesz],
            bytes,
        );

        try abi.util.unmapVector(
            &frames,
            abi.caps.ROOT_SELF_VMEM,
            LOADER_TMP,
        );

        try abi.util.mapVector(
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
        .{ .writable = true },
        .{},
    );

    // map an initial heap
    // log.info("mapping a heap", .{});
    const heap = try abi.caps.ROOT_MEMORY.allocSized(abi.caps.Frame, .@"256KiB");
    try new_vmem.map(
        heap,
        heap_bottom,
        .{ .writable = true },
        .{},
    );

    // log.info("creating a new thread", .{});
    const new_thread = try abi.caps.ROOT_MEMORY.alloc(abi.caps.Thread);

    try new_thread.setVmem(new_vmem);
    try new_thread.setPrio(0);
    try new_thread.writeRegs(&.{
        .arg0 = sender.cap, // set RDI to
        .user_instr_ptr = header.entry,
        .user_stack_ptr = 0x7FFF_FFF4_0000,
    });

    // log.info("ip=0x{x} sp=0x{x}", .{ header.entry, 0x7FFF_FFF4_0000 });

    log.info("everything ready, exec", .{});
    try new_thread.start();

    return .{ new_thread, new_vmem };
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
}
