const std = @import("std");

//

// pub fn serialize(comptime T: type, msg: T) void {}

// fn serializeRecurse(comptime T: type, msg: T, reg_idx: u7) void {}

// pub fn deserialize(comptime T: type) T {}

// pub const MessageInfo = struct {
//     /// number of capabilities that need to use the extra regs
//     cap_count: u7 = 0,
//     /// number of bytes in registers + extra registers for this message,
//     /// the serialized data is packed
//     data_size: u32 = 0,
//     /// has a variable sized slice (like: []const u8)
//     /// it is converted into either inlined data or
//     /// passed with a `Frame` cap (shared memory)
//     has_slice: bool = false,
// };

// pub fn messageInfo(comptime T: type) MessageInfo {
//     var info: MessageInfo = .{};
//     messageInfoRecurse(T, &info);
//     return info;
// }

// fn messageInfoRecurse(comptime T: type, info: *MessageInfo) void {
//     @sizeOf(T);
// }

// pub fn call() void {}
