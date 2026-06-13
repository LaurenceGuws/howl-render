const std = @import("std");

pub const Rgba8 = struct {
    r: u8,
    g: u8,
    b: u8,
    a: u8,
};

pub const SemanticColorKind = enum(u2) {
    default = 0,
    indexed = 1,
    rgb = 2,
};

pub const SemanticColor = struct {
    kind: SemanticColorKind = .default,
    value: u32 = 0,
};

test "semantic color defaults are deterministic" {
    const semantic = SemanticColor{};
    try std.testing.expectEqual(SemanticColorKind.default, semantic.kind);
    try std.testing.expectEqual(@as(u32, 0), semantic.value);
}
