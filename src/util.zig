const std = @import("std");

const log = std.log.scoped(.util);

//

/// print the offset of each field in hex
pub fn debugFieldOffsets(comptime T: type) void {
    const s = @typeInfo(T).Struct;

    const v: T = undefined;

    log.info("struct {any} field offsets:", .{T});
    inline for (s.fields) |field| {
        const offs = @intFromPtr(&@field(&v, field.name)) - @intFromPtr(&v);
        log.info(" - 0x{x}: {s}", .{ offs, field.name });
    }
}

// less effort than spamming align(1) on every field,
// since zig packed structs are not like in every other language
pub fn pack(comptime T: type) type {
    var s = comptime @typeInfo(T).Struct;
    const n_fields = comptime s.fields.len;

    var fields: [n_fields]std.builtin.Type.StructField = undefined;
    inline for (0..n_fields) |i| {
        fields[i] = s.fields[i];
        fields[i].alignment = 1;
    }
    s.fields = fields[0..];

    return @Type(std.builtin.Type{ .Struct = s });
}
