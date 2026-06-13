const std = @import("std");
const source_cell = @import("../tv_surface/cell.zig");
const source_publication = @import("../vt_publication/publication.zig");
const contract = @import("../text/contract.zig");

pub const SurfaceTheme = struct {
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

pub const default_theme = defaultTheme();

fn defaultTheme() SurfaceTheme {
    const palette = defaultPalette();
    return .{
        .default_fg = .{ .r = 204, .g = 204, .b = 204, .a = 255 },
        .default_bg = .{ .r = 0, .g = 0, .b = 0, .a = 255 },
        .cursor_color = .{ .r = 204, .g = 204, .b = 204, .a = 255 },
        .palette = palette,
    };
}

fn defaultPalette() [256]contract.Rgba8 {
    @setEvalBranchQuota(4096);
    var palette: [256]contract.Rgba8 = undefined;
    var idx: u16 = 0;
    while (idx < 256) : (idx += 1) palette[idx] = indexedDefaultColor(@intCast(idx));
    return palette;
}

fn indexedDefaultColor(idx: u8) contract.Rgba8 {
    if (idx < 16) return switch (idx) {
        0 => .{ .r = 0, .g = 0, .b = 0, .a = 255 },
        1 => .{ .r = 170, .g = 0, .b = 0, .a = 255 },
        2 => .{ .r = 0, .g = 170, .b = 0, .a = 255 },
        3 => .{ .r = 170, .g = 85, .b = 0, .a = 255 },
        4 => .{ .r = 0, .g = 0, .b = 170, .a = 255 },
        5 => .{ .r = 170, .g = 0, .b = 170, .a = 255 },
        6 => .{ .r = 0, .g = 170, .b = 170, .a = 255 },
        7 => .{ .r = 170, .g = 170, .b = 170, .a = 255 },
        8 => .{ .r = 85, .g = 85, .b = 85, .a = 255 },
        9 => .{ .r = 255, .g = 85, .b = 85, .a = 255 },
        10 => .{ .r = 85, .g = 255, .b = 85, .a = 255 },
        11 => .{ .r = 255, .g = 255, .b = 85, .a = 255 },
        12 => .{ .r = 85, .g = 85, .b = 255, .a = 255 },
        13 => .{ .r = 255, .g = 85, .b = 255, .a = 255 },
        14 => .{ .r = 85, .g = 255, .b = 255, .a = 255 },
        else => .{ .r = 255, .g = 255, .b = 255, .a = 255 },
    };
    if (idx < 232) {
        const i: u32 = idx - 16;
        const r: u8 = @intCast((i / 36) * 51);
        const g: u8 = @intCast(((i / 6) % 6) * 51);
        const b: u8 = @intCast((i % 6) * 51);
        return .{ .r = r, .g = g, .b = b, .a = 255 };
    }
    const gray: u8 = @intCast((@as(u32, idx) - 232) * 10 + 8);
    return .{ .r = gray, .g = gray, .b = gray, .a = 255 };
}

fn rgbaFromVtRgb(color: source_publication.SourceRgb) contract.Rgba8 {
    return .{ .r = color.r, .g = color.g, .b = color.b, .a = 255 };
}

fn indexed256(idx: u8, theme: SurfaceTheme) contract.Rgba8 {
    return theme.palette[idx];
}

pub fn themeFromPublicationColors(colors: source_publication.SourceColors) SurfaceTheme {
    var palette: [256]contract.Rgba8 = undefined;
    for (colors.palette, 0..) |color, idx| palette[idx] = rgbaFromVtRgb(color);
    return .{
        .default_fg = rgbaFromVtRgb(colors.foreground),
        .default_bg = rgbaFromVtRgb(colors.background),
        .cursor_color = rgbaFromVtRgb(colors.cursor),
        .palette = palette,
    };
}

pub fn mapCellColor(color: source_cell.Color, is_fg: bool, theme: SurfaceTheme) contract.Rgba8 {
    return switch (color.kind) {
        .default => if (is_fg) theme.default_fg else theme.default_bg,
        .indexed => indexed256(@intCast(color.value & 0xFF), theme),
        .rgb => .{
            .r = @intCast((color.value >> 16) & 0xFF),
            .g = @intCast((color.value >> 8) & 0xFF),
            .b = @intCast(color.value & 0xFF),
            .a = 255,
        },
    };
}

pub fn mapPublicationColor(color: source_publication.SourceColor, is_fg: bool, theme: SurfaceTheme) contract.Rgba8 {
    return switch (color.kind) {
        0 => if (is_fg) theme.default_fg else theme.default_bg,
        1 => indexed256(@intCast(color.value & 0xFF), theme),
        2 => .{
            .r = @intCast((color.value >> 16) & 0xFF),
            .g = @intCast((color.value >> 8) & 0xFF),
            .b = @intCast(color.value & 0xFF),
            .a = 255,
        },
        else => unreachable,
    };
}

pub fn semanticColorFromCellColor(color: source_cell.Color) contract.SemanticColor {
    return switch (color.kind) {
        .default => .{ .kind = .default },
        .indexed => .{ .kind = .indexed, .value = color.value & 0xFF },
        .rgb => .{ .kind = .rgb, .value = color.value & 0xFFFFFF },
    };
}

pub fn semanticColorFromPublicationColor(color: source_publication.SourceColor) contract.SemanticColor {
    std.debug.assert(color.kind <= publication_color_kind_max);
    return switch (color.kind) {
        0 => .{ .kind = .default },
        1 => .{ .kind = .indexed, .value = color.value & 0xFF },
        2 => .{ .kind = .rgb, .value = color.value & 0xFFFFFF },
        else => unreachable,
    };
}

pub fn mapUnderlineStyle(style: source_cell.UnderlineStyle) contract.UnderlineStyle {
    return switch (style) {
        .straight => .straight,
        .double => .double,
        .curly => .curly,
        .dotted => .dotted,
        .dashed => .dashed,
    };
}

pub fn mapPublicationUnderlineStyle(value: u8) contract.UnderlineStyle {
    return switch (value) {
        1 => .double,
        2 => .curly,
        3 => .dotted,
        4 => .dashed,
        else => .straight,
    };
}

pub fn vtCellTruth(src: source_cell.Cell) CellSemanticTruth {
    std.debug.assert(src.combining_len <= src.combining.len);
    const default_fg = src.fg_color.kind == .default;
    const default_bg = src.bg_color.kind == .default;
    const blank = src.codepoint == ' ' or src.codepoint == '\t';
    const visible_flags = src.flags.continuation or src.attrs.inverse or src.attrs.underline or src.attrs.strikethrough or src.attrs.invisible;
    return .{
        .default_fg = default_fg,
        .default_bg = default_bg,
        .empty = blank and src.combining_len == 0 and default_fg and default_bg and !visible_flags,
    };
}

pub fn publicationCellTruth(src: source_publication.SourceCell) CellSemanticTruth {
    std.debug.assert(src.combining_len <= src.combining.len);
    const default_fg = src.fg_color.kind == 0;
    const default_bg = src.bg_color.kind == 0;
    const blank = src.codepoint == ' ' or src.codepoint == '\t';
    const visible_flags = src.flags.continuation != 0 or src.attrs.inverse != 0 or src.attrs.underline != 0 or src.attrs.strikethrough != 0 or src.attrs.invisible != 0;
    return .{
        .default_fg = default_fg,
        .default_bg = default_bg,
        .empty = blank and src.combining_len == 0 and default_fg and default_bg and !visible_flags,
    };
}

pub fn assertSemanticEmptyClassification(truth: CellSemanticTruth, theme: SurfaceTheme, bg: contract.Rgba8, empty: bool) void {
    if (truth.empty) std.debug.assert(truth.default_fg);
    if (truth.empty) std.debug.assert(truth.default_bg);
    std.debug.assert(empty == truth.empty);
    if (truth.empty) std.debug.assert(std.meta.eql(bg, theme.default_bg));
    if (truth.empty) std.debug.assert(bg.a == 255);
}

fn assertOpaqueColor(value: contract.Rgba8) void {
    std.debug.assert(value.a == 255);
}

pub fn applyInverseStyle(cell: *contract.CellInput, theme: SurfaceTheme, truth: CellSemanticTruth) void {
    const fg = if (truth.default_fg) theme.default_fg else cell.fg;
    const bg = if (truth.default_bg) theme.default_bg else cell.bg;
    cell.fg = bg;
    cell.bg = fg;
    cell.empty = false;
    assertOpaqueColor(cell.fg);
    assertOpaqueColor(cell.bg);
    if (truth.default_bg) std.debug.assert(std.meta.eql(cell.fg, theme.default_bg));
}

pub fn applySelectionStyle(cell: *contract.CellInput, theme: SurfaceTheme, truth: CellSemanticTruth) void {
    _ = truth;
    cell.fg = theme.default_bg;
    cell.bg = theme.default_fg;
    cell.empty = false;
    assertOpaqueColor(cell.fg);
    assertOpaqueColor(cell.bg);
}

test "renderable content color keeps opaque default background for ordinary publication cell" {
    const theme = SurfaceTheme{
        .default_fg = .{ .r = 0xAA, .g = 0xBB, .b = 0xCC, .a = 255 },
        .default_bg = .{ .r = 0x11, .g = 0x22, .b = 0x33, .a = 255 },
        .cursor_color = .{ .r = 0, .g = 0, .b = 0, .a = 255 },
        .palette = [_]contract.Rgba8{.{ .r = 0, .g = 0, .b = 0, .a = 255 }} ** 256,
    };

    const truth = publicationCellTruth(.{
        .codepoint = 'A',
        .flags = .{ .continuation = 0 },
        .fg_color = .{ .kind = 0, .value = 0 },
        .bg_color = .{ .kind = 0, .value = 0 },
        .underline_color = .{ .kind = 0, .value = 0 },
        .underline_style = 0,
        .attrs = std.mem.zeroes(source_publication.SourceCellAttrs),
        .link_id = 0,
    });

    assertSemanticEmptyClassification(truth, theme, theme.default_bg, false);
    try std.testing.expectEqual(@as(u8, 255), mapPublicationColor(.{ .kind = 0, .value = 0 }, false, theme).a);
}

test "renderable content color keeps default background truth through inverse and selection" {
    const theme = SurfaceTheme{
        .default_fg = .{ .r = 0xA1, .g = 0xB2, .b = 0xC3, .a = 255 },
        .default_bg = .{ .r = 0x11, .g = 0x22, .b = 0x33, .a = 255 },
        .cursor_color = .{ .r = 0, .g = 0, .b = 0, .a = 255 },
        .palette = [_]contract.Rgba8{.{ .r = 0, .g = 0, .b = 0, .a = 255 }} ** 256,
    };
    const truth = CellSemanticTruth{ .default_fg = true, .default_bg = true, .empty = false };
    var inverse = contract.CellInput{
        .codepoint = 'I',
        .fg = theme.default_fg,
        .bg = theme.default_bg,
    };
    applyInverseStyle(&inverse, theme, truth);
    try std.testing.expectEqual(theme.default_bg.r, inverse.fg.r);
    try std.testing.expectEqual(theme.default_fg.r, inverse.bg.r);
    try std.testing.expectEqual(@as(u8, 255), inverse.fg.a);
    try std.testing.expectEqual(@as(u8, 255), inverse.bg.a);

    var selected = contract.CellInput{
        .codepoint = 'S',
        .fg = theme.default_fg,
        .bg = theme.default_bg,
    };
    applySelectionStyle(&selected, theme, truth);
    try std.testing.expectEqual(theme.default_bg.r, selected.fg.r);
    try std.testing.expectEqual(theme.default_fg.r, selected.bg.r);
    try std.testing.expectEqual(@as(u8, 255), selected.fg.a);
    try std.testing.expectEqual(@as(u8, 255), selected.bg.a);
}

test "renderable content color semantic empty truth does not treat continuation as empty" {
    const continuation = vtCellTruth(.{ .codepoint = ' ', .flags = .{ .continuation = true } });
    try std.testing.expect(!continuation.empty);
}
