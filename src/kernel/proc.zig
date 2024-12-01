const std = @import("std");
const abi = @import("abi");

pub const arch = @import("arch.zig");
pub const spin = @import("spin.zig");
pub const vmem = @import("vmem.zig");
pub const pmem = @import("pmem.zig");
pub const ring = abi.ring;
pub const main = @import("main.zig");
pub const tree = @import("tree.zig");

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
    futex_next: ?*Context = null,

    previous_job: union(enum) {
        yield: void,
        futex: void,
    } = .yield,

    protos: [1]?*main.Protocol = .{null},

    queues_n: usize = 0,
    queues: [1]struct {
        sq: *abi.sys.SubmissionQueue,
        cq: *abi.sys.CompletionQueue,
    } = undefined,
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

pub fn popWait() usize {
    while (true) {
        if (popReady()) |next| {
            return next;
        }

        @setCold(true);

        // halt the CPU until there is something to do
        // FIXME: switch to a temporary VMM and release the current process
        arch.x86_64.ints.wait();
    }
}

pub fn nextPid(now_pid: usize) ?usize {
    const next_pid = popReady() orelse {
        return null;
    };
    pushReady(now_pid);

    return next_pid;
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

    futex_tree_lock.lock();
    defer futex_tree_lock.unlock();

    // the address is already checked to be safe to use
    if (value.load(.acquire) != expected) {
        return;
    }

    const addr = this.addr_space.?.translate(pmem.VirtAddr.new(@intFromPtr(value))).?;

    // add the process into the sleep queue
    switch (futex_tree.entry(addr)) {
        .occupied => |entry| {
            const already_waiting_pid = entry.value;
            const already_waiting = find(already_waiting_pid);

            this.futex_next = already_waiting;
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
    return cpu_table[arch.cpu_id()].current_pid.?;
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
