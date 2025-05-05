const std = @import("std");
const root = @import("root");

pub const btree = @import("btree.zig");
pub const caps = @import("caps.zig");
pub const ring = @import("ring.zig");
pub const rt = @import("rt.zig");
pub const sys = @import("sys.zig");
pub const util = @import("util.zig");

//

/// where the kernel places the root binary
pub const ROOT_EXE = 0x200_0000;

// TODO: move kernel/conf.zig here
pub const LOG_SERVERS: bool = true;

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

pub fn panic(msg: []const u8, error_return_trace: ?*std.builtin.StackTrace, ret_addr: ?usize) noreturn {
    _ = error_return_trace;

    const name =
        if (@hasDecl(root, "name")) root.name else "<unknown>";
    std.log.scoped(.panic).err("{s} panicked: {s}\nstack trace:", .{ name, msg });
    var iter = std.debug.StackIterator.init(ret_addr, @frameAddress());
    if (ret_addr) |addr| {
        std.log.scoped(.panic).warn("  0x{x}", .{addr});
    }
    while (iter.next()) |addr| {
        std.log.scoped(.panic).warn("  0x{x}", .{addr});
    }

    asm volatile ("mov 0, %rax"); // read from nullptr to kill the process
    unreachable;
}

//

/// kernel object variant that a capability points to
pub const ObjectType = enum(u8) {
    /// an unallocated/invalid capability
    null = 0,
    /// capability that allows kernel object allocation
    memory,
    /// capability to manage a single thread control block (TCB)
    thread,
    /// capability to the virtual memory structure
    vmem,
    /// capability to a physical memory region (sized `ChunkSize`)
    frame,
    /// capability to **the** receiver end of an endpoint,
    /// there can only be a single receiver
    receiver,
    /// capability to **a** sender end of an endpoint,
    /// there can be multiple senders
    sender,
    /// capability to **a** notify object
    /// there can be multiple of them
    notify,

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
    framebuffer: caps.Frame = .{},
    framebuffer_width: usize = 0,
    framebuffer_height: usize = 0,
    framebuffer_pitch: usize = 0,
    framebuffer_bpp: u16 = 0,
    hpet: caps.Frame = .{},

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

pub const RootProtocol = util.Protocol(struct {
    /// request a physical memory allocator capability
    /// only system processes are allowed request this
    memory: fn () struct { sys.Error!void, caps.Memory },

    /// request self vmem capability
    /// only vm can use this
    selfVmem: fn () struct { sys.Error!void, caps.Vmem },

    /// request a x86 ioport allocator capability
    /// only rm can use this
    ioports: fn () struct { sys.Error!void, caps.X86IoPortAllocator },

    /// request a x86 irq allocator capability
    /// only rm can use this
    irqs: fn () struct { sys.Error!void, caps.X86IrqAllocator },

    /// provide a sender to the vm server
    /// only vm can use this
    vmReady: fn (vm_sender: caps.Sender) struct { sys.Error!void },

    /// install a new pm sender that all new .pm requests get
    pmReady: fn (pm_sender: caps.Sender) struct { sys.Error!void },

    /// install a new rm sender that all new .rm requests get
    rmReady: fn (pm_sender: caps.Sender) struct { sys.Error!void },

    /// install a new vfs sender that all new .vfs requests get
    vfsReady: fn (vfs_sender: caps.Sender) struct { sys.Error!void },

    /// request a sender to the vm server
    /// only pm can use this
    vm: fn () struct { sys.Error!void, caps.Sender },

    /// request a sender to the pm server
    pm: fn () struct { sys.Error!void, caps.Sender },

    /// request a sender to the rm server
    rm: fn () struct { sys.Error!void, caps.Sender },

    /// request a sender to the vfs server
    vfs: fn () struct { sys.Error!void, caps.Sender },
});

pub const VmProtocol = util.Protocol(struct {
    /// create a new empty address space
    /// returns a handle that can be used to create threads
    newVmem: fn () struct { sys.Error!void, usize },

    // TODO: make sure there is only one copy of
    // this frame so that the vm can read it in peace
    /// load an ELF into an address space
    loadElf: fn (handle: usize, elf: caps.Frame, offset: usize, length: usize) sys.Error!void,

    /// create a new thread from an address space
    /// ip and sp are already set
    newThread: fn (handle: usize) struct { sys.Error!void, caps.Thread },
});

// pub const PmProtocol = util.Protocol(struct {});
