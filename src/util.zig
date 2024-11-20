const std = @import("std");

const log = std.log.scoped(.util);

//

pub fn debugFieldOffsets(comptime T: type) void {
    const s = @typeInfo(T).Struct;

    const v: T = undefined;

    log.info("struct {any} field offsets:", .{T});
    inline for (s.fields) |field| {
        const offs = @intFromPtr(&@field(&v, field.name)) - @intFromPtr(&v);
        log.info(" - 0x{x}: {s}", .{ offs, field.name });
    }
}
