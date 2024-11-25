const std = @import("std");

//

pub fn CachePadded(comptime T: type) type {
    return extern struct {
        val: T,
        _pad: [std.atomic.cache_line - @sizeOf(T) % std.atomic.cache_line]u8 = undefined,
    };
}

pub const Slot = struct {
    first: usize,
    len: usize,

    const Self = @This();

    pub fn take(self: Self, n: usize) ?Self {
        if (n > self.len) return null;
        return Self{ .first = self.first, .len = n };
    }

    pub fn min(self: Self, n: usize) Self {
        return Self{ .first = self.first, .len = @min(n, self.len) };
    }

    pub fn slices(self: Self, comptime T: type, storage: []T) [2][]T {
        std.debug.assert(self.len <= storage.len);

        if (self.first + self.len <= storage.len) {
            return .{ storage[self.first .. self.first + self.len], &.{} };
        } else {
            const first = storage[self.first..];
            return .{ first, storage[0 .. self.len - first.len] };
        }
    }
};

pub const Marker = struct {
    read_end: CachePadded(std.atomic.Value(usize)) = .{ .val = .{ .raw = 0 } },
    write_end: CachePadded(std.atomic.Value(usize)) = .{ .val = .{ .raw = 0 } },
    capacity: usize,

    const Self = @This();

    pub fn uninitSlot(self: *Self) Slot {
        const write = self.write_end.val.load(.acquire);
        const read = self.read_end.val.load(.acquire);

        // read end - 1 is the limit, the number of available spaces can only grow
        // read=write would be ambiguous so read=write always means that the whole buf is empty
        // => write of self.len to an empty buffer is not possible (atm)
        const avail = if (write < read)
            read - write
        else
            self.capacity - write + read;
        if (avail > self.capacity) {
            std.debug.panic("assertion failed: avail cannot be more than the capacity", .{});
        }

        return Slot{
            .first = write,
            .len = avail - 1,
        };
    }

    pub fn initSlot(self: *Self) Slot {
        const read = self.read_end.val.load(.acquire);
        const write = self.write_end.val.load(.acquire);

        // write end is the limit, the number of available items can only grow
        const avail = if (write >= read)
            write - read
        else
            self.capacity - read + write;
        if (avail > self.capacity) {
            std.debug.panic("assertion failed: avail cannot be more than the capacity", .{});
        }

        return Slot{
            .first = read,
            .len = avail,
        };
    }

    pub fn acquire(self: *Self, n: usize) ?Slot {
        if (n > self.capacity) return null;
        return self.uninitSlot().take(n);
    }

    pub fn acquireUpTo(self: *Self, n: usize) ?Slot {
        return self.uninitSlot().min(n);
    }

    pub fn produce(self: *Self, acquired_slot: Slot) void {
        const new_write_end = (acquired_slot.first + acquired_slot.len) % self.capacity;
        const old = self.write_end.val.swap(new_write_end, .release);
        if (old != acquired_slot.first) {
            std.debug.panic("assertion failed: acquire and produce mismatch", .{});
        }
    }

    pub fn consume(self: *Self, n: usize) ?Slot {
        if (n > self.capacity) return null;
        return self.initSlot().take(n);
    }

    pub fn consumeUpTo(self: *Self, n: usize) ?Slot {
        return self.initSlot().min(n);
    }

    pub fn release(self: *Self, consumed_slot: Slot) void {
        const new_read_end = (consumed_slot.first + consumed_slot.len) % self.capacity;
        const old = self.read_end.val.swap(new_read_end, .release);
        if (old != consumed_slot.first) {
            std.debug.panic("assertion failed: consume and release mismatch", .{});
        }
    }
};

/// single reader and single writer fixed size ring buffer
///
/// multiple concurrent readers or multiple concurrent writers cause UB
///
/// reading and writing at the same time is allowed
pub fn AtomicRing(comptime T: type, comptime size: usize) type {
    return struct {
        storage: [size]T = undefined,
        marker: Marker = .{ .capacity = size },

        const Self = @This();

        pub fn init() Self {
            return Self{};
        }

        pub fn push(self: *Self, v: T) error{Full}!void {
            const slot = self.marker.acquire(1) orelse return error.Full;
            self.storage[slot.first] = v;
            self.marker.produce(slot);
        }

        pub fn pop(self: *Self) ?T {
            const slot = self.marker.consume(1) orelse return null;
            const val = self.storage[slot.first];
            self.storage[slot.first] = undefined; // debug
            self.marker.release(slot);
            return val;
        }

        pub fn write(self: *Self, v: []const T) error{Full}!void {
            const slot = self.marker.acquire(v.len) orelse return error.Full;
            const slices = slot.slices(T, self.storage[0..]);

            std.mem.copyForwards(T, slices[0], v[0..slices[0].len]);
            std.mem.copyForwards(T, slices[1], v[slices[0].len..]);

            self.marker.produce(slot);
        }

        pub fn read(self: *Self, buf: []T) ?[]T {
            const slot = self.marker.consume(buf.len) orelse return null;
            const slices = slot.slices(T, self.storage[0..]);

            std.mem.copyForwards(T, buf[0..slices[0].len], slices[0]);
            std.mem.copyForwards(T, buf[slices[0].len..], slices[1]);

            return buf;
        }
    };
}
