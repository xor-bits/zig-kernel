const acpi = @import("acpi.zig");

//

/// parse Multiple APIC Description Table
pub fn madt(sdt: *const acpi.SdtHeader) !void {
    _ = sdt;
}
