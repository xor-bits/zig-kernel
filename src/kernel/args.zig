const std = @import("std");
const limine = @import("limine");

const log = std.log.scoped(.args);

//

pub export var kernel_file: limine.KernelFileRequest = .{};
pub export var modules: limine.ModuleRequest = .{};

//

pub fn parse() !Args {
    const kernel_file_response: *limine.KernelFileResponse = kernel_file.response orelse {
        return error.NoKernelFile;
    };

    const cmdline = std.mem.sliceTo(kernel_file_response.kernel_file.cmdline, 0);
    log.info("cmdline: {s}", .{cmdline});

    var args: Args = .{};

    var args_iter = std.mem.splitScalar(u8, cmdline, ' ');
    while (args_iter.next()) |_arg| {
        var arg = std.mem.splitScalar(u8, _arg, '=');
        const first = arg.next() orelse {
            continue;
        };
        const second = arg.rest();

        if (std.mem.eql(u8, first, "initfs")) {
            args.initfs = second;
        }
    }

    const modules_response: *limine.ModuleResponse = modules.response orelse {
        std.debug.panic("no initfs.tar.gz", .{});
    };

    for (modules_response.modules()) |module| {
        if (std.mem.eql(u8, args.initfs, std.mem.sliceTo(module.path, 0))) {
            args.initfs = module.data();
        }
    }

    if (args.initfs.len == 0) {
        return error.MissingInitfs;
    }

    return args;
}

//

pub const Args = struct {
    initfs: []const u8 = "",
};
