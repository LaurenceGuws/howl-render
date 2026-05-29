const std = @import("std");

pub const SourceRgb = struct {
    r: u8,
    g: u8,
    b: u8,
};

pub const SourceColor = struct {
    kind: u8,
    value: u32,
};

pub const SourceColors = struct {
    foreground: SourceRgb,
    background: SourceRgb,
    cursor: SourceRgb,
    palette: [256]SourceRgb,
};

pub const SourceCellFlags = struct {
    continuation: u8,
};

pub const SourceCellAttrs = struct {
    bold: u8,
    dim: u8,
    italic: u8,
    underline: u8,
    underline_color_set: u8,
    blink: u8,
    inverse: u8,
    invisible: u8,
    strikethrough: u8,
    selected: u8,
};

pub const SourceCell = struct {
    codepoint: u32,
    combining_len: u8 = 0,
    combining: [3]u32 = [_]u32{0} ** 3,
    flags: SourceCellFlags,
    fg_color: SourceColor,
    bg_color: SourceColor,
    underline_color: SourceColor,
    underline_style: u8,
    attrs: SourceCellAttrs,
    link_id: u32,
};

pub const SourceSelectionPoint = struct {
    row: i32,
    col: u16,
};

pub const SourceSelection = struct {
    active: u8,
    selecting: u8,
    start: SourceSelectionPoint,
    end: SourceSelectionPoint,
};

comptime {
    std.debug.assert(@sizeOf(SourceColor) == 8);
    std.debug.assert(@sizeOf(SourceRgb) == 3);
    std.debug.assert(@sizeOf(SourceColors) == 777);
}
