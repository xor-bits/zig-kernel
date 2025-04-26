const std = @import("std");
const abi = @import("abi");

const addr = @import("addr.zig");
const arch = @import("arch.zig");
const caps = @import("caps.zig");
const spin = @import("spin.zig");

const log = std.log.scoped(.proc);
const Error = abi.sys.Error;

//

// TODO: maybe a fastpath ring buffer before the linked list to reduce locking

var active_threads: std.atomic.Value(usize) = .init(0);
var queues: [4]Queue = .{ .{}, .{}, .{}, .{} };
var queue_locks: [4]spin.Mutex = .{ .new(), .new(), .new(), .new() };

const Queue = struct {
    head: ?caps.Ref(caps.Thread) = null,
    tail: ?caps.Ref(caps.Thread) = null,

    pub fn push(self: *@This(), thread: caps.Ref(caps.Thread)) void {
        if (self.tail) |tail| {
            thread.ptr().prev = tail;
            tail.ptr().next = thread;
        } else {
            const thread_ptr = thread.ptr();
            thread_ptr.next = null;
            thread_ptr.prev = null;
            self.head = thread;
        }

        self.tail = thread;
    }

    pub fn pop(self: *@This()) ?caps.Ref(caps.Thread) {
        const head = self.head orelse return null;
        const tail = self.tail orelse return null;

        if (head.paddr.raw == tail.paddr.raw) {
            self.head = null;
            self.tail = null;
        } else {
            self.head = head.ptr().next.?; // assert that its not null
        }

        return head;
    }
};

//

/// add the current thread back to the ready queue (if ready) and maybe switch to another thread
pub fn yield(trap: *arch.SyscallRegs) void {
    const local = arch.cpu_local();
    if (local.current_thread) |prev_thread| {
        local.current_thread = null;
        prev_thread.trap = trap.*;

        switch (prev_thread.status) {
            .ready, .running => ready(prev_thread),
            .stopped, .waiting => {},
        }
    }

    switchNow(trap);
}

/// switch to another thread without adding the thread back to the ready queue
pub fn switchNow(trap: *arch.SyscallRegs) void {
    switchTo(trap, next().ptr());
}

/// switch to another thread, skipping the scheduler entirely
pub fn switchTo(trap: *arch.SyscallRegs, thread: *caps.Thread) void {
    const local = arch.cpu_local();
    local.current_thread = thread;
    caps.Vmem.switchTo(thread.vmem.?);
    trap.* = thread.trap;
}

/// stop the thread and (TODO) interrupt a processor that might be running it
pub fn stop(thread: caps.Ref(caps.Thread)) Error!void {
    const thread_ptr = thread.ptr();
    if (thread_ptr.status == .stopped) return Error.IsStopped;

    thread_ptr.status = .stopped;
    _ = active_threads.fetchSub(1, .release);
    // FIXME: IPI
    // TODO: stop the processor and take the thread
}

/// start the thread, if its not running
pub fn start(thread: caps.Ref(caps.Thread)) Error!void {
    const thread_ptr = thread.ptr();
    if (thread_ptr.status != .stopped) return Error.NotStopped;
    if (thread_ptr.vmem == null) return Error.NoVmem;

    _ = active_threads.fetchAdd(1, .acquire);
    ready(thread_ptr);
}

pub fn ready(thread: *caps.Thread) void {
    const prio = thread.priority;
    std.debug.assert(thread.status != .ready and thread.status != .running);
    thread.status = .ready;

    queue_locks[prio].lock();
    defer queue_locks[prio].unlock();

    queues[prio].push(caps.Ref(caps.Thread){ .paddr = addr.Virt.fromPtr(thread).hhdmToPhys() });
}

pub fn next() caps.Ref(caps.Thread) {
    // log.debug("waiting for next thread", .{});
    // defer log.debug("waiting for next thread done", .{});

    if (active_threads.load(.monotonic) == 0) {
        log.err("NO ACTIVE THREADS", .{});
        log.err("THIS IS A USER-SPACE ERROR", .{});
        log.err("SYSTEM HALT UNTIL REBOOT", .{});
        // arch.hcf();
    }

    while (true) {
        if (tryNext()) |next_thread| return next_thread;
        arch.ints.wait();
    }
}

pub fn tryNext() ?caps.Ref(caps.Thread) {
    for (&queue_locks, &queues) |*lock, *queue| {
        lock.lock();
        defer lock.unlock();

        if (queue.pop()) |next_thread| {
            if (next_thread.ptr().status == .stopped) {
                continue;
            } else {
                return next_thread;
            }
        }
    }

    return null;
}
