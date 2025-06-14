const std = @import("std");
const abi = @import("abi");

const initfsd = @import("initfsd.zig");

const log = std.log.scoped(.root);
const Error = abi.sys.Error;
const caps = abi.caps;

//

pub const std_options = abi.std_options;
pub const panic = abi.panic;

pub export var manifest = abi.loader.Manifest.new(.{
    .name = "root",
});

//

/// elf loader temporary mapping location
pub const LOADER_TMP = 0x2000_0000_0000;
/// uncompressed initfs.tar location
pub const INITFS_TAR = 0x3000_0000_0000;
pub const FRAMEBUFFER = 0x4000_0000_0000;
pub const BACKBUFFER = 0x4100_0000_0000;
pub const FRAMEBUFFER_INFO = 0x4200_0000_0000;
pub const INITFS_TMP = 0x5000_0000_0000;
pub const INITFS_LIST = 0x5800_0000_0000;
pub const STACK_SIZE = 0x40000;
pub const STACK_TOP = 0x8000_0000_0000 - 0x2000;
pub const STACK_BOTTOM = STACK_TOP - STACK_SIZE;
pub const INITFS_STACK_TOP = STACK_BOTTOM - 0x2000;
pub const INITFS_STACK_BOTTOM = INITFS_STACK_TOP - STACK_SIZE;
pub const SPINNER_STACK_TOP = INITFS_STACK_BOTTOM - 0x2000;
pub const SPINNER_STACK_BOTTOM = SPINNER_STACK_TOP - STACK_SIZE;
/// boot info location
pub const BOOT_INFO = 0x8000_0000_0000 - 0x1000;

//

pub var self_memory_lock: abi.lock.YieldMutex = .new();
pub var self_vmem_lock: abi.lock.YieldMutex = .new();

//

pub fn main() !void {
    log.info("I am root", .{});

    try initfsd.init();

    // const boot_info = @as(*const volatile abi.BootInfo, @ptrFromInt(BOOT_INFO)).*;
    // var system: System = .{};
    // system.devices.set(.hpet, .{
    //     .mmio_frame = boot_info.hpet,
    //     .info_frame = .{},
    // });
    // system.devices.set(.framebuffer, .{
    //     .mmio_frame = boot_info.framebuffer,
    //     .info_frame = boot_info.framebuffer_info,
    // });
    // system.devices.set(.mcfg, .{
    //     .mmio_frame = boot_info.mcfg,
    //     .info_frame = boot_info.mcfg_info,
    // });

    var servers = std.ArrayList(Server).init(abi.mem.slab_allocator);

    var resources = std.ArrayHashMap(
        [99]u8,
        Resource,
        StringContext,
        true,
    ).init(abi.mem.slab_allocator);

    try resources.ensureUnusedCapacity(10);

    try initfsd.wait();

    const boot_info = @as(*const volatile abi.BootInfo, @ptrFromInt(BOOT_INFO)).*;

    const initfsd_entry = try resources.getOrPut(("hiillos.initfsd.ipc" ++ .{0} ** 80).*);
    initfsd_entry.value_ptr.* = .{
        .handle = (try initfsd.getReceiver()).cap,
        .type = .receiver,
        .given = 1,
    };
    const hpet_entry = try resources.getOrPut(("hiillos.root.hpet" ++ .{0} ** 82).*);
    hpet_entry.value_ptr.* = .{
        .handle = boot_info.hpet.cap,
        .type = .frame,
        .given = 1,
    };
    // const hpet_info_entry = try resources.getOrPut(("hiillos.root.hpet_info" ++ .{0} ** 77).*);
    // hpet_info_entry.value_ptr.* = .{
    //     .handle = boot_info.hpet_info.cap,
    //     .type = .frame,
    //     .given = 1,
    // };
    const fb_entry = try resources.getOrPut(("hiillos.root.fb" ++ .{0} ** 84).*);
    fb_entry.value_ptr.* = .{
        .handle = boot_info.framebuffer.cap,
        .type = .frame,
        .given = 1,
    };
    const fb_info_entry = try resources.getOrPut(("hiillos.root.fb_info" ++ .{0} ** 79).*);
    fb_info_entry.value_ptr.* = .{
        .handle = boot_info.framebuffer_info.cap,
        .type = .frame,
        .given = 1,
    };
    const mcfg_entry = try resources.getOrPut(("hiillos.root.mcfg" ++ .{0} ** 82).*);
    mcfg_entry.value_ptr.* = .{
        .handle = boot_info.mcfg.cap,
        .type = .frame,
        .given = 1,
    };
    const mcfg_info_entry = try resources.getOrPut(("hiillos.root.mcfg_info" ++ .{0} ** 77).*);
    mcfg_info_entry.value_ptr.* = .{
        .handle = boot_info.mcfg_info.cap,
        .type = .frame,
        .given = 1,
    };

    // find all critical system servers in the initfs
    try collectAllServers(&servers);

    // create all export resources, like IPC Receivers or Notify objects
    try createAllExports(&servers, &resources);

    // create all import resources, like IPC Senders, Notify objects, X86IoPorts or X86Irqs
    try createAllImports(&servers, &resources);

    // load all servers
    try loadAllServers(&servers);

    // grant all exports
    try grantAllExports(&servers, &resources);

    // grant all imports
    try grantAllImports(&servers, &resources);

    // launch all servers
    for (servers.items) |*server| {
        const server_manifest = (try server.bin.manifest()) orelse continue;

        log.info("exec '{s}'", .{server_manifest.getName()});
        try server.thread.start();
    }

    // TODO: wait for crashed servers
}

fn collectAllServers(servers: *std.ArrayList(Server)) !void {
    var it = initfsd.fileIterator();
    while (it.next()) |server_binary| {
        const elf_file = initfsd.readFile(server_binary.inode);
        var elf = abi.loader.Elf.init(elf_file) catch |err| {
            log.warn("skipping invalid ELF \"initfs://{s}\": {}", .{ server_binary.path, err });
            continue;
        };
        const opt_manifest = elf.manifest() catch |err| {
            log.warn("skipping invalid ELF \"initfs://{s}\": {}", .{ server_binary.path, err });
            continue;
        };

        if (opt_manifest == null) continue;
        try servers.append(.{ .bin = elf });
    }

    // virtual memory manager (system) (server)
    // maps new processes to memory and manages page faults,
    // heaps, lazy alloc, shared memory, swapping, etc.
    // try servers.append(.{ .bin = try abi.loader.Elf.init(try binBytes("/sbin/vm")) });

    // process manager (system) (server)
    // manages unix-like process stuff like permissions, cli args, etc.
    // try servers.append(.{ .bin = try abi.loader.Elf.init(try binBytes("/sbin/pm")) });

    // resource manager (system) (server)
    // manages ioports, irqs, device memory, etc. should also manage physical memory
    // try servers.append(.{ .bin = try abi.loader.Elf.init(try binBytes("/sbin/rm")) });

    // virtual filesystem (system) (server)
    // manages the main VFS tree, everything mounted into it and file descriptors
    // try servers.append(.{ .bin = try abi.loader.Elf.init(try binBytes("/sbin/vfs")) });

    // timer (system) (server)
    // manages timer drivers and accepts sleep, sleepDeadline and timestamp calls
    // try servers.append(.{ .bin = try abi.loader.Elf.init(try binBytes("/sbin/timer")) });

    // input (system) (server)
    // manages input drivers
    // try servers.append(.{ .bin = try abi.loader.Elf.init(try binBytes("/sbin/input")) });

    // debug print all servers and their imports/exports
    for (servers.items) |*server| {
        const server_manifest = (try server.bin.manifest()) orelse continue;

        log.info("name: {s}", .{server_manifest.getName()});
        log.info("imports:", .{});
        var imports = try server.bin.imports();
        while (try imports.next()) |imp|
            log.info(" - {} [note={}]: {s}", .{ imp.val.ty, imp.val.note, imp.val.getName() });
        log.info("exports:", .{});
        var exports = try server.bin.exports();
        while (try exports.next()) |exp|
            log.info(" - {} [note={}]: {s}", .{ exp.val.ty, exp.val.note, exp.val.getName() });
        log.info("", .{});
    }
}

fn createAllExports(
    servers: *std.ArrayList(Server),
    resources: *std.ArrayHashMap([99]u8, Resource, StringContext, true),
) !void {
    for (servers.items) |*server| {
        const server_manifest = (try server.bin.manifest()) orelse continue;
        var exports = try server.bin.exports();
        while (try exports.next()) |exp| {
            log.info("found export '{s}' in '{s}' called '{s}'", .{
                exp.val.getName(), server_manifest.getName(), exp.name,
            });

            const result = try resources.getOrPut(exp.val.name);
            if (result.found_existing) {
                log.warn("export resource collision: '{s}'", .{exp.val.getName()});
                continue;
            }

            // FIXME: validate the data
            switch (exp.val.ty) {
                .receiver => {
                    result.value_ptr.* = Resource{
                        .handle = (try caps.Receiver.create()).cap,
                        .type = .receiver,
                    };
                },
                .notify => {
                    result.value_ptr.* = Resource{
                        .handle = (try caps.Notify.create()).cap,
                        .type = .notify,
                    };
                },
                else => {
                    log.warn("invalid resource export: '{s}'", .{exp.name});
                    continue;
                },
            }
        }
    }
}

fn createAllImports(
    servers: *std.ArrayList(Server),
    resources: *std.ArrayHashMap([99]u8, Resource, StringContext, true),
) !void {
    for (servers.items) |*server| {
        const server_manifest = (try server.bin.manifest()) orelse continue;
        var imports = try server.bin.imports();
        while (try imports.next()) |imp| {
            if (imp.val.ty == .sender) continue;

            log.info("found import '{s}' in '{s}' called '{s}'", .{
                imp.val.getName(), server_manifest.getName(), imp.name,
            });

            const result = try resources.getOrPut(imp.val.name);
            if (result.found_existing) continue;

            // FIXME: validate the data
            switch (imp.val.ty) {
                .x86_ioport => {
                    result.value_ptr.* = Resource{
                        .handle = (try caps.X86IoPort.create(
                            caps.ROOT_X86_IOPORT_ALLOCATOR,
                            @truncate(imp.val.note),
                        )).cap,
                        .type = .x86_ioport,
                        .given = 1,
                    };
                },
                .x86_irq => {
                    result.value_ptr.* = Resource{
                        .handle = (try caps.X86Irq.create(
                            caps.ROOT_X86_IRQ_ALLOCATOR,
                            @truncate(imp.val.note),
                        )).cap,
                        .type = .x86_irq,
                        .given = 1,
                    };
                },
                .x86_irq_allocator => {
                    result.value_ptr.* = Resource{
                        .handle = try abi.sys.handleDuplicate(caps.ROOT_X86_IRQ_ALLOCATOR.cap),
                        .type = .x86_irq_allocator,
                        .given = 1,
                    };
                },
                else => {
                    log.warn("invalid resource import: '{s}'", .{imp.name});
                    continue;
                },
            }
        }
    }
}

fn loadAllServers(
    servers: *std.ArrayList(Server),
) !void {
    for (servers.items) |*server| {
        server.vmem = try caps.Vmem.create();
        server.proc = try caps.Process.create(server.vmem);
        server.thread = try caps.Thread.create(server.proc);

        const entry = try server.bin.loadInto(caps.ROOT_SELF_VMEM, server.vmem);
        try abi.loader.prepareSpawn(server.vmem, server.thread, entry);
    }
}

fn grantAllExports(
    servers: *std.ArrayList(Server),
    resources: *std.ArrayHashMap([99]u8, Resource, StringContext, true),
) !void {
    for (servers.items) |*server| {
        const server_manifest = (try server.bin.manifest()) orelse continue;
        var exports = try server.bin.exports();
        while (try exports.next()) |exp| {
            const res = resources.getPtr(exp.val.name) orelse {
                log.warn("unresolved export resource: '{s}'", .{exp.val.getName()});
                continue;
            };
            std.debug.assert(res.given == 0);
            res.given += 1;

            log.info("granting export: '{s}' to '{s}'", .{
                exp.val.getName(), server_manifest.getName(),
            });

            // TODO: lower the root server privileges on the resource
            // to allow only creating new senders

            const dupe = try abi.sys.handleDuplicate(res.handle);
            const their_handle = try server.proc.giveCap(dupe);
            try server.vmem.write(
                exp.addr + @offsetOf(abi.loader.Resource, "handle"),
                std.mem.asBytes(&their_handle)[0..],
            );
        }
    }
}

fn grantAllImports(
    servers: *std.ArrayList(Server),
    resources: *std.ArrayHashMap([99]u8, Resource, StringContext, true),
) !void {
    for (servers.items) |*server| {
        const server_manifest = (try server.bin.manifest()) orelse continue;
        var imports = try server.bin.imports();
        while (try imports.next()) |imp| {
            const res = resources.getPtr(imp.val.name) orelse {
                log.warn("unresolved import resource: '{s}'", .{imp.val.getName()});
                continue;
            };

            log.info("granting import: '{s}' to '{s}'", .{
                imp.val.getName(), server_manifest.getName(),
            });

            // FIXME: validate the data
            const new_handle: u32 = switch (imp.val.ty) {
                .sender,
                => (try caps.Sender.create(caps.Receiver{ .cap = res.handle }, 0)).cap,

                .notify,
                .x86_irq_allocator,
                => try abi.sys.handleDuplicate(res.handle),

                .x86_ioport,
                .x86_irq,
                .frame,
                => b: {
                    if (res.given != 1) {
                        log.warn("duplicate request to the same import resource", .{});
                        continue;
                    }
                    break :b try abi.sys.handleDuplicate(res.handle);
                },

                else => continue,
            };
            res.given += 1;

            const their_handle = try server.proc.giveCap(new_handle);
            try server.vmem.write(
                imp.addr + @offsetOf(abi.loader.Resource, "handle"),
                std.mem.asBytes(&their_handle)[0..],
            );
        }
    }
}

const Resource = packed struct {
    handle: u32,
    given: u24 = 0,
    type: abi.ObjectType,
};

const StringContext = struct {
    pub fn hash(_: @This(), s: [99]u8) u32 {
        return std.array_hash_map.hashString(s[0..]);
    }
    pub fn eql(_: @This(), a: [99]u8, b: [99]u8, _: usize) bool {
        return std.array_hash_map.eqlString(a[0..], b[0..]);
    }
};

const Server = struct {
    /// server vmem
    vmem: caps.Vmem = .{},
    /// server proc
    proc: caps.Process = .{},
    /// server main thread
    thread: caps.Thread = .{},
    /// server ELF binary
    bin: abi.loader.Elf,
};

//

pub extern var __stack_end: u8;
pub extern var __thread_stack_end: u8;

pub export fn _start() linksection(".text._start") callconv(.Naked) noreturn {
    asm volatile (
        \\ jmp zigMain
        :
        : [sp] "{rsp}" (&__stack_end),
    );
}

export fn zigMain() noreturn {
    log.info("hello", .{});
    // switch to a bigger stack (256KiB, because the initfs deflate takes up over 128KiB on its own)
    mapStack() catch |err| {
        std.debug.panic("not enough memory for a stack: {}", .{err});
    };

    asm volatile (
        \\ jmp zigMainRealstack
        :
        : [sp] "{rsp}" (STACK_TOP - 0x100),
    );
    unreachable;
}

fn mapStack() !void {
    log.info("mapping stack", .{});

    const frame = try caps.Frame.create(1024 * 256);
    _ = try caps.ROOT_SELF_VMEM.map(
        frame,
        0,
        STACK_BOTTOM,
        1024 * 256,
        .{ .writable = true },
        .{ .fixed = true },
    );

    log.info("stack mapping complete 0x{x}..0x{x}", .{ STACK_BOTTOM, STACK_TOP });
}

export fn zigMainRealstack() noreturn {
    main() catch |err| {
        std.debug.panic("{}", .{err});
    };
    abi.sys.selfStop();
}
