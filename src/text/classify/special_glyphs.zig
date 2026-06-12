pub fn isPowerlineCodepoint(codepoint: u21) bool {
    return (codepoint >= 0xE0B0 and codepoint <= 0xE0BF) or
        (codepoint >= 0xE0D6 and codepoint <= 0xE0D7);
}

pub fn isBoxDrawingCodepoint(codepoint: u21) bool {
    return codepoint >= 0x2500 and codepoint <= 0x259F;
}

/// Returns true when the shared generated raster path currently implements the codepoint.
pub fn isGeneratedSpecialSupported(codepoint: u32) bool {
    return switch (codepoint) {
        0x2500...0x257f,
        0x2580...0x259f,
        0x2800...0x28ff,
        0xe0b0...0xe0b7,
        0xe0b8...0xe0bf,
        0x1fb00...0x1fb3b,
        0x1fb70...0x1fb7b,
        0x1cd00...0x1cde5,
        0x1fbe6,
        0x1fbe7,
        => true,
        else => false,
    };
}

test "powerline codepoints match kitty box-font cases" {
    try @import("std").testing.expect(isPowerlineCodepoint(0xe0b0));
    try @import("std").testing.expect(isPowerlineCodepoint(0xe0d6));
    try @import("std").testing.expect(!isPowerlineCodepoint(0xe0a0));
}

test "generated special support names only shared raster families" {
    const testing = @import("std").testing;
    for ([_]u32{ 0x2500, 0x2580, 0x2801, 0xe0b0, 0xe0bf, 0x1fb00, 0x1fb3b, 0x1fb70, 0x1fb7b, 0x1cd00, 0x1cde5, 0x1fbe6, 0x1fbe7 }) |cp| {
        try testing.expect(isGeneratedSpecialSupported(cp));
    }
    for ([_]u32{ 0xe0d6, 0xe0d7, 0x1fb3c, 0x1fb67, 0x1fb68, 0x1fb6f, 0x1fb7c, 0x1fb8b, 0x1fb93, 0x1fba0, 0x1fbae, 0xf5d0, 0xf60d }) |cp| {
        try testing.expect(!isGeneratedSpecialSupported(cp));
    }
}
