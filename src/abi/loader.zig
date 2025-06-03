const std = @import("std");
const abi = @import("lib.zig");

//

/// general server info
pub const Manifest = extern struct {
    /// manifest symbol magic number
    magic: u64 = exp_magic,
    /// server identifier
    name: [120]u8 = .{0} ** 120,

    pub const exp_magic = 0x5b9061e5c940d983;

    pub const Info = struct {
        name: []const u8,
    };

    pub fn new(comptime info: Info) @This() {
        return @This(){
            .name = (info.name ++ .{0} ** (120 - info.name.len)).*,
        };
    }

    pub fn getName(self: *const @This()) []const u8 {
        return std.mem.sliceTo(self.name[0..], 0);
    }
};

pub const Resource = extern struct {
    /// resource symbol magic number
    magic: u64 = exp_magic,
    ty: abi.ObjectType = .null,
    handle: u32 = 0,
    name: [114]u8 = .{0} ** 114,

    pub const exp_magic = 0xc47d27b79d2c8bb9;

    pub const Info = struct {
        ty: abi.ObjectType,
        name: []const u8,
    };

    pub fn new(comptime info: Info) @This() {
        return .{
            .ty = info.ty,
            .name = (info.name ++ .{0} ** (114 - info.name.len)).*,
        };
    }

    pub fn getName(self: *const @This()) []const u8 {
        return std.mem.sliceTo(self.name[0..], 0);
    }
};

// FIXME: alignment when reading from data
pub const Elf = struct {
    data: []const u8,
    header: ?std.elf.Header = null,

    program: ?[]const std.elf.Elf64_Phdr = null,
    sections: ?[]const std.elf.Elf64_Shdr = null,

    symbol_table: ?[]const u8 = null,
    string_table: ?[]const u8 = null,
    section_header_string_table: ?[]const u8 = null,

    pub fn init(elf: []const u8) !@This() {
        return .{ .data = elf };
    }

    pub fn ExternStructIterator(
        comptime T: type,
        comptime sym_name_prefix: []const u8,
    ) type {
        return struct {
            data: []const u8,
            string_table: []const u8,
            sections: []const std.elf.Elf64_Shdr,
            symbols: []const std.elf.Elf64_Sym,

            pub const Next = struct {
                val: T,
                addr: usize,
            };

            pub fn next(self: *@This()) !?Next {
                while (self.symbols.len >= 1) {
                    defer self.symbols = self.symbols[1..];

                    const sym = self.symbols[0];
                    const sym_name = try getString(self.string_table, sym.st_name);
                    if (!std.mem.startsWith(u8, sym_name, sym_name_prefix)) continue;

                    if (sym.st_shndx >= self.sections.len)
                        return error.OutOfBounds;
                    const sect = self.sections[sym.st_shndx];
                    const sect_data = try getSectionData(self.data, sect);

                    if (sym.st_value < sect.sh_addr)
                        return error.OutOfBounds;
                    if ((std.math.add(u64, sym.st_value, sym.st_size) catch
                        return error.OutOfBounds) >
                        (std.math.add(u64, sect.sh_addr, sect.sh_size) catch
                            return error.OutOfBounds))
                        return error.OutOfBounds;
                    if (sym.st_size != @sizeOf(T))
                        continue;

                    const offs = sym.st_value - sect.sh_addr;
                    const bytes = sect_data[offs..][0..sym.st_size];

                    return .{
                        .val = std.mem.bytesAsValue(T, bytes).*,
                        .addr = sym.st_value,
                    };
                }

                return null;
            }
        };
    }

    pub fn externStructIterator(
        self: *@This(),
        comptime T: type,
        comptime sym_name_prefix: []const u8,
    ) !ExternStructIterator(T, sym_name_prefix) {
        return .{
            .data = self.data,
            .string_table = try self.getStringTable(),
            .sections = try self.getSections(),
            .symbols = try self.symbols(),
        };
    }

    pub fn ExternStructMagicIterator(
        comptime T: type,
        comptime sym_name_prefix: []const u8,
    ) type {
        return struct {
            inner: ExternStructIterator(T, sym_name_prefix),

            pub fn next(self: *@This()) !?@TypeOf(self.inner).Next {
                while (try self.inner.next()) |item| {
                    if (item.val.magic == T.exp_magic) return item;
                    std.log.info("discarded: invalid magic", .{});
                }
                return null;
            }
        };
    }

    pub fn externStructMagicIterator(
        self: *@This(),
        comptime T: type,
        comptime sym_name_prefix: []const u8,
    ) !ExternStructMagicIterator(T, sym_name_prefix) {
        return .{
            .inner = try self.externStructIterator(T, sym_name_prefix),
        };
    }

    pub fn manifest(self: *@This()) !?Manifest {
        var it = try self.externStructMagicIterator(Manifest, "manifest");

        const item = (try it.next()) orelse return null;
        if (try it.next() != null) return error.MultipleManifests;

        return item.val;
    }

    pub fn imports(self: *@This()) !ExternStructMagicIterator(Resource, "import") {
        return try self.externStructMagicIterator(Resource, "import");
    }

    pub fn exports(self: *@This()) !ExternStructMagicIterator(Resource, "export") {
        return try self.externStructMagicIterator(Resource, "export");
    }

    pub fn symbols(self: *@This()) ![]const std.elf.Elf64_Sym {
        const symbol_table = try self.getSymbolTable();

        return @as(
            [*]const std.elf.Elf64_Sym,
            @alignCast(@ptrCast(symbol_table)),
        )[0 .. symbol_table.len / @sizeOf(std.elf.Elf64_Sym)];
    }

    fn getHeader(self: *@This()) !std.elf.Header {
        if (self.header) |h| return h;

        var stream = std.io.fixedBufferStream(self.data);
        self.header = try std.elf.Header.read(&stream);
        return self.header.?;
    }

    fn getProgram(self: *@This()) ![]const std.elf.Elf64_Shdr {
        if (self.program) |s| return s;

        const header = try self.getHeader();
        self.program = try programHeaders(self.data, header);
        return self.program.?;
    }

    fn getSections(self: *@This()) ![]const std.elf.Elf64_Shdr {
        if (self.sections) |s| return s;

        const header = try self.getHeader();
        self.sections = try sectionHeaders(self.data, header);
        return self.sections.?;
    }

    fn getSymbolTable(self: *@This()) ![]const u8 {
        if (self.symbol_table) |tab| return tab;

        const section_header_string_table = try self.getSectionHeaderStringTable();

        for (try self.getSections()) |sect| {
            const sh_name = try getString(section_header_string_table, sect.sh_name);
            if (!std.mem.eql(u8, ".symtab", sh_name)) continue;

            self.symbol_table = try getSectionData(self.data, sect);
            return self.symbol_table.?;
        }

        return error.MissingSymtab;
    }

    fn getStringTable(self: *@This()) ![]const u8 {
        if (self.string_table) |tab| return tab;

        const section_header_string_table = try self.getSectionHeaderStringTable();

        for (try self.getSections()) |sect| {
            const sh_name = try getString(section_header_string_table, sect.sh_name);
            if (!std.mem.eql(u8, ".strtab", sh_name)) continue;

            self.string_table = try getSectionData(self.data, sect);
            return self.string_table.?;
        }

        return error.MissingStrtab;
    }

    fn getSectionHeaderStringTable(self: *@This()) ![]const u8 {
        if (self.section_header_string_table) |tab| return tab;

        const sections = try self.getSections();
        const shstrndx = (try self.getHeader()).shstrndx;
        if (shstrndx >= sections.len)
            return error.OutOfBounds;

        self.section_header_string_table =
            try getSectionData(self.data, sections[shstrndx]);
        return self.section_header_string_table.?;
    }

    fn getString(strtab: []const u8, off: u32) ![]const u8 {
        if (off >= strtab.len)
            return error.OutOfBounds;

        return std.mem.sliceTo(strtab[off..], 0);
    }

    fn getSectionData(bin: []const u8, shdr: std.elf.Elf64_Shdr) ![]const u8 {
        // bounds checking
        if (bin.len < std.math.add(
            u64,
            shdr.sh_offset,
            shdr.sh_size,
        ) catch return error.OutOfBounds)
            return error.OutOfBounds;

        return bin[shdr.sh_offset..][0..shdr.sh_size];
    }

    fn programHeaders(bin: []const u8, header: std.elf.Header) ![]const std.elf.Elf64_Phdr {
        // bounds checking
        if (bin.len < std.math.add(
            u64,
            header.phoff,
            std.math.mul(u64, header.phnum, @sizeOf(std.elf.Elf64_Phdr)) catch
                return error.OutOfBounds,
        ) catch return error.OutOfBounds)
            return error.OutOfBounds;

        const program_headers: [*]const std.elf.Elf64_Phdr = @alignCast(@ptrCast(bin.ptr + header.phoff));
        return program_headers[0..header.phnum];
    }

    fn sectionHeaders(bin: []const u8, header: std.elf.Header) ![]const std.elf.Elf64_Shdr {
        // bounds checking
        if (bin.len < std.math.add(
            u64,
            header.shoff,
            std.math.mul(u64, header.shnum, @sizeOf(std.elf.Elf64_Shdr)) catch
                return error.OutOfBounds,
        ) catch return error.OutOfBounds)
            return error.OutOfBounds;

        const section_headers: [*]const std.elf.Elf64_Shdr = @alignCast(@ptrCast(bin.ptr + header.shoff));
        return section_headers[0..header.shnum];
    }
};
