const std = @import("std");
const abi = @import("abi");

pub const arch = @import("arch.zig");
pub const hpet = @import("hpet.zig");
pub const lazy = @import("lazy.zig");
pub const main = @import("main.zig");
pub const pmem = @import("pmem.zig");
pub const ring = abi.ring;
pub const spin = @import("spin.zig");
pub const tree = @import("tree.zig");
pub const vmem = @import("vmem.zig");
pub const util = @import("util.zig");
pub const slab = @import("slab.zig");
pub const proto = @import("proto.zig");
pub const heap = @import("heap.zig");

//

const log = std.log.scoped(.proc);

//

pub const Context = struct {
    lock: spin.Mutex = spin.Mutex.new(),
    status: enum {
        empty,
        running,
        ready,
        sleeping,
    } = .empty,
    addr_space: ?vmem.AddressSpace = null,
    trap: arch.SyscallRegs = .{},
    is_system: bool = false,

    /// futex uses this field to make a linked list
    /// if multiple processes are waiting on the same address
    futex_next: ?usize = null,

    /// linked list of protocols owned by this
    protos: ?*proto.Protocol = null,

    queues_n: usize = 0,
    queues: [1]struct {
        // FIXME: lock
        unhandled: ?abi.sys.SubmissionEntry = null,
        sq: *abi.sys.SubmissionQueue,
        cq: *abi.sys.CompletionQueue,
        // FIXME: make sure the page doesnt get freed
        futex: pmem.PhysAddr,
    } = undefined,

    fd_map_lock: spin.Mutex = .{},
    fd_map: std.ArrayList(*FileDescriptor) = std.ArrayList(*FileDescriptor).init(slab.global_allocator.allocator()),

    const Self = @This();

    fn pidOf(self: *Self) usize {
        return (@intFromPtr(self) - @intFromPtr(&proc_table)) / @sizeOf(Self);
    }
};

var fd_alloc_lock: spin.Mutex = .{};
var fd_alloc: std.heap.MemoryPool(FileDescriptor) = std.heap.MemoryPool(FileDescriptor).init(slab.global_allocator.allocator());

pub const FileDescriptor = struct {
    protocol: *proto.Protocol,
    real_fd: u32,
    refcnt: std.atomic.Value(u32),
};

// TODO: lazy page allocation for a table that can grow
var proc_table: [256]Context = blk: {
    var arr: [256]Context = undefined;
    for (&arr) |*c| {
        c.* = Context{};
    }
    break :blk arr;
};

const PidList = std.DoublyLinkedList(usize);
var pid_allocator_lock: spin.Mutex = .{};
var pid_allocator = std.heap.MemoryPool(PidList.Node).init(pmem.page_allocator);

fn pushPid(list: *PidList, pid: usize) void {
    pid_allocator_lock.lock();
    defer pid_allocator_lock.unlock();

    const node: *PidList.Node = pid_allocator.create(PidList.Node);
    node.* = .{ .data = pid };
    list.append(list);
}

fn popPid(list: *PidList) ?usize {
    const node = list.popFirst() orelse return null;
    const pid = node.data;

    pid_allocator_lock.lock();
    defer pid_allocator_lock.unlock();

    pid_allocator.destroy(node);
    return pid;
}

pub fn Pipe(comptime T: type, comptime limit: usize) type {
    return struct {
        buffer: ring.AtomicRing(T, [limit]T) = ring.AtomicRing(T, [limit]T).init(undefined, limit),

        waiting_for_items_lock: spin.Mutex = .{},
        waiting_for_items: PidList = .{},

        // waiting_for_room_lock: spin.Mutex = .{},
        // waiting_for_room: PidList = .{},

        const Self = @This();

        pub fn push(self: *Self) void {
            // TODO: wait if full

            self.waiting_for_items_lock.lock();
            const pid = popPid(&self.waiting_for_items);
            self.waiting_for_items_lock.unlock();

            if (pid) |some_pid| {
                self.buffer.push(some_pid);
            }

            pushReady(pid);
        }

        pub fn pop(self: *Self) error{WentToSleep}!T {
            if (self.buffer.pop()) |val| {
                return val;
            }

            @setCold(true);

            self.waiting_for_items_lock.lock();
            pushPid(&self.waiting_for_items, currentPid().?);
            self.waiting_for_items_lock.unlock();
            return error.WentToSleep;
        }
    };
}

pub fn pushReady(pid: usize) void {
    ready_w_lock.lock();
    defer ready_w_lock.unlock();

    ready.push(pid) catch unreachable;
}

pub fn popReady() ?usize {
    ready_r_lock.lock();
    defer ready_r_lock.unlock();

    return ready.pop();
}

var lazy_wait_vmm = lazy.Lazy(vmem.AddressSpace).new();

/// NOTE: might or might not switch to another VMM
pub fn popWait() usize {
    if (popReady()) |next| {
        return next;
    }

    @setCold(true);

    const vmm = lazy_wait_vmm.waitOrInit(struct {
        pub fn init() vmem.AddressSpace {
            return vmem.AddressSpace.new();
        }
    });
    vmm.switchTo();

    while (true) {
        if (popReady()) |next| {
            return next;
        }

        // halt the CPU until there is something to do
        // FIXME: switch to a temporary VMM and release the current process
        const before_wait = hpet.now();
        arch.x86_64.ints.wait();
        const elapsed: f64 = @floatFromInt(hpet.elapsedNanos(before_wait));
        log.info("hlt lasted {d}ms", .{elapsed / 1_000_000.0});
    }
}

pub fn nextPid(now_pid: usize) ?usize {
    const next_pid = popReady() orelse {
        return null;
    };
    pushReady(now_pid);

    return next_pid;
}

pub fn tick() void {
    log.info("TIMER INTERRUPT, pid={any}", .{currentPid()});

    if (currentPid()) |current_pid| {
        ioJobs(find(current_pid));
    }
}

pub fn ioJobs(proc: *Context) void {
    for (proc.queues[0..proc.queues_n], 0..) |*queue, ring_id| {
        if (!queue.cq.canWrite(1)) {
            continue;
        }

        // FIXME: validate the queue memory and slots instead of just trusting it
        const submission: abi.sys.SubmissionEntry = if (queue.unhandled) |unhandled|
            unhandled
        else
            queue.sq.pop() orelse continue;
        queue.unhandled = null;

        var result: ?abi.sys.CompletionEntry = null;
        switch (submission.opcode) {
            .proto_create => {
                result = resultToCompletionEntry(
                    proto_create(proc, ring_id, submission),
                );
            },
            .open => {
                result = resultToCompletionEntry(
                    open(proc, ring_id, submission),
                );
            },
            else => result = .{
                .user_data = submission.user_data,
                .result = abi.sys.encode(error.InvalidArgument),
            },
        }

        if (result) |_result| {
            // this is why shadowing is useful
            var __result = _result;
            __result.user_data = submission.user_data;
            queue.cq.push(__result) catch {};

            const futex = queue.futex.toHhdm().ptr(*std.atomic.Value(usize));
            _ = futex.fetchAdd(1, .release);
            futex_wake_external(queue.futex, 1);
        }
    }

    var next_proto = proc.protos;
    while (next_proto) |protocol| {
        next_proto = protocol.next;

        const handler = &protocol.handler.?;

        // FIXME: validate the queue memory and slots instead of just trusting it
        var completion: abi.sys.CompletionEntry = if (handler.unhandled) |unhandled|
            unhandled
        else
            protocol.handler.?.completion_queue.pop() orelse continue;
        handler.unhandled = null;

        // log.debug("got completion", .{});

        if (handler.sources.remove(completion.user_data)) |source_node| {
            const source_node_copy = source_node.*;
            slab.global_allocator.allocator().destroy(source_node);

            // FIXME: nothing if the proc is gone
            const source_proc = find(source_node_copy.value.process_id);
            // FIXME: nothing if the queue is gone
            const source_queue = source_proc.queues[source_node_copy.value.queue_id];
            // FIXME: use the queue without switching page maps
            source_proc.addr_space.?.switchTo();
            defer proc.addr_space.?.switchTo();

            if (source_node_copy.value.is_open) {
                if (abi.sys.decode(completion.result) catch null) |real_fd| {
                    var fd: *FileDescriptor = undefined;
                    {
                        fd_alloc_lock.lock();
                        defer fd_alloc_lock.unlock();
                        fd = fd_alloc.create() catch |err| {
                            log.err("could not allocate FileDescriptor: {}", .{err});
                            break;
                        };
                    }

                    fd.protocol = protocol;
                    fd.real_fd = @truncate(real_fd);
                    fd.refcnt = .{ .raw = 1 };

                    const fake_fd = source_proc.fd_map.items.len;
                    {
                        source_proc.fd_map_lock.lock();
                        defer source_proc.fd_map_lock.unlock();

                        source_proc.fd_map.append(fd) catch |err| {
                            log.err("could not allocate FileDescriptor: {}", .{err});
                            break;
                        };
                    }

                    completion.result = abi.sys.encode(fake_fd);
                }
            }

            // the user process is responsible for not submitting too much crap
            // without collecting the results
            //
            // the completion queue size is 2x the submission queue size,
            // so well behaved apps dont have issues with results getting discarded
            source_queue.cq.push(.{
                .user_data = source_node_copy.value.user_data,
                .result = completion.result,
            }) catch {};

            futex_wake_external(source_queue.futex, 1);
        } else {
            log.err("protocol handler returned user_data that was invalid", .{});
        }
    }
}

fn resultToCompletionEntry(v: abi.sys.Error!?abi.sys.CompletionEntry) ?abi.sys.CompletionEntry {
    return v catch |e| {
        return .{
            .result = abi.sys.encodeError(e),
        };
    };
}

fn proto_create(proc: *Context, _: usize, req: abi.sys.SubmissionEntry) abi.sys.Error!?abi.sys.CompletionEntry {
    log.debug("proto_create", .{});

    if (req.buffer_len != @sizeOf(abi.io.ProtoCreate.Buffer)) {
        return abi.sys.Error.InvalidArgument;
    }

    if (@intFromPtr(req.buffer) % @alignOf(abi.io.ProtoCreate.Buffer) != 0) {
        return abi.sys.Error.InvalidArgument;
    }

    const buffer = @as(*abi.io.ProtoCreate.Buffer, @alignCast(@ptrCast(req.buffer))).*;
    const name = &buffer.protocol;

    // FIXME: untrusted pointers all over the place

    const protocol = try proto.register(name, .{
        .process_id = proc.pidOf(),
        .submission_queue = buffer.submission_queue,
        .completion_queue = buffer.completion_queue,
        .futex = buffer.futex,
        .buffers = buffer.buffers,
        .buffer_size = buffer.buffer_size,
    });

    protocol.next = proc.protos;
    proc.protos = protocol;

    return abi.sys.CompletionEntry{ .result = 0 };
}

fn open(proc: *Context, ring_id: usize, req: abi.sys.SubmissionEntry) abi.sys.Error!?abi.sys.CompletionEntry {
    if (req.buffer_len > 0x1000 + 3 + 16) {
        return error.InvalidArgument;
    }

    var path: []const u8 = try untrustedSlice(u8, @intFromPtr(req.buffer), req.buffer_len);

    var protocol_name: []const u8 = "fs";
    if (std.mem.indexOf(u8, path[0..@min(19, path.len)], "://")) |split_idx| {
        protocol_name = path[0..split_idx];
        path = path[split_idx + 3 ..];
    }

    log.debug("open `{s}` in `{s}`", .{ path, protocol_name });

    if (path.len > 0x1000) {
        return abi.sys.Error.InvalidArgument;
    }

    const protocol = try proto.find(protocol_name);
    protocol.lock.lock();
    defer protocol.lock.unlock();

    const handler = &(protocol.handler orelse return abi.sys.Error.UnknownProtocol);

    const target_proc = find(handler.process_id);

    // FIXME: handler sanitation

    // target_proc.lock.lock();
    // defer target_proc.lock.unlock();

    // FIXME: copy the other way, to remove these 2 switches
    // it requires using the ring buffer indirectly
    target_proc.addr_space.?.switchTo();
    defer proc.addr_space.?.switchTo();

    const slot = handler.submission_queue.marker.acquire(1) orelse {
        proc.queues[ring_id].unhandled = req;
        return null;
    };

    const user_data = handler.sources_next;
    handler.sources_next = handler.sources_next +% 1;

    const source_node = slab.global_allocator.allocator().create(proto.Sources.Node) catch unreachable; // FIXME: OOM
    source_node.key = user_data;
    source_node.value = .{
        .process_id = proc.pidOf(),
        .queue_id = ring_id,
        .user_data = req.user_data,
        .is_open = true,
    };
    if (!handler.sources.insert(source_node)) {
        // FIXME: IDs wrapped
        log.err("protocol user_data IDs wrapped", .{});
    }

    // write the buffer data to the target process
    // handler.buffers is already verified to be usable
    const per_submission_buffer: [*]u8 = @ptrCast(&handler.buffers[slot.first * handler.buffer_size]);
    proc.addr_space.?.readBytes(
        per_submission_buffer[0..path.len],
        pmem.VirtAddr.new(@intFromPtr(path.ptr)),
        .user,
    ) catch unreachable; // FIXME: segfault
    // target_proc.addr_space.?.writeBytes(
    //     pmem.VirtAddr.new(@intFromPtr(per_submission_buffer)),
    //     path,
    //     .user,
    // ) catch unreachable; // FIXME: segfault
    // FIXME: untrusted pointer
    handler.submission_queue.storage[slot.first] = .{
        .user_data = user_data,
        .offset = req.offset,
        .buffer = @ptrCast(per_submission_buffer),
        .buffer_len = @truncate(path.len), // path is less than or equal to 0x1000
        .fd = 0,
        .opcode = .open,
        .flags = req.flags,
    };
    handler.submission_queue.marker.produce(slot);

    const addr = target_proc.addr_space.?.translate(
        pmem.VirtAddr.new(@intFromPtr(handler.futex)),
        true,
    ) orelse unreachable; // FIXME: segfault
    futex_wake_external(addr, 1);
    log.info("done producing", .{});

    return null;
}

const FutexTree = tree.RbTree(pmem.PhysAddr, usize, struct {
    fn inner(a: pmem.PhysAddr, b: pmem.PhysAddr) std.math.Order {
        return std.math.order(a.raw, b.raw);
    }
}.inner);
var futex_tree_lock: spin.Mutex = .{};
var futex_tree: FutexTree = .{};
var futex_node_allocator = std.heap.MemoryPool(FutexTree.Node).init(pmem.page_allocator);

pub fn futex_wait(value: *std.atomic.Value(usize), expected: usize, trap: *arch.SyscallRegs) void {
    const this_pid = currentPid().?;
    const this = find(this_pid);

    // the address is already checked to be safe to use
    if (value.load(.acquire) != expected) {
        return;
    }

    const addr = this.addr_space.?.translate(pmem.VirtAddr.new(@intFromPtr(value)), false) orelse {
        // not mapped, do nothing as it might have been a lazy page
        return;
    };

    futex_tree_lock.lock();
    defer futex_tree_lock.unlock();

    // add the process into the sleep queue
    switch (futex_tree.entry(addr)) {
        .occupied => |entry| {
            const already_waiting_pid = entry.value;
            this.futex_next = already_waiting_pid;
            entry.value = this_pid;
        },
        .vacant => |entry| {
            const node = futex_node_allocator.create() catch {
                std.debug.panic("futex OOM", .{});
            };
            node.key = addr;
            node.value = this_pid;
            futex_tree.insertVacant(node, entry);
        },
    }

    unlockAndYield(trap);

    const next_pid = popWait();
    lockAndSwitchTo(next_pid, trap);
}

pub fn futex_wake(value: *std.atomic.Value(usize), n: usize) void {
    if (n == 0) return;

    const this_pid = currentPid().?;
    const this = find(this_pid);
    const addr = this.addr_space.?.translate(pmem.VirtAddr.new(@intFromPtr(value)), true) orelse return;

    futex_wake_external(addr, n);
}

pub fn futex_wake_external(addr: pmem.PhysAddr, n: usize) void {
    if (n == 0) return;

    futex_tree_lock.lock();
    defer futex_tree_lock.unlock();

    const node = futex_tree.remove(addr) orelse return;

    var first_proc = node.value;
    for (0..n) |_| {
        pushReady(first_proc);
        if (find(first_proc).futex_next) |next_proc| {
            first_proc = next_proc;
        } else {
            break;
        }
    }
}

pub fn yield(now_pid: usize, trap: *arch.SyscallRegs) void {
    const next_pid = popReady() orelse {
        return;
    };
    pushReady(now_pid);

    // save the previous process
    unlockAndYield(trap);

    // FIXME: page fault now could lead to a race condition

    // switch to the next process
    lockAndSwitchTo(next_pid, trap);
}

// pub fn protocol_next(
//     now_pid: usize,
//     proto_id: usize,
//     path_buf: *[4096]u8,
//     req: *abi.sys.ProtocolRequest,
//     trap: *arch.SyscallRegs,
// ) void {
//     const proc = find(now_pid);
//     const proto = proc.protos[proto_id].?;

//     const next = proto.sleepers.pop() catch {
//         proc.previous_job = .{ .protocol_next = .{ .id = 1 } };
//         unlockAndYield(trap);
//     };

//     // TODO:
//     return;

//     const next = proto.sleepers.pop() catch {
//         proc.popReady();
//         // save the previous process
//         proc.unlockAndYield(trap);
//     };
// }

pub fn find(pid: usize) *Context {
    return &proc_table[pid];
}

pub fn currentPid() ?usize {
    return arch.cpu_local().current_pid;
}

pub fn current() *Context {
    return find(currentPid().?);
}

// FIXME: lock first, then unlock to prevent the active VMM from being deallocated or something
// then the zero process wait switches to a custom waiting VMM
/// WARNING: assumes that the current process lock **IS** held, and then **RELEASES** it
/// set the current process to be ready and switch away from it
pub fn unlockAndYield(trap: *arch.SyscallRegs) void {
    const cpu = arch.cpu_local();
    if (cpu.current_pid) |prev| {
        cpu.current_pid = null;

        const proc = &proc_table[prev];
        proc.status = .ready;
        proc.trap = trap.*;
        proc.lock.unlock();
    }

    // set the ip to kernel space, so if we accidentally return here,
    // then that page faults as user in kernel space without an active process,
    // which can be detected as a kernel error
    trap.user_instr_ptr = 0xFFFF_FFFF_8000_0000;
}

/// WARNING: assumes that the next process lock is **NOT** held, and then **LOCKS** it
pub fn lockAndSwitchTo(pid: usize, trap: *arch.SyscallRegs) void {
    const proc = &proc_table[pid];
    proc.lock.lock();
    proc.status = .running;

    arch.cpu_local().current_pid = pid;
    proc.addr_space.?.switchTo();
    trap.* = proc.trap;
}

pub fn returnEarly(pid: usize) noreturn {
    arch.x86_64.sysret(&proc_table[pid].trap);
}

//

var ready_r_lock: spin.Mutex = .{};
var ready_w_lock: spin.Mutex = .{};
var ready: ring.AtomicRing(usize, [256]usize) = ring.AtomicRing(usize, [256]usize).init(undefined, 256);

//

pub fn isInLowerHalf(comptime T: type, bottom: usize, length: usize) abi.sys.Error!void {
    const byte_len = @mulWithOverflow(@sizeOf(T), length);
    if (byte_len[1] != 0) {
        return error.InvalidAddress;
    }

    const top = @addWithOverflow(bottom, byte_len[0]);
    if (top[1] != 0) {
        return error.InvalidAddress;
    }

    if (top[0] >= 0x8000_0000_0000) {
        return error.InvalidAddress;
    }
}

pub fn untrustedSlice(comptime T: type, bottom: usize, length: usize) abi.sys.Error![]T {
    try isInLowerHalf(T, bottom, length);

    if (bottom % @alignOf(T) != 0) {
        return abi.sys.Error.InvalidArgument;
    }

    // pagefaults from the kernel touching lower half should just kill the process,
    // way faster and easier than testing for access
    // (no supervisor pages are ever mapped to lower half)

    const first: [*]T = @ptrFromInt(bottom);
    return first[0..length];
}

pub fn untrustedPtr(comptime T: type, ptr: usize) abi.sys.Error!*T {
    const slice = try untrustedSlice(T, ptr, 1);
    return &slice[0];
}

fn fillWith(comptime n: usize, comptime val: anytype) [n]@TypeOf(val) {
    var arr = [n]@TypeOf(val);
    for (&arr) |*v| {
        v.* = val;
    }
    return arr;
}
