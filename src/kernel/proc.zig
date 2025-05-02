const std = @import("std");
const abi = @import("abi");

const addr = @import("addr.zig");
const apic = @import("apic.zig");
const arch = @import("arch.zig");
const caps = @import("caps.zig");
const conf = @import("conf.zig");
const main = @import("main.zig");
const spin = @import("spin.zig");
const util = @import("util.zig");

const log = std.log.scoped(.proc);
const Error = abi.sys.Error;

//

// TODO: maybe a fastpath ring buffer before the linked list to reduce locking

var active_threads: std.atomic.Value(usize) = .init(1);
var queues: [4]Queue = .{Queue{}} ** 4;
var queue_locks: [4]spin.Mutex = .{spin.Mutex{}} ** 4;
var waiters: [256]Waiter = .{Waiter.init(null)} ** 256;

const Queue = util.Queue(caps.Thread, "next", "prev");
const Waiter = std.atomic.Value(?*main.CpuLocalStorage);

//

pub fn init() void {
    // the number is 1 by default, starting root makes it 2 and this drops it back to the real 1
    _ = active_threads.fetchSub(1, .seq_cst);
}

/// add the current thread back to the ready queue (if ready) and maybe switch to another thread
pub fn yield(trap: *arch.SyscallRegs) void {
    const local = arch.cpuLocal();
    if (local.current_thread) |prev_thread| {
        local.current_thread = null;
        prev_thread.trap = trap.*;

        switch (prev_thread.status) {
            .ready, .running => {
                prev_thread.status = .waiting;
                ready(prev_thread);
            },
            .stopped, .waiting => {},
        }
    }

    switchNow(trap);
}

/// switch to another thread without adding the thread back to the ready queue
pub fn switchNow(trap: *arch.SyscallRegs) void {
    switchTo(trap, next());
}

/// switch to another thread, skipping the scheduler entirely
/// does **NOT** save the previous context or set its status
pub fn switchTo(trap: *arch.SyscallRegs, thread: *caps.Thread) void {
    const local = arch.cpuLocal();
    local.current_thread = thread;
    caps.Vmem.switchTo(thread.vmem.?);
    trap.* = thread.trap;
    thread.status = .running;

    if (conf.LOG_CTX_SWITCHES)
        log.debug("switch to {*}", .{thread});
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

    queues[prio].pushBack(thread);

    // notify a single sleeping processor
    for (&waiters) |*w| {
        const waiter: *const main.CpuLocalStorage = w.swap(null, .acquire) orelse continue;
        // log.info("giving thread to {} ({})", .{ waiter.id, waiter.lapic_id });
        apic.interProcessorInterrupt(waiter.lapic_id);
        break;
    }

    // TODO: else notify the lowest priority processor
    // (if its current priority is lower than this new one)
}

pub fn next() *caps.Thread {
    if (active_threads.load(.monotonic) == 0) {
        log.err("NO ACTIVE THREADS", .{});
        log.err("THIS IS A USER-SPACE ERROR", .{});
        log.err("SYSTEM HALT UNTIL REBOOT", .{});
        // arch.hcf();
    }

    if (tryNext()) |next_thread| return next_thread;

    if (conf.LOG_WAITING)
        log.debug("waiting for next thread", .{});
    defer if (conf.LOG_WAITING)
        log.debug("next thread acquired", .{});

    while (true) {
        const locals = arch.cpuLocal();
        waiters[locals.id].store(locals, .seq_cst);
        arch.ints.wait();

        if (tryNext()) |next_thread| return next_thread;
    }
}

pub fn tryNext() ?*caps.Thread {
    for (&queue_locks, &queues) |*lock, *queue| {
        lock.lock();
        defer lock.unlock();

        if (queue.popFront()) |next_thread| {
            if (next_thread.status == .stopped) {
                continue;
            } else {
                return next_thread;
            }
        }
    }

    return null;
}
