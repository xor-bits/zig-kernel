const std = @import("std");

//

pub const Base = enum {
    binary,
    decimal,
};

pub fn NumberPrefix(comptime T: type, comptime base: Base) type {
    return struct {
        num: T,

        pub const Self = @This();

        pub fn new(num: T) Self {
            return Self{
                .num = num,
            };
        }

        // format(actual_fmt, options, writer);
        pub fn format(self: Self, comptime _: []const u8, opts: std.fmt.FormatOptions, writer: anytype) !void {
            var num = self.num;
            const prec = opts.precision orelse 1;
            switch (base) {
                .binary => {
                    const table: [10][]const u8 = .{ "", "Ki", "Mi", "Gi", "Ti", "Pi", "Ei", "Zi", "Yi", "Ri" };
                    for (table) |scale| {
                        if (num < 1024 * prec) {
                            return std.fmt.format(writer, "{d} {s}", .{ num, scale });
                        }
                        num /= 1024;
                    }
                    return std.fmt.format(writer, "{d} Qi", .{num});
                },
                .decimal => {
                    const table: [10][]const u8 = .{ "", "K", "M", "G", "T", "P", "E", "Z", "Y", "R" };
                    for (table) |scale| {
                        if (num < 1000 * prec) {
                            return std.fmt.format(writer, "{d} {s}", .{ num, scale });
                        }
                        num /= 1000;
                    }
                    return std.fmt.format(writer, "{d} Q", .{num});
                },
            }
        }
    };
}
