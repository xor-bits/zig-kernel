const std = @import("std");
const abi = @import("abi");

const caps = abi.caps;

//

const log = std.log.scoped(.vfs);
pub const std_options = abi.std_options;
pub const panic = abi.panic;
pub const name = "vfs";
const Error = abi.sys.Error;

//

pub fn main() !void {
    log.info("hello from vfs", .{});

    const root = abi.RootProtocol.Client().init(abi.rt.root_ipc);
    const vm_client = abi.VmProtocol.Client().init(abi.rt.vm_ipc);

    log.debug("requesting memory", .{});
    var res: Error!void, const memory: caps.Memory = try root.call(.memory, {});
    try res;

    // endpoint for vfs server <-> unix app communication
    log.debug("allocating vfs endpoint", .{});
    const vfs_recv = try memory.alloc(caps.Receiver);
    const vfs_send = try vfs_recv.subscribe();

    log.debug("requesting initfs sender", .{});
    res, const initfs_sender: caps.Sender = try root.call(.initfs, {});
    try res;
    const initfs_client = abi.InitfsProtocol.Client().init(initfs_sender);

    res, const entries_frame: caps.Frame, const entries = try initfs_client.call(.list, {});
    try res;

    res, const addr, _ = try vm_client.call(.mapFrame, .{ abi.rt.vmem_handle, entries_frame, abi.sys.Rights{}, abi.sys.MapFlags{} });
    try res;

    var byte: usize = 0;
    for (0..entries) |i| {
        const stat = @as(*const volatile abi.Stat, @ptrFromInt(addr + i * @sizeOf(abi.Stat))).*;
        const path = @as([*:0]const u8, @ptrFromInt(addr + entries * @sizeOf(abi.Stat) + byte));
        const path_name = std.mem.span(path);
        byte += 1 + path_name.len;

        log.info("{s}: {}", .{ path_name, stat });
    }

    // inform the root that vfs is ready
    log.debug("vfs ready", .{});
    res, _ = try root.call(.serverReady, .{ abi.ServerKind.vfs, vfs_send });
    try res;

    // const root_node = try DirNode.create();
    // root_node.inode;

    // const server = abi.vfsProtocol.Server(.{}).init(vfs_recv);
    // try server.run();
}

//

const FileNode = struct {
    refcnt: RefCnt = .{},

    /// inode of the file in the correct device
    inode: u128 = 0,

    cache_lock: abi.lock.YieldMutex = .{},

    /// all cached pages
    pages: []const caps.Frame = &.{},

    pub fn create() !*@This() {
        file_node_allocator_lock.lock();
        defer file_node_allocator_lock.unlock();
        const node = try file_node_allocator.create();
        node.* = .{};
        return node;
    }

    pub fn clone(self: *@This()) void {
        self.refcnt.inc();
    }

    pub fn destroy(self: *@This()) void {
        if (self.refcnt.dec()) {
            @branchHint(.cold);

            file_node_allocator_lock.lock();
            defer file_node_allocator_lock.unlock();
            file_node_allocator.destroy(self);
        }
    }
};

const DirNode = struct {
    refcnt: RefCnt = .{},

    /// inode of the directory in the correct device
    inode: u128 = 0,

    cache_lock: abi.lock.YieldMutex = .{},

    dir_entries: usize = 0,
    file_entries: usize = 0,
    /// all cached entries
    /// first `dir_entries` subdirectories (*DirNode)
    /// then `file_entries` files in this directory (*FileNode)
    entries: []const *anyopaque = &.{},

    pub fn create() !*@This() {
        dir_node_allocator_lock.lock();
        defer dir_node_allocator_lock.unlock();
        const node = try dir_node_allocator.create();
        node.* = .{};
        return node;
    }

    pub fn clone(self: *@This()) void {
        self.refcnt.inc();
    }

    pub fn destroy(self: *@This()) void {
        if (self.refcnt.dec()) {
            @branchHint(.cold);

            dir_node_allocator_lock.lock();
            defer dir_node_allocator_lock.unlock();
            dir_node_allocator.destroy(self);
        }
    }

    pub fn subdirs(self: *@This()) []const *DirNode {
        return @ptrCast(self.entries[0..self.dir_entries]);
    }

    pub fn files(self: *@This()) []const *FileNode {
        return @ptrCast(self.entries[self.dir_entries..][0..self.file_entries]);
    }
};

const RefCnt = struct {
    refcnt: std.atomic.Value(usize) = .init(1),

    pub fn inc(self: *@This()) void {
        const old = self.refcnt.fetchAdd(1, .monotonic);
        if (old >= std.math.maxInt(isize)) @panic("too many ref counts");
    }

    pub fn dec(self: *@This()) bool {
        const old_cnt = self.refcnt.fetchSub(1, .release);
        std.debug.assert(old_cnt < std.math.maxInt(isize));

        if (old_cnt == 1) {
            @branchHint(.cold);
        } else {
            return false;
        }

        // fence
        _ = self.refcnt.load(.acquire);

        return true;
    }
};

var file_node_allocator: std.heap.MemoryPool(FileNode) = std.heap.MemoryPool(FileNode).init(abi.mem.server_page_allocator);
var file_node_allocator_lock: abi.lock.YieldMutex = .{};
var dir_node_allocator: std.heap.MemoryPool(DirNode) = std.heap.MemoryPool(DirNode).init(abi.mem.server_page_allocator);
var dir_node_allocator_lock: abi.lock.YieldMutex = .{};

//

comptime {
    abi.rt.installRuntime();
}
