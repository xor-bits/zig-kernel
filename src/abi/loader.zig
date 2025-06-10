const std = @import("std");
const abi = @import("lib.zig");

const caps = abi.caps;
const log = std.log.scoped(.loader);

//

pub fn exec(elf: []const u8) !void {
    const vmem = try caps.Vmem.create();
    defer vmem.close();

    const proc = try caps.Process.create(vmem);
    defer proc.close();

    const entry = try load(vmem, elf);

    try spawn(vmem, proc, entry);
}

pub fn load(vmem: caps.Vmem, elf: []const u8) !usize {
    const self_vmem = try caps.Vmem.self();
    defer self_vmem.close();

    var loader = try Elf.init(elf);
    const entry = try loader.loadInto(self_vmem, vmem);
    return entry;
}

pub fn prepareSpawn(vmem: caps.Vmem, thread: caps.Thread, entry: u64) !void {
    // map a stack
    const stack = try caps.Frame.create(1024 * 256);
    defer stack.close();
    const stack_ptr = try vmem.map(
        stack,
        0,
        0,
        1024 * 256,
        .{ .writable = true },
        .{},
    );
    // FIXME: protect the stack guard region as
    // no read, no write, no exec and prevent mapping
    try vmem.unmap(stack_ptr, 0x1000);

    try thread.setPrio(0);
    try thread.writeRegs(&.{
        // .arg0 = sender_there,
        .user_instr_ptr = entry,
        .user_stack_ptr = stack_ptr + 1024 * 256 - 0x100,
    });
}

pub fn spawn(vmem: caps.Vmem, proc: caps.Process, entry: u64) !void {
    const thread = try caps.Thread.create(proc);
    defer thread.close();

    try prepareSpawn(vmem, thread, entry);
    try thread.start();
}

//

/// general server info
pub const Manifest = extern struct {
    /// manifest symbol magic number
    magic: u128 = exp_magic,
    /// server identifier
    name: [112]u8 = .{0} ** 112,

    pub const exp_magic = 0x5b9061e5c940d983eeb14ce5e02618b7;

    pub const Info = struct {
        name: []const u8,
    };

    pub fn new(comptime info: Info) @This() {
        return @This(){
            .name = (info.name ++ .{0} ** (112 - info.name.len)).*,
        };
    }

    pub fn getName(self: *const @This()) []const u8 {
        return std.mem.sliceTo(self.name[0..], 0);
    }
};

pub const Resource = extern struct {
    /// resource symbol magic number
    magic: u128 = exp_magic,
    note: u64,
    handle: u32 = 0,
    ty: abi.ObjectType = .null,
    name: [99]u8 = .{0} ** 99,

    pub const exp_magic = 0xc47d27b79d2c8bb9469ee8883d14a25c;

    pub const Info = struct {
        ty: abi.ObjectType,
        name: []const u8,
        note: u64 = 0,
    };

    pub fn new(comptime info: Info) @This() {
        return .{
            .ty = info.ty,
            .name = (info.name ++ .{0} ** (99 - info.name.len)).*,
            .note = info.note,
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
    data_table: ?[]const u8 = null,
    bss_table: ?[]const u8 = null,
    section_header_string_table: ?[]const u8 = null,

    pub fn init(elf: []const u8) !@This() {
        return .{ .data = elf };
    }

    pub fn crc32(self: *@This()) u32 {
        var crc: u32 = 0;
        for (self.data) |b| {
            crc = @addWithOverflow(crc, @as(u32, b))[0];
        }
        return crc;
    }

    pub fn loadInto(self: *@This(), self_vmem: caps.Vmem, vmem: caps.Vmem) !usize {
        // TODO: syscall to write directly into a `caps.Vmem`
        // TODO: combine contiguous Frames

        for (try self.getProgram()) |program_header| {
            if (program_header.p_type != std.elf.PT_LOAD) continue;
            if (program_header.p_memsz == 0) continue;

            // log.debug("loading phdr", .{});

            const bytes = try getProgramData(self.data, program_header);

            const rights = abi.sys.Rights{
                .readable = program_header.p_flags & std.elf.PF_R != 0,
                .writable = program_header.p_flags & std.elf.PF_W != 0,
                .executable = program_header.p_flags & std.elf.PF_X != 0,
            };

            const segment_vaddr_bottom = std.mem.alignBackward(usize, program_header.p_vaddr, 0x1000);
            const segment_vaddr_top = std.mem.alignForward(usize, program_header.p_vaddr + program_header.p_memsz, 0x1000);
            const segment_data_bottom_offset = program_header.p_vaddr - segment_vaddr_bottom;
            // const data_vaddr_bottom = program_header.p_vaddr;
            // const data_vaddr_top = data_vaddr_bottom + program_header.p_filesz;
            // const zero_vaddr_bottom = std.mem.alignForward(usize, data_vaddr_top, 0x1000);
            // const zero_vaddr_top = segment_vaddr_top;

            // log.info("flags: {}, segment_vaddr_bottom=0x{x} segment_vaddr_top=0x{x} data_vaddr_bottom=0x{x} data_vaddr_top=0x{x}", .{
            //     rights,
            //     segment_vaddr_bottom,
            //     segment_vaddr_top,
            //     data_vaddr_bottom,
            //     data_vaddr_top,
            // });

            const size = segment_vaddr_top - segment_vaddr_bottom;
            const frame = try caps.Frame.create(size);
            defer frame.close();

            // TODO: Frame.write instead of Vmem.map + memcpy + Vmem.unmap
            const loader_tmp = try self_vmem.map(
                frame,
                0,
                0,
                size,
                .{ .writable = true },
                .{},
            );

            // log.info("copying to [ 0x{x}..0x{x} ]", .{
            //     segment_vaddr_bottom + segment_data_bottom_offset,
            //     segment_vaddr_bottom + segment_data_bottom_offset + program_header.p_filesz,
            // });
            abi.util.copyForwardsVolatile(u8, @as(
                [*]volatile u8,
                @ptrFromInt(loader_tmp + segment_data_bottom_offset),
            )[0..program_header.p_filesz], bytes);

            try self_vmem.unmap(
                loader_tmp,
                size,
            );

            _ = try vmem.map(
                frame,
                0,
                segment_vaddr_bottom,
                size,
                rights,
                .{ .fixed = true },
            );
        }

        return (try self.getHeader()).entry;
    }

    pub fn ExternStructIterator(
        comptime T: type,
        comptime sym_name_prefix: []const u8,
    ) type {
        return struct {
            data: []const u8,
            string_table: ?[]const u8,
            sections: []const std.elf.Elf64_Shdr,
            symbols: []const std.elf.Elf64_Sym,

            pub const Next = struct {
                val: T,
                addr: usize,
                /// lifetime tied to the ELF binary lifetime
                name: []const u8,
            };

            pub fn next(self: *@This()) !?Next {
                while (self.symbols.len >= 1) {
                    defer self.symbols = self.symbols[1..];

                    const sym = self.symbols[0];

                    // check the size
                    if (sym.st_size != @sizeOf(T))
                        continue;

                    // check the name prefix if strtab is found
                    var sym_name: []const u8 = "???";
                    if (self.string_table) |strtab| {
                        sym_name = try getString(strtab, sym.st_name);
                        if (!std.mem.startsWith(u8, sym_name, sym_name_prefix)) continue;
                    }

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

                    const offs = sym.st_value - sect.sh_addr;
                    const bytes = sect_data[offs..][0..sym.st_size];

                    return .{
                        .val = std.mem.bytesAsValue(T, bytes).*,
                        .addr = sym.st_value,
                        .name = sym_name,
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
            .string_table = self.getStringTable() catch null,
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

    fn getProgram(self: *@This()) ![]const std.elf.Elf64_Phdr {
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

        self.symbol_table = try self.getSectionByName(".symtab") orelse
            return error.MissingSymtab;

        return self.symbol_table.?;
    }

    fn getStringTable(self: *@This()) ![]const u8 {
        if (self.string_table) |tab| return tab;

        self.string_table = try self.getSectionByName(".strtab") orelse
            return error.MissingStrtab;

        return self.string_table.?;
    }

    fn getSectionByName(self: *@This(), name: []const u8) !?[]const u8 {
        const section_header_string_table = try self.getSectionHeaderStringTable();

        for (try self.getSections()) |sect| {
            const sh_name = try getString(section_header_string_table, sect.sh_name);
            if (!std.mem.eql(u8, name, sh_name)) continue;

            return try getSectionData(self.data, sect);
        }

        return null;
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

    fn getProgramData(bin: []const u8, phdr: std.elf.Elf64_Phdr) ![]const u8 {
        // bounds checking
        if (bin.len < std.math.add(
            u64,
            phdr.p_offset,
            phdr.p_filesz,
        ) catch return error.OutOfBounds)
            return error.OutOfBounds;

        return bin[phdr.p_offset..][0..phdr.p_filesz];
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
