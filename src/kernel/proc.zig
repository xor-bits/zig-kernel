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

    // unhandled: ?abi.sys.SubmissionEntry,
    queues_n: usize = 0,
    queues: [1]struct {
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
}

pub fn ioJobs(proc: *Context) void {
    for (proc.queues[0..proc.queues_n], 0..) |queue, ring_id| {
        if (!queue.cq.canWrite(1)) {
            continue;
        }

        // FIXME: validate the queue memory and slots instead of just trusting it
        const submission: abi.sys.SubmissionEntry = queue.sq.pop() orelse continue;

        var result: ?abi.sys.CompletionEntry = null;
        switch (submission.opcode) {
            .vfs_proto_next_open => {
                result = resultToCompletionEntry(
                    vfs_proto_next_open(proc, ring_id, submission),
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

fn vfs_proto_next_open(proc: *Context, ring_id: usize, req: abi.sys.SubmissionEntry) abi.sys.Error!?abi.sys.CompletionEntry {
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
        .user_data = req.user_data,
        .process_id = proc.pidOf(),
        .ring_id = ring_id,
        .flags = 1,
    };

    return null;
}

fn open(proc: *Context, ring_id: usize, req: abi.sys.SubmissionEntry) abi.sys.Error!?abi.sys.CompletionEntry {
    _ = req; // autofix
    _ = proc; // autofix
    _ = ring_id; // autofix

    // const path = try main.untrustedSlice(u8, @intFromPtr(req.buffer), req.buffer_len);
    // log.info("open `{s}`", .{path});

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
