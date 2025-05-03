const std = @import("std");
const builtin = @import("builtin");

const acpi = @import("acpi.zig");
const addr = @import("addr.zig");
const arch = @import("arch.zig");
const caps = @import("caps.zig");
const hpet = @import("hpet.zig");
const lazy = @import("lazy.zig");
const pmem = @import("pmem.zig");
const spin = @import("spin.zig");

const log = std.log.scoped(.apic);

//

pub const IRQ_TIMER: u8 = 43;
pub const IRQ_IPI: u8 = 44;
pub const IRQ_SPURIOUS: u8 = 255;

pub const IRQ_AVAIL_LOW: u8 = 45;
pub const IRQ_AVAIL_HIGH: u8 = 254;
pub const IRQ_AVAIL_COUNT = IRQ_AVAIL_HIGH - IRQ_AVAIL_LOW + 1;

pub const IA32_APIC_XAPIC_ENABLE: u64 = 1 << 11;
pub const IA32_APIC_X2APIC_ENABLE: u64 = 1 << 10;
pub const APIC_SW_ENABLE: u32 = 1 << 8;
pub const APIC_DISABLE: u32 = 1 << 16;
pub const APIC_NMI: u32 = 4 << 8;
pub const APIC_TIMER_MODE_ONESHOT: u32 = 0;
pub const APIC_TIMER_MODE_PERIODIC: u32 = 0b01 << 17;
pub const APIC_TIMER_MODE_TSC_DEADLINE: u32 = 0b10 << 17;

// const APIC_TIMER_DIV: u32 = 0b1011; // div by 1
// const APIC_TIMER_DIV: u32 = 0b0000; // div by 2
// const APIC_TIMER_DIV: u32 = 0b0001; // div by 4
const APIC_TIMER_DIV: u32 = 0b0010; // div by 8
// const APIC_TIMER_DIV: u32 = 0b0011; // div by 16
// const APIC_TIMER_DIV: u32 = 0b1000; // div by 32
// const APIC_TIMER_DIV: u32 = 0b1001; // div by 64
// const APIC_TIMER_DIV: u32 = 0b1010; // div by 128

//

var apic_base = lazy.Lazy(*volatile LocalApicRegs).new();
/// all I/O APICs
var ioapics = std.ArrayList(IoApicInfo).init(pmem.page_allocator);
var ioapic_lock: spin.Mutex = .{};
/// all Local APIC IDs that I/O APICs can use as interrupt destinations
var ioapic_lapics = std.ArrayList(IoApicLapic).init(pmem.page_allocator);
var ioapic_lapic_lock: spin.Mutex = .{};

pub const Handler = std.atomic.Value(?*caps.Notify);

const IoApicLapic = struct {
    lapic_id: u4,
    handlers: *[IRQ_AVAIL_COUNT]Handler,
};

//

/// parse Multiple APIC Description Table
pub fn init(madt: *const Madt) !void {
    log.info("init APIC-{}", .{arch.cpuId()});

    if (builtin.target.cpu.arch == .x86_64) {
        disablePic();
    }

    // cpu0 also sets up all I/O APICs
    if (arch.cpuId() == 0)
        ioapic_lock.lock();
    defer if (arch.cpuId() == 0)
        ioapic_lock.unlock();

    var lapic_addr: u64 = madt.lapic_addr;

    var ext_len: usize = 0;
    while (ext_len < madt.header.length - @sizeOf(Madt)) {
        const entry_base: *const Entry = @ptrFromInt(@intFromPtr(madt) + ext_len + @sizeOf(Madt));
        ext_len += entry_base.record_len;

        switch (entry_base.entry_type) {
            0 => {
                const entry: *const ProcessorLocalApic = @ptrCast(entry_base);
                _ = entry;
                // INFO: this is not important
            },
            1 => {
                const entry: *const IoApic = @ptrCast(entry_base);
                if (arch.cpuId() != 0) continue;

                log.info("found I/O APIC addr: 0x{x}", .{entry.io_apic_addr});
                try ioapics.append(.{
                    .addr = addr.Phys.fromInt(entry.io_apic_addr).toHhdm().toPtr(*volatile IoApicRegs),
                    .io_apic_id = entry.io_apic_id,
                    .global_system_interrupt_base = entry.global_system_interrupt_base,
                });
            },
            2 => {
                const entry: *const IoApicInterruptSourceOverride = @ptrCast(entry_base);
                if (arch.cpuId() != 0) continue;

                // FIXME: this is prob important
                log.err("I/O APIC interrupt source override detected but not yet handled: {}", .{entry});
            },
            3 => {
                const entry: *const IoApicNmiSource = @ptrCast(entry_base);
                _ = entry;
                // NOTE: this might be important
            },
            4 => {
                const entry: *const LapicNmis = @ptrCast(entry_base);
                _ = entry;
                // NOTE: this could be important

            },
            5 => {
                const entry: *const LapicAddrOverride = @ptrCast(entry_base);
                lapic_addr = entry.lapic_addr;
            },
            9 => {
                const entry: *const ProcessorLx2apic = @ptrCast(entry_base);
                _ = entry;
                // NOTE: this may be important
            },
            else => {
                // ignore others
            },
        }
    }

    if (arch.cpuId() == 0)
        log.info("found Local APIC addr: 0x{x}", .{lapic_addr});
    const lapic: *volatile LocalApicRegs = addr.Phys.fromInt(lapic_addr).toHhdm().toPtr(*volatile LocalApicRegs);

    const lapic_id = lapic.lapic_id.val;
    if (lapic_id <= 0xF) {
        fillHandlers(&arch.cpuLocal().cpu_config.idt);

        ioapic_lapic_lock.lock();
        defer ioapic_lapic_lock.unlock();
        try ioapic_lapics.append(.{
            .lapic_id = @truncate(lapic_id),
            .handlers = &arch.cpuLocal().interrupt_handlers,
        });
    }

    apic_base.initNow(lapic);
}

fn fillHandlers(idt: *arch.Idt) void {
    inline for (0..IRQ_AVAIL_COUNT) |i| {
        idt.entries[i + IRQ_AVAIL_LOW] = arch.Entry.generate(struct {
            pub fn handler(_: *const arch.InterruptStackFrame) void {
                log.info("extra interrupt i=0x{x}", .{i + IRQ_AVAIL_LOW});
                defer eoi();

                const kb_byte = arch.inb(0x60);
                log.info("kbbyte={}", .{kb_byte});

                const notify = arch.cpuLocal().interrupt_handlers[i].load(.acquire) orelse return;
                _ = notify.notify(0);
            }
        }).asInt();
    }
}

pub fn enable() void {
    const lapic = apic_base.get().?.*;

    // reset APIC to a well-known state
    lapic.destination_format.val = 0xFFFF_FFFF;
    lapic.logical_destination.val &= 0x00FF_FFFF;
    lapic.lvt_timer.val = APIC_DISABLE;
    lapic.lvt_performance_monitoring_counters.val = APIC_NMI;
    lapic.lvt_lint0.val = APIC_DISABLE;
    lapic.lvt_lint1.val = APIC_DISABLE;
    lapic.task_priority.val = 0;

    // enable
    lapic.spurious_interrupt_vector.val = APIC_SW_ENABLE | @as(u32, IRQ_SPURIOUS);

    // enable APIC
    arch.x86_64.wrmsr(
        arch.x86_64.IA32_APIC_BASE,
        arch.x86_64.rdmsr(arch.x86_64.IA32_APIC_BASE) | IA32_APIC_XAPIC_ENABLE,
    );

    // enable timer interrupts
    const period = measureApicTimerSpeed(lapic) * 500;
    lapic.divide_configuration.val = APIC_TIMER_DIV;
    lapic.lvt_timer.val = IRQ_TIMER | APIC_TIMER_MODE_PERIODIC;
    lapic.initial_count.val = period;
    lapic.lvt_thermal_sensor.val = 0;
    lapic.lvt_error.val = 0;
    lapic.divide_configuration.val = APIC_TIMER_DIV; // buggy hardware fix

    if (arch.cpuId() == 0)
        log.info("APIC initialized", .{});
}

/// returns the apic period for 1ms
fn measureApicTimerSpeed(lapic: *volatile LocalApicRegs) u32 {
    lapic.divide_configuration.val = APIC_TIMER_DIV;

    hpet.hpetSpinWait(1_000, struct {
        lapic: *volatile LocalApicRegs,
        pub fn run(s: *const @This()) void {
            s.lapic.initial_count.val = 0xFFFF_FFFF;
        }
    }{ .lapic = lapic });

    lapic.lvt_timer.val = APIC_DISABLE;
    const count = 0xFFFF_FFFF - lapic.current_count.val;

    if (arch.cpuId() == 0)
        log.info("APIC timer speed: 1ms = {d} ticks", .{count});

    return count;
}

pub fn spurious(_: *const anyopaque) void {
    eoi();
}

pub fn timer(_: *const anyopaque) void {
    eoi();
}

pub fn ipi(_: *const anyopaque) void {
    eoi();
}

pub fn eoi() void {
    apic_base.get().?.*.eoi.val = 0;
}

pub fn interProcessorInterrupt(target_lapic_id: u8) void {
    const lapic_regs: *volatile LocalApicRegs = apic_base.get().?.*;

    // log.info("ICR_HIGH: {*}", .{&lapic_regs.interrupt_command[1].val});
    // log.info("ICR_LOW: {*}", .{&lapic_regs.interrupt_command[0].val});

    const icr_high = IcrHigh{
        .destination = target_lapic_id,
    };
    const icr_low = IcrLow{
        .vector = IRQ_IPI,
        .delivery_mode = .fixed,
        .destination_mode = .physical,
        .level = .assert,
        .trigger_mode = .edge,
        .destination_shorthand = .no_shorthand,
    };

    // log.info("ICR_HIGH: {}", .{icr_high});
    // log.info("ICR_LOW: {}", .{icr_low});

    lapic_regs.interrupt_command[1].val = @bitCast(icr_high);
    lapic_regs.interrupt_command[0].val = @bitCast(icr_low);
}

/// source IRQ would be the source like keyboard at 1
/// destination IRQ would be the IDT handler index
pub fn registerExternalInterrupt(source_irq: u8, notify: *caps.Notify) ?void {
    log.info("registering interrupt {}", .{source_irq});

    ioapic_lapic_lock.lock();
    defer ioapic_lapic_lock.unlock();
    ioapic_lock.lock();
    defer ioapic_lock.unlock();

    const lapic_id, const handler, const i = findUsableHandler() orelse return null;
    const ioapic, const low_index = findUsableRedirectEntry(source_irq) orelse return null;
    const high_index = low_index + 1;

    log.info("lapic_id={} i={}", .{
        source_irq, i,
    });

    var low = ioapicRead(ioapic, low_index);
    var high = ioapicRead(ioapic, high_index);

    var val = @as(IoApicRedirect, @bitCast([2]u32{ low, high }));
    val.mask = .enable;
    val.destination_mode = .physical;
    val.delivery_mode = .fixed;
    val.vector = i + IRQ_AVAIL_LOW;
    val._reserved0 = 0;
    val._reserved1 = 0;
    val.destination_apic_id = lapic_id;

    low, high = @as([2]u32, @bitCast(val));

    handler.store(notify, .seq_cst);

    ioapicWrite(ioapic, high_index, high);
    ioapicWrite(ioapic, low_index, low);

    log.info("listening", .{});

    // FIXME: read the overrides

}

/// `ioapic_lapic_lock` has to be held
fn findUsableHandler() ?struct { u4, *Handler, u8 } {
    for (ioapic_lapics.items) |lapic| {
        for (lapic.handlers[0..], 0..) |*handler, i| {
            // modifying any handler is done behind the `ioapic_lapic_lock`
            // the 'atomicity' is only for setting the handler
            // and the handler running at the same time

            if (handler.load(.monotonic) != null) continue;

            return .{ lapic.lapic_id, handler, @truncate(i) };
        }
    }

    return null;
}

fn findUsableRedirectEntry(source_irq: u32) ?struct { *volatile IoApicRegs, u32 } {
    for (ioapics.items) |ioapic| {
        const min = ioapic.global_system_interrupt_base;
        if (min > source_irq) continue;

        const max = @as(IoApicVer, @bitCast(ioapicRead(ioapic.addr, 1))).num_irqs_minus_one + 1 + min;
        if (max <= source_irq) continue;

        const low_index = 0x10 + (source_irq - min) * 2;
        const high_index = low_index + 1;

        const low = ioapicRead(ioapic.addr, low_index);
        const high = ioapicRead(ioapic.addr, high_index);

        const val = @as(IoApicRedirect, @bitCast([2]u32{ low, high }));

        // log.info("ioapic={*} entry={} val={}", .{ ioapic.addr, source_irq - min, val });

        if (val.vector == 0) {
            log.info("slot {}", .{source_irq - min});
            return .{ ioapic.addr, low_index };
        }
    }

    return null;
}

fn ioapicRead(ioapic: *volatile IoApicRegs, reg: u32) u32 {
    ioapic.register_select.val = reg;
    return ioapic.register_data.val;
}

fn ioapicWrite(ioapic: *volatile IoApicRegs, reg: u32, val: u32) void {
    ioapic.register_select.val = reg;
    ioapic.register_data.val = val;
}

//

pub const Register = extern struct {
    val: u32 align(16),
};

pub const IoApicInfo = struct {
    addr: *volatile IoApicRegs,
    io_apic_id: u8,
    global_system_interrupt_base: u32,
};

pub const IoApicRegs = extern struct {
    register_select: Register,
    register_data: Register,
};

/// I/O APIC register index 0
pub const IoApicId = packed struct {
    _reserved0: u24,
    apic_id: u4,
    _reserved1: u4,
};

/// I/O APIC register index 1
pub const IoApicVer = packed struct {
    io_apic_version: u8,
    _reserved0: u8,
    num_irqs_minus_one: u8,
    _reserved1: u8,
};

/// I/O APIC register index 2
pub const IoApicArb = packed struct {
    _reserved0: u24,
    apic_arbitration_id: u4,
    _reserved1: u4,
};

/// I/O APIC register index N and N+1
pub const IoApicRedirect = packed struct {
    vector: u8, // destination IDT index
    delivery_mode: DeliveryMode,
    destination_mode: DestinationMode,
    delivery_status: DeliveryStatus = .idle,
    pin_polarity: enum(u1) {
        active_high,
        active_low,
    } = .active_high,
    remote_irr: u1 = 0, // idk
    trigger_mode: TriggerMode = .edge,
    mask: enum(u1) {
        enable,
        disable,
    } = .enable,
    _reserved0: u39 = 0,
    destination_apic_id: u4,
    _reserved1: u4 = 0,
};

pub const DeliveryMode = enum(u3) {
    fixed,
    lowest_priority, // this one is interesting for scheduling
    smi,
    reserved0,
    nmi,
    init,
    start_up,
    reserved1,
};

pub const DestinationMode = enum(u1) {
    physical,
    logical,
};

pub const DeliveryStatus = enum(u1) {
    idle,
    send_pending,
};

pub const TriggerMode = enum(u1) {
    edge,
    level,
};

pub const IcrHigh = packed struct {
    reserved: u24 = 0,
    destination: u8,
};

pub const IcrLow = packed struct {
    vector: u8,
    delivery_mode: DeliveryMode,
    destination_mode: DestinationMode,
    delivery_status: DeliveryStatus = .idle,
    reserved0: u1 = 0,
    level: enum(u1) {
        deassert,
        assert,
    },
    trigger_mode: TriggerMode,
    reserved1: u2 = 0,
    destination_shorthand: enum(u2) {
        no_shorthand,
        self,
        all_including_self,
        all_excluding_self,
    },
    reserved2: u12 = 0,
};

pub const LocalApicRegs = extern struct {
    _reserved0: [2]Register,
    lapic_id: Register,
    lapic_version: Register,
    _reserved1: [4]Register,
    task_priority: Register,
    arbitration_priority: Register,
    processor_priority: Register,
    eoi: Register,
    remote_read: Register,
    logical_destination: Register,
    destination_format: Register,
    spurious_interrupt_vector: Register,
    in_service: [8]Register,
    trigger_mode: [8]Register,
    interrupt_request: [8]Register,
    error_status: Register,
    _reserved2: [6]Register,
    lvt_corrected_machine_check_interrupt: Register,
    interrupt_command: [2]Register,
    lvt_timer: Register,
    lvt_thermal_sensor: Register,
    lvt_performance_monitoring_counters: Register,
    lvt_lint0: Register,
    lvt_lint1: Register,
    lvt_error: Register,
    initial_count: Register,
    current_count: Register,
    _reserved3: [1]Register,
    divide_configuration: Register,
    _reserved4: [4]Register,

    pub fn format(self: *volatile @This(), comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        const this = @typeInfo(@This()).Struct;

        try writer.writeAll(@typeName(@This()));
        try std.fmt.format(writer, " {{ ", .{});

        inline for (this.fields) |field| {
            if (field.name[0] == '_') {
                continue;
            }

            switch (@typeInfo(field.type)) {
                .Struct => {
                    const s: *volatile Register = &@field(self, field.name);
                    try std.fmt.format(writer, ".{s} = 0x{x}, ", .{ field.name, s.val });
                },
                .Array => {
                    const s: []volatile Register = @field(self, field.name)[0..];

                    try std.fmt.format(writer, ".{s} = .{{ ", .{field.name});
                    for (s) |*reg| {
                        // FIXME: i have no clue if Zig drops the volatile qualifier with ptr captures
                        try std.fmt.format(writer, "0x{x}, ", .{reg.val});
                    }
                    try std.fmt.format(writer, "}}, ", .{});
                },
                else => {},
            }
        }

        try std.fmt.format(writer, "}}", .{});
    }
};

pub const Madt = extern struct {
    header: acpi.SdtHeader align(1),
    lapic_addr: u32 align(1),
    flags: u32 align(1),
};

const Entry = extern struct {
    entry_type: u8,
    record_len: u8,
};

const ProcessorLocalApic = extern struct {
    entry: Entry align(1),
    acpi_processor_id: u8,
    apic_id: u8,
    flags: u32 align(1),
};

const IoApic = extern struct {
    entry: Entry align(1),
    io_apic_id: u8,
    reserved: u8,
    io_apic_addr: u32 align(1),
    global_system_interrupt_base: u32 align(1),
};

const IoApicInterruptSourceOverride = extern struct {
    entry: Entry align(1),
    bus_source: u8,
    irq_source: u8,
    global_system_interrupt: u32 align(1),
    flags: u16 align(1),
};

const IoApicNmiSource = extern struct {
    entry: Entry align(1),
    nmi_source: u8,
    reserved: u8,
    flags: u16 align(1),
    global_system_interrupt: u32 align(1),
};

const LapicNmis = extern struct {
    entry: Entry align(1),
    acpi_processor_id: u8,
    flags: u16 align(1),
    lint: u8,
};

const LapicAddrOverride = extern struct {
    entry: Entry align(1),
    lapic_addr: u64 align(1),
};

const ProcessorLx2apic = extern struct {
    entry: Entry align(1),
    local_x2apic_id: u32 align(1),
    flags: u32 align(1),
    acpi_id: u32 align(1),
};

//

var entry_spin: spin.Mutex = .new();
var wait_spin: spin.Mutex = .newLocked();

fn disablePic() void {
    if (!entry_spin.tryLock()) {
        // some other cpu is already working on this,
        // wait for it to be complete and then return
        wait_spin.lock();
        defer wait_spin.unlock();
        return;
    }

    // leave entry_spin as locked but unlock wait_spin to signal others
    defer wait_spin.unlock();

    log.info("obliterating PIC because PIC sucks", .{});
    const outb = arch.x86_64.outb;
    const ioWait = arch.x86_64.ioWait;

    // the PIC is shit (not APIC, APIC is great)
    // AND its enabled by default usually
    // AND it gives spurious interrupts
    // AND the interrupts it gives by default most likely
    // conflict with CPU exceptions (INTEL WTF WHY)
    const pic1 = 0x20;
    const pic2 = 0xA0;
    const pic1_cmd = pic1;
    const pic1_data = pic1 + 1;
    const pic2_cmd = pic2;
    const pic2_data = pic2 + 1;

    const icw1_icw4 = 0x1;
    const icw1_init = 0x10;
    const icw4_8086 = 0x1;

    // remap pic to discarded IRQs (32..47)
    outb(pic1_cmd, icw1_init | icw1_icw4);
    ioWait();
    outb(pic2_cmd, icw1_init | icw1_icw4);
    ioWait();
    outb(pic1_data, 32); // set master to IRQ32..IRQ39
    ioWait();
    outb(pic2_data, 40); // set master to IRQ40..IRQ47
    ioWait();
    outb(pic1_data, 4);
    ioWait();
    outb(pic2_data, 2);
    ioWait();
    outb(pic1_data, icw4_8086);
    ioWait();
    outb(pic2_data, icw4_8086);
    ioWait();

    // mask out all interrupts to limit the random useless spam from PIC
    outb(pic1_data, 0xFF);
    outb(pic2_data, 0xFF);

    log.info("PIC disabled", .{});
}
