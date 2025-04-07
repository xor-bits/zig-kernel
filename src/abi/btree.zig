const std = @import("std");

const log = std.log.scoped(.btree);

//

pub const Error = std.mem.Allocator.Error;

pub const Config = struct {
    // node_len: usize = 100,
    node_size: usize = 0x1000,
    search: enum { linear, binary } = .binary,
};

pub fn BTreeMap(comptime K: type, comptime V: type, comptime cfg: Config) type {
    return struct {
        root: usize = 0,
        depth: usize = 0,

        pub const LeafNode = struct {
            used: usize = 0,
            keys: [MAX]K = undefined,
            vals: [MAX]V = undefined,

            pub const _MAX: usize = (cfg.node_size - @sizeOf(usize)) / (@sizeOf(K) + @sizeOf(V)) / 2 * 2;

            pub const MAX: usize = _MAX - 1;
            pub const MIN: usize = MAX / 2;
        };

        pub const BranchNode = struct {
            used: usize = 0,
            keys: [MAX]K = undefined,
            vals: [MAX]V = undefined,
            ptrs: [MAX + 1]usize = undefined,

            pub const _MAX: usize = (cfg.node_size - @sizeOf(usize) * 2) / (@sizeOf(K) + @sizeOf(V) + @sizeOf(usize)) / 2 * 2;

            pub const MAX: usize = _MAX - 1;
            pub const MIN: usize = MAX / 2;
        };

        fn insert_arr(comptime T: type, arr: []T, len: usize, i: usize, val: T) void {
            std.debug.assert(i <= len and len <= arr.len);

            arr[len] = val;
            std.mem.rotate(T, arr[0 .. len + 1][i..], 1);
            // len.* += 1;
        }

        comptime {
            std.debug.assert(@sizeOf(LeafNode) <= cfg.node_size);
            std.debug.assert(@sizeOf(BranchNode) <= cfg.node_size);

            if (LeafNode.MIN == 0 or BranchNode.MIN == 0)
                @compileError("node_size too small");
        }

        const IndexResult = union(enum) {
            /// the key is in `keys[i]` and its value is in `vals[i]`
            found: usize,
            /// the key and value are in a sub-tree at `ptrs[i]`
            not_found: usize,
        };

        fn indexOf(key: K, keys: []const K) IndexResult {
            var idx: usize = undefined;
            if (cfg.search == .binary) {
                idx = std.sort.lowerBound(
                    K,
                    keys,
                    key,
                    struct {
                        fn inner(ctx: K, cursor: K) std.math.Order {
                            return std.math.order(ctx, cursor);
                        }
                    }.inner,
                );
            } else {
                idx = 0;
                while (idx < keys.len and keys[idx] < key) : (idx += 1) {}
            }

            if (idx >= keys.len or keys[idx] != key) {
                return .{ .not_found = idx };
            } else {
                return .{ .found = idx };
            }
        }

        /// insert `val` at `key`, returning the old value
        pub fn insert(self: *@This(), alloc: std.mem.Allocator, key: K, val: V) Error!?V {
            if (self.root == 0) {
                @branchHint(.cold); // lazy init, happens only once
                const node: *LeafNode = try alloc.create(LeafNode);
                node.* = .{};

                node.keys[0] = key;
                node.vals[0] = val;
                node.used = 1;

                self.root = @intFromPtr(node);
                return null;
            }

            if (self.depth == 0) {
                const root: *LeafNode = @as(?*LeafNode, @ptrFromInt(self.root)) orelse return null;
                if (root.used == LeafNode.MAX) try self.split_root(alloc);
            } else if (self.depth == 1) {
                const root: *BranchNode = @as(?*BranchNode, @ptrFromInt(self.root)) orelse return null;
                if (root.used == BranchNode.MAX) try self.split_root(alloc);
            }

            return insert_recurse(alloc, key, val, self.root, self.depth);
        }

        fn insert_recurse(
            alloc: std.mem.Allocator,
            key: K,
            val: V,
            root: usize,
            depth: usize,
        ) Error!?V {
            if (depth == 0) {
                const node: *LeafNode = @as(?*LeafNode, @ptrFromInt(root)) orelse return null;
                std.debug.assert(node.used != LeafNode.MAX);

                switch (indexOf(key, node.keys[0..node.used])) {
                    .found => |i| {
                        const old = node.vals[i];
                        node.vals[i] = val;
                        return old;
                    },
                    .not_found => |i| {
                        insert_arr(K, node.keys[0..], node.used, i, key);
                        insert_arr(V, node.vals[0..], node.used, i, val);
                        node.used += 1;
                        return null;
                    },
                }
            } else {
                const node: *BranchNode = @as(?*BranchNode, @ptrFromInt(root)) orelse return null;
                std.debug.assert(node.used != BranchNode.MAX);

                switch (indexOf(key, node.keys[0..node.used])) {
                    .found => |i| {
                        const old = node.vals[i];
                        node.vals[i] = val;
                        return old;
                    },
                    .not_found => |_i| {
                        var i = _i;

                        if (isFull(node.ptrs[i], depth - 1)) {
                            try splitNthChild(alloc, root, depth, i);
                            if (key > node.keys[i]) i += 1;
                        }

                        return insert_recurse(alloc, key, val, node.ptrs[i], depth - 1);
                    },
                }
            }
        }

        pub fn debug(self: *@This()) void {
            if (self.root == 0) return;
            debug_recurse(self.root, self.depth);
        }

        fn debug_recurse(root: usize, depth: usize) void {
            if (depth == 0) {
                const node: *LeafNode = @as(?*LeafNode, @ptrFromInt(root)) orelse return;

                log.info("---------\\/\\/ leaf depth={}", .{depth});
                for (node.keys[0..node.used]) |key| {
                    log.info("{}", .{key});
                }
                log.info("---------", .{});
            } else {
                const node: *BranchNode = @as(?*BranchNode, @ptrFromInt(root)) orelse return;

                log.info("---------\\/\\/ branch depth={}", .{depth});
                for (node.keys[0..node.used]) |key| {
                    log.info("{}", .{key});
                }
                log.info("---------", .{});

                for (node.ptrs[0 .. node.used + 1]) |next| {
                    debug_recurse(next, depth - 1);
                }
            }
        }

        /// insert `val` at `key`, returning it if it already exists
        pub fn try_insert(self: *@This(), key: K, val: V) ?V {
            _ = .{ self, key, val };
        }

        pub fn remove(self: *@This(), key: K) ?V {
            _ = .{ self, key };
        }

        pub fn get(self: *const @This(), key: K) ?*V {
            return get_recurse(key, self.root, self.depth);
        }

        fn get_recurse(key: K, root: usize, depth: usize) ?*V {
            if (depth == 0) {
                const node: *LeafNode = @as(?*LeafNode, @ptrFromInt(root)) orelse return null;

                switch (indexOf(key, node.keys[0..node.used])) {
                    .found => |i| return &node.vals[i],
                    .not_found => return null,
                }
            } else {
                const node: *BranchNode = @as(?*BranchNode, @ptrFromInt(root)) orelse return null;

                switch (indexOf(key, node.keys[0..node.used])) {
                    .found => |i| return &node.vals[i],
                    .not_found => |i| return get_recurse(key, node.ptrs[i], depth - 1),
                }
            }
        }

        fn isFull(root: usize, depth: usize) bool {
            // log.info("isFull(root={}, depth={})", .{ root, depth });
            if (depth == 0) {
                const node: *LeafNode = @as(?*LeafNode, @ptrFromInt(root)) orelse unreachable;
                return node.used == LeafNode.MAX;
            } else {
                const node: *BranchNode = @as(?*BranchNode, @ptrFromInt(root)) orelse unreachable;
                return node.used == BranchNode.MAX;
            }
        }

        fn splitNthChild(alloc: std.mem.Allocator, root: usize, depth: usize, n: usize) Error!void {
            // log.info("split_nth_child(root={}, depth={}, n={})", .{ root, depth, n });
            if (depth == 0) unreachable;

            const parent: *BranchNode = @as(?*BranchNode, @ptrFromInt(root)) orelse unreachable;
            std.debug.assert(parent.used != BranchNode.MAX);

            if (depth == 1) {
                const full_node: *LeafNode = @as(?*LeafNode, @ptrFromInt(parent.ptrs[n])) orelse unreachable;
                std.debug.assert(full_node.used == LeafNode.MAX);

                const new_node = try alloc.create(LeafNode);
                new_node.* = .{};

                // copy the right half (maybe less than the minimum, so it becomes invalid) to the new node
                std.mem.copyForwards(K, new_node.keys[0..], full_node.keys[LeafNode.MIN + 1 ..]);
                std.mem.copyForwards(V, new_node.vals[0..], full_node.vals[LeafNode.MIN + 1 ..]);
                // move the first one from the right half to the parent
                insert_arr(K, parent.keys[0..], parent.used, n, full_node.keys[LeafNode.MIN]);
                insert_arr(V, parent.vals[0..], parent.used, n, full_node.vals[LeafNode.MIN]);
                // add the new child
                insert_arr(V, parent.ptrs[0..], parent.used + 1, n + 1, @intFromPtr(new_node));

                full_node.used = LeafNode.MIN;
                new_node.used = LeafNode.MAX - LeafNode.MIN - 1;
                parent.used += 1;
            } else {
                const full_node: *BranchNode = @as(?*BranchNode, @ptrFromInt(parent.ptrs[n])) orelse unreachable;
                std.debug.assert(full_node.used == BranchNode.MAX);

                const new_node = try alloc.create(BranchNode);
                new_node.* = .{};

                // copy the right half (maybe less than the minimum, so it becomes invalid) to the new node
                std.mem.copyForwards(K, new_node.keys[0..], full_node.keys[BranchNode.MIN + 1 ..]);
                std.mem.copyForwards(V, new_node.vals[0..], full_node.vals[BranchNode.MIN + 1 ..]);
                std.mem.copyForwards(usize, new_node.ptrs[0..], full_node.ptrs[BranchNode.MIN + 2 ..]);
                // move the first one from the right half to the parent
                insert_arr(K, parent.keys[0..], parent.used, n, full_node.keys[BranchNode.MIN]);
                insert_arr(V, parent.vals[0..], parent.used, n, full_node.vals[BranchNode.MIN]);
                // add the new child
                insert_arr(V, parent.ptrs[0..], parent.used + 1, n + 1, @intFromPtr(new_node));

                full_node.used = BranchNode.MIN;
                new_node.used = BranchNode.MAX - BranchNode.MIN - 1;
                parent.used += 1;
            }
        }

        fn split_root(self: *@This(), alloc: std.mem.Allocator) Error!void {
            const new_root = try alloc.create(BranchNode);
            new_root.* = .{};
            new_root.ptrs[0] = self.root;
            new_root.used = 0;

            self.root = @intFromPtr(new_root);
            self.depth += 1;
            // FIXME: recover from errors
            try splitNthChild(alloc, self.root, self.depth, 0);
        }
    };
}
