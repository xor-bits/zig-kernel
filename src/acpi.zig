const std = @import("std");
const limine = @import("limine");

const pmem = @import("pmem.zig");

const log = std.log.scoped(.acpi);

//

pub export var rsdp_req: limine.RsdpRequest = .{};

//

pub fn init() !void {
    log.info("init acpi", .{});

    const rsdp_resp: *limine.RsdpResponse = rsdp_req.response orelse {
        return error.NoRsdp;
    };

    const rsdp: *const Rsdp = if (rsdp_resp.revision >= 3)
        pmem.PhysAddr.new(@intFromPtr(rsdp_resp.address)).toHhdm().ptr(*const Rsdp)
    else
        @ptrCast(rsdp_resp.address);
    if (!isChecksumValid(Rsdp, rsdp)) {
        return error.InvalidRsdpChecksum;
    }
    if (!std.mem.eql(u8, rsdp.signature[0..], "RSD PTR ")) {
        return error.InvalidRsdpSignature;
    }

    log.info("ACPI OEM: {s}", .{rsdp.oem_id});

    if (rsdp.revision == 0) {
        try acpiv1(rsdp);
    } else {
        try acpiv2(rsdp);
    }
}

fn acpiv1(rsdp: *const Rsdp) !void {
    log.info("ACPI v1", .{});

    const rsdt: *const Rsdt = pmem.PhysAddr.new(rsdp.rsdt_addr).toHhdm().ptr(*const Rsdt);
    if (!isChecksumValid(Rsdt, rsdt)) {
        return error.InvalidRsdtChecksum;
    }
    if (!std.mem.eql(u8, rsdt.header.signature[0..], "RSDT")) {
        return error.InvalidRsdtSignature;
    }

    log.info("SDT Headers:", .{});
    for (rsdt.pointers()) |sdt_ptr| {
        const sdt: *const SdtHeader = pmem.PhysAddr.new(sdt_ptr).toHhdm().ptr(*const SdtHeader);
        log.info(" - {s}", .{sdt.signature});
    }
}

fn acpiv2(rsdp: *const Rsdp) !void {
    log.info("ACPI v2", .{});

    const xsdp: *const Xsdp = @ptrCast(rsdp);
    if (!isChecksumValid(Xsdp, xsdp)) {
        return error.InvalidRsdpChecksum;
    }

    const xsdt: *const Xsdt = pmem.PhysAddr.new(xsdp.xsdt_addr).toHhdm().ptr(*const Xsdt);
    if (!isChecksumValid(Xsdt, xsdt)) {
        return error.InvalidXsdtChecksum;
    }
    if (!std.mem.eql(u8, xsdt.header.signature[0..], "XSDT")) {
        return error.InvalidXsdtSignature;
    }

    log.info("SDT Headers:", .{});
    for (xsdt.pointers()) |sdt_ptr| {
        const sdt: *const SdtHeader = pmem.PhysAddr.new(sdt_ptr).toHhdm().ptr(*const SdtHeader);
        log.info(" - {s}", .{sdt.signature});
    }
}

//

const Rsdp = extern struct {
    signature: [8]u8 align(1),
    checksum: u8 align(1),
    oem_id: [6]u8 align(1),
    revision: u8 align(1),
    rsdt_addr: u32 align(1),
};

const Xsdp = extern struct {
    rsdp: Rsdp align(1),

    length: u32 align(1),
    xsdt_addr: u64 align(1),
    ext_checksum: u8 align(1),
    _reserved: [3]u8 align(1),
};

const SdtHeader = extern struct {
    signature: [4]u8 align(1),
    length: u32 align(1),
    revision: u8 align(1),
    checksum: u8 align(1),
    oem_id: [6]u8 align(1),
    oem_table_id: [8]u8 align(1),
    oem_revision: u32 align(1),
    creator_id: u32 align(1),
    creator_revision: u32 align(1),
};

const Rsdt = extern struct {
    header: SdtHeader align(1),

    fn pointers(self: *const @This()) []align(1) const u32 {
        const arr_self: [*]const @This() = @ptrCast(self);
        const arr_ptr: [*]align(1) const u32 = @ptrCast(&arr_self[1]);
        return arr_ptr[0 .. (self.header.length - @sizeOf(@This())) / @sizeOf(u32)];
    }
};

const Xsdt = extern struct {
    header: SdtHeader align(1),

    fn pointers(self: *const @This()) []align(1) const u64 {
        const arr_self: [*]const @This() = @ptrCast(self);
        const arr_ptr: [*]align(1) const u64 = @ptrCast(&arr_self[1]);
        return arr_ptr[0 .. (self.header.length - @sizeOf(@This())) / @sizeOf(u64)];
    }
};

//

pub fn isChecksumValid(comptime T: type, val: *const T) bool {
    var len: usize = undefined;

    switch (T) {
        SdtHeader, Rsdt, Xsdt => {
            const val_sdt: *const SdtHeader = @ptrCast(val);
            len = val_sdt.length;
        },
        Rsdp => len = @sizeOf(T),
        Xsdp => len = @sizeOf(T),
        else => @compileError("isChecksumValid: unknown type"),
    }

    const bytes_ptr: [*]const u8 = @ptrCast(val);
    const as_bytes = bytes_ptr[0..len];

    var checksum: u8 = 0;
    for (as_bytes) |b| {
        checksum +%= b;
    }

    return checksum == 0;
}

// less effor than spamming align(1) on every field,
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
