const std = @import("std");

const abi = @import("lib.zig");
const ring = @import("ring.zig");

//

pub const Id = enum(usize) {
    /// print debug logs to serial output
    log = 1,
    /// manually panic the kernel from user-space in debug mode
    kernel_panic,

    /// create a new `Frame` object that can be mapped to one or many `Vmem`s
    frame_create,
    /// get the `Frame` object's size in pages
    frame_get_size,

    /// create a new `Vmem` object that handles a single virtual address space
    vmem_create,
    /// create a new handle to the current `Vmem`
    vmem_self,
    /// map a part of (or the whole) `Frame` into this `Vmem`
    vmem_map,
    /// unmap any virtual address space region from this `Vmem`
    vmem_unmap,

    /// create a new `Process` object that handles a single process
    /// capability handles are tied to processes
    proc_create,
    /// create a new handle to the current `Process`
    proc_self,

    /// create a new `Thread` object that handles a single thread within a single process
    thread_create,
    /// create a new handle to the current `Thread`
    thread_self,
    /// read all registers of a stopped `Thread`
    thread_read_regs,
    /// write all registers of a stopped `Thread`
    thread_write_regs,
    /// start a stopped/new `Thread`
    thread_start,
    /// stop a running `Thread`
    thread_stop,
    /// modify `Thread` priority, the priority can only be as high as the highest priority in the current process
    thread_set_prio,

    /// create a new `Receiver` object that is the receiver end of a new IPC queue
    receiver_create,
    // receiver_subscribe,
    /// wait until a matching `Sender.call` is called and return the message
    receiver_recv,
    /// non-blocking reply to the last caller with a message
    receiver_reply,
    /// combined `receiver_reply` + `receiver_recv`
    receiver_reply_recv,
    /// save the last caller into a new `Reply` object to allow another `receiver_recv` before `receiver_reply`
    receiver_save_caller,
    // receiver_load_caller,

    /// non-blocking reply to the last caller with a message
    reply_reply,

    /// create a new `Sender` object that is the sender end of some already existing IPC queue
    sender_create,
    // sender_send, // TODO: non-blocking call
    /// wait until a matching `Receiver.recv` is called and switch to that thread
    /// with a provided message, and return the reply message
    sender_call,

    // TODO: maybe make all kernel objects be 'waitable' and 'notifyable'
    /// create a new `Notify` object that is a messageless IPC structure
    notify_create,
    /// wait until this `Notify` is notified with `notify_notify`,
    /// or return immediately if it was already notified
    notify_wait,
    /// check if this `Notify` object is already notified
    notify_poll,
    /// notify this `Notify` object and wake up sleepers
    notify_notify,

    /// create a new `X86IoPort` object that manages a single x86 I/O port
    /// TODO: use I/O Permissions Bitmap in the TSS to do port io from user-space
    x86_ioport_create,
    /// `inb` instruction on the specific provided `X86IoPort` port
    x86_ioport_inb,
    /// `outb` instruction on the specific provided `X86IoPort` port
    x86_ioport_outb,

    /// create a new `X86Irq` object that manages a single x86 interrupt vector
    x86_irq_create,
    /// notify a specific `Notify` object every time this IRQ is generated
    x86_irq_subscribe,
    /// stop notifying a specific `Notify` object
    x86_irq_unsubscribe,

    /// identify which object type some capability is
    handle_identify,
    /// create another handle to the same object
    handle_duplicate,
    /// close a handle to some object, might or might not delete the object
    handle_close,

    /// give up the CPU for other tasks
    self_yield,
    /// stop the active thread
    self_stop,

    // TODO: maybe move all object call id's here to be syscall id's
};

/// capability or mapping rights
pub const Rights = packed struct {
    readable: bool = true,
    writable: bool = false,
    executable: bool = false,
    user_accessible: bool = true,
    _: u4 = 0,

    pub fn intersection(self: Rights, other: Rights) Rights {
        return Rights{
            .readable = self.readable and other.readable,
            .writable = self.writable and other.writable,
            .executable = self.executable and other.executable,
            .user_accessible = self.user_accessible and other.user_accessible,
        };
    }

    pub fn asInt(self: Rights) u8 {
        return @as(u8, @bitCast(self));
    }

    pub fn fromInt(i: u8) Rights {
        return @as(Rights, @bitCast(i));
    }
};

/// https://wiki.osdev.org/Paging#PAT
pub const CacheType = enum(u8) {
    /// All accesses are uncacheable.
    /// Write combining is not allowed.
    /// Speculative accesses are not allowed.
    uncacheable = 3,
    /// All accesses are uncacheable.
    /// Write combining is allowed.
    /// Speculative reads are allowed.
    write_combining = 4,
    /// Reads allocate cache lines on a cache miss.
    /// Cache lines are not allocated on a write miss.
    /// Write hits update the cache and main memory.
    write_through = 1,
    /// Reads allocate cache lines on a cache miss.
    /// All writes update main memory.
    /// Cache lines are not allocated on a write miss.
    /// Write hits invalidate the cache line and update main memory.
    write_protect = 5,
    /// Reads allocate cache lines on a cache miss,
    /// and can allocate to either the shared, exclusive, or modified state.
    /// Writes allocate to the modified state on a cache miss.
    write_back = 0,
    /// Same as uncacheable,
    /// except that this can be overriden by Write-Combining MTRRs.
    uncached = 2,

    pub fn patMsr() u64 {
        return (@as(u64, 6) << 0) |
            (@as(u64, 4) << 8) |
            (@as(u64, 7) << 16) |
            (@as(u64, 0) << 24) |
            (@as(u64, 1) << 32) |
            (@as(u64, 5) << 40) |
            (@as(u64, 0) << 48) |
            (@as(u64, 0) << 56);
    }
};

/// extra mapping flags
pub const MapFlags = packed struct {
    // protection_key: u8 = 0,
    cache: CacheType = .write_back,
    // global: bool = false,

    pub fn asInt(self: MapFlags) u64 {
        return @as(u8, @bitCast(self));
    }

    pub fn fromInt(i: u64) MapFlags {
        return @as(MapFlags, @bitCast(@as(u8, @truncate(i))));
    }
};

/// syscall interface Error type
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
    OutOfBounds,
    NotFound,
    ReadFault,
    WriteFault,
    ExecFault,

    UnknownError,
};

/// FIXME: should be Error!u32
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
        error.OutOfBounds => 24,
        error.NotFound => 25,
        error.ReadFault => 26,
        error.WriteFault => 27,
        error.ExecFault => 28,

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
        24 => error.OutOfBounds,
        25 => error.NotFound,
        26 => error.ReadFault,
        27 => error.WriteFault,
        28 => error.ExecFault,

        else => return error.UnknownError,
    };
}

pub fn decodeVoid(v: usize) Error!void {
    _ = try decode(v);
}

/// x86_64 thread registers
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

/// small IPC message
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

// SYSCALLS

pub fn log(s: []const u8) void {
    _ = syscall(.log, .{ @intFromPtr(s.ptr), s.len }) catch unreachable;
}

pub fn kernelPanic() noreturn {
    if (!abi.conf.KERNEL_PANIC_SYSCALL) @compileError("debug kernel panics not enabled");
    _ = syscall(.kernel_panic, .{}) catch {};
    unreachable;
}

pub fn frameCreate(size_bytes: usize) Error!u32 {
    return @intCast(try syscall(.frame_create, .{size_bytes}));
}

pub fn frameGetSize(frame: u32) Error!usize {
    return try syscall(.frame_get_size, .{frame}) * 0x1000;
}

pub fn vmemCreate() Error!u32 {
    return @intCast(try syscall(.vmem_create, .{}));
}

pub fn vmemSelf() Error!u32 {
    return @intCast(try syscall(.vmem_self, .{}));
}

pub fn packRightsFlags(rights: Rights, flags: MapFlags) u16 {
    const val: packed struct { r: Rights, f: MapFlags } = .{ .r = rights, .f = flags };
    return @bitCast(val);
}

pub fn unpackRightsFlags(v: u16) struct { Rights, MapFlags } {
    const val: packed struct { r: Rights, f: MapFlags } = @bitCast(v);
    return .{ val.r, val.f };
}

pub fn vmemMap(
    vmem: u32,
    frame: u32,
    frame_offset: usize,
    vaddr: usize,
    length: usize,
    rights: Rights,
    flags: MapFlags,
) Error!void {
    _ = try syscall(.vmem_map, .{
        vmem, frame, frame_offset, vaddr, length, packRightsFlags(rights, flags),
    });
}

pub fn vmemUnmap(vmem: u32, vaddr: usize, length: usize) void {
    _ = try syscall(.vmem_unmap, .{
        vmem, vaddr, length,
    });
}

pub fn procCreate(vmem: u32) Error!u32 {
    return @intCast(try syscall(.proc_create, .{vmem}));
}

pub fn procSelf() Error!u32 {
    return @intCast(try syscall(.proc_self, .{}));
}

pub fn threadCreate(proc: u32) Error!u32 {
    return @intCast(try syscall(.thread_create, .{proc}));
}

pub fn threadSelf() Error!u32 {
    return @intCast(try syscall(.thread_self, .{}));
}

pub fn threadReadRegs(thread: u32, dst: *ThreadRegs) Error!void {
    _ = try syscall(.thread_read_regs, .{
        thread,
        @intFromPtr(dst),
    });
}

pub fn threadWriteRegs(thread: u32, dst: *const ThreadRegs) Error!void {
    _ = try syscall(.thread_write_regs, .{
        thread,
        @intFromPtr(dst),
    });
}

pub fn threadStart(thread: u32) Error!void {
    _ = try syscall(.thread_start, .{
        thread,
    });
}

pub fn threadStop(thread: u32) Error!void {
    _ = try syscall(.thread_stop, .{
        thread,
    });
}

pub fn threadSetPrio(thread: u32, prio: u2) Error!void {
    _ = try syscall(.thread_set_prio, .{
        thread,
        prio,
    });
}

pub fn receiverCreate() void {
    @compileError("TODO");
}

pub fn receiverRecv() void {
    @compileError("TODO");
}

pub fn receiverReply() void {
    @compileError("TODO");
}

pub fn receiverReplyRecv() void {
    @compileError("TODO");
}

pub fn receiverSaveCaller() void {
    @compileError("TODO");
}

pub fn replyReply() void {
    @compileError("TODO");
}

pub fn senderCreate() void {
    @compileError("TODO");
}

pub fn senderCall() void {
    @compileError("TODO");
}

pub fn notifyCreate() Error!u32 {
    return @intCast(try syscall(.notify_create, .{}));
}

pub fn notifyWait(notify: u32) Error!void {
    _ = try syscall(.notify_wait, .{notify});
}

pub fn notifyPoll(notify: u32) Error!bool {
    return try syscall(.notify_wait, .{notify}) != 0;
}

pub fn notifyNotify(notify: u32) Error!bool {
    return try syscall(.notify_notify, .{notify}) != 0;
}

pub fn x86IoportCreate() void {
    @compileError("TODO");
}

pub fn x86IoportInb() void {
    @compileError("TODO");
}

pub fn x86IoportOutb() void {
    @compileError("TODO");
}

pub fn x86IrqCreate() void {
    @compileError("TODO");
}

pub fn x86IrqSubscribe() void {
    @compileError("TODO");
}

pub fn x86IrqUnsubscribe() void {
    @compileError("TODO");
}

pub fn handleIdentify(cap: u32) abi.ObjectType {
    return std.meta.intToEnum(
        abi.ObjectType,
        syscall(.handle_identify, .{cap}) catch unreachable,
    ) catch .null;
}

pub fn handleDuplicate(cap: u32) Error!u32 {
    return @intCast(try syscall(.handle_duplicate, .{cap}));
}

pub fn handleClose(cap: u32) void {
    syscall(.handle_close, .{cap}) catch unreachable;
}

pub fn self_yield() void {
    _ = syscall(.self_yield, .{}) catch unreachable;
}

pub fn self_stop() noreturn {
    _ = syscall(.self_stop, .{}) catch {};
    asm volatile ("mov 0, %rax"); // read from nullptr to kill the process for sure
    unreachable;
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
