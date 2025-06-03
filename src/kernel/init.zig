const std = @import("std");
const abi = @import("abi");
const limine = @import("limine");

const acpi = @import("acpi.zig");
const addr = @import("addr.zig");
const arch = @import("arch.zig");
const args = @import("args.zig");
const caps = @import("caps.zig");
const fb = @import("fb.zig");
const hpet = @import("hpet.zig");
const pmem = @import("pmem.zig");
const proc = @import("proc.zig");
const util = @import("util.zig");

const log = std.log.scoped(.init);
const Error = abi.sys.Error;
const volat = util.volat;

//

/// load and exec the root process
pub fn exec(a: args.Args) !void {
    log.info("creating root vmem", .{});
    const init_vmem = try caps.Vmem.init();
    try init_vmem.start();
    init_vmem.switchTo();

    log.info("creating root proc", .{});
    const init_proc = try caps.Process.init(init_vmem);

    log.info("creating root thread", .{});
    const init_thread = try caps.Thread.init(init_proc);
    init_thread.priority = 0;
    init_thread.trap.user_instr_ptr = abi.ROOT_EXE;

    log.info("creating root boot_info", .{});
    const boot_info = try caps.Frame.init(@sizeOf(abi.BootInfo));

    try mapRoot(init_thread, init_vmem, boot_info, a);

    var id: u32 = undefined;

    id = try init_proc.pushCapability(.init(init_vmem));
    std.debug.assert(id == abi.caps.ROOT_SELF_VMEM.cap);

    id = try init_proc.pushCapability(.init(init_thread));
    std.debug.assert(id == abi.caps.ROOT_SELF_THREAD.cap);

    id = try init_proc.pushCapability(.init(init_proc));
    std.debug.assert(id == abi.caps.ROOT_SELF_PROC.cap);

    id = try init_proc.pushCapability(.init(boot_info));
    std.debug.assert(id == abi.caps.ROOT_BOOT_INFO.cap);

    proc.start(init_thread);
    proc.init();
}

const Result = struct {
    boot_info: caps.Ref(caps.Frame),
    framebuffer: ?caps.Ref(caps.Frame),
};

fn mapRoot(thread: *caps.Thread, vmem: *caps.Vmem, boot_info: *caps.Frame, a: args.Args) !void {
    _ = thread;

    const data_len = a.root_data.len + a.root_path.len + a.initfs_data.len + a.initfs_path.len;

    log.info("writing root boot_info", .{});
    try boot_info.write(0, @as([*]const u8, @ptrCast(&abi.BootInfo{
        .root_data = @ptrFromInt(abi.ROOT_EXE),
        .root_data_len = a.root_data.len,
        .root_path = @ptrFromInt(abi.ROOT_EXE + a.root_data.len),
        .root_path_len = a.root_path.len,
        .initfs_data = @ptrFromInt(abi.ROOT_EXE + a.root_data.len + a.root_path.len),
        .initfs_data_len = a.initfs_data.len,
        .initfs_path = @ptrFromInt(abi.ROOT_EXE + a.root_data.len + a.root_path.len + a.initfs_data.len),
        .initfs_path_len = a.initfs_path.len,
    }))[0..@sizeOf(abi.BootInfo)]);

    log.info("creating root frame", .{});
    const root_frame = try caps.Frame.init(data_len);

    var i: usize = 0;
    log.info("copying root data", .{});
    try root_frame.write(i, a.root_data);
    i += a.root_data.len;
    log.info("copying root path", .{});
    try root_frame.write(i, a.root_path);
    i += a.root_path.len;
    log.info("copying initfs data", .{});
    try root_frame.write(i, a.initfs_data);
    i += a.initfs_data.len;
    log.info("copying initfs path", .{});
    try root_frame.write(i, a.initfs_path);

    log.info("mapping root", .{});
    _ = try vmem.map(
        root_frame,
        0,
        addr.Virt.fromInt(abi.ROOT_EXE),
        @intCast(root_frame.pages.len),
        .{
            .readable = true,
            .writable = true,
            .executable = true,
            .user_accessible = true,
        },
        .{ .fixed = true },
    );

    arch.flushTlb();

    log.info("root mapped and copied", .{});
}
