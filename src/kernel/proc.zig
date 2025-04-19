const std = @import("std");

const addr = @import("addr.zig");
const arch = @import("arch.zig");
const caps = @import("caps.zig");
const spin = @import("spin.zig");

const log = std.log.scoped(.proc);

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

/// add the current thread back to the ready queue and maybe switch to another thread
pub fn yield(trap: *arch.SyscallRegs) void {
    const local = arch.cpu_local();

    if (local.current_thread) |prev_thread| {
        local.current_thread = null;
        prev_thread.trap = trap.*;

        if (!prev_thread.stopped) {
            ready(prev_thread);
        }
    }

    const next_thread = next();
    local.current_thread = next_thread.ptr();
    trap.* = local.current_thread.?.trap;
}

/// stop the thread and (TODO) interrupt a processor that might be running it
pub fn stop(thread: caps.Ref(caps.Thread)) void {
    const thread_ptr = thread.ptr();
    if (thread_ptr.stopped) return;

    thread_ptr.stopped = true;
    _ = active_threads.fetchSub(1, .release);
    // FIXME: IPI
    // TODO: stop the processor and take the thread
}

/// start the thread, if its not running
pub fn start(thread: caps.Ref(caps.Thread)) void {
    const thread_ptr = thread.ptr();
    if (!thread_ptr.stopped) return;

    _ = active_threads.fetchAdd(1, .acquire);
    thread_ptr.stopped = false;
    ready(thread_ptr);
}

pub fn ready(thread: *caps.Thread) void {
    const prio = thread.priority;
    std.debug.assert(thread.stopped == false);

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
            if (next_thread.ptr().stopped) {
                continue;
            } else {
                return next_thread;
            }
        }
    }

    return null;
}
