const std = @import("std");

//

pub var gpa = std.heap.GeneralPurposeAllocator(.{}){};

//

pub fn main() !void {
    const args = try std.process.argsAlloc(gpa.allocator());
    if (args.len != 4)
        return error.@"usage: xorriso_limine_wrapper <limine-exec> <iso-root> <iso-file>";

    std.debug.print("running xorriso and limine\n", .{});

    var xorriso = std.process.Child.init(&.{
        "xorriso",
        "-as",
        "mkisofs",
        "-b",
        "boot/limine/limine-bios-cd.bin",
        "-no-emul-boot",
        "-boot-load-size",
        "4",
        "-boot-info-table",
        "--efi-boot",
        "boot/limine/limine-uefi-cd.bin",
        "-efi-boot-part",
        "--efi-boot-image",
        "--protective-msdos-label",
        args[2],
        "-o",
        args[3],
    }, gpa.allocator());

    const xorriso_term = try xorriso.spawnAndWait();
    switch (xorriso_term) {
        .Exited => |code| {
            if (code != 0)
                return error.@"xorriso failed";
        },
        else => return error.@"xorriso failed",
    }

    var limine = std.process.Child.init(&.{
        args[1],
        "bios-install",
        args[3],
    }, gpa.allocator());

    const limine_term = try limine.spawnAndWait();
    switch (limine_term) {
        .Exited => |code| {
            if (code != 0)
                return error.@"limine failed";
        },
        else => return error.@"limine failed",
    }
    // if (limine_term != std.process.Child.Term{ .Exited = 0 }) {
    //     return error.@"limine failed";
    // }
}
