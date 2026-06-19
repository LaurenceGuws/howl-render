const std = @import("std");
const cell_input = @import("../cell/input.zig");
const color = @import("../cell/color.zig");
const effects = @import("../cell/effects.zig");
const metrics = @import("../text/metrics.zig");
const cursor_presentation = @import("../cursor/presentation.zig");

pub const Rgba8 = color.Rgba8;
pub const SemanticColorKind = color.SemanticColorKind;
pub const SemanticColor = color.SemanticColor;
pub const UnderlineStyle = effects.UnderlineStyle;
pub const FontStyle = effects.FontStyle;
pub const TextPresentation = effects.TextPresentation;
pub const DecorationKind = effects.DecorationKind;
pub const FontMetrics = metrics.FontMetrics;
pub const FaceMetrics26Dot6 = metrics.FaceMetrics26Dot6;
pub const DecorationGeometry = metrics.DecorationGeometry;
pub const CursorGeometry = metrics.CursorGeometry;
pub const CellMetrics = metrics.CellMetrics;
pub const GridMetrics = metrics.GridMetrics;
pub const CellInput = cell_input.CellInput;
pub const max_extra_cursors = cursor_presentation.max_extra_cursors;
pub const max_cursor_trail_rects = cursor_presentation.max_cursor_trail_rects;
pub const CursorColor = cursor_presentation.CursorColor;
pub const Rgb8 = cursor_presentation.Rgb8;
pub const CellExtent = cursor_presentation.CellExtent;
pub const CursorShape = cursor_presentation.CursorShape;
pub const ExtraCursorMode = cursor_presentation.ExtraCursorMode;
pub const ExtraCursorPresentation = cursor_presentation.ExtraCursorPresentation;
pub const CursorTrailRect = cursor_presentation.CursorTrailRect;
pub const CursorTrailSource = cursor_presentation.CursorTrailSource;
pub const CursorPresentation = cursor_presentation.CursorPresentation;

pub const FontFaceId = struct {
    value: u32,
};

pub const CellTextId = struct {
    value: u32,
};

pub const SpriteKey = struct {
    value: u64,
};

pub const CellText = struct {
    id: CellTextId,
    first_cp: u32,
    codepoints: []const u32,
};

pub const LineTextCache = struct {
    texts: []const CellText = &.{},
};

pub const RenderableCell = struct {
    text_id: CellTextId,
    first_cell: u32,
    cell_span: u8,
    style: effects.FontStyle,
    presentation: effects.TextPresentation,
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
};

pub const CellCluster = struct {
    text_id: CellTextId,
    first_cell: u32,
    cell_span: u8,
    first_cp: u32,
    style: effects.FontStyle,
    presentation: effects.TextPresentation,
};

pub const RunFont = struct {
    face_id: FontFaceId,
    style: effects.FontStyle,
    presentation: effects.TextPresentation,
    scale: u8 = 1,
    subscale_n: u8 = 0,
    subscale_d: u8 = 0,
    multicell_y: u8 = 0,
    alignment: u8 = 0,
};

pub const TextRun = struct {
    cluster_start: u32,
    cluster_count: u32,
    font: RunFont,
};

pub const ResolvedRun = struct {
    run: TextRun,
    features_id: u32 = 0,
};

pub const GlyphInstance = struct {
    face_id: FontFaceId,
    glyph_id: u32,
    cluster_index: u32,
    x_offset_px: f32 = 0,
    y_offset_px: f32 = 0,
    x_advance_px: f32 = 0,
};

pub const GlyphPlacement = struct {
    x_offset_px: f32 = 0,
    y_offset_px: f32 = 0,
    advance_px: f32 = 0,
};

pub const GlyphGroupKind = enum(u3) {
    normal,
    ligature,
    icon,
    emoji,
    box_fallback,
    missing,
};

pub const GlyphGroup = struct {
    first_cell: u32,
    first_cp: u32 = 0,
    cell_span: u8,
    glyphs: []const GlyphInstance,
    placement: GlyphPlacement = .{},
    sprite_key: SpriteKey,
    kind: GlyphGroupKind,
};

pub const SpriteColorMode = enum(u2) {
    alpha,
    color,
};

pub const SpritePosition = struct {
    slot: u32,
    key: SpriteKey,
    rendered: bool = false,
    colored: bool = false,
};

pub const TextSpriteDraw = struct {
    sprite: SpritePosition,
    x_px: i32,
    y_px: i32,
    width_px: u16,
    height_px: u16,
    placement: GlyphPlacement = .{},
    color: color.Rgba8,
    first_cell: u32,
    cell_span: u8,
};

pub const TextBackgroundDraw = struct {
    x_px: i32,
    y_px: i32,
    width_px: u16,
    height_px: u16,
    color: color.Rgba8,
    first_cell: u32,
    cell_span: u8,
};

pub const TextClearDraw = struct {
    x_px: i32,
    y_px: i32,
    width_px: u16,
    height_px: u16,
    color: color.Rgba8,
    first_cell: u32,
    cell_span: u8,
};

pub const TextCursorDraw = struct {
    x_px: i32,
    y_px: i32,
    width_px: u16,
    height_px: u16,
    color: color.Rgba8,
};

pub const TextDecorationDraw = struct {
    kind: effects.DecorationKind,
    x_px: i32,
    y_px: i32,
    width_px: u16,
    height_px: u16,
    color: color.Rgba8,
    first_cell: u32,
    cell_span: u8,
};

pub const SpriteRasterKind = enum(u2) {
    glyph,
    undercurl,
};

pub const DecorationSpriteRaster = struct {
    stroke_px: u16 = 1,
    amplitude_px: u16 = 2,
    period_px: u16 = 8,
    y_px: u16 = 0,
};

pub const BoxDrawingRasterMetrics = struct {
    light_stroke_px: u16 = 1,
    heavy_stroke_px: u16 = 2,
};

pub const SpriteRasterRequest = struct {
    kind: SpriteRasterKind = .glyph,
    key: SpriteKey,
    group: GlyphGroup,
    decoration: DecorationSpriteRaster = .{},
    box_drawing: BoxDrawingRasterMetrics = .{},
    placement: GlyphPlacement = .{},
    width_px: u16,
    height_px: u16,
    baseline_px: i16 = 0,
    color_mode: SpriteColorMode = .alpha,
};

pub const TextScene = struct {
    full_redraw: bool = true,
    clear_draws: []const TextClearDraw = &.{},
    background_draws: []const TextBackgroundDraw = &.{},
    sprite_draws: []const TextSpriteDraw,
    decoration_draws: []const TextDecorationDraw = &.{},
    cursor_draws: []const TextCursorDraw = &.{},
    raster_requests: []const SpriteRasterRequest = &.{},
    missing: []const MissingGlyph,
};

pub const SpecialSpriteRoute = enum(u3) {
    blank,
    box,
    block,
    braille,
    powerline,
    legacy_computing,
};

pub const TextCluster = struct {
    grapheme_utf8: []const u8,
    first_cp: u32,
    presentation: ?effects.TextPresentation = null,
    style: effects.FontStyle = .regular,
    cell_span: u8 = 1,
};

pub const ShapedGlyph = struct {
    glyph_id: u32,
    atlas_key: u64,
    x_offset_px: f32,
    y_offset_px: f32,
    x_advance_px: f32,
    face_id: u32,
};

pub const ShapedRun = struct {
    cluster_start: u32,
    cluster_count: u32,
    glyphs: []const ShapedGlyph,
};

pub const MissingGlyphReason = enum(u3) {
    unresolved_codepoint,
    style_unavailable,
    no_fallback_face,
    shaping_failed,
    raster_failed,
};

pub const MissingGlyph = struct {
    codepoint: u32,
    style: effects.FontStyle,
    presentation: effects.TextPresentation,
    reason: MissingGlyphReason,
};

test "grid scene defaults stay deterministic" {
    const cluster = TextCluster{ .grapheme_utf8 = "a", .first_cp = 97 };
    try std.testing.expectEqual(@as(u8, 1), cluster.cell_span);
    const text = CellText{ .id = .{ .value = 1 }, .first_cp = 'A', .codepoints = &.{'A'} };
    try std.testing.expectEqual(@as(u32, 'A'), text.codepoints[0]);
}

test "text scene draw spans retain first cell and cell span facts" {
    const rgba = color.Rgba8{ .r = 1, .g = 2, .b = 3, .a = 255 };
    const sprite = TextSpriteDraw{
        .sprite = .{ .slot = 3, .key = .{ .value = 9 } },
        .x_px = 0,
        .y_px = 0,
        .width_px = 8,
        .height_px = 16,
        .color = rgba,
        .first_cell = 5,
        .cell_span = 2,
    };
    const background = TextBackgroundDraw{ .x_px = 0, .y_px = 0, .width_px = 8, .height_px = 16, .color = rgba, .first_cell = 5, .cell_span = 2 };
    const clear = TextClearDraw{ .x_px = 0, .y_px = 0, .width_px = 8, .height_px = 16, .color = rgba, .first_cell = 5, .cell_span = 2 };
    const decoration = TextDecorationDraw{ .kind = .underline, .x_px = 0, .y_px = 0, .width_px = 8, .height_px = 1, .color = rgba, .first_cell = 5, .cell_span = 2 };
    const scene = TextScene{ .sprite_draws = &.{sprite}, .missing = &.{} };

    try std.testing.expectEqual(@as(u32, 5), scene.sprite_draws[0].first_cell);
    try std.testing.expectEqual(@as(u8, 2), scene.sprite_draws[0].cell_span);
    try std.testing.expectEqual(@as(u32, 5), background.first_cell);
    try std.testing.expectEqual(@as(u8, 2), background.cell_span);
    try std.testing.expectEqual(@as(u32, 5), clear.first_cell);
    try std.testing.expectEqual(@as(u8, 2), clear.cell_span);
    try std.testing.expectEqual(@as(u32, 5), decoration.first_cell);
    try std.testing.expectEqual(@as(u8, 2), decoration.cell_span);
}
