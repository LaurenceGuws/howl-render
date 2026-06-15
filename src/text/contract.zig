const std = @import("std");

const cell_input = @import("cell_input.zig");
const color = @import("color.zig");
const effects = @import("effects.zig");
const metrics = @import("metrics.zig");
const scene_contract = @import("scene_contract.zig");
const cursor_presentation = @import("../vt_publication/cursor.zig");

pub const Rgba8 = color.Rgba8;
pub const SemanticColorKind = color.SemanticColorKind;
pub const SemanticColor = color.SemanticColor;

pub const UnderlineStyle = effects.UnderlineStyle;
pub const BackendCaps = effects.BackendCaps;
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
pub const CursorColor = cursor_presentation.CursorColor;
pub const Rgb8 = cursor_presentation.Rgb8;
pub const CellExtent = cursor_presentation.CellExtent;
pub const CursorShape = cursor_presentation.CursorShape;
pub const ExtraCursorMode = cursor_presentation.ExtraCursorMode;
pub const ExtraCursorPresentation = cursor_presentation.ExtraCursorPresentation;
pub const CursorTrailRect = cursor_presentation.CursorTrailRect;
pub const CursorTrailSource = cursor_presentation.CursorTrailSource;
pub const CursorPresentation = cursor_presentation.CursorPresentation;

pub const FontFaceId = scene_contract.FontFaceId;
pub const CellTextId = scene_contract.CellTextId;
pub const SpriteKey = scene_contract.SpriteKey;
pub const CellText = scene_contract.CellText;
pub const LineTextCache = scene_contract.LineTextCache;
pub const RenderableCell = scene_contract.RenderableCell;
pub const CellCluster = scene_contract.CellCluster;
pub const RunFont = scene_contract.RunFont;
pub const TextRun = scene_contract.TextRun;
pub const ResolvedRun = scene_contract.ResolvedRun;
pub const GlyphInstance = scene_contract.GlyphInstance;
pub const GlyphPlacement = scene_contract.GlyphPlacement;
pub const GlyphGroupKind = scene_contract.GlyphGroupKind;
pub const GlyphGroup = scene_contract.GlyphGroup;
pub const SpriteColorMode = scene_contract.SpriteColorMode;
pub const SpritePosition = scene_contract.SpritePosition;
pub const TextSpriteDraw = scene_contract.TextSpriteDraw;
pub const TextBackgroundDraw = scene_contract.TextBackgroundDraw;
pub const TextClearDraw = scene_contract.TextClearDraw;
pub const TextCursorDraw = scene_contract.TextCursorDraw;
pub const TextDecorationDraw = scene_contract.TextDecorationDraw;
pub const SpriteRasterKind = scene_contract.SpriteRasterKind;
pub const DecorationSpriteRaster = scene_contract.DecorationSpriteRaster;
pub const BoxDrawingRasterMetrics = scene_contract.BoxDrawingRasterMetrics;
pub const SpriteRasterRequest = scene_contract.SpriteRasterRequest;
pub const TextScene = scene_contract.TextScene;
pub const SpecialSpriteRoute = scene_contract.SpecialSpriteRoute;
pub const TextCluster = scene_contract.TextCluster;
pub const ShapedGlyph = scene_contract.ShapedGlyph;
pub const ShapedRun = scene_contract.ShapedRun;
pub const MissingGlyphReason = scene_contract.MissingGlyphReason;
pub const MissingGlyph = scene_contract.MissingGlyph;

test "contract root re-exports owner modules only" {
    const cell = CellInput{ .codepoint = 'a', .fg = .{ .r = 1, .g = 2, .b = 3, .a = 255 }, .bg = .{ .r = 4, .g = 5, .b = 6, .a = 255 } };
    cell.assertValid();
    const scene = TextScene{ .sprite_draws = &.{}, .missing = &.{} };
    try std.testing.expect(scene.full_redraw);
}
