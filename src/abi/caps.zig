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

    pub fn readRegs(this: @This(), regs: *sys.ThreadRegs) sys.Error!void {
        try sys.threadReadRegs(this.cap, regs);
    }

    pub fn writeRegs(this: @This(), regs: *const sys.ThreadRegs) sys.Error!void {
        try sys.threadWriteRegs(this.cap, regs);
    }

    pub fn start(this: @This()) sys.Error!void {
        try sys.threadStart(this.cap);
    }

    pub fn stop(this: @This()) sys.Error!void {
        try sys.threadStop(this.cap);
    }

    pub fn setPrio(this: @This(), prio: u2) sys.Error!void {
        try sys.threadSetPrio(this.cap, prio);
    }
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

    pub fn close(this: @This()) void {
        sys.handleClose(this.cap);
    }

    /// if length is zero, the rest of the frame is mapped
    pub fn map(
        this: @This(),
        frame: Frame,
        frame_offset: usize,
        vaddr: usize,
        length: usize,
        rights: abi.sys.Rights,
        flags: abi.sys.MapFlags,
    ) sys.Error!usize {
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

    pub fn close(this: @This()) void {
        sys.handleClose(this.cap);
    }

    pub fn getSize(self: @This()) sys.Error!usize {
        return try sys.frameGetSize(self.cap);
    }

    // pub fn read(self: @This(), dst: []u8) sys.Error!void {}

    // pub fn write(self: @This(), dst: []u8) sys.Error!void {}
};

/// capability to a MMIO physical memory region
pub const DeviceFrame = extern struct {
    cap: u32 = 0,

    pub const Type: abi.ObjectType = .device_frame;
};

/// capability to **the** receiver end of an endpoint,
/// there can only be a single receiver
pub const Receiver = extern struct {
    cap: u32 = 0,

    pub const Type: abi.ObjectType = .receiver;

    pub fn create() sys.Error!@This() {
        const cap = try sys.receiverCreate();
        return .{ .cap = cap };
    }

    pub fn recv(self: @This()) sys.Error!sys.Message {
        return try sys.receiverRecv(self.cap);
    }

    pub fn reply(self: @This(), msg: sys.Message) sys.Error!void {
        return try sys.receiverReply(self.cap, msg);
    }

    pub fn replyRecv(self: @This(), msg: sys.Message) sys.Error!sys.Message {
        return try sys.receiverReplyRecv(self.cap, msg);
    }

    pub fn saveCaller(self: @This()) sys.Error!Reply {
        return .{ .cap = try sys.receiverSaveCaller(self.cap) };
    }

    pub fn loadCaller(self: @This(), reply_cap: Reply) sys.Error!void {
        return try sys.receiverLoadCaller(self.cap, reply_cap.cap);
    }
};

/// capability to **a** sender end of an endpoint,
/// there can be multiple senders
pub const Sender = extern struct {
    cap: u32 = 0,

    pub const Type: abi.ObjectType = .sender;

    pub fn create(recv: Receiver) sys.Error!@This() {
        const cap = try sys.senderCreate(recv.cap);
        return .{ .cap = cap };
    }

    pub fn call(self: @This(), msg: sys.Message) sys.Error!sys.Message {
        return try sys.senderCall(self.cap, msg);
    }
};

/// capability to **a** reply object
/// it can be saved/loaded from receiver or replied with
pub const Reply = extern struct {
    cap: u32 = 0,

    pub const Type: abi.ObjectType = .reply;

    pub fn create() sys.Error!@This() {
        const cap = try sys.replyCreate();
        return .{ .cap = cap };
    }

    pub fn reply(self: @This(), msg: sys.Message) sys.Error!void {
        return sys.replyReply(self.cap, msg);
    }
};

/// capability to **a** notify object
/// there can be multiple of them
pub const Notify = extern struct {
    cap: u32 = 0,

    pub const Type: abi.ObjectType = .notify;

    pub fn create() sys.Error!@This() {
        const cap = try sys.notifyCreate();
        return .{ .cap = cap };
    }

    pub fn wait(self: @This()) sys.Error!void {
        return try sys.notifyWait(self.cap);
    }

    pub fn poll(self: @This()) sys.Error!bool {
        return try sys.notifyPoll(self.cap);
    }

    pub fn notify(self: @This()) sys.Error!bool {
        return try sys.notifyNotify(self.cap);
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
