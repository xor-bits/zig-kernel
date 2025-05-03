const std = @import("std");

const abi = @import("lib.zig");
const ring = @import("ring.zig");

//

pub const Id = enum(usize) {
    /// print debug logs to serial output
    log = 1,
    /// identify the object type of a capability
    debug,
    call,
    recv,
    reply,
    reply_recv,
    /// read (and reset) an extra message register of the current thread
    get_extra,
    /// write an extra message register of the current thread
    set_extra,
    /// give up the CPU for other tasks
    yield,

    // TODO: maybe move all object call id's here to be syscall id's
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
    ThreadSafety,
    AlreadyMapped,
    NotMapped,
    MappingOverlap,
    PermissionDenied,
    Internal,
    NoReplyTarget,
    NotifyAlreadySubscribed,
    IrqAlreadySubscribed,
    TooManyIrqs,

    UnknownError,
};

pub fn encode(result: Error!usize) usize {
    const val = result catch |err| {
        return encodeError(err);
    };

    return val;
}

pub fn encodeVoid(result: Error!void) usize {
    result catch |err| {
        return encodeError(err);
    };
    return 0;
}

fn encodeError(err: Error) usize {
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
        error.ThreadSafety => 14,
        error.AlreadyMapped => 15,
        error.NotMapped => 16,
        error.MappingOverlap => 17,
        error.PermissionDenied => 18,
        error.Internal => 19,
        error.NoReplyTarget => 20,
        error.NotifyAlreadySubscribed => 21,
        error.IrqAlreadySubscribed => 22,
        error.TooManyIrqs => 23,

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
        14 => error.ThreadSafety,
        15 => error.AlreadyMapped,
        16 => error.NotMapped,
        17 => error.MappingOverlap,
        18 => error.PermissionDenied,
        19 => error.Internal,
        20 => error.NoReplyTarget,
        21 => error.NotifyAlreadySubscribed,
        22 => error.IrqAlreadySubscribed,
        23 => error.TooManyIrqs,

        else => return error.UnknownError,
    };
}

pub fn decodeVoid(v: usize) Error!void {
    _ = try decode(v);
}

//

// MEMORY CAPABILITY CALLS

pub const MemoryCallId = enum(u8) {
    alloc,
};

// allocate a new capability using a memory capability
pub fn alloc(mem_cap: u32, ty: abi.ObjectType, dyn_size: ?abi.ChunkSize) !u32 {
    var msg: Message = .{
        .arg0 = @intFromEnum(MemoryCallId.alloc),
        .arg1 = @intFromEnum(ty),
        .arg2 = @intFromEnum(dyn_size orelse .@"4KiB"),
    };
    try call(mem_cap, &msg);
    return @truncate(msg.cap);
}

// THREAD CAPABILITY CALLS

pub const ThreadCallId = enum(u8) {
    start,
    stop,
    read_regs,
    write_regs,
    set_vmem,
    set_prio,
    transfer_cap,
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

pub fn threadStart(thread_cap: u32) !void {
    var msg: Message = .{
        .arg0 = @intFromEnum(ThreadCallId.start),
    };
    try call(thread_cap, &msg);
}

pub fn threadStop(thread_cap: u32) !void {
    var msg: Message = .{
        .arg0 = @intFromEnum(ThreadCallId.stop),
    };
    try call(thread_cap, &msg);
}

pub fn threadReadRegs(thread_cap: u32, regs: *ThreadRegs) !void {
    var msg: Message = .{
        .arg0 = @intFromEnum(ThreadCallId.read_regs),
        .arg1 = @intFromPtr(regs),
    };
    try call(thread_cap, &msg);
}

pub fn threadWriteRegs(thread_cap: u32, regs: *const ThreadRegs) !void {
    var msg: Message = .{
        .arg0 = @intFromEnum(ThreadCallId.write_regs),
        .arg1 = @intFromPtr(regs),
    };
    try call(thread_cap, &msg);
}

pub fn threadSetVmem(thread_cap: u32, vmem_cap: u32) !void {
    var msg: Message = .{
        .arg0 = @intFromEnum(ThreadCallId.set_vmem),
        .arg1 = vmem_cap,
    };
    try call(thread_cap, &msg);
}

pub fn threadSetPrio(thread_cap: u32, priority: u2) !void {
    var msg: Message = .{
        .arg0 = @intFromEnum(ThreadCallId.set_prio),
        .arg1 = priority,
    };
    try call(thread_cap, &msg);
}

pub fn threadTransferCap(thread_cap: u32, cap: u32) !void {
    var msg: Message = .{
        .arg0 = @intFromEnum(ThreadCallId.transfer_cap),
        .arg1 = cap,
    };
    try call(thread_cap, &msg);
}

// VMEM CAPABILITY CALLS

pub const VmemCallId = enum(u8) {
    map,
    unmap,
};

pub fn vmemMap(vmem_cap: u32, frame_cap: u32, vaddr: usize, rights: abi.sys.Rights, flags: abi.sys.MapFlags) !void {
    var msg: Message = .{
        .arg0 = @intFromEnum(VmemCallId.map),
        .arg1 = frame_cap,
        .arg2 = vaddr,
        .arg3 = @as(u32, @bitCast(rights)),
        .arg4 = @as(u40, @bitCast(flags)),
    };
    try call(vmem_cap, &msg);
}

pub fn vmemUnmap(vmem_cap: u32, frame_cap: u32, vaddr: usize) !void {
    var msg: Message = .{
        .arg0 = @intFromEnum(VmemCallId.unmap),
        .arg1 = frame_cap,
        .arg2 = vaddr,
    };
    try call(vmem_cap, &msg);
}

// FRAME CAPABILITY CALLS

pub const FrameCallId = enum(u8) {};

// RECEIVER CAPABILITY CALLS

pub const ReceiverCallId = enum(u8) {
    subscribe,
};

pub fn receiverSubscribe(recv_cap: u32) Error!u32 {
    var msg: Message = .{
        .arg0 = @intFromEnum(ReceiverCallId.subscribe),
    };
    try call(recv_cap, &msg);
    return @truncate(msg.cap);
}

// SENDER CAPABILITY CALLS

// NOTIFY CAPABILITY CALLS

pub const NotifyCallId = enum(u8) {
    wait,
    poll,
    notify,
    clone,
};

// returns the cap id of whoever notified this thread first
pub fn notifyWait(notify_cap: u32) Error!u32 {
    var msg: Message = .{
        .arg0 = @intFromEnum(NotifyCallId.wait),
    };
    try call(notify_cap, &msg);
    return @truncate(msg.cap);
}

// returns the cap id of whoever notified this thread first
pub fn notifyPoll(notify_cap: u32) Error!?u32 {
    var msg: Message = .{
        .arg0 = @intFromEnum(NotifyCallId.poll),
    };
    try call(notify_cap, &msg);
    return if ((msg.cap) == 0) null else @truncate(msg.cap);
}

/// returns true if it was already signaled
pub fn notifyNotify(notify_cap: u32) Error!bool {
    var msg: Message = .{
        .arg0 = @intFromEnum(NotifyCallId.notify),
    };
    try call(notify_cap, &msg);
    return msg.arg0 != 0;
}

/// clone the capability, the clone points to the same notify object
pub fn notifyClone(notify_cap: u32) Error!u32 {
    var msg: Message = .{
        .arg0 = @intFromEnum(NotifyCallId.clone),
    };
    try call(notify_cap, &msg);
    return @truncate(msg.arg0);
}

// X86IOPORTALLOCATOR CAPABILITY CALLS

pub const X86IoPortAllocatorCallId = enum(u8) {
    alloc,
    clone,
};

pub fn x86IoPortAllocatorAlloc(x86_ioport_allocator_cap_id: u32, port: u16) Error!u32 {
    var msg: Message = .{
        .arg0 = @intFromEnum(X86IoPortAllocatorCallId.alloc),
        .arg1 = port,
    };
    try call(x86_ioport_allocator_cap_id, &msg);
    return @truncate(msg.arg0);
}

pub fn x86IoPortAllocatorClone(x86_ioport_allocator_cap_id: u32) Error!u32 {
    var msg: Message = .{
        .arg0 = @intFromEnum(X86IoPortAllocatorCallId.clone),
    };
    try call(x86_ioport_allocator_cap_id, &msg);
    return @truncate(msg.arg0);
}

// X86IOPORT CAPABILITY CALLS

pub const X86IoPortCallId = enum(u8) {
    inb,
    outb,
};

pub fn x86IoPortInb(x86_ioport_cap_id: u32) Error!u8 {
    var msg: Message = .{
        .arg0 = @intFromEnum(X86IoPortCallId.inb),
    };
    try call(x86_ioport_cap_id, &msg);
    return @truncate(msg.arg0);
}

pub fn x86IoPortOutb(x86_ioport_cap_id: u32, byte: u8) Error!void {
    var msg: Message = .{
        .arg0 = @intFromEnum(X86IoPortCallId.outb),
        .arg1 = @truncate(byte),
    };
    try call(x86_ioport_cap_id, &msg);
}

// X86IRQALLOCATOR CAPABILITY CALLS

pub const X86IrqAllocatorCallId = enum(u8) {
    alloc,
    clone,
};

pub fn x86IrqAllocatorAlloc(x86_irq_allocator_cap_id: u32, global_system_interrupt: u8) Error!u32 {
    var msg: Message = .{
        .arg0 = @intFromEnum(X86IrqAllocatorCallId.alloc),
        .arg1 = global_system_interrupt,
    };
    try call(x86_irq_allocator_cap_id, &msg);
    return @truncate(msg.arg0);
}

pub fn x86IrqAllocatorClone(x86_irq_allocator_cap_id: u32) Error!u32 {
    var msg: Message = .{
        .arg0 = @intFromEnum(X86IrqAllocatorCallId.clone),
    };
    try call(x86_irq_allocator_cap_id, &msg);
    return @truncate(msg.arg0);
}

// X86IRQ CAPABILITY CALLS

pub const X86IrqCallId = enum(u8) {
    subscribe,
    unsubscribe,
};

pub fn x86IrqSubscribe(x86_irq_cap_id: u32, notify_cap_id: u32) Error!void {
    var msg: Message = .{
        .arg0 = @intFromEnum(X86IrqCallId.subscribe),
        .arg1 = notify_cap_id,
    };
    try call(x86_irq_cap_id, &msg);
}

pub fn x86IrqUnsubscribe(x86_irq_cap_id: u32, notify_cap_id: u32) Error!void {
    var msg: Message = .{
        .arg0 = @intFromEnum(X86IrqCallId.unsubscribe),
        .arg1 = notify_cap_id,
    };
    try call(x86_irq_cap_id, &msg);
}

// SYSCALLS

pub const Message = extern struct {
    /// capability id
    cap: u32 = 0,
    /// Number of extra arguments in the thread extra arguments array.
    /// They can contain capabilities that have their ownership
    /// automatically transferred.
    extra: u32 = 0, // u7
    // fast registers \/
    arg0: usize = 0,
    arg1: usize = 0,
    arg2: usize = 0,
    arg3: usize = 0,
    arg4: usize = 0,
};

comptime {
    std.debug.assert(@sizeOf(Message) == @sizeOf([6]usize));
}

pub fn log(s: []const u8) void {
    _ = syscall(.log, .{ @intFromPtr(s.ptr), s.len }) catch unreachable;
}

pub fn debug(cap: u32) !abi.ObjectType {
    const id = try syscall(.debug, .{cap});
    return std.meta.intToEnum(abi.ObjectType, id) catch unreachable;
}

pub fn call(cap: u32, msg: *Message) !void {
    msg.cap = cap;
    _ = try rwcall(.call, msg);
}

pub fn recv(cap: u32, msg: *Message) !void {
    msg.cap = cap;
    _ = try rwcall(.recv, msg);
}

pub fn reply(cap: u32, msg: *Message) !void {
    msg.cap = cap;
    const regs: *[6]usize = @ptrCast(msg);
    _ = try syscall(.reply, .{
        regs[0],
        regs[1],
        regs[2],
        regs[3],
        regs[4],
        regs[5],
    });
}

pub fn replyRecv(cap: u32, msg: *Message) !void {
    msg.cap = cap;
    _ = try rwcall(.reply_recv, msg);
}

pub fn getExtra(idx: u7) usize {
    const result, const vals = syscall1rw(@intFromEnum(Id.get_extra), .{
        idx,
    });
    _ = decode(result) catch unreachable;
    return vals[0];
}

pub fn setExtra(idx: u7, val: usize, is_cap: bool) void {
    _ = syscall(.set_extra, .{
        idx,
        val,
        @intFromBool(is_cap),
    }) catch unreachable;
}

pub fn yield() void {
    _ = syscall(.yield, .{}) catch unreachable;
}

fn rwcall(id: Id, msg: *Message) !usize {
    const regs: *[6]usize = @ptrCast(msg);

    const res, const args_out = syscall6rw(@intFromEnum(id), .{
        regs[0],
        regs[1],
        regs[2],
        regs[3],
        regs[4],
        regs[5],
    });

    regs[0] = args_out[0];
    regs[1] = args_out[1];
    regs[2] = args_out[2];
    regs[3] = args_out[3];
    regs[4] = args_out[4];
    regs[5] = args_out[5];

    return decode(res);
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

pub fn syscall1rw(id: usize, args: [1]usize) struct { usize, [1]usize } {
    var arg0: usize = undefined; // arrays dont work on outputs for whatever reason

    const res = asm volatile ("syscall"
        : [ret] "={rax}" (-> usize),
          [arg0out] "={rdi}" (arg0),
        : [id] "{rax}" (id),
          [arg0in] "{rdi}" (args[0]),
        : "rcx", "r11" // rcx becomes rip and r11 becomes rflags
    );

    return .{
        res,
        .{arg0},
    };
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
