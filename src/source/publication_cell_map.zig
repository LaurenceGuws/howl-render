const std = @import("std");
const source_cell = @import("cell.zig");
const source_vt = @import("vt.zig");
const contract = @import("../text/contract.zig");
const scene = @import("../text/scene.zig");

pub const FrameTheme = struct {
    default_fg: contract.Rgba8,
    default_bg: contract.Rgba8,
    cursor_color: contract.Rgba8,
    palette: [256]contract.Rgba8,
};

pub const CellSemanticTruth = struct {
    default_fg: bool,
    default_bg: bool,
    empty: bool,
};

const publication_color_kind_max: u8 = 2;

pub fn themeFromPublicationColors(colors: source_vt.SourceColors) FrameTheme {
    var palette: [256]contract.Rgba8 = undefined;
    for (colors.palette, 0..) |color, idx| palette[idx] = rgbaFromVtRgb(color);
    return .{
        .default_fg = rgbaFromVtRgb(colors.foreground),
        .default_bg = rgbaFromVtRgb(colors.background),
        .cursor_color = rgbaFromVtRgb(colors.cursor),
        .palette = palette,
    };
}

pub fn mapPublicationCellInput(src: source_vt.SourceCell, t: FrameTheme) contract.CellInput {
    std.debug.assert(src.combining_len <= src.combining.len);
    const truth = publicationCellTruth(src);
    assertSemanticEmptyTruth(truth);
    const semantic_fg = semanticColorFromPublicationColor(src.fg_color);
    const semantic_bg = semanticColorFromPublicationColor(src.bg_color);
    const semantic_underline_color = semanticColorFromPublicationColor(src.underline_color);
    const bg = publicationColorToTextSceneRgba8(src.bg_color, false, t);
    var out: contract.CellInput = .{
        .codepoint = @intCast(src.codepoint),
        .combining_len = src.combining_len,
        .combining = src.combining,
        .style = mapFontStyle(src.attrs.bold != 0, src.attrs.italic != 0),
        .presentation = detectCellPresentation(@intCast(src.codepoint), src.combining_len, src.combining),
        .semantic_fg = semantic_fg,
        .semantic_bg = semantic_bg,
        .fg = publicationColorToTextSceneRgba8(src.fg_color, true, t),
        .bg = bg,
        .underline_color_set = src.attrs.underline_color_set != 0,
        .semantic_underline_color = semantic_underline_color,
        .underline_color = if (src.attrs.underline_color_set != 0) publicationColorToTextSceneRgba8(src.underline_color, true, t) else .{ .r = 0, .g = 0, .b = 0, .a = 0 },
        .underline_style = publicationUnderlineStyle(src.underline_style),
        .underline = src.attrs.underline != 0,
        .strikethrough = src.attrs.strikethrough != 0,
        .continuation = src.flags.continuation != 0,
        .empty = truth.empty,
    };
    assertSemanticEmptyClassification(truth, t, out.bg, out.empty);
    if (src.attrs.inverse != 0) applyInverseStyle(&out, t, truth);
    if (src.attrs.dim != 0) applyDimStyle(&out);
    if (src.attrs.selected != 0) applySelectionStyle(&out, t, truth);
    if (src.attrs.invisible != 0) applyInvisibleStyle(&out);
    return out;
}

pub fn vtCellTruth(src: source_cell.Cell) CellSemanticTruth {
    std.debug.assert(src.combining_len <= src.combining.len);
    const default_fg = src.fg_color.kind == .default;
    const default_bg = src.bg_color.kind == .default;
    const blank = src.codepoint == ' ' or src.codepoint == '\t';
    const visible_flags = src.flags.continuation or src.attrs.inverse or src.attrs.underline or src.attrs.strikethrough;
    return .{
        .default_fg = default_fg,
        .default_bg = default_bg,
        .empty = blank and src.combining_len == 0 and default_fg and default_bg and !visible_flags,
    };
}

pub fn publicationCellTruth(src: source_vt.SourceCell) CellSemanticTruth {
    std.debug.assert(src.combining_len <= src.combining.len);
    const default_fg = src.fg_color.kind == 0;
    const default_bg = src.bg_color.kind == 0;
    const blank = src.codepoint == ' ' or src.codepoint == '\t';
    const visible_flags = src.flags.continuation != 0 or src.attrs.inverse != 0 or src.attrs.underline != 0 or src.attrs.strikethrough != 0;
    return .{
        .default_fg = default_fg,
        .default_bg = default_bg,
        .empty = blank and src.combining_len == 0 and default_fg and default_bg and !visible_flags,
    };
}

pub fn applyInverseStyle(cell: *contract.CellInput, t: FrameTheme, truth: CellSemanticTruth) void {
    const fg = if (truth.default_fg) t.default_fg else cell.fg;
    const bg = if (truth.default_bg) t.default_bg else cell.bg;
    cell.fg = bg;
    cell.bg = fg;
    cell.empty = false;

    if (truth.default_bg) std.debug.assert(std.meta.eql(cell.fg, t.default_bg));
}

pub fn applySelectionStyle(cell: *contract.CellInput, t: FrameTheme, truth: CellSemanticTruth) void {
    cell.fg = t.default_bg;
    cell.bg = t.default_fg;
    cell.empty = false;

    if (truth.default_bg) std.debug.assert(std.meta.eql(cell.fg, t.default_bg));
}

pub fn mapPublicationCursor(source: source_vt.PublicationSource, t: FrameTheme) ?scene.CursorInput {
    const cursor_visible = source.cursor.visible and (!source.cursor.blink or source.cursor_phase_visible);
    return if (cursor_visible) .{
        .cell_col = source.cursor.col,
        .cell_row = source.cursor.row,
        .shape = mapTextSceneCursorShape(source.cursor.shape),
        .color = t.cursor_color,
        .blink = source.cursor.blink,
    } else null;
}

fn rgbaFromVtRgb(color: source_vt.SourceRgb) contract.Rgba8 {
    return .{ .r = color.r, .g = color.g, .b = color.b, .a = 255 };
}

fn indexed256(idx: u8, t: FrameTheme) contract.Rgba8 {
    return t.palette[idx];
}

fn colorToRgba8(color: anytype, is_fg: bool, t: FrameTheme) contract.Rgba8 {
    return switch (color.kind) {
        0 => if (is_fg) t.default_fg else t.default_bg,
        1 => indexed256(@intCast(color.value & 0xFF), t),
        2 => .{
            .r = @intCast((color.value >> 16) & 0xFF),
            .g = @intCast((color.value >> 8) & 0xFF),
            .b = @intCast(color.value & 0xFF),
            .a = 255,
        },
        else => unreachable,
    };
}

fn publicationColorToTextSceneRgba8(color: source_vt.SourceColor, is_fg: bool, t: FrameTheme) contract.Rgba8 {
    return colorToRgba8(color, is_fg, t);
}

fn semanticColorFromPublicationColor(color: source_vt.SourceColor) contract.SemanticColor {
    std.debug.assert(color.kind <= publication_color_kind_max);
    return switch (color.kind) {
        0 => .{ .kind = .default },
        1 => .{ .kind = .indexed, .value = color.value & 0xFF },
        2 => .{ .kind = .rgb, .value = color.value & 0xFFFFFF },
        else => unreachable,
    };
}

fn mapFontStyle(bold: bool, italic: bool) contract.FontStyle {
    if (bold and italic) return .bold_italic;
    if (bold) return .bold;
    if (italic) return .italic;
    return .regular;
}

fn publicationUnderlineStyle(value: u8) contract.UnderlineStyle {
    return switch (value) {
        1 => .double,
        2 => .curly,
        3 => .dotted,
        4 => .dashed,
        else => .straight,
    };
}

fn applyDimStyle(cell: *contract.CellInput) void {
    cell.fg.r = @intCast(@as(u16, cell.fg.r) / 2);
    cell.fg.g = @intCast(@as(u16, cell.fg.g) / 2);
    cell.fg.b = @intCast(@as(u16, cell.fg.b) / 2);
}

fn applyInvisibleStyle(cell: *contract.CellInput) void {
    cell.fg = .{ .r = 0, .g = 0, .b = 0, .a = 0 };
}

fn detectCellPresentation(codepoint: u21, combining_len: u8, combining: [3]u32) contract.TextPresentation {
    _ = codepoint;
    std.debug.assert(combining_len <= combining.len);
    for (combining[0..combining_len]) |cp| {
        if (cp == 0xFE0F) return .emoji;
        if (cp == 0xFE0E) return .text;
    }
    return .any;
}

fn assertSemanticEmptyTruth(truth: CellSemanticTruth) void {
    if (truth.empty) std.debug.assert(truth.default_fg);
    if (truth.empty) std.debug.assert(truth.default_bg);
}

pub fn assertSemanticEmptyClassification(truth: CellSemanticTruth, t: FrameTheme, bg: contract.Rgba8, empty: bool) void {
    std.debug.assert(empty == truth.empty);
    if (truth.empty) std.debug.assert(std.meta.eql(bg, t.default_bg));
    if (truth.empty) std.debug.assert(bg.a == 255);
}

fn mapTextSceneCursorShape(shape: anytype) scene.CursorShape {
    const name = @tagName(shape);
    if (std.mem.eql(u8, name, "underline")) return .underline;
    if (std.mem.eql(u8, name, "beam")) return .beam;
    if (std.mem.eql(u8, name, "hollow_block")) return .hollow_block;
    return .block;
}

test "publication cell map keeps opaque default background for ordinary cell" {
    const theme = FrameTheme{
        .default_fg = .{ .r = 0xAA, .g = 0xBB, .b = 0xCC, .a = 255 },
        .default_bg = .{ .r = 0x11, .g = 0x22, .b = 0x33, .a = 255 },
        .cursor_color = .{ .r = 0, .g = 0, .b = 0, .a = 255 },
        .palette = [_]contract.Rgba8{.{ .r = 0, .g = 0, .b = 0, .a = 255 }} ** 256,
    };
    const mapped = mapPublicationCellInput(.{
        .codepoint = 'A',
        .flags = .{ .continuation = 0 },
        .fg_color = .{ .kind = 0, .value = 0 },
        .bg_color = .{ .kind = 0, .value = 0 },
        .underline_color = .{ .kind = 0, .value = 0 },
        .underline_style = 0,
        .attrs = .{ .bold = 0, .dim = 0, .italic = 0, .underline = 0, .underline_color_set = 0, .blink = 0, .inverse = 0, .invisible = 0, .strikethrough = 0, .selected = 0 },
        .link_id = 0,
    }, theme);

    try std.testing.expectEqual(theme.default_bg.r, mapped.bg.r);
    try std.testing.expectEqual(theme.default_bg.g, mapped.bg.g);
    try std.testing.expectEqual(theme.default_bg.b, mapped.bg.b);
    try std.testing.expectEqual(@as(u8, 255), mapped.bg.a);
    try std.testing.expect(!mapped.empty);
    try std.testing.expectEqual(contract.SemanticColorKind.default, mapped.semantic_fg.kind);
    try std.testing.expectEqual(contract.SemanticColorKind.default, mapped.semantic_bg.kind);
}

test "publication cell map keeps default background truth through inverse and selection" {
    const theme = FrameTheme{
        .default_fg = .{ .r = 0xA1, .g = 0xB2, .b = 0xC3, .a = 255 },
        .default_bg = .{ .r = 0x11, .g = 0x22, .b = 0x33, .a = 255 },
        .cursor_color = .{ .r = 0, .g = 0, .b = 0, .a = 255 },
        .palette = [_]contract.Rgba8{.{ .r = 0, .g = 0, .b = 0, .a = 255 }} ** 256,
    };

    const inverse = mapPublicationCellInput(.{
        .codepoint = 'I',
        .flags = .{ .continuation = 0 },
        .fg_color = .{ .kind = 0, .value = 0 },
        .bg_color = .{ .kind = 0, .value = 0 },
        .underline_color = .{ .kind = 0, .value = 0 },
        .underline_style = 0,
        .attrs = .{ .bold = 0, .dim = 0, .italic = 0, .underline = 0, .underline_color_set = 0, .blink = 0, .inverse = 1, .invisible = 0, .strikethrough = 0, .selected = 0 },
        .link_id = 0,
    }, theme);
    try std.testing.expectEqual(theme.default_bg.r, inverse.fg.r);
    try std.testing.expectEqual(theme.default_bg.g, inverse.fg.g);
    try std.testing.expectEqual(theme.default_bg.b, inverse.fg.b);
    try std.testing.expectEqual(theme.default_fg.r, inverse.bg.r);
    try std.testing.expectEqual(theme.default_fg.g, inverse.bg.g);
    try std.testing.expectEqual(theme.default_fg.b, inverse.bg.b);
    try std.testing.expectEqual(@as(u8, 255), inverse.bg.a);
    try std.testing.expect(!inverse.empty);

    const selected = mapPublicationCellInput(.{
        .codepoint = 'S',
        .flags = .{ .continuation = 0 },
        .fg_color = .{ .kind = 0, .value = 0 },
        .bg_color = .{ .kind = 0, .value = 0 },
        .underline_color = .{ .kind = 0, .value = 0 },
        .underline_style = 0,
        .attrs = .{ .bold = 0, .dim = 0, .italic = 0, .underline = 0, .underline_color_set = 0, .blink = 0, .inverse = 0, .invisible = 0, .strikethrough = 0, .selected = 1 },
        .link_id = 0,
    }, theme);
    try std.testing.expectEqual(theme.default_bg.r, selected.fg.r);
    try std.testing.expectEqual(theme.default_bg.g, selected.fg.g);
    try std.testing.expectEqual(theme.default_bg.b, selected.fg.b);
    try std.testing.expectEqual(theme.default_fg.r, selected.bg.r);
    try std.testing.expectEqual(theme.default_fg.g, selected.bg.g);
    try std.testing.expectEqual(theme.default_fg.b, selected.bg.b);
    try std.testing.expectEqual(@as(u8, 255), selected.bg.a);
    try std.testing.expect(!selected.empty);
}
