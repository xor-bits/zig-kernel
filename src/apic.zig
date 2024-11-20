const std = @import("std");
const builtin = @import("builtin");

const acpi = @import("acpi.zig");
const arch = @import("arch.zig");
const pmem = @import("pmem.zig");

const log = std.log.scoped(.apic);

//

/// parse Multiple APIC Description Table
pub fn init(madt: *const Madt) !void {
    log.info("init APIC", .{});

    if (builtin.target.cpu.arch == .x86_64) {
        disablePic();
        log.info("PIC disabled", .{});
    }

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
                _ = entry;
                // TODO: this is going to be used later for I/O APIC
            },
            2 => {
                const entry: *const IoApicInterruptSourceOverride = @ptrCast(entry_base);
                _ = entry;
                // FIXME: this is prob important
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

    log.info("found local apic addr: 0x{x}", .{lapic_addr});
}

//

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

fn disablePic() void {
    log.info("obliterating PIC because PIC sucks", .{});
    const outb = arch.x86_64.outb;
    const io_wait = arch.x86_64.io_wait;

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
    io_wait();
    outb(pic2_cmd, icw1_init | icw1_icw4);
    io_wait();
    outb(pic1_data, 32); // set master to IRQ32..IRQ39
    io_wait();
    outb(pic2_data, 40); // set master to IRQ40..IRQ47
    io_wait();
    outb(pic1_data, 4);
    io_wait();
    outb(pic2_data, 2);
    io_wait();
    outb(pic1_data, icw4_8086);
    io_wait();
    outb(pic2_data, icw4_8086);
    io_wait();

    // mask out all interrupts to limit the random useless spam from PIC
    outb(pic1_data, 0xFF);
    outb(pic2_data, 0xFF);
}
