const abi = @import("abi");
const std = @import("std");

const main = @import("main.zig");

const log = std.log.scoped(.hpet);
const caps = abi.caps;

//

var hpet_regs: ?*volatile HpetRegs = null;
var notify: caps.Notify = .{};
var irqs: [24]caps.X86Irq = .{caps.X86Irq{}} ** 24;

var timer_count: u8 = 0;
var timers: [32]Timer = .{Timer{}} ** 32;

pub fn init(hpet_addr: usize) !void {
    // disable PIT
    const pit_cmd = try main.ioports.alloc(0x43);
    try pit_cmd.outb(0b00_00_001); // ch 0, latch count val cmd, one-shot
    try pit_cmd.outb(0b01_00_001); // ch 1, latch count val cmd, one-shot
    try pit_cmd.outb(0b10_00_001); // ch 2, latch count val cmd, one-shot

    // enable HPET
    hpet_regs = @ptrFromInt(hpet_addr);
    timer_count = @as(*volatile Caps, &hpet_regs.?.caps_and_id).*.n_timers_minus_one + 1;

    notify = try main.memory.alloc(caps.Notify);

    for (0..timer_count) |timer_idx| {
        const timer = hpet_regs.?.timer(timer_idx);

        var conf = @as(*volatile TimerNConfigAndCaps, &timer.config_and_caps).*;
        for (0..24) |irq_idx| {
            if (conf.int_route_cap & (@as(u32, 1) << @as(u5, @truncate(irq_idx))) == 0) continue;

            if (irqs[irq_idx].cap == 0) {
                irqs[irq_idx] = main.irqs.alloc(@truncate(irq_idx)) catch continue;
                try irqs[irq_idx].subscribe(notify);
            }

            log.info("timer hooked up to IRQ{}", .{irq_idx});

            conf = .{
                .int_route_cap = conf.int_route_cap,
                .int_route_config = @as(u5, @truncate(irq_idx)),
                // .pe
            };
            break;
        } else {
            log.err("cannot use timer {} interrupts: 0b{b} {}", .{ timer_idx, conf.int_route_cap, conf });
        }
        @as(*volatile TimerNConfigAndCaps, &timer.config_and_caps).* = conf;
    }

    sleepDeadline(.{}, timestampNanos() + 2_000_000_000);
}

pub fn hpetThread(self: caps.Thread) callconv(.SysV) noreturn {
    hpetThreadMain() catch |err| {
        log.err("HPET interrupt thread error: {}", .{err});
    };
    self.stop() catch {};
    unreachable;
}

fn hpetThreadMain() !void {
    const regs = hpet_regs.?;
    while (true) {
        const main_counter = regs.readMainCounter();

        log.info("HPET INTERRUPT", .{});

        for (timers[0..timer_count], 0..) |*timer, i| {
            timer.lock.lock();
            defer timer.lock.unlock();

            const timer_comparator = @as(*volatile u64, &regs.timer(i).comparator_value);
            const current = timer.current orelse continue;

            // wake up the current waiter
            if (current.deadline <= main_counter) {
                var msg: abi.sys.Message = .{};
                try current.reply.reply(&msg);
            } else {
                continue;
            }

            // wake up every waiter that has its deadline completed
            while (timer.deadlines.removeOrNull()) |next| {
                if (next.deadline <= main_counter) {
                    // wake it up if its ready
                    var msg: abi.sys.Message = .{};
                    try next.reply.reply(&msg);
                } else {
                    // or set it as the timers current target and stop
                    timer.current = next;
                    timer_comparator.* = next.deadline;
                    break;
                }
            }
        }

        _ = try notify.wait();
    }
}

pub fn now() u64 {
    return hpet_regs.?.readMainCounter();
}

pub fn asNanos(t: u64) u128 {
    const regs = hpet_regs.?;
    return @as(u128, t) * regs.readSpeed() / 1_000_000;
}

pub fn elapsedNanos(from_then: u64) u128 {
    const regs = hpet_regs.?;
    return @as(u128, regs.readMainCounter() - from_then) * regs.readSpeed() / 1_000_000;
}

pub fn timestampNanos() u128 {
    const regs = hpet_regs.?;
    return @as(u128, regs.readMainCounter()) * regs.readSpeed() / 1_000_000;
}

pub fn hpetSpinWait(micros: u32) void {
    const regs: *volatile HpetRegs = hpet_regs.?;

    const ticks = (@as(u64, micros) * 1_000_000_000) / @as(u128, regs.readSpeed());

    const deadline = regs.readMainCounter() + ticks;
    while (regs.readMainCounter() <= deadline) {
        abi.sys.yield();
    }
}

pub fn sleepDeadline(reply: caps.Reply, timestamp_nanos: u128) void {
    const regs = hpet_regs.?;
    const _counter = timestamp_nanos * 1_000_000 / regs.readSpeed();
    if (_counter > std.math.maxInt(u64)) {
        @branchHint(.cold);
        log.err("FIXME: deadline val is bigger than max main counter val", .{});
        return;
    }
    const counter: u64 = @truncate(_counter);

    var least_used: u8 = 0;
    for (timers[0..timer_count], 0..) |*timer, i| {
        const active_deadline_count = timer.count();
        if (active_deadline_count <= timers[least_used].count()) {
            least_used = @truncate(i);
            if (active_deadline_count == 0) break;
        }
    }

    var new: Deadline = .{ .deadline = counter, .reply = reply };

    const timer = &timers[least_used];
    if (timer.current) |timer_current| {
        if (counter < timer_current.deadline) {
            // set a new comparator value if the new deadline is sooner than the current

            @as(*volatile u64, &regs.timer(least_used).comparator_value).* = new.deadline;
            new, timer.current = .{ timer_current, new };
        }

        timer.deadlines.add(new) catch |err| {
            log.err("lost track of timers: {}", .{err});
        };
    } else {
        @as(*volatile u64, &regs.timer(least_used).comparator_value).* = new.deadline;
        timer.current = new;
    }
}

const tmp_allocator = std.mem.Allocator{
    .ptr = @ptrFromInt(0x1000),
    .vtable = &.{
        .alloc = _alloc,
        .resize = _resize,
        .remap = _remap,
        .free = _free,
    },
};

fn _alloc(_: *anyopaque, len: usize, _: std.mem.Alignment, _: usize) ?[*]u8 {
    const frame = main.memory.allocSized(caps.Frame, abi.ChunkSize.of(len) orelse return null) catch return null;
    const res, const addr, _ = main.vm_client.call(
        .mapFrame,
        .{ main.vmem_handle, frame, abi.sys.Rights{ .writable = true }, abi.sys.MapFlags{} },
    ) catch return null;
    res catch return null;

    return @ptrFromInt(addr);
}

fn _resize(_: *anyopaque, mem: []u8, _: std.mem.Alignment, new_len: usize, _: usize) bool {
    const n = abi.ChunkSize.of(mem.len) orelse return false;
    return n.sizeBytes() >= new_len;
}

fn _remap(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize, _: usize) ?[*]u8 {
    return null;
}

fn _free(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize) void {}

//

//

const Timer = struct {
    _: void align(std.atomic.cache_line) = {},

    /// null means the timer is off, non null means the current comparator value (for faster read)
    lock: abi.lock.YieldMutex = .{},
    current: ?Deadline = null,
    deadlines: std.PriorityQueue(Deadline, void, struct {
        fn inner(_: void, a: Deadline, b: Deadline) std.math.Order {
            return std.math.order(a.deadline, b.deadline);
        }
    }.inner) = .init(tmp_allocator, {}),

    fn count(self: *@This()) u64 {
        return self.deadlines.count() + @intFromBool(self.current != null);
    }
};

const Deadline = struct {
    deadline: u64,
    reply: caps.Reply,
};

//

const Flags = packed struct {
    comparator_count: u5,
    counter_size: u1,
    reserved: u1,
    legacy_replacement: u1,
};

const HpetRegs = extern struct {
    caps_and_id: Caps,
    pad0: u64,
    config: Config,
    pad1: u64,
    interrupt_status: InterruptStatus,
    pad2: [25]u64,
    main_counter_value: u64,

    fn readMainCounter(self: *volatile @This()) u64 {
        return @as(*volatile u64, &self.main_counter_value).*;
    }

    fn readSpeed(self: *volatile @This()) u32 {
        return @as(*volatile u32, &self.caps_and_id.counter_period_femtoseconds).*;
    }

    fn timer(self: *volatile @This(), n: usize) *volatile TimerRegs {
        const timer_base: usize = @intFromPtr(self);
        return @ptrFromInt(timer_base + 0x100 + 0x20 * n);
    }
};

const TimerRegs = extern struct {
    config_and_caps: TimerNConfigAndCaps,
    comparator_value: u64,
    // fsb_interrupt_route: FsbInterruptRoute,
};

const Caps = packed struct {
    rev_id: u8,
    n_timers_minus_one: u5,
    u64_capable: u1,
    reserved: u1,
    legacy_replacement_capable: u1,
    vendor_id: u16,
    counter_period_femtoseconds: u32,
};

const Config = packed struct {
    enable_config: u1,
    legacy_replacement_config: u1,
    reserved: u62,
};

const InterruptStatus = packed struct {
    timer_n_status: u32,
    reserved: u32,
};

const TimerNConfigAndCaps = packed struct {
    reserved0: u1 = 0,
    int_type_config: u1 = 0,
    int_enable_config: u1 = 1,
    type_config: u1 = 0,
    periodic_int_cap: u1 = 0,
    u64_cap: u1 = 0,
    value_set_config: u1 = 0,
    reserved1: u1 = 0,
    u32_mode_forced_config: u1 = 0,
    int_route_config: u5 = 2,
    fsb_enable_config: u1 = 0,
    fsb_interrupt_mapping_cap: u1 = 0,
    reserved2: u16 = 0,
    int_route_cap: u32,
};
