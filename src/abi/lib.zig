const std = @import("std");
const root = @import("root");

pub const btree = @import("btree.zig");
pub const caps = @import("caps.zig");
pub const conf = @import("conf.zig");
pub const epoch = @import("epoch.zig");
pub const input = @import("input.zig");
pub const lock = @import("lock.zig");
pub const mem = @import("mem.zig");
pub const ring = @import("ring.zig");
pub const rt = @import("rt.zig");
pub const sys = @import("sys.zig");
pub const util = @import("util.zig");

//

/// where the kernel places the root binary
pub const ROOT_EXE = 0x200_0000;

//

pub const std_options: std.Options = .{
    .logFn = logFn,
    .log_level = if (@hasDecl(root, "log_level")) root.log_level else .debug,
};

fn logFn(comptime message_level: std.log.Level, comptime scope: @TypeOf(.enum_literal), comptime format: []const u8, args: anytype) void {
    const level_txt = comptime message_level.asText();
    const prefix2 = if (scope == .default) ": " else "(" ++ @tagName(scope) ++ "): ";
    var bw = std.io.bufferedWriter(SysLog{});
    const writer = bw.writer();

    // FIXME: lock the log
    nosuspend {
        writer.print(level_txt ++ prefix2 ++ format ++ "\n", args) catch return;
        bw.flush() catch return;
    }
}

pub fn panic(msg: []const u8, _: ?*std.builtin.StackTrace, _: ?usize) noreturn {
    @branchHint(.cold);
    const log = std.log.scoped(.panic);

    const name =
        if (@hasDecl(root, "name")) root.name else "<unknown>";
    log.err("{s} panicked: {s}\nstack trace:", .{ name, msg });
    var iter = std.debug.StackIterator.init(@returnAddress(), @frameAddress());
    while (iter.next()) |addr| {
        log.warn("  0x{x}", .{addr});
    }

    sys.self_stop();
}

//

/// kernel object variant that a capability points to
pub const ObjectType = enum(u8) {
    /// an unallocated/invalid capability
    null = 0,
    /// capability that allows kernel object allocation
    memory,
    /// capability to manage a single process
    process,
    /// capability to manage a single thread control block (TCB)
    thread,
    /// capability to the virtual memory structure
    vmem,
    /// capability to a physical memory region (sized `ChunkSize`)
    frame,
    /// capability to a MMIO physical memory region
    device_frame,
    /// capability to **the** receiver end of an endpoint,
    /// there can only be a single receiver
    receiver,
    /// capability to **a** sender end of an endpoint,
    /// there can be multiple senders
    sender,
    /// capability to **a** notify object
    /// there can be multiple of them
    notify,
    /// capability to **a** reply object
    /// it can be saved/loaded from receiver or replied with
    reply,

    /// x86 specific capability that allows allocating `x86_ioport` capabilities
    x86_ioport_allocator,
    /// x86 specific capability that gives access to one IO port
    x86_ioport,
    /// x86 specific capability that allows allocating `x86_irq` capabilities
    x86_irq_allocator,
    /// x86 specific capability that gives access to one IRQ (= interrupt request)
    x86_irq,
};

/// kernel object size in bit-width (minus 12)
pub const ChunkSize = enum(u5) {
    @"4KiB",
    @"8KiB",
    @"16KiB",
    @"32KiB",
    @"64KiB",
    @"128KiB",
    @"256KiB",
    @"512KiB",
    @"1MiB",
    @"2MiB",
    @"4MiB",
    @"8MiB",
    @"16MiB",
    @"32MiB",
    @"64MiB",
    @"128MiB",
    @"256MiB",
    @"512MiB",
    @"1GiB",

    pub fn of(n_bytes: usize) ?ChunkSize {
        // 0 = 4KiB, 1 = 8KiB, ..
        const page_size = @max(12, std.math.log2_int_ceil(usize, n_bytes)) - 12;
        if (page_size >= 18) return null;
        return @enumFromInt(page_size);
    }

    pub fn next(self: @This()) ?@This() {
        return std.meta.intToEnum(@This(), @intFromEnum(self) + 1) catch return null;
    }

    pub fn sizeBytes(self: @This()) usize {
        return @as(usize, 0x1000) << @intFromEnum(self);
    }

    pub fn alignOf(self: @This()) usize {
        if (self.sizeBytes() >= ChunkSize.@"1GiB".sizeBytes()) return ChunkSize.@"1GiB".sizeBytes();
        if (self.sizeBytes() >= ChunkSize.@"2MiB".sizeBytes()) return ChunkSize.@"2MiB".sizeBytes();
        return ChunkSize.@"4KiB".sizeBytes();
    }
};

/// data structure in the boot info frame provided to the root process
pub const BootInfo = extern struct {
    root_data: [*]u8,
    root_data_len: usize,
    root_path: [*]u8,
    root_path_len: usize,
    initfs_data: [*]u8,
    initfs_data_len: usize,
    initfs_path: [*]u8,
    initfs_path_len: usize,
    framebuffer: caps.DeviceFrame = .{},
    framebuffer_info: caps.Frame = .{},
    hpet: caps.DeviceFrame = .{},
    hpet_info: caps.Frame = .{},
    // TODO: parse ACPI tables in rm server
    mcfg: caps.DeviceFrame = .{},
    mcfg_info: caps.Frame = .{},

    pub fn rootData(self: @This()) []u8 {
        return self.root_data[0..self.root_data_len];
    }

    pub fn rootPath(self: @This()) []u8 {
        return self.root_path[0..self.root_path_len];
    }

    pub fn initfsData(self: @This()) []u8 {
        return self.initfs_data[0..self.initfs_data_len];
    }

    pub fn initfsPath(self: @This()) []u8 {
        return self.initfs_path[0..self.initfs_path_len];
    }
};

//

pub const SysLog = struct {
    pub const Error = error{};
    pub fn write(self: @This(), bytes: []const u8) Error!usize {
        try self.writeAll(bytes);
        return bytes.len;
    }
    pub fn writeAll(_: @This(), bytes: []const u8) Error!void {
        sys.log(bytes);
    }
    pub fn flush(_: @This()) Error!void {}
};

//

pub const DeviceKind = enum(u8) {
    hpet,
    framebuffer,
    mcfg,
};

pub const ServerKind = enum(u8) {
    vm,
    pm,
    rm,
    vfs,
    timer,
    input,
};

pub const Device = struct {
    /// the actual physical device frame
    mmio_frame: caps.DeviceFrame = .{},
    /// info about the device
    info_frame: caps.Frame = .{},
};

pub const RootProtocol = util.Protocol(struct {
    /// request a physical memory allocator capability
    /// only system processes are allowed request this
    memory: fn () struct { sys.Error!void, caps.Memory },

    /// request a x86 ioport allocator capability
    /// only rm can use this
    ioports: fn () struct { sys.Error!void, caps.X86IoPortAllocator },

    /// request a x86 irq allocator capability
    /// only rm can use this
    irqs: fn () struct { sys.Error!void, caps.X86IrqAllocator },

    /// request a device physical frame and its info frame
    /// only rm can use this
    device: fn (kind: DeviceKind) struct { sys.Error!void, caps.DeviceFrame, caps.Frame },

    /// inform root that the server is ready and provide a sender to the server
    /// only servers can use this, and `kind` has to match the server
    /// returns a vmem handle, if it isn't the vm server
    serverReady: fn (kind: ServerKind, sender: caps.Sender) struct { sys.Error!void, void },

    /// request a sender to the server
    serverSender: fn (kind: ServerKind) struct { sys.Error!void, caps.Sender },

    /// request a sender to the initfs server
    initfs: fn () struct { sys.Error!void, caps.Sender },

    /// create a new sender to the root
    newSender: fn () struct { sys.Error!void, caps.Sender },
});

pub const InitfsProtocol = util.Protocol(struct {
    /// open a file from initfs, copy all of its content into
    /// the provided frame (and returns the same frame)
    openFile: fn (path: [32:0]u8, frame: caps.Frame) struct { sys.Error!void, caps.Frame },

    /// open a file from initfs and return its length
    fileSize: fn (path: [32:0]u8) struct { sys.Error!void, usize },

    /// returns the paths of every file and directory in initfs and the entry count
    list: fn () struct { sys.Error!void, caps.Frame, usize },
});

pub const VmProtocol = util.Protocol(struct {
    /// create a new empty address space
    /// returns a handle that can be used to create threads
    newVmem: fn () struct { sys.Error!void, usize },

    /// change the vmem handle's owner
    moveOwner: fn (handle: usize, sender_cap_id: u32) struct { sys.Error!void, void },

    // TODO: make sure there is only one copy of
    // this frame so that the vm can read it in peace
    /// load an ELF into an address space, returns the entrypoint addr
    loadElf: fn (handle: usize, elf: caps.Frame, offset: usize, length: usize) struct { sys.Error!void, usize },

    /// map a frame into an address space
    mapFrame: fn (handle: usize, frame: caps.Frame, rights: sys.Rights, flags: sys.MapFlags) struct { sys.Error!void, usize, caps.Frame },

    /// map a frame into an address space
    mapDeviceFrame: fn (handle: usize, frame: caps.DeviceFrame, rights: sys.Rights, flags: sys.MapFlags) struct { sys.Error!void, usize, caps.DeviceFrame },

    /// map an anonymous frame into an address space
    mapAnon: fn (handle: usize, len: usize, rights: sys.Rights, flags: sys.MapFlags) struct { sys.Error!void, usize },

    /// create a new thread from an address space
    /// ip and sp are already set
    newThread: fn (handle: usize, ip_override: usize, sp_override: usize) struct { sys.Error!void, caps.Thread },

    /// create a new sender to the vm server
    /// only root can call this
    newSender: fn () struct { sys.Error!void, caps.Sender },
});

pub const PmProtocol = util.Protocol(struct {
    // /// exec an elf file
    // execElf: fn (path: [32:0]u8) struct { sys.Error!void, usize },

    /// spawn a new thread in the current process
    /// uses the ELF entrypoint if `ip_override` is 0
    /// creates a new stack if `sp_override` is 0
    spawn: fn (ip_override: usize, sp_override: usize) struct { sys.Error!void, caps.Thread },

    /// grow the caller process' heap
    growHeap: fn (by: usize) struct { sys.Error!void, usize },

    /// map a frame into the caller process' heap
    mapFrame: fn (frame: caps.Frame, rights: sys.Rights, flags: sys.MapFlags) struct { sys.Error!void, usize, caps.Frame },

    /// map a device frame into the caller process' heap
    mapDeviceFrame: fn (frame: caps.DeviceFrame, rights: sys.Rights, flags: sys.MapFlags) struct { sys.Error!void, usize, caps.DeviceFrame },

    /// create a new sender the pm server
    /// only root can call this
    newSender: fn () struct { sys.Error!void, caps.Sender },
});

pub const RmProtocol = util.Protocol(struct {
    /// request PS/2 keyboard ports
    requestPs2: fn () struct { sys.Error!void, caps.X86IoPort, caps.X86IoPort },

    /// request HPET device memory for a driver (and the PIT port)
    requestHpet: fn () struct { sys.Error!void, caps.DeviceFrame, caps.X86IoPort },

    /// request framebuffer device memory and its info frame
    requestFramebuffer: fn () struct { sys.Error!void, caps.DeviceFrame, caps.Frame },

    /// request pci configuration space device memory and its info frame
    requestPci: fn () struct { sys.Error!void, caps.DeviceFrame, caps.Frame },

    /// request an interrupt handler for a driver
    requestInterruptHandler: fn (irq: u8, notify: caps.Notify) struct { sys.Error!void, caps.Notify },

    /// request a notify kernel object
    requestNotify: fn () struct { sys.Error!void, caps.Notify },

    /// create a new sender to the rm server
    /// only root can call this
    newSender: fn () struct { sys.Error!void, caps.Sender },
});

pub const VfsProtocol = util.Protocol(struct {
    /// open a namespace, like fs://, initfs:// or fs:///app/1
    namespaceShort: fn (path: [32:0]u8) struct { sys.Error!void, usize },

    // /// open a namespace, like fs://, initfs:// or fs:///app/1
    // namespace: fn (path: [128:0]u8) struct { sys.Error!void, usize },

    // /// open a sub-namespace, /app/1 in fs://
    // subnamespaceShort: fn (ns_handle: usize, path: [24:0]u8) struct { sys.Error!void, usize },

    /// close a namespace handle
    closeNamespace: fn (handle: usize) struct { sys.Error!void, void },

    /// open a file within a namespace
    openShort: fn (ns_handle: usize, path: [24:0]u8) struct { sys.Error!void, usize },

    // /// open a file within a namespace
    // open: fn (ns_handle: usize, path: [120:0]u8) struct { sys.Error!void, usize },

    /// close a file handle
    close: fn (handle: usize) struct { sys.Error!void, void },

    /// gets a shared 4K page in a file
    getPage: fn (handle: usize, index: usize) struct { sys.Error!void, caps.Frame },

    /// create a new sender to the rm server
    /// only root can call this
    newSender: fn () struct { sys.Error!void, caps.Sender },
});

/// root,unix app <-> timer communication
pub const TimerProtocol = util.Protocol(struct {
    /// get the current timestamp
    timestamp: fn () u128,

    /// stop the thread until the current timestamp + `nanos` is reached
    sleep: fn (nanos: u128) void,

    /// stop the thread until this timestamp is reached
    sleepDeadline: fn (nanos: u128) void,

    /// create a new sender to the hpet server
    /// only root can call this
    newSender: fn () struct { sys.Error!void, caps.Sender },
});

/// timer <-> hpet communication
pub const HpetProtocol = util.Protocol(struct {
    /// get the current timestamp
    timestamp: fn () u128,

    /// stop the `reply` thread until the current timestamp + `nanos` is reached
    sleep: fn (nanos: u128, reply: caps.Reply) void,

    /// stop the `reply` thread until this timestamp is reached
    sleepDeadline: fn (nanos: u128, reply: caps.Reply) void,
});

/// root,unix app <-> input communication
pub const InputProtocol = util.Protocol(struct {
    /// wait for the next keyboard input
    nextKey: fn () struct { sys.Error!void, input.KeyCode, input.KeyState },

    /// create a new sender to the input server
    /// only root can call this
    newSender: fn () struct { sys.Error!void, caps.Sender },
});

/// input <-> ps2 communication
pub const Ps2Protocol = util.Protocol(struct {
    /// stop the `reply` thread until there is some keyboard input
    nextKey: fn (reply: caps.Reply) void,
});

pub const FramebufferInfoFrame = extern struct {
    width: usize = 0,
    height: usize = 0,
    pitch: usize = 0,
    bpp: u16 = 0,
    red_mask_size: u8,
    red_mask_shift: u8,
    green_mask_size: u8,
    green_mask_shift: u8,
    blue_mask_size: u8,
    blue_mask_shift: u8,
};

pub const McfgInfoFrame = extern struct {
    pci_segment_group: u16,
    start_pci_bus: u8,
    end_pci_bus: u8,
};

pub const Stat = extern struct {
    atime: u128,
    mtime: u128,
    inode: u128,
    uid: u64,
    gid: u64,
    size: u64,
    mode: Mode,
};

pub const Mode = packed struct {
    other_x: bool,
    other_w: bool,
    other_r: bool,

    group_x: bool,
    group_w: bool,
    group_r: bool,

    owner_x: bool,
    owner_w: bool,
    owner_r: bool,

    set_gid: bool,
    set_uid: bool,

    type: enum(u2) {
        file,
        dir,
        file_link,
        dir_link,
    },

    _reserved0: u3 = 0,
    _reserved1: u16 = 0,
};
