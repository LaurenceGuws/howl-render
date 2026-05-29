const std = @import("std");

pub const Rgb8 = struct {
    r: u8,
    g: u8,
    b: u8,
};

pub const Color = struct {
    kind: u8,
    value: u32,
};

pub const RenderColorState = struct {
    foreground: Rgb8,
    background: Rgb8,
    cursor: Rgb8,
    palette: [256]Rgb8,
};

pub const CellFlags = struct {
    continuation: u8,
    reserved0: u8 = 0,
    reserved1: u8 = 0,
    reserved2: u8 = 0,
};

pub const CellAttrs = struct {
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

pub const Cell = struct {
    codepoint: u32,
    combining_len: u8 = 0,
    reserved0: u8 = 0,
    reserved1: u8 = 0,
    reserved2: u8 = 0,
    combining: [3]u32 = [_]u32{0} ** 3,
    flags: CellFlags,
    fg_color: Color,
    bg_color: Color,
    underline_color: Color,
    underline_style: u8,
    reserved3: u8 = 0,
    reserved4: u8 = 0,
    reserved5: u8 = 0,
    attrs: CellAttrs,
    link_id: u32,
};

pub const SelectionPos = struct {
    row: i32,
    col: u16,
    reserved0: u16 = 0,
};

pub const Selection = struct {
    active: u8,
    selecting: u8,
    reserved0: u16 = 0,
    start: SelectionPos,
    end: SelectionPos,
};

comptime {
    std.debug.assert(@sizeOf(Color) == 8);
    std.debug.assert(@sizeOf(Rgb8) == 3);
    std.debug.assert(@sizeOf(RenderColorState) == 777);
}
