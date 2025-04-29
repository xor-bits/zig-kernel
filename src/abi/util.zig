const std = @import("std");

const abi = @import("lib.zig");
const caps = @import("caps.zig");
const sys = @import("sys.zig");

//

pub const FrameVector = std.EnumArray(abi.ChunkSize, caps.Frame);

//

pub fn allocVector(mem: caps.Memory, size: usize) !FrameVector {
    if (size > abi.ChunkSize.@"1GiB".sizeBytes()) return error.SegmentTooBig;
    var frames: FrameVector = .initFill(.{ .cap = 0 });

    inline for (std.meta.fields(abi.ChunkSize)) |f| {
        const variant: abi.ChunkSize = @enumFromInt(f.value);
        const specific_size: usize = variant.sizeBytes();

        if (size & specific_size != 0) {
            const frame = try mem.allocSized(caps.Frame, variant);
            frames.set(variant, frame);
        }
    }

    return frames;
}

pub fn mapVector(v: *const FrameVector, vmem: caps.Vmem, _vaddr: usize, rights: sys.Rights, flags: sys.MapFlags) !void {
    var vaddr = _vaddr;

    var iter = @constCast(v).iterator();
    while (iter.next()) |e| {
        if (e.value.*.cap == 0) continue;

        try vmem.map(
            e.value.*,
            vaddr,
            rights,
            flags,
        );

        vaddr += e.key.sizeBytes();
    }
}

pub fn unmapVector(v: *const FrameVector, vmem: caps.Vmem, _vaddr: usize) !void {
    var vaddr = _vaddr;

    var iter = @constCast(v).iterator();
    while (iter.next()) |e| {
        if (e.value.*.cap == 0) continue;

        try vmem.unmap(
            e.value.*,
            vaddr,
        );

        vaddr += e.key.sizeBytes();
    }
}

pub fn copyForwardsVolatile(comptime T: type, dest: []volatile T, source: []const T) void {
    for (dest[0..source.len], source) |*d, s| d.* = s;
}
