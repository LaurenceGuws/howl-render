const render = @import("draw_primitives.zig");
const special_glyphs = @import("special_glyphs.zig");

pub fn builtinRoute(cp: u32) ?render.SpecialSpriteRoute {
    if (cp == 0 or cp == '\t') return .blank;
    if (cp >= 0x2500 and cp <= 0x257f) return .box;
    if (cp >= 0x2580 and cp <= 0x259f) return .block;
    if (cp >= 0x2800 and cp <= 0x28ff) return .braille;
    if (special_glyphs.isPowerlineCodepoint(@intCast(cp))) return .powerline;
    if (special_glyphs.isGeneratedSpecialSupported(cp) and (cp >= 0x1fb00 or cp >= 0x1cd00 or (cp >= 0xf5d0 and cp <= 0xf60d))) return .legacy_computing;
    return null;
}

pub fn isIconCodepoint(cp: u32) bool {
    return (cp >= 0xe000 and cp <= 0xf8ff) or
        (cp >= 0x2700 and cp <= 0x27bf) or
        (cp >= 0x1f100 and cp <= 0x1f1ff) or
        (cp >= 0xf0000 and cp <= 0xffffd) or
        (cp >= 0x100000 and cp <= 0x10fffd);
}

test "builtin route classifies box drawing" {
    try @import("std").testing.expectEqual(render.SpecialSpriteRoute.box, builtinRoute(0x2500).?);
}

test "builtin route leaves kitty symbol-map powerline glyphs alone" {
    try @import("std").testing.expectEqual(@as(?render.SpecialSpriteRoute, null), builtinRoute(0xe0a0));
    try @import("std").testing.expectEqual(@as(?render.SpecialSpriteRoute, null), builtinRoute(0xe0c0));
}

test "builtin route classifies octant symbols" {
    try @import("std").testing.expectEqual(render.SpecialSpriteRoute.legacy_computing, builtinRoute(0x1cd00).?);
    try @import("std").testing.expectEqual(render.SpecialSpriteRoute.legacy_computing, builtinRoute(0x1fbe6).?);
}

test "builtin route classifies kitty eight bars" {
    try @import("std").testing.expectEqual(render.SpecialSpriteRoute.legacy_computing, builtinRoute(0x1fb70).?);
}

test "builtin route classifies kitty legacy computing tail" {
    try @import("std").testing.expectEqual(render.SpecialSpriteRoute.legacy_computing, builtinRoute(0x1fbae).?);
}

test "builtin route classifies generated special sprite families" {
    const testing = @import("std").testing;
    for ([_]u32{ 0x1fb00, 0x1fb3b, 0x1fb3c, 0x1fb67, 0x1fb68, 0x1fb6f, 0x1fb70, 0x1fb7b, 0x1fb7c, 0x1fb8b, 0x1fb93, 0x1fba0, 0x1fbae, 0x1cd00, 0x1cde5, 0x1fbe6, 0xf5d0, 0xf60d }) |cp| {
        try testing.expectEqual(render.SpecialSpriteRoute.legacy_computing, builtinRoute(cp).?);
    }
    try testing.expectEqual(render.SpecialSpriteRoute.powerline, builtinRoute(0xe0d6).?);
    try testing.expectEqual(render.SpecialSpriteRoute.powerline, builtinRoute(0xe0d7).?);
}

test "icon codepoint classification stays explicit" {
    try @import("std").testing.expect(isIconCodepoint(0xf101));
    try @import("std").testing.expect(!isIconCodepoint('A'));
    try @import("std").testing.expectEqual(@as(?render.SpecialSpriteRoute, null), builtinRoute(0xf101));
}
