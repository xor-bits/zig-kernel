const std = @import("std");

const abi = @import("lib.zig");
const ring = @import("ring.zig");

//

pub const Id = enum(usize) {
    /// print debug logs to serial output
    log = 0x1,

    send = 0x2,

    recv = 0x3,

    reply = 0x4,

    /// give up the CPU for other tasks
    yield = 0x8,
};

pub const Rights = extern struct {
    readable: bool = true,
    writable: bool = false,
    executable: bool = false,
    user_accessible: bool = true,

    pub fn intersection(self: Rights, other: Rights) Rights {
        return Rights{
            .readable = self.readable and other.readable,
            .writable = self.writable and other.writable,
            .executable = self.executable and other.executable,
            .user_accessible = self.user_accessible and other.user_accessible,
        };
    }
};

pub const MapFlags = extern struct {
    write_through: bool = false,
    cache_disable: bool = false,
    huge_page: bool = false,
    global: bool = false,
    protection_key: u8 = 0,
};

pub const Error = error{
    Unimplemented,
    InvalidAddress,
    InvalidFlags,
    InvalidType,
    InvalidArgument,
    InvalidCapability,
    InvalidSyscall,
    OutOfMemory,
    EntryNotPresent,
    EntryIsHuge,
    NotStopped,
    IsStopped,
    NoVmem,

    UnknownError,
};

pub fn encode(result: Error!usize) usize {
    const val = result catch |err| {
        return encodeError(err);
    };

    return val;
}

pub fn encodeError(err: Error) usize {
    return @bitCast(-@as(isize, switch (err) {
        error.Unimplemented => 1,
        error.InvalidAddress => 2,
        error.InvalidFlags => 3,
        error.InvalidType => 4,
        error.InvalidArgument => 5,
        error.InvalidCapability => 6,
        error.InvalidSyscall => 7,
        error.OutOfMemory => 8,
        error.EntryNotPresent => 9,
        error.EntryIsHuge => 10,
        error.NotStopped => 11,
        error.IsStopped => 12,
        error.NoVmem => 13,

        error.UnknownError => std.debug.panic("unknown error shouldn't be encoded", .{}),
    }));
}

pub fn decode(v: usize) Error!usize {
    const v_isize: isize = @bitCast(v);
    const err = -v_isize;

    return switch (err) {
        std.math.minInt(isize)...0 => v,
        1 => error.Unimplemented,
        2 => error.InvalidAddress,
        3 => error.InvalidFlags,
        4 => error.InvalidType,
        5 => error.InvalidArgument,
        6 => error.InvalidCapability,
        7 => error.InvalidSyscall,
        8 => error.OutOfMemory,
        9 => error.EntryNotPresent,
        10 => error.EntryIsHuge,
        11 => error.NotStopped,
        12 => error.IsStopped,
        13 => error.NoVmem,
        else => return error.UnknownError,
    };
}

//

// MEMORY CAPABILITY CALLS

pub const MemoryCallId = enum(u8) {
    alloc,
};

// allocate a new capability using a memory capability
pub fn alloc(mem_cap: u32, ty: abi.ObjectType) !u32 {
    return @truncate(try syscall(.send, .{
        @as(usize, mem_cap),
        @intFromEnum(MemoryCallId.alloc),
        @as(usize, @intFromEnum(ty)),
    }));
}

// THREAD CAPABILITY CALLS

pub const ThreadCallId = enum(u8) {
    start,
    stop,
    read_regs,
    write_regs,
    set_vmem,
    set_prio,
};

pub const ThreadRegs = extern struct {
    _r15: u64 = 0,
    _r14: u64 = 0,
    _r13: u64 = 0,
    _r12: u64 = 0,
    // RFlags, inaccessible to user-space (it is ignored on write and set to 0 on read)
    _r11: u64 = 0,
    /// r10
    arg5: u64 = 0,
    /// r9
    arg4: u64 = 0,
    /// r8
    arg3: u64 = 0,
    _rbp: u64 = 0,
    /// rsi
    arg1: u64 = 0,
    /// rdi
    arg0: u64 = 0,
    /// rdx
    arg2: u64 = 0,
    /// rcx
    user_instr_ptr: u64 = 0,
    _rbx: u64 = 0,
    /// rax = 0, also the return register
    syscall_id: u64 = 0,
    /// rsp
    user_stack_ptr: u64 = 0,
};

pub fn thread_start(thread_cap: u32) !void {
    _ = try syscall(.send, .{
        @as(usize, thread_cap),
        @intFromEnum(ThreadCallId.start),
    });
}

pub fn thread_stop(thread_cap: u32) !void {
    _ = try syscall(.send, .{
        @as(usize, thread_cap),
        @intFromEnum(ThreadCallId.stop),
    });
}

pub fn thread_read_regs(thread_cap: u32, regs: *ThreadRegs) !void {
    _ = try syscall(.send, .{
        @as(usize, thread_cap),
        @intFromEnum(ThreadCallId.read_regs),
        @intFromPtr(regs),
    });
}

pub fn thread_write_regs(thread_cap: u32, regs: *const ThreadRegs) !void {
    _ = try syscall(.send, .{
        @as(usize, thread_cap),
        @intFromEnum(ThreadCallId.write_regs),
        @intFromPtr(regs),
    });
}

pub fn thread_set_vmem(thread_cap: u32, vmem_cap: u32) !void {
    _ = try syscall(.send, .{
        @as(usize, thread_cap),
        @intFromEnum(ThreadCallId.set_vmem),
        @as(usize, vmem_cap),
    });
}

pub fn thread_set_prio(thread_cap: u32, priority: u2) !void {
    _ = try syscall(.send, .{
        @as(usize, thread_cap),
        @intFromEnum(ThreadCallId.set_prio),
        @as(usize, priority),
    });
}

// LVL4 (VMEM) CAPABILITY CALLS

pub const Lvl4CallId = enum(u8) {};

// LVL3 CAPABILITY CALLS

pub const Lvl3CallId = enum(u8) {
    map,
};

pub fn map_level3(lvl3_cap: u32, vmem_cap: u32, vaddr: usize, rights: abi.sys.Rights, flags: abi.sys.MapFlags) !void {
    _ = try syscall(.send, .{
        @as(usize, lvl3_cap),
        @intFromEnum(Lvl3CallId.map),
        @as(usize, vmem_cap),
        vaddr,
        @as(usize, @as(u32, @bitCast(rights))),
        @as(usize, @as(u40, @bitCast(flags))),
    });
}

// LVL2 CAPABILITY CALLS

pub const Lvl2CallId = enum(u8) {
    map,
};

pub fn map_level2(lvl2_cap: u32, vmem_cap: u32, vaddr: usize, rights: abi.sys.Rights, flags: abi.sys.MapFlags) !void {
    _ = try syscall(.send, .{
        @as(usize, lvl2_cap),
        @intFromEnum(Lvl2CallId.map),
        @as(usize, vmem_cap),
        vaddr,
        @as(usize, @as(u32, @bitCast(rights))),
        @as(usize, @as(u40, @bitCast(flags))),
    });
}

// LVL1 CAPABILITY CALLS

pub const Lvl1CallId = enum(u8) {
    map,
};

pub fn map_level1(lvl1_cap: u32, vmem_cap: u32, vaddr: usize, rights: abi.sys.Rights, flags: abi.sys.MapFlags) !void {
    _ = try syscall(.send, .{
        @as(usize, lvl1_cap),
        @intFromEnum(Lvl1CallId.map),
        @as(usize, vmem_cap),
        vaddr,
        @as(usize, @as(u32, @bitCast(rights))),
        @as(usize, @as(u40, @bitCast(flags))),
    });
}

// FRAME CAPABILITY CALLS

pub const FrameCallId = enum(u8) {
    map,
};

pub fn map_frame(frame_cap: u32, vmem_cap: u32, vaddr: usize, rights: abi.sys.Rights, flags: abi.sys.MapFlags) !void {
    _ = try syscall(.send, .{
        @as(usize, frame_cap),
        @intFromEnum(FrameCallId.map),
        @as(usize, vmem_cap),
        vaddr,
        @as(usize, @as(u32, @bitCast(rights))),
        @as(usize, @as(u40, @bitCast(flags))),
    });
}

// RECEIVER CAPABILITY CALLS

pub const ReceiverCallId = enum(u8) {
    subscribe,
};

pub fn receiver_subscribe(recv_cap: u32) Error!u32 {
    return @truncate(try syscall(.send, .{
        @as(usize, recv_cap),
        @intFromEnum(ReceiverCallId.subscribe),
    }));
}

// SENDER CAPABILITY CALLS

// SYSCALLS

pub const Args = struct {
    arg0: usize = 0,
    arg1: usize = 0,
    arg2: usize = 0,
    arg3: usize = 0,
    arg4: usize = 0,
};

pub fn log(s: []const u8) void {
    _ = syscall(.log, .{ @intFromPtr(s.ptr), s.len }) catch unreachable;
}

pub fn call(cap_ptr: usize, args: *Args) !void {
    _ = try rwcall(.send, cap_ptr, args);
}

pub fn recv(cap_ptr: usize, args: *Args) !usize {
    return rwcall(.recv, cap_ptr, args);
}

fn rwcall(id: Id, cap_ptr: usize, args: *Args) !usize {
    const res, const args_out = syscall6rw(@intFromEnum(id), .{
        cap_ptr,
        args.arg0,
        args.arg1,
        args.arg2,
        args.arg3,
        args.arg4,
    });
    args.arg0 = args_out[1];
    args.arg1 = args_out[2];
    args.arg2 = args_out[3];
    args.arg3 = args_out[4];
    args.arg4 = args_out[5];

    return decode(res);
}

pub fn reply(cap_ptr: usize, args: Args) !void {
    _ = try syscall(.reply, .{
        cap_ptr,
        args.arg0,
        args.arg1,
        args.arg2,
        args.arg3,
        args.arg4,
    });
}

// pub fn recv(cap_ptr: usize) !struct { usize, Args } {
//     const res, const args = call6rw(@intFromEnum(Id.replyRecv), .{
//         cap_ptr,
//         0,
//         0,
//         0,
//         0,
//         0,
//     });
//     const result = try decode(res);
//     return .{ result, .{
//         .arg0 = args[1],
//         .arg1 = args[2],
//         .arg2 = args[3],
//         .arg3 = args[4],
//         .arg4 = args[5],
//     } };
// }

pub fn yield() void {
    _ = syscall(.yield, .{}) catch unreachable;
}

//

pub fn syscall(id: Id, args: anytype) Error!usize {
    const ArgsType = @TypeOf(args);
    const args_type_info = @typeInfo(ArgsType);
    if (args_type_info != .@"struct" or !args_type_info.@"struct".is_tuple) {
        @compileError("expected tuple argument, found " ++ @typeName(ArgsType));
    }

    const fields = args_type_info.@"struct".fields;

    const syscall_id = @intFromEnum(id);
    const result: usize = switch (fields.len) {
        0 => syscall0(
            syscall_id,
        ),
        1 => syscall1(
            syscall_id,
            @field(args, fields[0].name),
        ),
        2 => syscall2(
            syscall_id,
            @field(args, fields[0].name),
            @field(args, fields[1].name),
        ),
        3 => syscall3(
            syscall_id,
            @field(args, fields[0].name),
            @field(args, fields[1].name),
            @field(args, fields[2].name),
        ),
        4 => syscall4(
            syscall_id,
            @field(args, fields[0].name),
            @field(args, fields[1].name),
            @field(args, fields[2].name),
            @field(args, fields[3].name),
        ),
        5 => syscall5(
            syscall_id,
            @field(args, fields[0].name),
            @field(args, fields[1].name),
            @field(args, fields[2].name),
            @field(args, fields[3].name),
            @field(args, fields[4].name),
        ),
        6 => syscall6(
            syscall_id,
            @field(args, fields[0].name),
            @field(args, fields[1].name),
            @field(args, fields[2].name),
            @field(args, fields[3].name),
            @field(args, fields[4].name),
            @field(args, fields[5].name),
        ),
        else => @compileError("expected 6 or less syscall arguments, found " ++ fields.len),
    };

    return try decode(result);
}

// TODO: move intFromEnum to here
pub fn syscall0(id: usize) usize {
    return asm volatile ("syscall"
        : [ret] "={rax}" (-> usize),
        : [id] "{rax}" (id),
        : "rcx", "r11" // rcx becomes rip and r11 becomes rflags
    );
}

pub fn syscall1(id: usize, arg1: usize) usize {
    return asm volatile ("syscall"
        : [ret] "={rax}" (-> usize),
        : [id] "{rax}" (id),
          [arg1] "{rdi}" (arg1),
        : "rcx", "r11" // rcx becomes rip and r11 becomes rflags
    );
}

pub fn syscall2(id: usize, arg1: usize, arg2: usize) usize {
    return asm volatile ("syscall"
        : [ret] "={rax}" (-> usize),
        : [id] "{rax}" (id),
          [arg1] "{rdi}" (arg1),
          [arg2] "{rsi}" (arg2),
        : "rcx", "r11" // rcx becomes rip and r11 becomes rflags
    );
}

pub fn syscall3(id: usize, arg1: usize, arg2: usize, arg3: usize) usize {
    return asm volatile ("syscall"
        : [ret] "={rax}" (-> usize),
        : [id] "{rax}" (id),
          [arg1] "{rdi}" (arg1),
          [arg2] "{rsi}" (arg2),
          [arg3] "{rdx}" (arg3),
        : "rcx", "r11" // rcx becomes rip and r11 becomes rflags
    );
}

pub fn syscall4(id: usize, arg1: usize, arg2: usize, arg3: usize, arg4: usize) usize {
    return asm volatile ("syscall"
        : [ret] "={rax}" (-> usize),
        : [id] "{rax}" (id),
          [arg1] "{rdi}" (arg1),
          [arg2] "{rsi}" (arg2),
          [arg3] "{rdx}" (arg3),
          [arg4] "{r8}" (arg4),
        : "rcx", "r11" // rcx becomes rip and r11 becomes rflags
    );
}

pub fn syscall5(id: usize, arg1: usize, arg2: usize, arg3: usize, arg4: usize, arg5: usize) usize {
    return asm volatile ("syscall"
        : [ret] "={rax}" (-> usize),
        : [id] "{rax}" (id),
          [arg1] "{rdi}" (arg1),
          [arg2] "{rsi}" (arg2),
          [arg3] "{rdx}" (arg3),
          [arg4] "{r8}" (arg4),
          [arg5] "{r9}" (arg5),
        : "rcx", "r11" // rcx becomes rip and r11 becomes rflags
    );
}

pub fn syscall6(id: usize, arg1: usize, arg2: usize, arg3: usize, arg4: usize, arg5: usize, arg6: usize) usize {
    return asm volatile ("syscall"
        : [ret] "={rax}" (-> usize),
        : [id] "{rax}" (id),
          [arg1] "{rdi}" (arg1),
          [arg2] "{rsi}" (arg2),
          [arg3] "{rdx}" (arg3),
          [arg4] "{r8}" (arg4),
          [arg5] "{r9}" (arg5),
          [arg6] "{r10}" (arg6),
        : "rcx", "r11" // rcx becomes rip and r11 becomes rflags
    );
}

pub fn syscall6rw(id: usize, args: [6]usize) struct { usize, [6]usize } {
    var arg0: usize = undefined; // arrays dont work on outputs for whatever reason
    var arg1: usize = undefined;
    var arg2: usize = undefined;
    var arg3: usize = undefined;
    var arg4: usize = undefined;
    var arg5: usize = undefined;

    const res = asm volatile ("syscall"
        : [ret] "={rax}" (-> usize),
          [arg0out] "={rdi}" (arg0),
          [arg1out] "={rsi}" (arg1),
          [arg2out] "={rdx}" (arg2),
          [arg3out] "={r8}" (arg3),
          [arg4out] "={r9}" (arg4),
          [arg5out] "={r10}" (arg5),
        : [id] "{rax}" (id),
          [arg0in] "{rdi}" (args[0]),
          [arg1in] "{rsi}" (args[1]),
          [arg2in] "{rdx}" (args[2]),
          [arg3in] "{r8}" (args[3]),
          [arg4in] "{r9}" (args[4]),
          [arg5in] "{r10}" (args[5]),
        : "rcx", "r11" // rcx becomes rip and r11 becomes rflags
    );

    return .{
        res,
        .{ arg0, arg1, arg2, arg3, arg4, arg5 },
    };
}
