const std = @import("std");

const abi = @import("lib.zig");
const ring = @import("ring.zig");

//

pub const Id = enum(usize) {
    /// print debug logs to serial output
    log = 0x1,

    send = 0x2,

    recv = 0x3,

    /// give up the CPU for other tasks
    yield = 0x8,
};

pub const IdPageMap = enum(usize) {
    /// map an entry
    map = 0x1,
    /// unmap an entry
    unmap = 0x2,
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
    InvalidAddress,
    NoSuchProcess,
    OutOfVirtualMemory,
    OutOfMemory,
    InvalidAlloc,
    InvalidUtf8,

    NotFound,
    AlreadyExists,
    NotADirectory,
    NotAFile,
    FilesystemError,
    PermissionDenied,
    UnexpectedEOF,
    Interrupted,
    WriteZero,
    BadFileDescriptor,

    InvalidFlags,

    InvalidDomain,
    InvalidType,
    UnknownProtocol,

    ConnectionRefused,
    Closed,

    InvalidArgument,

    IsAPipe,
    NotASocket,

    Unimplemented,

    InvalidCapability,
    EntryNotPresent,
    EntryIsHuge,

    UnknownError,

    // pub fn decode() Self!usize {}
};

pub fn encode(result: Error!usize) usize {
    const val = result catch |err| {
        return encodeError(err);
    };

    return val;
}

pub fn encodeError(err: Error) usize {
    return @bitCast(-@as(isize, switch (err) {
        error.InvalidAddress => 1,
        error.NoSuchProcess => 2,
        error.OutOfVirtualMemory => 3,
        error.OutOfMemory => 4,
        error.InvalidAlloc => 5,
        error.InvalidUtf8 => 6,

        error.NotFound => 7,
        error.AlreadyExists => 8,
        error.NotADirectory => 9,
        error.NotAFile => 10,
        error.FilesystemError => 11,
        error.PermissionDenied => 12,
        error.UnexpectedEOF => 13,
        error.Interrupted => 14,
        error.WriteZero => 15,
        error.BadFileDescriptor => 16,

        error.InvalidFlags => 17,

        error.InvalidDomain => 18,
        error.InvalidType => 19,
        error.UnknownProtocol => 20,

        error.ConnectionRefused => 21,
        error.Closed => 22,

        error.InvalidArgument => 23,

        error.IsAPipe => 24,
        error.NotASocket => 25,

        error.InvalidCapability => 26,
        error.EntryNotPresent => 27,
        error.EntryIsHuge => 28,

        error.Unimplemented => 29,

        error.UnknownError => std.debug.panic("unknown error shouldn't be encoded", .{}),
    }));
}

pub fn decode(v: usize) Error!usize {
    const v_isize: isize = @bitCast(v);
    const err = -v_isize;

    return switch (err) {
        std.math.minInt(isize)...0 => v,
        1 => error.InvalidAddress,
        2 => error.NoSuchProcess,
        3 => error.OutOfVirtualMemory,
        4 => error.OutOfMemory,
        5 => error.InvalidAlloc,
        6 => error.InvalidUtf8,

        7 => error.NotFound,
        8 => error.AlreadyExists,
        9 => error.NotADirectory,
        10 => error.NotAFile,
        11 => error.FilesystemError,
        12 => error.PermissionDenied,
        13 => error.UnexpectedEOF,
        14 => error.Interrupted,
        15 => error.WriteZero,
        16 => error.BadFileDescriptor,

        17 => error.InvalidFlags,

        18 => error.InvalidDomain,
        19 => error.InvalidType,
        20 => error.UnknownProtocol,

        21 => error.ConnectionRefused,
        22 => error.Closed,

        23 => error.InvalidArgument,

        24 => error.IsAPipe,
        25 => error.NotASocket,

        26 => error.InvalidCapability,
        27 => error.EntryNotPresent,
        28 => error.EntryIsHuge,

        29 => error.Unimplemented,

        else => return error.UnknownError,
    };
}

//

pub const Page = struct { v: [0x1000]u8 align(0x1000) };

//

pub fn log(s: []const u8) void {
    _ = call(.log, .{ @intFromPtr(s.ptr), s.len }) catch unreachable;
}

// MEMORY CAPABILITY CALLS

pub const MemoryCallId = enum(u8) {
    alloc,
};

// allocate a new capability using a memory capability
pub fn alloc(mem_cap: u32, ty: abi.ObjectType) !u32 {
    return @truncate(try call(.send, .{
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
    _ = try call(.send, .{
        @as(usize, thread_cap),
        @intFromEnum(ThreadCallId.start),
    });
}

pub fn thread_stop(thread_cap: u32) !void {
    _ = try call(.send, .{
        @as(usize, thread_cap),
        @intFromEnum(ThreadCallId.stop),
    });
}

pub fn thread_read_regs(thread_cap: u32, regs: *ThreadRegs) !void {
    _ = try call(.send, .{
        @as(usize, thread_cap),
        @intFromEnum(ThreadCallId.read_regs),
        @intFromPtr(regs),
    });
}

pub fn thread_write_regs(thread_cap: u32, regs: *const ThreadRegs) !void {
    _ = try call(.send, .{
        @as(usize, thread_cap),
        @intFromEnum(ThreadCallId.write_regs),
        @intFromPtr(regs),
    });
}

// LVL4 (VMEM) CAPABILITY CALLS

pub const Lvl4CallId = enum(u8) {};

// LVL3 CAPABILITY CALLS

pub const Lvl3CallId = enum(u8) {
    map,
};

pub fn map_level3(lvl3_cap: u32, vmem_cap: u32, vaddr: usize, rights: abi.sys.Rights, flags: abi.sys.MapFlags) !void {
    _ = try call(.send, .{
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
    _ = try call(.send, .{
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
    _ = try call(.send, .{
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
    _ = try call(.send, .{
        @as(usize, frame_cap),
        @intFromEnum(FrameCallId.map),
        @as(usize, vmem_cap),
        vaddr,
        @as(usize, @as(u32, @bitCast(rights))),
        @as(usize, @as(u40, @bitCast(flags))),
    });
}

// SYSCALLS

pub const Args = struct {
    arg0: usize = 0,
    arg1: usize = 0,
    arg2: usize = 0,
    arg3: usize = 0,
    arg4: usize = 0,
};

pub fn send(cap_ptr: usize, args: Args) !usize {
    return call(.send, .{
        cap_ptr,
        args.arg0,
        args.arg1,
        args.arg2,
        args.arg3,
        args.arg4,
    });
}

pub fn recv(cap_ptr: usize) !Args {
    const res, const args = call6rw(@intFromEnum(Id.recv), .{
        cap_ptr,
        0,
        0,
        0,
        0,
        0,
    });

    _ = try decode(res);

    return .{
        .arg0 = args[0],
        .arg1 = args[1],
        .arg2 = args[2],
        .arg3 = args[3],
        .arg4 = args[4],
    };
}

pub fn yield() void {
    _ = call(.yield, .{}) catch unreachable;
}

//

pub fn call(id: Id, args: anytype) Error!usize {
    const ArgsType = @TypeOf(args);
    const args_type_info = @typeInfo(ArgsType);
    if (args_type_info != .@"struct" or !args_type_info.@"struct".is_tuple) {
        @compileError("expected tuple argument, found " ++ @typeName(ArgsType));
    }

    const fields = args_type_info.@"struct".fields;

    const syscall_id = @intFromEnum(id);
    const result: usize = switch (fields.len) {
        0 => call0(
            syscall_id,
        ),
        1 => call1(
            syscall_id,
            @field(args, fields[0].name),
        ),
        2 => call2(
            syscall_id,
            @field(args, fields[0].name),
            @field(args, fields[1].name),
        ),
        3 => call3(
            syscall_id,
            @field(args, fields[0].name),
            @field(args, fields[1].name),
            @field(args, fields[2].name),
        ),
        4 => call4(
            syscall_id,
            @field(args, fields[0].name),
            @field(args, fields[1].name),
            @field(args, fields[2].name),
            @field(args, fields[3].name),
        ),
        5 => call5(
            syscall_id,
            @field(args, fields[0].name),
            @field(args, fields[1].name),
            @field(args, fields[2].name),
            @field(args, fields[3].name),
            @field(args, fields[4].name),
        ),
        6 => call6(
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
pub fn call0(id: usize) usize {
    return asm volatile ("syscall"
        : [ret] "={rax}" (-> usize),
        : [id] "{rax}" (id),
        : "rcx", "r11" // rcx becomes rip and r11 becomes rflags
    );
}

pub fn call1(id: usize, arg1: usize) usize {
    return asm volatile ("syscall"
        : [ret] "={rax}" (-> usize),
        : [id] "{rax}" (id),
          [arg1] "{rdi}" (arg1),
        : "rcx", "r11" // rcx becomes rip and r11 becomes rflags
    );
}

pub fn call2(id: usize, arg1: usize, arg2: usize) usize {
    return asm volatile ("syscall"
        : [ret] "={rax}" (-> usize),
        : [id] "{rax}" (id),
          [arg1] "{rdi}" (arg1),
          [arg2] "{rsi}" (arg2),
        : "rcx", "r11" // rcx becomes rip and r11 becomes rflags
    );
}

pub fn call3(id: usize, arg1: usize, arg2: usize, arg3: usize) usize {
    return asm volatile ("syscall"
        : [ret] "={rax}" (-> usize),
        : [id] "{rax}" (id),
          [arg1] "{rdi}" (arg1),
          [arg2] "{rsi}" (arg2),
          [arg3] "{rdx}" (arg3),
        : "rcx", "r11" // rcx becomes rip and r11 becomes rflags
    );
}

pub fn call4(id: usize, arg1: usize, arg2: usize, arg3: usize, arg4: usize) usize {
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

pub fn call5(id: usize, arg1: usize, arg2: usize, arg3: usize, arg4: usize, arg5: usize) usize {
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

pub fn call6(id: usize, arg1: usize, arg2: usize, arg3: usize, arg4: usize, arg5: usize, arg6: usize) usize {
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

pub fn call6rw(id: usize, args: [6]usize) struct { usize, [6]usize } {
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
