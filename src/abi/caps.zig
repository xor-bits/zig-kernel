const abi = @import("lib.zig");
const sys = @import("sys.zig");

// some hardcoded capability handles

pub const ROOT_SELF_VMEM: Vmem = .{ .cap = 1 };
pub const ROOT_SELF_THREAD: Thread = .{ .cap = 2 };
pub const ROOT_MEMORY: Memory = .{ .cap = 3 };
pub const ROOT_BOOT_INFO: Frame = .{ .cap = 4 };

//

/// capability that allows kernel object allocation
pub const Memory = struct {
    cap: u32,

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

/// capability to manage a single thread control block (TCB)
pub const Thread = struct {
    cap: u32,

    pub const Type: abi.ObjectType = .thread;

    pub fn start(self: @This()) sys.Error!void {
        return sys.threadStart(self.cap);
    }

    pub fn stop(self: @This()) sys.Error!void {
        return sys.threadStop(self.cap);
    }

    pub fn readRegs(self: @This(), regs: *sys.ThreadRegs) sys.Error!void {
        return sys.threadReadRegs(self.cap, regs);
    }

    pub fn writeRegs(self: @This(), regs: *const sys.ThreadRegs) sys.Error!void {
        return sys.threadWriteRegs(self.cap, regs);
    }

    pub fn setVmem(self: @This(), vmem: Vmem) sys.Error!void {
        return sys.threadSetVmem(self.cap, vmem.cap);
    }

    pub fn setPrio(self: @This(), priority: u2) sys.Error!void {
        return sys.threadSetPrio(self.cap, priority);
    }
};

/// capability to the virtual memory structure
pub const Vmem = struct {
    cap: u32,

    pub const Type: abi.ObjectType = .vmem;

    pub fn map(self: @This(), frame: Frame, vaddr: usize, rights: abi.sys.Rights, flags: abi.sys.MapFlags) sys.Error!void {
        return sys.vmemMap(self.cap, frame.cap, vaddr, rights, flags);
    }

    pub fn unmap(self: @This(), frame: Frame, vaddr: usize) sys.Error!void {
        return sys.vmemUnmap(self.cap, frame.cap, vaddr);
    }

    pub fn transferCap(self: @This(), cap: u32) sys.Error!void {
        return sys.vmemTransferCap(self.cap, cap);
    }
};

/// capability to a physical memory region (sized `ChunkSize`)
pub const Frame = struct {
    cap: u32,

    pub const Type: abi.ObjectType = .frame;
};

/// capability to **the** receiver end of an endpoint,
/// there can only be a single receiver
pub const Receiver = struct {
    cap: u32,

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

    pub fn subscribe(self: @This()) sys.Error!Sender {
        const cap = try sys.receiverSubscribe(self.cap);
        return .{ .cap = cap };
    }
};

/// capability to **a** sender end of an endpoint,
/// there can be multiple senders
pub const Sender = struct {
    cap: u32,

    pub const Type: abi.ObjectType = .sender;

    pub fn call(self: @This(), msg: *sys.Message) sys.Error!void {
        return sys.call(self.cap, msg);
    }
};
