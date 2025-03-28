pub const std = @import("std");

pub const ring = @import("ring.zig");
pub const abi = @import("lib.zig");

//

pub const Result = extern struct {
    done: bool = false,
    result: usize = 0,
};

pub const ProtoCreate = struct {
    buffer: Buffer,
    result: Result = .{},
    io_ring: ?*const abi.IoRing = null,

    pub const Return = abi.sys.Error!void;

    pub const Buffer = extern struct {
        protocol: [16]u8,
        submission_queue: *abi.sys.SubmissionQueue,
        completion_queue: *abi.sys.CompletionQueue,
        futex: *std.atomic.Value(usize),
        /// all buffers
        buffers: [*]u8,
        /// size of one of the buffers,
        /// there are as many as there are submission slots
        buffer_size: usize,
    };

    const Self = @This();

    pub fn new(comptime name: []const u8, proto_ring: *const abi.IoRing, buffers: []u8) Self {
        const pad: usize = 16 - name.len;
        const protocol = name ++ std.mem.zeroes([pad:0]u8);

        return newRaw(.{
            .protocol = protocol.*,
            .submission_queue = &proto_ring.inner.submissions,
            .completion_queue = &proto_ring.inner.completions,
            .futex = &proto_ring.inner.futex,
            .buffers = buffers.ptr,
            .buffer_size = buffers.len / proto_ring.inner.submissions.marker.capacity,
        });
    }

    pub fn newRaw(val: Buffer) Self {
        return Self{
            .buffer = val,
        };
    }

    /// the data behind the `self` pointer has to be pinned in
    /// memory at least until the request is complete
    pub fn submit(self: *Self, io_ring: *const abi.IoRing) void {
        self.io_ring = io_ring;
        submit_entry(.{
            .user_data = @intFromPtr(&self.result),
            .opcode = .proto_create,
            .flags = 0,
            .fd = 0,
            .buffer = @ptrCast(&self.buffer),
            .buffer_len = @sizeOf(@TypeOf(self.buffer)),
            .offset = 0,
        }, io_ring);
    }

    pub fn wait(self: *Self) Return {
        const io_ring = self.io_ring orelse std.debug.panic("request not submitted", .{});
        wait_entry(io_ring, &self.result);

        _ = try abi.sys.decode(self.result.result);
    }
};

pub const Open = struct {
    path: []const u8,
    result: Result = .{},
    io_ring: ?*const abi.IoRing = null,

    pub const Return = abi.sys.Error!u32;

    const Self = @This();

    pub fn new(comptime path: []const u8) Self {
        return .{
            .path = path,
        };
    }

    /// the data behind the `self` pointer has to be pinned in
    /// memory at least until the request is complete
    pub fn submit(self: *Self, io_ring: *const abi.IoRing) void {
        self.io_ring = io_ring;
        submit_entry(.{
            .user_data = @intFromPtr(&self.result),
            .opcode = .open,
            .flags = 0,
            .fd = 0,
            .buffer = @constCast(@ptrCast(self.path.ptr)),
            .buffer_len = @truncate(self.path.len),
            .offset = 0,
        }, io_ring);
    }

    pub fn wait(self: *Self) Return {
        const io_ring = self.io_ring orelse std.debug.panic("request not submitted", .{});
        wait_entry(io_ring, &self.result);

        return @truncate(try abi.sys.decode(self.result.result));
    }
};

pub fn submit_entry(entry: abi.sys.SubmissionEntry, io_ring: *const abi.IoRing) void {
    while (true) {
        if (io_ring.submit(entry)) |_| {
            return;
        } else |_| {}

        // FIXME: 2 futexes, one for waiting for free slots and one for waiting for returns
        io_ring_process(io_ring);
    }
}

pub fn wait_entry(io_ring: *const abi.IoRing, result: *const Result) void {
    while (true) {
        if (result.done) {
            break;
        }

        io_ring_process(io_ring);
    }
}

pub fn io_ring_process(io_ring: *const abi.IoRing) void {
    const next = io_ring.wait_completion();
    const result_ptr: *Result = @ptrFromInt(next.user_data);
    result_ptr.done = true;
    result_ptr.result = next.result;
}

pub fn sync(request: anytype, io_ring: *const abi.IoRing) @TypeOf(request).Return {
    var _request = request;
    _request.submit(io_ring);
    return _request.wait();
}
