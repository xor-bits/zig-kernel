const abi = @import("abi");
const std = @import("std");

const addr = @import("../addr.zig");
const caps = @import("../caps.zig");
const pmem = @import("../pmem.zig");
const spin = @import("../spin.zig");

const conf = abi.conf;
const log = std.log.scoped(.caps);
const Error = abi.sys.Error;

//

pub const Process = struct {
    // FIXME: prevent reordering so that the offset would be same on all objects
    refcnt: abi.epoch.RefCnt = .{},

    vmem: *caps.Vmem,
    lock: spin.Mutex = .newLocked(),
    caps: std.ArrayList(caps.CapabilitySlot), // TODO: unmanaged

    pub fn init(from_vmem: *caps.Vmem) !*@This() {
        errdefer from_vmem.deinit();

        if (conf.LOG_OBJ_CALLS)
            log.info("Process.init", .{});

        const obj: *@This() = try caps.slab_allocator.allocator().create(@This());
        obj.* = .{
            .vmem = from_vmem,
            .caps = .init(caps.slab_allocator.allocator()),
        };
        obj.lock.unlock();

        return obj;
    }

    pub fn deinit(self: *@This()) void {
        if (!self.refcnt.dec()) return;

        if (conf.LOG_OBJ_CALLS)
            log.info("Process.deinit", .{});

        for (self.caps.items) |*cap_slot| {
            cap_slot.deinit();
        }

        self.caps.deinit();
        self.vmem.deinit();

        caps.slab_allocator.allocator().destroy(self);
    }

    pub fn clone(self: *@This()) *@This() {
        if (conf.LOG_OBJ_CALLS)
            log.info("Process.clone", .{});

        self.refcnt.inc();
        return self;
    }

    pub fn pushCapability(self: *@This(), cap: caps.Capability) Error!u32 {
        std.debug.assert(cap.type != .null);

        // TODO: free list

        self.lock.lock();
        defer self.lock.unlock();

        const handle_usize = self.caps.items.len + 1;
        if (handle_usize > std.math.maxInt(u32)) return Error.OutOfBounds;
        const handle: u32 = @intCast(handle_usize);

        try self.caps.append(caps.CapabilitySlot.init(cap));

        return handle;
    }

    pub fn getCapability(self: *@This(), handle: u32) Error!caps.Capability {
        if (handle == 0) return Error.InvalidCapability;

        self.lock.lock();
        defer self.lock.unlock();

        if (handle - 1 >= self.caps.items.len) return Error.InvalidCapability;
        const slot = &self.caps.items[handle - 1];

        return slot.get() orelse return Error.InvalidCapability;
    }

    pub fn takeCapability(self: *@This(), handle: u32) Error!caps.Capability {
        if (handle == 0) return Error.InvalidCapability;

        // TODO: free list

        self.lock.lock();
        defer self.lock.unlock();

        if (handle - 1 >= self.caps.items.len) return Error.InvalidCapability;
        const slot = &self.caps.items[handle - 1];

        const cap = slot.get() orelse return Error.InvalidCapability;
        slot.* = .{};
        return cap;
    }

    pub fn getObject(self: *@This(), comptime T: type, handle: u32) Error!*T {
        const cap = try self.getCapability(handle);
        errdefer cap.deinit();

        return cap.as(T) orelse return Error.InvalidCapability;
    }
};
