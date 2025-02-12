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

    previous_job: union(enum) {
        yield: void,
        futex: void,
    } = .yield,

    protos_n: usize = 0,
    protos: [1]?*main.Protocol = .{null},

    queues_n: usize = 0,
    queues: [1]struct {
        // FIXME: lock
        unhandled: ?abi.sys.SubmissionEntry = null,
        sq: *abi.sys.SubmissionQueue,
        cq: *abi.sys.CompletionQueue,
        futex: pmem.PhysAddr,
    } = undefined,

    const Self = @This();

    fn pidOf(self: *Self) usize {
        return (@intFromPtr(self) - @intFromPtr(&proc_table)) / @sizeOf(Self);
    }
};

pub const Cpu = struct {
    current_pid: ?usize,
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
            .proto_next_open => {
                result = resultToCompletionEntry(
                    proto_next_open(proc, ring_id, submission),
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
}

fn resultToCompletionEntry(v: abi.sys.Error!?abi.sys.CompletionEntry) ?abi.sys.CompletionEntry {
    return v catch |e| {
        return .{
            .result = abi.sys.encodeError(e),
        };
    };
}

fn proto_create(proc: *Context, _: usize, req: abi.sys.SubmissionEntry) abi.sys.Error!?abi.sys.CompletionEntry {
    const name = try untrustedSlice(u8, @intFromPtr(req.buffer), @as(usize, req.buffer_len));

    if (name.len > 16) {
        log.warn("vfs proto name too long", .{});
        return abi.sys.Error.InvalidArgument;
    }

    // FIXME: use a map
    if (std.mem.eql(u8, name, "initfs")) {
        main.known_protos.initfs_lock.lock();
        defer main.known_protos.initfs_lock.unlock();
        if (main.known_protos.initfs != null) {
            log.warn("vfs proto already registered", .{});
            return abi.sys.Error.InternalError;
        }
        main.known_protos.initfs = .{
            .name = "initfs".* ++ std.mem.zeroes([10]u8),
        };

        // FIXME:
        const fd = proc.protos_n;
        proc.protos_n += 1;
        proc.protos[fd] = &main.known_protos.initfs.?;

        return abi.sys.CompletionEntry{ .result = fd + 1 };
    } else if (std.mem.eql(u8, name, "fs")) {
        main.known_protos.fs_lock.lock();
        defer main.known_protos.fs_lock.unlock();
        if (main.known_protos.fs != null) {
            log.warn("vfs proto already registered", .{});
            return abi.sys.Error.InternalError;
        }
        main.known_protos.fs = .{
            .name = "fs".* ++ std.mem.zeroes([14]u8),
        };

        const fd = proc.protos_n;
        proc.protos_n += 1;
        proc.protos[fd] = &main.known_protos.fs.?;

        return abi.sys.CompletionEntry{ .result = fd + 1 };
    } else {
        log.warn("FIXME: other vfs proto name", .{});
        return abi.sys.Error.InternalError;
    }
}

fn proto_next_open(proc: *Context, ring_id: usize, req: abi.sys.SubmissionEntry) abi.sys.Error!?abi.sys.CompletionEntry {
    if (req.fd <= 0 or req.fd - 1 >= proc.protos_n) {
        log.warn("fd out of bounds", .{});
        return error.BadFileDescriptor;
    }

    const fd: usize = @intCast(req.fd);
    const proto: *main.Protocol = proc.protos[fd - 1] orelse {
        log.warn("fd not assigned", .{});
        return error.BadFileDescriptor;
    };

    proto.open = .{
        .req = req,
        .process_id = proc.pidOf(),
        .ring_id = ring_id,
    };

    return null;
}

fn open(proc: *Context, ring_id: usize, req: abi.sys.SubmissionEntry) abi.sys.Error!?abi.sys.CompletionEntry {
    if (req.buffer_len > 0x1000 + 3 + 16) {
        return error.InvalidArgument;
    }

    var path: []const u8 = try untrustedSlice(u8, @intFromPtr(req.buffer), req.buffer_len);

    var proto: []const u8 = "fs";
    if (std.mem.indexOf(u8, path[0..@min(19, path.len)], "://")) |split_idx| {
        proto = path[0..split_idx];
        path = path[split_idx + 3 ..];
    }

    var protocol_maybe: ?*main.Protocol = null;
    if (std.mem.eql(u8, proto, "fs")) {
        main.known_protos.fs_lock.lock();
        defer main.known_protos.fs_lock.unlock();

        protocol_maybe = if (main.known_protos.fs) |*s| s else null;
    } else if (std.mem.eql(u8, proto, "initfs")) {
        main.known_protos.initfs_lock.lock();
        defer main.known_protos.initfs_lock.unlock();

        protocol_maybe = if (main.known_protos.initfs) |*s| s else null;
    }

    if (path.len > 0x1000) {
        return error.InvalidArgument;
    }

    const protocol = protocol_maybe orelse return error.InvalidProtocol;
    protocol.lock.lock();
    defer protocol.lock.unlock();

    const target_req = protocol.open orelse return error.InvalidProtocol;
    protocol.open = null;

    const target_proc = find(target_req.process_id);

    log.info("open `{s}` in `{s}`", .{ path, proto });

    target_proc.addr_space.?.switchTo();
    defer proc.addr_space.?.switchTo();

    const target_ring = &target_proc.queues[target_req.ring_id];

    // FIXME: massive security bugs from trusting the user given buffer
    // the buffer could easily point to kernel memory,
    // letting the user process write any data over the kernel code

    const slot: abi.ring.Slot = target_ring.cq.marker.acquire(1) orelse {
        proc.queues[ring_id].unhandled = req;
        log.info("unhandled", .{});
        return null;
    };
    proc.addr_space.?.readBytes(
        target_req.req.buffer[0..path.len],
        pmem.VirtAddr.new(@intFromPtr(path.ptr)),
        .user,
    ) catch {
        // FIXME: segfault the target proc

    };
    const completion = abi.sys.CompletionEntry{
        .user_data = target_req.req.user_data,
        .result = path.len,
    };
    target_ring.cq.storage[slot.first] = completion;
    target_ring.cq.marker.produce(slot);

    // wake the target process if it was waiting on the ring futex
    const futex = target_ring.futex.toHhdm().ptr(*std.atomic.Value(usize));
    _ = futex.fetchAdd(1, .release);
    futex_wake_external(target_ring.futex, 1);

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

    const addr = this.addr_space.?.translate(pmem.VirtAddr.new(@intFromPtr(value))).?;

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

    this.previous_job = .{ .futex = void{} };
    unlockAndYield(trap);

    const next_pid = popWait();
    lockAndSwitchTo(next_pid, trap);
}

pub fn futex_wake(value: *std.atomic.Value(usize), n: usize) void {
    if (n == 0) return;

    const this_pid = currentPid().?;
    const this = find(this_pid);
    const addr = this.addr_space.?.translate(pmem.VirtAddr.new(@intFromPtr(value))) orelse return;

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

    find(now_pid).previous_job = .{ .yield = void{} };

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
    return cpu_table[arch.cpu_id()].current_pid;
}

pub fn current() *Context {
    return find(currentPid().?);
}

// FIXME: lock first, then unlock to prevent the active VMM from being deallocated or something
// then the zero process wait switches to a custom waiting VMM
/// WARNING: assumes that the current process lock **IS** held, and then **RELEASES** it
/// set the current process to be ready and switch away from it
pub fn unlockAndYield(trap: *arch.SyscallRegs) void {
    const cpu = &cpu_table[arch.cpu_id()];
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

    cpu_table[arch.cpu_id()].current_pid = pid;
    proc.addr_space.?.switchTo();
    trap.* = proc.trap;
}

pub fn returnEarly(pid: usize) noreturn {
    arch.x86_64.sysret(&proc_table[pid].trap);
}

//

// TODO: lazy page allocation for a table that can grow
var proc_table: [256]Context = blk: {
    var arr: [256]Context = undefined;
    for (&arr) |*c| {
        c.* = Context{};
    }
    break :blk arr;
};

// TODO: same lazy page allocation for a page that can grow
var cpu_table: [32]Cpu = undefined;

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
