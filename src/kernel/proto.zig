const std = @import("std");
const abi = @import("abi");

const spin = @import("spin.zig");
const tree = @import("tree.zig");

const log = std.log.scoped(.proto);

//

pub const Protocol = struct {
    lock: spin.Mutex = .{},
    name: [16]u8,
    handler: ?Handler = null,
    // linked list field for a single process owning multiple protocols
    next: ?*Protocol = null,
};

pub const Handler = struct {
    /// which process is responsible for this protocol
    process_id: usize,

    submission_queue: *abi.sys.SubmissionQueue,
    completion_queue: *abi.sys.CompletionQueue,
    futex: *std.atomic.Value(usize),

    buffers: [*]u8,
    buffer_size: usize,

    // where each submit came from, and where does the completion go to
    sources: Sources = .{},
    sources_next: u64 = 1,

    unhandled: ?abi.sys.CompletionEntry = null,
};

pub const Sources = tree.RbTree(u64, Source, order);

pub const Source = struct {
    process_id: usize,
    queue_id: usize,
    user_data: u64,
    is_open: bool,
};

fn order(a: u64, b: u64) std.math.Order {
    return std.math.order(a, b);
}

//

pub fn register(
    name: *const [16]u8,
    handler: Handler,
) abi.sys.Error!*Protocol {
    log.debug("creating proto: `{s}`", .{std.mem.sliceTo(name, 0)});

    var proto: *Protocol = undefined;

    // FIXME: use a map
    if (std.mem.eql(u8, &known_protos.initfs.name, name)) {
        proto = &known_protos.initfs;
    } else if (std.mem.eql(u8, &known_protos.fs.name, name)) {
        proto = &known_protos.fs;
    } else {
        log.warn("FIXME: other vfs proto name", .{});
        return abi.sys.Error.Unimplemented;
    }

    proto.lock.lock();
    defer proto.lock.unlock();

    if (proto.handler != null) {
        log.warn("vfs proto already registered", .{});
        return abi.sys.Error.AlreadyExists;
    }

    proto.name = name.*;
    proto.handler = handler;

    return proto;
}

pub fn find(
    name: []const u8,
) abi.sys.Error!*Protocol {
    if (std.mem.eql(u8, name, "initfs")) {
        return &known_protos.initfs;
    } else if (std.mem.eql(u8, name, "fs")) {
        return &known_protos.fs;
    } else {
        return abi.sys.Error.UnknownProtocol;
    }
}

//

var known_protos: struct {
    initfs: Protocol = .{
        .lock = .{},
        .name = ("initfs" ++ std.mem.zeroes([10:0]u8)).*,
    },
    fs: Protocol = .{
        .lock = .{},
        .name = ("fs" ++ std.mem.zeroes([14:0]u8)).*,
    },
} = .{};
