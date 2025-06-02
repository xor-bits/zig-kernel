const abi = @import("lib.zig");
const sys = @import("sys.zig");

// some hardcoded capability handles

pub const ROOT_SELF_VMEM: Vmem = .{ .cap = 1 };
pub const ROOT_SELF_THREAD: Thread = .{ .cap = 2 };
pub const ROOT_SELF_PROC: Process = .{ .cap = 3 };
pub const ROOT_BOOT_INFO: Frame = .{ .cap = 4 };
pub const ROOT_MEMORY: Memory = .{ .cap = 5 };
pub const ROOT_X86_IOPORT_ALLOCATOR: X86IoPortAllocator = .{ .cap = 5 };
pub const ROOT_X86_IRQ_ALLOCATOR: X86IrqAllocator = .{ .cap = 6 };

//

/// capability that allows kernel object allocation
pub const Memory = extern struct {
    cap: u32 = 0,

    pub const Type: abi.ObjectType = .memory;

    pub fn alloc(self: @This(), comptime T: type) sys.Error!T {
        const cap = try sys.alloc(self.cap, T.Type, null);
        return .{ .cap = cap };
    }

    pub fn allocSized(self: @This(), comptime T: type, size: abi.ChunkSize) sys.Error!T {
        const cap = try sys.alloc(self.cap, T.Type, size);
        return .{ .cap = cap };
    }
};

/// capability to manage a single process
pub const Process = extern struct {
    cap: u32 = 0,

    pub const Type: abi.ObjectType = .process;

    pub fn create(vmem: Vmem) sys.Error!@This() {
        const cap = try sys.procCreate(vmem.cap);
        return .{ .cap = cap };
    }

    pub fn self() sys.Error!@This() {
        const cap = try sys.procSelf();
        return .{ .cap = cap };
    }
};

/// capability to manage a single thread control block (TCB)
pub const Thread = extern struct {
    cap: u32 = 0,

    pub const Type: abi.ObjectType = .thread;

    pub fn create(proc: Process) sys.Error!@This() {
        const cap = try sys.threadCreate(proc.cap);
        return .{ .cap = cap };
    }

    pub fn self() sys.Error!@This() {
        const cap = try sys.threadSelf();
        return .{ .cap = cap };
    }

    pub fn setPrio(this: @This(), prio: u2) sys.Error!void {
        _ = .{ this, prio };
        // sys.threadSetPrio(thread_cap: u32, priority: u2)
    }

    // pub fn writeRegs(this: @This(), regs: *const sys.ThreadRegs) sys.Error!void {}

    // pub fn readRegs(this: @This(), regs: *sys.ThreadRegs) sys.Error!void {}
};

/// capability to the virtual memory structure
pub const Vmem = extern struct {
    cap: u32 = 0,

    pub const Type: abi.ObjectType = .vmem;

    pub fn create() sys.Error!@This() {
        const cap = try sys.vmemCreate();
        return .{ .cap = cap };
    }

    pub fn self() sys.Error!@This() {
        const cap = try sys.vmemSelf();
        return .{ .cap = cap };
    }

    pub fn map(
        this: @This(),
        frame: Frame,
        frame_offset: usize,
        vaddr: usize,
        length: usize,
        rights: abi.sys.Rights,
        flags: abi.sys.MapFlags,
    ) sys.Error!void {
        return sys.vmemMap(
            this.cap,
            frame.cap,
            frame_offset,
            vaddr,
            length,
            rights,
            flags,
        );
    }

    pub fn unmap(this: @This(), vaddr: usize, length: usize) sys.Error!void {
        return sys.vmemUnmap(this.cap, vaddr, length);
    }
};

/// capability to a physical memory region (sized `ChunkSize`)
pub const Frame = extern struct {
    cap: u32 = 0,

    pub const Type: abi.ObjectType = .frame;

    pub fn create(size_bytes: usize) sys.Error!@This() {
        const cap = try sys.frameCreate(size_bytes);
        return .{ .cap = cap };
    }

    pub fn frameGetSize(self: @This()) sys.Error!usize {
        return try sys.frameGetSize(self.cap);
    }
};

/// capability to a MMIO physical memory region
pub const DeviceFrame = extern struct {
    cap: u32 = 0,

    pub const Type: abi.ObjectType = .device_frame;

    pub fn addrOf(self: @This()) !usize {
        return sys.deviceFrameAddrOf(self.cap);
    }

    pub fn sizeOf(self: @This()) !abi.ChunkSize {
        return sys.deviceFrameSizeOf(self.cap);
    }

    pub fn subframe(self: @This(), paddr: usize, size: abi.ChunkSize) !DeviceFrame {
        return .{ .cap = try sys.deviceFrameSubframe(self.cap, paddr, size) };
    }
};

/// capability to **the** receiver end of an endpoint,
/// there can only be a single receiver
pub const Receiver = extern struct {
    cap: u32 = 0,

    pub const Type: abi.ObjectType = .receiver;

    pub fn recv(self: @This(), msg: *sys.Message) sys.Error!void {
        return sys.recv(self.cap, msg);
    }

    pub fn reply(self: @This(), msg: *sys.Message) sys.Error!void {
        return sys.reply(self.cap, msg);
    }

    pub fn replyRecv(self: @This(), msg: *sys.Message) sys.Error!void {
        return sys.replyRecv(self.cap, msg);
    }

    pub fn saveCaller(self: @This()) sys.Error!Reply {
        return .{ .cap = try sys.receiverSaveCaller(self.cap) };
    }

    pub fn loadCaller(self: @This(), reply_cap: Reply) sys.Error!void {
        return sys.receiverLoadCaller(self.cap, reply_cap.cap);
    }

    pub fn subscribe(self: @This()) sys.Error!Sender {
        const cap = try sys.receiverSubscribe(self.cap);
        return .{ .cap = cap };
    }
};

/// capability to **a** sender end of an endpoint,
/// there can be multiple senders
pub const Sender = extern struct {
    cap: u32 = 0,

    pub const Type: abi.ObjectType = .sender;

    pub fn call(self: @This(), msg: *sys.Message) sys.Error!void {
        return sys.call(self.cap, msg);
    }
};

/// capability to **a** reply object
/// it can be saved/loaded from receiver or replied with
pub const Reply = extern struct {
    cap: u32 = 0,

    pub const Type: abi.ObjectType = .reply;

    pub fn reply(self: @This(), msg: *sys.Message) sys.Error!void {
        return sys.reply(self.cap, msg);
    }
};

/// capability to **a** notify object
/// there can be multiple of them
pub const Notify = extern struct {
    cap: u32 = 0,

    pub const Type: abi.ObjectType = .notify;

    pub fn wait(self: @This()) sys.Error!u32 {
        return sys.notifyWait(self.cap);
    }

    pub fn poll(self: @This()) sys.Error!?u32 {
        return sys.notifyPoll(self.cap);
    }

    pub fn notify(self: @This()) sys.Error!bool {
        return sys.notifyNotify(self.cap);
    }

    pub fn clone(self: @This()) sys.Error!Notify {
        return .{ .cap = try sys.notifyClone(self.cap) };
    }
};

/// x86 specific capability that allows allocating `x86_ioport` capabilities
pub const X86IoPortAllocator = extern struct {
    cap: u32 = 0,

    pub const Type: abi.ObjectType = .x86_ioport_allocator;

    pub fn alloc(self: @This(), port: u16) sys.Error!X86IoPort {
        return .{ .cap = try sys.x86IoPortAllocatorAlloc(self.cap, port) };
    }

    pub fn clone(self: @This()) sys.Error!@This() {
        return .{ .cap = try sys.x86IoPortAllocatorClone(self.cap) };
    }
};

/// x86 specific capability that gives access to one IO port
pub const X86IoPort = extern struct {
    cap: u32 = 0,

    pub const Type: abi.ObjectType = .x86_ioport;

    pub fn inb(self: @This()) sys.Error!u8 {
        return sys.x86IoPortInb(self.cap);
    }

    pub fn outb(self: @This(), byte: u8) sys.Error!void {
        return sys.x86IoPortOutb(self.cap, byte);
    }
};

/// x86 specific capability that allows allocating `x86_irq` capabilities
pub const X86IrqAllocator = extern struct {
    cap: u32 = 0,

    pub const Type: abi.ObjectType = .x86_irq_allocator;

    pub fn alloc(self: @This(), global_system_interrupt: u8) sys.Error!X86Irq {
        return .{ .cap = try sys.x86IrqAllocatorAlloc(self.cap, global_system_interrupt) };
    }

    pub fn clone(self: @This()) sys.Error!@This() {
        return .{ .cap = try sys.x86IrqAllocatorClone(self.cap) };
    }
};

/// x86 specific capability that gives access to one IRQ (= interrupt request)
pub const X86Irq = extern struct {
    cap: u32 = 0,

    pub const Type: abi.ObjectType = .x86_irq;

    pub fn subscribe(self: @This(), notify: Notify) sys.Error!void {
        return sys.x86IrqSubscribe(self.cap, notify.cap);
    }

    pub fn unsubscribe(self: @This(), notify: Notify) sys.Error!void {
        return sys.x86IrqUnsubscribe(self.cap, notify.cap);
    }
};
