const std = @import("std");
const abi = @import("abi");

const initfsd = @import("initfsd.zig");

const log = std.log.scoped(.bootstrap);
const Error = abi.sys.Error;

//

pub const std_options = abi.std_options;
pub const panic = abi.panic;

//

pub fn main() !void {
    try map_naive(
        abi.BOOTSTRAP_BOOT_INFO,
        0x8000_0000_0000 - 0x1000,
        .{ .writable = true },
        .{},
    );
    log.info("boot info mapped", .{});
    const boot_info = @as(*volatile abi.BootInfo, @ptrFromInt(0x8000_0000_0000 - 0x1000));
    // log.info("boot info {}", .{boot_info.*});

    log.info("bootstrap binary addr: {*}", .{boot_info.bootstrapData().ptr});
    log.info("bootstrap binary size: {}", .{boot_info.bootstrapData().len});
    log.info("bootstrap binary path: '{s}'", .{boot_info.bootstrapPath()});
    log.info("initfs addr: {*}", .{boot_info.initfsData().ptr});
    log.info("initfs size: {}", .{boot_info.initfsData().len});
    log.info("initfs path: '{s}'", .{boot_info.initfsPath()});

    try initfsd.init(boot_info.initfsData());

    // try exec_elf("/sbin/init");

    var regs: abi.sys.ThreadRegs = .{};
    // try abi.sys.thread_read_regs(abi.BOOTSTRAP_SELF_THREAD, &regs);
    // log.info("regs='{}'", .{regs});
    // regs = .{};

    new_thread = try abi.sys.alloc(abi.BOOTSTRAP_MEMORY, .thread);
    regs.user_stack_ptr = @intFromPtr(&__thread_stack_end);
    regs.user_instr_ptr = @intFromPtr(&thread_main);
    try abi.sys.thread_write_regs(new_thread, &regs);
    try abi.sys.thread_set_vmem(new_thread, abi.BOOTSTRAP_SELF_VMEM);
    try abi.sys.thread_start(new_thread);

    const recv = try abi.sys.alloc(abi.BOOTSTRAP_MEMORY, .receiver);
    send = try abi.sys.receiver_subscribe(recv);

    var msg: abi.sys.Message = undefined;
    const from = try abi.sys.recv(recv, &msg);
    log.info("got call msg={any} from={}", .{ msg, from });
    msg = .{ .arg0 = 3, .arg1 = 4, .arg2 = 5, .arg3 = 6, .arg4 = 7 };
    try abi.sys.reply(recv, &msg);

    abi.sys.yield();

    try abi.sys.thread_stop(abi.BOOTSTRAP_SELF_THREAD);
    unreachable;
}

var new_thread: u32 = 0;
var send: u32 = 0;

export fn thread_main() noreturn {
    thread() catch |err| {
        std.debug.panic("{}", .{err});
    };
    while (true) {}
}

pub fn thread() !void {
    abi.sys.log("hello from secondary thread");
    var msg: abi.sys.Message = .{ .arg0 = 2, .arg1 = 3, .arg2 = 4, .arg3 = 5, .arg4 = 6 };
    try abi.sys.call(send, &msg);
    log.info("got reply msg={}", .{msg});
    try abi.sys.thread_stop(new_thread);
    unreachable;
}

pub fn map_naive(obj: u32, vaddr: usize, rights: abi.sys.Rights, flags: abi.sys.MapFlags) !void {
    const err = abi.sys.map_frame(obj, abi.BOOTSTRAP_SELF_VMEM, vaddr, .{
        .writable = true,
    }, .{});

    if (err != error.EntryNotPresent) return err;

    try map_naive_lvl1(vaddr, rights, flags);

    return abi.sys.map_frame(obj, abi.BOOTSTRAP_SELF_VMEM, vaddr, .{
        .writable = true,
    }, .{});

    // return map_naive_fn(abi.sys.map_frame, map_naive_lvl1, .frame, vaddr, rights, flags);
}

fn map_naive_lvl1(vaddr: usize, _: abi.sys.Rights, _: abi.sys.MapFlags) !void {
    return map_naive_fn(abi.sys.map_level1, map_naive_lvl2, .page_table_level_1, vaddr, .{
        .writable = true,
    }, .{});
}

fn map_naive_lvl2(vaddr: usize, _: abi.sys.Rights, _: abi.sys.MapFlags) !void {
    return map_naive_fn(abi.sys.map_level2, map_naive_lvl3, .page_table_level_2, vaddr, .{
        .writable = true,
    }, .{});
}

fn map_naive_lvl3(vaddr: usize, _: abi.sys.Rights, _: abi.sys.MapFlags) !void {
    return map_naive_fn(abi.sys.map_level3, map_naive_fail, .page_table_level_3, vaddr, .{
        .writable = true,
    }, .{});
}

fn map_naive_fail(_: usize, _: abi.sys.Rights, _: abi.sys.MapFlags) !void {
    return error.CannotMap;
}

fn map_naive_fn(comptime map_fn: anytype, comptime if_not_present: anytype, ty: abi.ObjectType, vaddr: usize, rights: abi.sys.Rights, flags: abi.sys.MapFlags) !void {
    const obj = try abi.sys.alloc(abi.BOOTSTRAP_MEMORY, ty);
    const err = map_fn(obj, abi.BOOTSTRAP_SELF_VMEM, vaddr, .{
        .writable = true,
    }, .{});

    if (err != error.EntryNotPresent) return err;

    try if_not_present(vaddr, rights, flags);

    return map_fn(obj, abi.BOOTSTRAP_SELF_VMEM, vaddr, .{
        .writable = true,
    }, .{});
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

    const new_vmem = try abi.sys.alloc(abi.BOOTSTRAP_MEMORY, .page_table_level_4);

    const maps = 0;
    _ = new_vmem;

    try maps.append(abi.sys.Map{
        .dst = 0x7FFF_FFF0_0000,
        .src = abi.sys.MapSource.newLazy(64 * 0x1000),
        .flags = .{
            .write = true,
            .execute = false,
        },
    });

    try maps.append(abi.sys.Map{
        .dst = abi.BOOTSTRAP_HEAP,
        .src = abi.sys.MapSource.newLazy(abi.BOOTSTRAP_HEAP_SIZE),
        .flags = .{
            .write = true,
            .execute = false,
        },
    });

    while (try program_headers.next()) |program_header| {
        if (program_header.p_type != std.elf.PT_LOAD) {
            continue;
        }

        if (program_header.p_memsz == 0) {
            continue;
        }

        const bytes: []const u8 = elf.buffer[program_header.p_offset..][0..program_header.p_filesz];

        const flags = abi.sys.MapFlags{
            .write = program_header.p_flags & std.elf.PF_W != 0,
            .execute = program_header.p_flags & std.elf.PF_X != 0,
        };

        const segment_vaddr_bottom = std.mem.alignBackward(usize, program_header.p_vaddr, 0x1000);
        const segment_vaddr_top = std.mem.alignForward(usize, program_header.p_vaddr + program_header.p_memsz, 0x1000);
        const data_vaddr_bottom = program_header.p_vaddr;
        const data_vaddr_top = data_vaddr_bottom + program_header.p_filesz;
        const zero_vaddr_bottom = std.mem.alignForward(usize, data_vaddr_top, 0x1000);
        const zero_vaddr_top = segment_vaddr_top;

        try maps.append(abi.sys.Map{
            .dst = data_vaddr_bottom,
            .src = abi.sys.MapSource.newBytes(bytes),
            .flags = flags,
        });

        if (zero_vaddr_bottom != zero_vaddr_top) {
            try maps.append(abi.sys.Map{
                .dst = zero_vaddr_bottom,
                .src = abi.sys.MapSource.newLazy(zero_vaddr_top - segment_vaddr_bottom),
                .flags = flags,
            });
        }

        // log.info("flags: {any}, vaddrs: {any}", .{
        //     flags,
        //     .{
        //         segment_vaddr_bottom,
        //         segment_vaddr_top,
        //         data_vaddr_bottom,
        //         data_vaddr_top,
        //         zero_vaddr_bottom,
        //         zero_vaddr_top,
        //     },
        // });
    }

    abi.sys.system_map(1, maps.items);
    abi.sys.system_exec(1, header.entry, 0x7FFF_FFF4_0000);
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
    log.info("hello from bootstrap", .{});

    // switch to a bigger stack (256KiB, because the initfs deflate takes up over 128KiB on its own)
    const stack_top: usize = 0x8000_0000_0000 - 0x2000;
    var stack_base = stack_top - 0x40000;
    for (0..0x40) |_| {
        // log.info("mapping 0x{x}", .{stack_base});
        map_4kib(stack_base) catch |err| {
            std.debug.panic("not enough memory for a stack: {}", .{err});
        };
        stack_base += 0x1000;
    }
    log.info("stack mapping complete 0x{x}..0x{x}", .{ stack_top - 0x40000, stack_top });

    asm volatile (
        \\ jmp zig_main_realstack
        :
        : [sp] "{rsp}" (comptime stack_top),
    );
    unreachable;
}

fn map_4kib(vaddr: usize) !void {
    try map_naive(
        try abi.sys.alloc(abi.BOOTSTRAP_MEMORY, .frame),
        vaddr,
        .{ .writable = true },
        .{},
    );
}

export fn zig_main_realstack() noreturn {
    main() catch |err| {
        std.debug.panic("{}", .{err});
    };
    while (true) {}
}
