const std = @import("std");

const arch = @import("arch.zig");
const main = @import("main.zig");
const uart = @import("uart.zig");
const spin = @import("spin.zig");
const pmem = @import("pmem.zig");

//

pub const std_options: std.Options = .{
    .logFn = logFn,
    .log_level = .debug,
};

fn logFn(comptime message_level: std.log.Level, comptime scope: @TypeOf(.enum_literal), comptime format: []const u8, args: anytype) void {
    const level_txt = comptime message_level.asText();
    const scope_txt = if (scope == .default) "" else " " ++ @tagName(scope);
    const level_col = comptime switch (message_level) {
        .debug => "\x1B[96m",
        .info => "\x1B[92m",
        .warn => "\x1B[93m",
        .err => "\x1B[91m",
    };
    const fmt = "\x1B[90m[ " ++ level_col ++ level_txt ++ "\x1B[90m" ++ scope_txt ++ " ]: \x1B[0m" ++ format;

    print(fmt, args);
}

var log_lock: spin.Mutex = .{};

fn print(comptime fmt: []const u8, args: anytype) void {
    log_lock.lock();
    defer log_lock.unlock();

    uart.print(fmt ++ "\n", args);
}

pub fn panic(msg: []const u8, error_return_trace: ?*std.builtin.StackTrace, ret_addr: ?usize) noreturn {
    @branchHint(.cold);
    _ = error_return_trace;
    const log = std.log.scoped(.panic);

    // TODO: maybe `std.debug.Dwarf.ElfModule` contains everything?

    log.err("KERNEL PANIC STACK TRACE:", .{});

    var iter = std.debug.StackIterator.init(ret_addr, @frameAddress());
    if (getSelfDwarf()) |_dwarf| {
        var dwarf = _dwarf;
        defer dwarf.deinit(pmem.page_allocator);

        while (iter.next()) |r_addr| {
            printSourceAtAddress(&dwarf, r_addr);
        }
    } else |err| {
        log.err("failed to open DWARF info: {}", .{err});

        while (iter.next()) |r_addr| {
            print("  \x1B[90m0x{x:0>16}\x1B[0m", .{r_addr});
        }
    }

    log.err("CPU panicked: {s}", .{msg});

    arch.hcf();
}

fn printSourceAtAddress(debug_info: *std.debug.Dwarf, address: usize) void {
    const sym = debug_info.getSymbolName(address) orelse {
        print("  \x1B[90m?? @ 0x{x:0>16}\x1B[0m", .{address});
        return;
    };

    const cu = debug_info.findCompileUnit(address) catch {
        print("  \x1B[90m{s}\x1B[0m", .{sym});
        return;
    };

    const source = debug_info.getLineNumberInfo(pmem.page_allocator, cu, address) catch {
        print("  \x1B[90m{s}\x1B[0m", .{sym});
        return;
    };

    print("  \x1B[90m{s}: {s}:{}:{}\x1B[0m", .{ sym, source.file_name, source.line, source.column });
}

fn getSelfDwarf() !std.debug.Dwarf {

    // std.debug.captureStackTrace(first_address: ?usize, stack_trace: *std.builtin.StackTrace)

    const kernel_file = @import("args.zig").kernel_file.response orelse return error.NoKernelFile;
    const elf_bin = kernel_file.kernel_file.data();
    var elf = std.io.fixedBufferStream(elf_bin);

    const header = try std.elf.Header.read(&elf);

    var sections = std.debug.Dwarf.null_section_array;

    for (sectionsHeaders(elf_bin, header)) |shdr| {
        const name = getString(elf_bin, header, shdr.sh_name);
        // std.log.info("shdr: {s}", .{name});

        if (std.mem.eql(u8, name, ".debug_info")) {
            sections[@intFromEnum(std.debug.Dwarf.Section.Id.debug_info)] = .{
                .data = getSectionData(elf_bin, shdr),
                .owned = false,
            };
        } else if (std.mem.eql(u8, name, ".debug_abbrev")) {
            sections[@intFromEnum(std.debug.Dwarf.Section.Id.debug_abbrev)] = .{
                .data = getSectionData(elf_bin, shdr),
                .owned = false,
            };
        } else if (std.mem.eql(u8, name, ".debug_str")) {
            sections[@intFromEnum(std.debug.Dwarf.Section.Id.debug_str)] = .{
                .data = getSectionData(elf_bin, shdr),
                .owned = false,
            };
        } else if (std.mem.eql(u8, name, ".debug_line")) {
            sections[@intFromEnum(std.debug.Dwarf.Section.Id.debug_line)] = .{
                .data = getSectionData(elf_bin, shdr),
                .owned = false,
            };
        } else if (std.mem.eql(u8, name, ".debug_ranges")) {
            sections[@intFromEnum(std.debug.Dwarf.Section.Id.debug_ranges)] = .{
                .data = getSectionData(elf_bin, shdr),
                .owned = false,
            };
        } else if (std.mem.eql(u8, name, ".eh_frame")) {
            sections[@intFromEnum(std.debug.Dwarf.Section.Id.eh_frame)] = .{
                .data = getSectionData(elf_bin, shdr),
                .owned = false,
            };
        } else if (std.mem.eql(u8, name, ".eh_frame_hdr")) {
            sections[@intFromEnum(std.debug.Dwarf.Section.Id.eh_frame_hdr)] = .{
                .data = getSectionData(elf_bin, shdr),
                .owned = false,
            };
        }
    }

    // sections[@intFromEnum(std.debug.Dwarf.Section.Id.debug_info)] =
    //     sectionFromSym(&__debug_info_start, &__debug_info_end);
    // sections[@intFromEnum(std.debug.Dwarf.Section.Id.debug_abbrev)] =
    //     sectionFromSym(&__debug_abbrev_start, &__debug_abbrev_end);
    // sections[@intFromEnum(std.debug.Dwarf.Section.Id.debug_str)] =
    //     sectionFromSym(&__debug_str_start, &__debug_str_end);
    // sections[@intFromEnum(std.debug.Dwarf.Section.Id.debug_line)] =
    //     sectionFromSym(&__debug_line_start, &__debug_line_end);
    // sections[@intFromEnum(std.debug.Dwarf.Section.Id.debug_ranges)] =
    //     sectionFromSym(&__debug_ranges_start, &__debug_ranges_end);
    // sections[@intFromEnum(std.debug.Dwarf.Section.Id.eh_frame)] =
    //     sectionFromSym(&__eh_frame_start, &__eh_frame_end);
    // sections[@intFromEnum(std.debug.Dwarf.Section.Id.eh_frame_hdr)] =
    //     sectionFromSym(&__eh_frame_hdr_start, &__eh_frame_hdr_end);

    var dwarf: std.debug.Dwarf = .{
        .endian = .little,
        .sections = sections,
        .is_macho = false,
    };

    try dwarf.open(pmem.page_allocator);

    return dwarf;
}

fn getString(bin: []const u8, header: std.elf.Header, off: u32) []const u8 {
    const strtab = getSectionData(
        bin,
        sectionsHeaders(bin, header)[header.shstrndx],
    );
    return std.mem.sliceTo(@as([*:0]const u8, @ptrCast(strtab.ptr + off)), 0);
}

fn getSectionData(bin: []const u8, shdr: std.elf.Elf64_Shdr) []const u8 {
    return bin[shdr.sh_offset..][0..shdr.sh_size];
}

fn sectionsHeaders(bin: []const u8, header: std.elf.Header) []const std.elf.Elf64_Shdr {
    // FIXME: bounds checking maybe
    const section_headers: [*]const std.elf.Elf64_Shdr = @alignCast(@ptrCast(bin.ptr + header.shoff));
    return section_headers[0..header.shnum];
}

fn sectionFromSym(start: *const u8, end: *const u8) std.debug.Dwarf.Section {
    const size = @intFromPtr(end) - @intFromPtr(start);
    const addr = @as([*]const u8, @ptrCast(start));
    return .{
        .data = addr[0..size],
        .owned = false,
    };
}

// extern var __debug_info_start: u8;
// extern var __debug_info_end: u8;
// extern var __debug_abbrev_start: u8;
// extern var __debug_abbrev_end: u8;
// extern var __debug_str_start: u8;
// extern var __debug_str_end: u8;
// extern var __debug_line_start: u8;
// extern var __debug_line_end: u8;
// extern var __debug_ranges_start: u8;
// extern var __debug_ranges_end: u8;
// extern var __eh_frame_start: u8;
// extern var __eh_frame_end: u8;
// extern var __eh_frame_hdr_start: u8;
// extern var __eh_frame_hdr_end: u8;
