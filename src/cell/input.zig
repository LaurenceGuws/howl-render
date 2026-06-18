const std = @import("std");
const color = @import("color.zig");
const effects = @import("effects.zig");

pub const CellInput = struct {
    codepoint: u21,
    combining_len: u8 = 0,
    combining: [3]u32 = [_]u32{0} ** 3,
    style: effects.FontStyle = .regular,
    presentation: effects.TextPresentation = .any,
    dim: bool = false,
    invisible: bool = false,
    semantic_fg: color.SemanticColor = .{},
    semantic_bg: color.SemanticColor = .{},
    fg: color.Rgba8,
    bg: color.Rgba8,
    underline_color_set: bool = false,
    semantic_underline_color: color.SemanticColor = .{},
    underline_color: color.Rgba8 = .{ .r = 0, .g = 0, .b = 0, .a = 0 },
    underline_style: effects.UnderlineStyle = .straight,
    underline: bool = false,
    strikethrough: bool = false,
    continuation: bool = false,
    empty: bool = false,

    pub fn assertValid(self: CellInput) void {
        std.debug.assert(self.combining_len <= self.combining.len);
    }
};

test "cell input combining length stays in bounds" {
    const cell = CellInput{
        .codepoint = 'a',
        .combining_len = 3,
        .combining = .{ 0x0301, 0x0308, 0x0327 },
        .fg = .{ .r = 1, .g = 2, .b = 3, .a = 255 },
        .bg = .{ .r = 4, .g = 5, .b = 6, .a = 255 },
    };
    cell.assertValid();
    try std.testing.expect(cell.combining_len <= cell.combining.len);
}
