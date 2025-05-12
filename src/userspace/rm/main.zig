const std = @import("std");
const abi = @import("abi");

const caps = abi.caps;

//

const log = std.log.scoped(.rm);
pub const std_options = abi.std_options;
pub const panic = abi.panic;
pub const name = "rm";
const Error = abi.sys.Error;

//

pub fn main() !void {
    log.info("hello from rm", .{});

    const root = abi.RootProtocol.Client().init(abi.rt.root_ipc);
    const vm_client = abi.VmProtocol.Client().init(abi.rt.vm_ipc);
    const vmem_handle = abi.rt.vmem_handle;

    log.debug("requesting memory", .{});
    var res: Error!void, const memory = try root.call(.memory, {});
    try res;

    log.debug("requesting ioport allocator", .{});
    res, const ioports = try root.call(.ioports, {});
    try res;

    log.debug("requesting irq allocator", .{});
    res, const irqs = try root.call(.irqs, {});
    try res;

    var devices = std.EnumArray(abi.DeviceKind, abi.Device).initFill(.{});
    var mmio_frame: caps.DeviceFrame = .{};
    var info_frame: caps.Frame = .{};

    log.debug("requesting HPET", .{});
    res, mmio_frame, info_frame = try root.call(.device, .{abi.DeviceKind.hpet});
    try res;
    devices.set(.hpet, .{ .mmio_frame = mmio_frame, .info_frame = info_frame });

    log.debug("requesting Framebuffer", .{});
    res, mmio_frame, info_frame = try root.call(.device, .{abi.DeviceKind.framebuffer});
    try res;
    devices.set(.framebuffer, .{ .mmio_frame = mmio_frame, .info_frame = info_frame });

    log.debug("requesting MCFG", .{});
    res, mmio_frame, info_frame = try root.call(.device, .{abi.DeviceKind.mcfg});
    try res;
    devices.set(.mcfg, .{ .mmio_frame = mmio_frame, .info_frame = info_frame });

    // endpoint for rm server <-> unix app communication
    log.debug("allocating rm endpoint", .{});
    const rm_recv = try memory.alloc(caps.Receiver);
    const rm_send = try rm_recv.subscribe();

    log.debug("mapping PCI cfg space", .{});
    res, const pci_cfg_addr: usize, _ = try vm_client.call(.mapDeviceFrame, .{
        vmem_handle,
        mmio_frame,
        abi.sys.Rights{ .writable = true },
        abi.sys.MapFlags{ .cache = .uncacheable },
    });
    try res;

    log.debug("mapping MCFG info", .{});
    res, const mcfg_addr: usize, _ = try vm_client.call(.mapFrame, .{
        vmem_handle,
        info_frame,
        abi.sys.Rights{},
        abi.sys.MapFlags{},
    });
    try res;

    const mcfg_info: *const abi.McfgInfoFrame = @ptrFromInt(mcfg_addr);
    log.info("MCFG={}", .{mcfg_info});

    for (0..256) |bus| {
        for (0..32) |device| {
            const dev = PcieDevice.get(pci_cfg_addr, @truncate(bus), @truncate(device), 0);
            if (dev.vendor_id.read() == 0xFFFF) continue;

            log.info("", .{});
            log.info("vendor={s}", .{dev.vendor_name()});
            log.info("device={s}", .{dev.device_name()});
            log.info("class={s}", .{dev.class_name()});
            log.info("subclass={s}", .{dev.subclass_name()});
        }
    }

    var system = System{
        .recv = rm_recv,
        .memory = memory,
        .ioports = ioports,
        .irqs = irqs,
        .root_endpoint = rm_send.cap,

        .vm_client = vm_client,
        .vmem_handle = vmem_handle,

        .devices = devices,
    };

    const server = abi.RmProtocol.Server(.{
        .Context = *System,
        .scope = if (abi.conf.LOG_SERVERS) .rm else null,
    }, .{
        .requestPs2 = requestPs2Handler,
        .requestHpet = requestHpetHandler,
        .requestFramebuffer = requestFramebufferHandler,
        .requestPci = requestPciHandler,
        .requestInterruptHandler = requestInterruptHandlerHandler,
        .requestNotify = requestNotifyHandler,
        .newSender = newSenderHandler,
    }).init(&system, rm_recv);

    // inform the root that rm is ready
    log.debug("rm ready", .{});
    res, _ = try root.call(.serverReady, .{ abi.ServerKind.rm, rm_send });
    try res;

    try server.run();
}

const System = struct {
    recv: caps.Receiver,
    memory: caps.Memory,
    ioports: caps.X86IoPortAllocator,
    irqs: caps.X86IrqAllocator,
    root_endpoint: u32,

    vm_client: abi.VmProtocol.Client(),
    vmem_handle: usize,

    ps2: bool = true,
    devices: std.EnumArray(abi.DeviceKind, abi.Device) = .initFill(.{}),

    active_irqs: [256]?caps.X86Irq = .{null} ** 256,
};

fn requestPs2Handler(ctx: *System, _: u32, _: void) struct { Error!void, caps.X86IoPort, caps.X86IoPort } {
    if (!ctx.ps2) return .{ Error.PermissionDenied, .{}, .{} };

    const data = ctx.ioports.alloc(0x60) catch |err| return .{ err, .{}, .{} };
    const cmds = ctx.ioports.alloc(0x64) catch |err| return .{ err, .{}, .{} };

    ctx.ps2 = false;

    return .{ {}, data, cmds };
}

fn requestHpetHandler(ctx: *System, _: u32, _: void) struct { Error!void, caps.DeviceFrame, caps.X86IoPort } {
    const hpet = ctx.devices.get(.hpet);
    if (hpet.mmio_frame.cap == 0) return .{ Error.PermissionDenied, .{}, .{} };
    const pit = ctx.ioports.alloc(0x43) catch |err| return .{ err, .{}, .{} };

    ctx.devices.set(.hpet, .{});
    return .{ {}, hpet.mmio_frame, pit };
}

fn requestFramebufferHandler(ctx: *System, _: u32, _: void) struct { Error!void, caps.DeviceFrame, caps.Frame } {
    const framebuffer = ctx.devices.get(.framebuffer);
    if (framebuffer.mmio_frame.cap == 0) return .{ Error.PermissionDenied, .{}, .{} };

    ctx.devices.set(.framebuffer, .{});
    return .{ {}, framebuffer.mmio_frame, framebuffer.info_frame };
}

fn requestPciHandler(ctx: *System, _: u32, _: void) struct { Error!void, caps.DeviceFrame, caps.Frame } {
    const mcfg = ctx.devices.get(.mcfg);
    if (mcfg.mmio_frame.cap == 0) return .{ Error.PermissionDenied, .{}, .{} };

    ctx.devices.set(.mcfg, .{});
    return .{ {}, mcfg.mmio_frame, mcfg.info_frame };
}

fn requestInterruptHandlerHandler(ctx: *System, _: u32, req: struct { u8, caps.Notify }) struct { Error!void, caps.Notify } {
    const irq = req.@"0";
    const notify = req.@"1";
    // TODO: share the notify cap if one is already there
    const irq_cap = ctx.irqs.alloc(irq) catch |err| return .{ err, notify };
    irq_cap.subscribe(notify) catch |err| return .{ err, notify };

    return .{ {}, notify };
}

fn requestNotifyHandler(ctx: *System, _: u32, _: void) struct { Error!void, caps.Notify } {
    const notify = ctx.memory.alloc(caps.Notify) catch |err| return .{ err, .{} };
    return .{ {}, notify };
}

fn newSenderHandler(ctx: *System, sender: u32, _: void) struct { Error!void, caps.Sender } {
    if (ctx.root_endpoint != sender)
        return .{ Error.PermissionDenied, .{} };

    const rm_sender = ctx.recv.subscribe() catch |err| {
        log.err("failed to subscribe: {}", .{err});
        return .{ err, .{} };
    };

    return .{ {}, rm_sender };
}

pub const Acc = enum { r, w, rw, none };

pub fn Reg(comptime T: type, comptime acc: Acc) type {
    return extern struct {
        _val: T,

        pub fn read(self: *@This()) T {
            if (acc == .w) @compileError("cannot read from a write-only register");
            if (acc == .none) @compileError("cannot read from a reserved register");

            return @as(*volatile T, &self._val).*;
        }

        pub fn write(self: *@This(), val: T) void {
            if (acc == .r) @compileError("cannot write into a read-only register");
            if (acc == .none) @compileError("cannot write into a reserved register");

            @as(*volatile T, &self._val).* = val;
        }
    };
}

pub const PcieDevice = extern struct {
    vendor_id: Reg(u16, .r),
    device_id: Reg(u16, .r),
    command: Reg(u16, .rw),
    status: Reg(u16, .r),
    rev_id: Reg(u8, .r),
    prog_if: Reg(u8, .r),
    subclass_id: Reg(u8, .r),
    class_id: Reg(u8, .r),

    pub fn get(base_addr: usize, bus: u8, device: u8, function: u8) *@This() {
        const ptr: usize = base_addr + ((@as(usize, bus) << 20) | (@as(usize, device) << 15) | (@as(usize, function) << 12));
        return @ptrFromInt(ptr);
    }

    // https://www.pcilookup.com/
    pub fn vendor_name(self: *@This()) []const u8 {
        const vendor_id = self.vendor_id.read();
        return switch (vendor_id) {
            0x8086 => "Intel Corporation",
            0x1AF4, 0x1B36 => "Red Hat, Inc.",
            0x1234 => "QEMU",
            else => {
                log.err("TODO: PCI vendor_id={x:0>4}", .{vendor_id});
                return "unknown";
            },
        };
    }

    pub fn device_name(self: *@This()) []const u8 {
        const vendor_id = @as(u32, self.vendor_id.read());
        const device_id = @as(u32, self.device_id.read());
        return switch (vendor_id << 16 | device_id) {
            0x8086_29C0 => "82G33/G31/P35/P31 Express DRAM Controller",
            0x8086_10D3 => "82574L Gigabit Network Connection",
            0x8086_2934 => "82801I (ICH9 Family) USB UHCI Controller #1",
            0x8086_2918 => "82801IB (ICH9) LPC Interface Controller",

            0x1AF4_1059 => "Virtio Sound",

            0x1234_1111 => "stdvga",
            else => {
                log.err("TODO: PCI vendor_id={x:0>4} device_id={x:0>4}", .{ vendor_id, device_id });
                return "unknown";
            },
        };
    }

    pub fn class_name(self: *@This()) []const u8 {
        const class_id = self.class_id.read();
        return switch (class_id) {
            0x0 => "Unclassified",
            0x1 => "Mass Storage Controller",
            0x2 => "Network Controller",
            0x3 => "Display Controller",
            0x4 => "Multimedia Controller",
            0x5 => "Memory Controller",
            0x6 => "Bridge",
            0x7 => "Simple Communication Controller",
            0x8 => "Base System Peripheral",
            0x9 => "Input Device Controller",
            0xA => "Docking Station",
            0xB => "Processor",
            0xC => "Serial Bus Controller",
            0xD => "Wireless Controller",
            0xE => "Intelligent Controller",
            0xF => "Satellite Communication Controller",
            0x10 => "Encryption Controller",
            0x11 => "Signal Processing Controller",
            0x12 => "Processing Accelerator",
            0x13 => "Non-Essential Instrumentation",
            0x14...0x3F => "(Reserved)",
            0x40 => "Co-Processor",
            0x41...0xFE => "(Reserved)",
            0xFF => "Unassigned Class (Vendor specific)",
        };
    }

    pub fn subclass_name(self: *@This()) []const u8 {
        const class_id = @as(u16, self.class_id.read());
        const subclass_id = @as(u16, self.subclass_id.read());
        return switch (class_id << 8 | subclass_id) {
            0x00_00 => "VGA incompatible controller unclassified device",
            0x00_01 => "VGA incompatible controller unclassified device",

            0x01_00 => "SCSI bus controller",
            0x01_01 => "IDE controller",
            0x01_02 => "Floppy disk controller",
            0x01_03 => "IPI bus controller",
            0x01_04 => "RAID controller",
            0x01_05 => "ATA controller",
            0x01_06 => "SATA controller",
            0x01_07 => "Serial attached SCSI controller",
            0x01_08 => "Non-Volatile memory controller",
            0x01_80 => "Other storage controller",

            0x02_00 => "Ethernet controller",
            0x02_01 => "Token ring controller",
            0x02_02 => "FDDI controller",
            0x02_03 => "ATM controller",
            0x02_04 => "ISDN controller",
            0x02_05 => "WorldFip controller",
            0x02_06 => "PICMG 2.14 multi-computing controller",
            0x02_07 => "Infiniband controller",
            0x02_08 => "Fabric controller",
            0x02_80 => "Other network controller",

            0x03_00 => "VGA compatible controller",
            0x03_01 => "XGA controller",
            0x03_02 => "3D Controller",
            0x03_80 => "Other display controller",

            0x04_00 => "Multimedia video controller",
            0x04_01 => "Multimedia audio controller",
            0x04_02 => "Computer telephony device",
            0x04_03 => "Audio device",
            0x04_80 => "Other multimedia controller",

            0x05_00 => "RAM controller",
            0x05_01 => "Flash controller",
            0x05_80 => "Other memory controller",

            0x06_00 => "Host bridge",
            0x06_01 => "ISA bridge",
            0x06_02 => "EISA bridge",
            0x06_03 => "MCA bridge",
            0x06_04 => "PCI-to-PCI bridge",
            0x06_05 => "PCMCIA bridge",
            0x06_06 => "NuBus bridge",
            0x06_07 => "CardBus bridge",
            0x06_08 => "RACEway bridge",
            0x06_09 => "PCI-to-PCI bridge",
            0x06_0A => "InfiniBand-to-PCI host bridge",
            0x06_80 => "Other bridge",

            0x0C_00 => "FireWire (IEEE 1394) controller",
            0x0C_01 => "ACCESS bus controller",
            0x0C_02 => "SSA controller",
            0x0C_03 => "USB controller",
            0x0C_04 => "Fibre controller",
            0x0C_05 => "SMBus controller",
            0x0C_06 => "InfiniBand controller",
            0x0C_07 => "IPMI controller",
            0x0C_08 => "SERCOS interface (IEC 61491)",
            0x0C_09 => "CANbus controller",
            0x0C_80 => "Other serial bus controller",

            else => {
                return switch (class_id) {
                    0x00 => "Unknown unclassified device",
                    0x01 => "Unknown storage controller",
                    0x02 => "Unknown network controller",
                    0x03 => "Unknown display controller",
                    0x04 => "Unknown multimedia controller",
                    0x05 => "Unknown memory controller",
                    0x06 => "Unknown bridge",
                    0x0C => "Unknown serial bus controller",
                    else => {
                        log.err("TODO: PCI class={x:0>2} subclass={x:0>2}", .{ class_id, subclass_id });
                        return "unknown";
                    },
                };
            },
        };
    }
};

comptime {
    abi.rt.installRuntime();
}
