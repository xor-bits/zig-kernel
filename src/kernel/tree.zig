const std = @import("std");

//

const log = std.log.scoped(.tree);

//

pub fn defaultOrder(comptime K: type) fn (K, K) std.math.Order {
    return struct {
        fn inner(a: K, b: K) std.math.Order {
            return std.math.order(a, b);
        }
    }.inner;
}

pub fn RbTree(
    comptime K: type,
    comptime V: type,
    comptime order: fn (K, K) std.math.Order,
) type {
    return struct {
        root: ?*Node = null,

        const Self = @This();

        pub const Node = struct {
            child: [2]?*Node,
            parent: ?*Node,
            color: Color,
            key: K,
            value: V,

            fn dir(self: *Node) Dir {
                if (self == self.parent.?.child[1]) {
                    return .right;
                } else {
                    return .left;
                }
            }

            fn color(node: ?*Node) Color {
                if (node) |_node| {
                    return _node.color;
                }
                return .black;
            }
        };

        fn rotateDir(self: *Self, subtree: *Node, dir: Dir) ?*Node {
            const g = subtree.parent;
            const s = subtree.child[1 - @intFromEnum(dir)].?;
            const c = s.child[@intFromEnum(dir)];

            subtree.child[1 - @intFromEnum(dir)] = c;
            if (c) |_c| {
                _c.parent = subtree;
            }

            s.child[@intFromEnum(dir)] = subtree;
            subtree.parent = s;
            s.parent = g;

            if (g) |_g| {
                _g.child[if (subtree == _g.child[1]) 1 else 0] = s;
            } else {
                self.root = s;
            }

            return s;
        }

        pub fn debug(self: *Self) void {
            log.info("{any} = {any}", .{ self.depth(), self });
        }

        pub fn depth(self: *Self) usize {
            var d: usize = 0;
            iter(self.root, 0, &d, struct {
                fn inner(max_depth: *usize, _d: usize, _: *Node) !void {
                    max_depth.* = @max(max_depth.*, _d);
                }
            }.inner) catch unreachable;
            return d;
        }

        pub fn format(self: *Self, comptime fmt: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
            _ = fmt;

            try std.fmt.format(writer, "{{ ", .{});
            try iter(self.root, 0, writer, struct {
                fn inner(w: anytype, _: usize, node: *Node) !void {
                    try std.fmt.format(w, "({any}, {any}), ", .{ node.key, node.value });
                }
            }.inner);
            try std.fmt.format(writer, "}}", .{});
        }

        fn iter(_node: ?*Node, d: usize, ctx: anytype, callback: anytype) !void {
            const node = _node orelse return;
            try callback(ctx, d, node);

            for (node.child) |next| {
                try iter(next, d + 1, ctx, callback);
            }
        }

        pub fn get(self: *Self, key: K) ?*Node {
            switch (self.entry(key)) {
                .occupied => |node| {
                    return node;
                },
                .vacant => {
                    return null;
                },
            }
        }

        pub fn insert(self: *Self, inserting: *Node) ?*Node {
            switch (self.entry(inserting.key)) {
                .occupied => |node| {
                    std.mem.swap(K, &node.key, &inserting.key);
                    std.mem.swap(V, &node.value, &inserting.value);
                    return inserting;
                },
                .vacant => |node| {
                    self.insertVacant(inserting, node);
                    return null;
                },
            }
        }

        pub fn remove(self: *Self, key: K) ?*Node {
            switch (self.entry(key)) {
                .occupied => |node| {
                    return self.removeNode(node);
                },
                .vacant => {
                    return null;
                },
            }
        }

        pub const Entry = union(enum) {
            occupied: *Node,
            vacant: Vacant,
        };

        pub const Vacant = struct {
            parent: ?*Node,
            dir: Dir,
        };

        pub fn insertVacant(self: *Self, node: *Node, _entry: Vacant) void {
            self.insert1(node, _entry.parent, _entry.dir);
        }

        pub fn entry(self: *Self, key: K) Entry {
            var parent: *Node = self.root orelse {
                return Entry{ .vacant = .{
                    .parent = null,
                    .dir = .left,
                } };
            };

            while (true) {
                const dir = dirFromOrder(order(key, parent.key)) orelse {
                    return Entry{ .occupied = parent };
                };
                parent = parent.child[@intFromEnum(dir)] orelse {
                    return Entry{ .vacant = .{
                        .parent = parent,
                        .dir = dir,
                    } };
                };
            }
        }

        fn insert1(
            self: *Self,
            _node: *Node,
            new_parent: ?*Node,
            _dir: Dir,
        ) void {
            var node = _node;
            var dir = _dir;
            var grandparent: *Node = undefined;
            var uncle: ?*Node = undefined;

            node.color = .red;
            node.child[0] = null;
            node.child[1] = null;
            node.parent = new_parent;

            var parent: *Node = new_parent orelse {
                self.root = node;
                return;
            };
            parent.child[@intFromEnum(dir)] = node;

            // rebalance
            while (true) {
                if (Node.color(parent) == .black) {
                    // case i1
                    return;
                }

                grandparent = parent.parent orelse {
                    // case i4
                    parent.color = .black;
                    return;
                };

                dir = parent.dir();
                uncle = grandparent.child[@intFromEnum(mirror(dir))];
                if (Node.color(uncle) == .black) {
                    // case i5,i6
                    // FIXME:
                    if (node == parent.child[@intFromEnum(mirror(dir))]) {
                        _ = self.rotateDir(parent, dir);
                        node = parent;
                        parent = grandparent.child[@intFromEnum(dir)].?;
                    }
                    // case i6
                    _ = self.rotateDir(grandparent, mirror(dir));
                    parent.color = .black;
                    grandparent.color = .red;
                    return;
                }

                // case i2
                grandparent.color = .red;
                parent.color = .black;
                uncle.?.color = .black;

                // iterate 2 tree levels higher
                parent = node.parent orelse {
                    break;
                };
            }

            // case i3
            return;
        }

        fn removeNode(self: *Self, node: *Node) *Node {
            if (node.child[0] != null and node.child[1] != null) {
                var left = node.child[1].?;
                while (true) {
                    if (left.child[0]) |next| {
                        left = next;
                    } else {
                        std.mem.swap(K, &node.key, &left.key);
                        std.mem.swap(V, &node.value, &left.value);
                        return self.removeNode(left);
                    }
                }
            }

            if (node.child[0]) |left| {
                std.mem.swap(K, &node.key, &left.key);
                std.mem.swap(V, &node.value, &left.value);
                std.mem.swap([2]?*Node, &node.child, &left.child);
                node.color = .black;
                return left;
            }

            if (node.child[1]) |right| {
                std.mem.swap(K, &node.key, &right.key);
                std.mem.swap(V, &node.value, &right.value);
                std.mem.swap([2]?*Node, &node.child, &right.child);
                node.color = .black;
                return right;
            }

            if (self.root == node) {
                self.root = null;
                return node;
            }

            if (Node.color(node) == .black) {
                self.remove2(node);
            }

            return node;
        }

        fn remove2(self: *Self, _node: *Node) void {
            var node = _node;
            var parent = node.parent.?;
            var dir = node.dir();
            parent.child[@intFromEnum(dir)] = null;

            var sibling: *Node = undefined;
            var close_nephew: ?*Node = undefined;
            var distant_nephew: ?*Node = undefined;

            while (true) {
                sibling = parent.child[@intFromEnum(mirror(dir))].?;
                close_nephew = sibling.child[@intFromEnum(dir)];
                distant_nephew = sibling.child[@intFromEnum(mirror(dir))];

                if (Node.color(sibling) == .red) {
                    // case d3
                    _ = self.rotateDir(parent, dir);
                    parent.color = .red;
                    sibling.color = .black;
                    sibling = close_nephew.?;
                    distant_nephew = sibling.child[@intFromEnum(mirror(dir))];
                }
                if (Node.color(distant_nephew) == .red) {
                    // case d6
                    _ = self.rotateDir(parent, dir);
                    sibling.color = parent.color;
                    parent.color = .black;
                    distant_nephew.?.color = .black;
                    return;
                }
                if (Node.color(close_nephew) == .red) {
                    // case d5
                    _ = self.rotateDir(sibling, mirror(dir));
                    sibling.color = .red;
                    close_nephew.?.color = .black;
                    distant_nephew = sibling;
                    sibling = close_nephew.?;

                    // case d6
                    _ = self.rotateDir(parent, dir);
                    sibling.color = parent.color;
                    parent.color = .black;
                    distant_nephew.?.color = .black;
                    return;
                }
                if (Node.color(parent) == .red) {
                    // case d4
                    sibling.color = .red;
                    parent.color = .black;
                    return;
                }

                // case d2
                sibling.color = .red;
                node = parent;

                // iterate 2 tree levels higher
                parent = node.parent orelse {
                    break;
                };
                dir = node.dir();
            }

            // case d1
            return;
        }
    };
}

const Color = enum {
    red,
    black,
};

const Dir = enum(u8) {
    left = 0,
    right = 1,
};

fn dirFromOrder(o: std.math.Order) ?Dir {
    return switch (o) {
        .gt => .right,
        .lt => .left,
        .eq => null,
    };
}

fn mirror(dir: Dir) Dir {
    return @enumFromInt(1 - @intFromEnum(dir));
}
