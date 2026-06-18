const std = @import("std");

pub const UnderlineStyle = enum {
    straight,
    double,
    curly,
    dotted,
    dashed,
};

pub const FontStyle = enum(u2) {
    regular = 0,
    bold = 1,
    italic = 2,
    bold_italic = 3,
};

pub const TextPresentation = enum(u2) {
    text = 0,
    emoji = 1,
    any = 2,
};

pub const DecorationKind = enum(u3) {
    underline,
    underline_dotted,
    underline_dashed,
    undercurl,
    strikethrough,
};

test "effect enum values stay stable" {
    try std.testing.expectEqual(@as(u2, 0), @intFromEnum(FontStyle.regular));
    try std.testing.expectEqual(@as(u2, 1), @intFromEnum(FontStyle.bold));
    try std.testing.expectEqual(@as(u2, 2), @intFromEnum(FontStyle.italic));
    try std.testing.expectEqual(@as(u2, 3), @intFromEnum(FontStyle.bold_italic));
    try std.testing.expectEqual(@as(u2, 0), @intFromEnum(TextPresentation.text));
    try std.testing.expectEqual(@as(u2, 1), @intFromEnum(TextPresentation.emoji));
    try std.testing.expectEqual(@as(u2, 2), @intFromEnum(TextPresentation.any));
}
