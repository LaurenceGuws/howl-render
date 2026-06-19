const std = @import("std");

const cell_input = @import("cell/input.zig");
const color = @import("cell/color.zig");
const effects = @import("cell/effects.zig");
const metrics = @import("text/metrics.zig");
const scene_grid = @import("grid/scene.zig");
const cursor_presentation = @import("cursor/presentation.zig");
const c = @import("howl_render_c");
const text_surface = @import("text/surface.zig");

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

pub const FontFaceId = scene_grid.FontFaceId;
pub const CellTextId = scene_grid.CellTextId;
pub const SpriteKey = scene_grid.SpriteKey;
pub const CellText = scene_grid.CellText;
pub const LineTextCache = scene_grid.LineTextCache;
pub const RenderableCell = scene_grid.RenderableCell;
pub const CellCluster = scene_grid.CellCluster;
pub const RunFont = scene_grid.RunFont;
pub const TextRun = scene_grid.TextRun;
pub const ResolvedRun = scene_grid.ResolvedRun;
pub const GlyphInstance = scene_grid.GlyphInstance;
pub const GlyphPlacement = scene_grid.GlyphPlacement;
pub const GlyphGroupKind = scene_grid.GlyphGroupKind;
pub const GlyphGroup = scene_grid.GlyphGroup;
pub const SpriteColorMode = scene_grid.SpriteColorMode;
pub const SpritePosition = scene_grid.SpritePosition;
pub const TextSpriteDraw = scene_grid.TextSpriteDraw;
pub const TextBackgroundDraw = scene_grid.TextBackgroundDraw;
pub const TextClearDraw = scene_grid.TextClearDraw;
pub const TextCursorDraw = scene_grid.TextCursorDraw;
pub const TextDecorationDraw = scene_grid.TextDecorationDraw;
pub const SpriteRasterKind = scene_grid.SpriteRasterKind;
pub const DecorationSpriteRaster = scene_grid.DecorationSpriteRaster;
pub const BoxDrawingRasterMetrics = scene_grid.BoxDrawingRasterMetrics;
pub const SpriteRasterRequest = scene_grid.SpriteRasterRequest;
pub const TextScene = scene_grid.TextScene;
pub const SpecialSpriteRoute = scene_grid.SpecialSpriteRoute;
pub const TextCluster = scene_grid.TextCluster;
pub const ShapedGlyph = scene_grid.ShapedGlyph;
pub const ShapedRun = scene_grid.ShapedRun;
pub const MissingGlyphReason = scene_grid.MissingGlyphReason;
pub const MissingGlyph = scene_grid.MissingGlyph;

export fn howl_render_text_init(out_handle: *c.HowlRenderTextHandle, config: ?*const c.HowlRenderTextConfig) c.HowlRenderCallStatus {
    const text_config = config orelse return c.HOWL_RENDER_CALL_INVALID_ARGUMENT;
    out_handle.* = null;
    const surface = text_surface.TextSurface.create(std.heap.c_allocator, text_config) catch |err| return callStatusFromError(err);
    out_handle.* = @ptrCast(surface);
    return c.HOWL_RENDER_CALL_OK;
}

export fn howl_render_text_deinit(handle: c.HowlRenderTextHandle) void {
    const surface = textSurfaceFromHandle(handle) orelse return;
    surface.destroy();
}

export fn howl_render_text_prepare(handle: c.HowlRenderTextHandle, prepare: ?*const c.HowlRenderTextPrepare, out_upload: ?*c.HowlRenderTextPreparedUpload) c.HowlRenderCallStatus {
    const surface = textSurfaceFromHandle(handle) orelse return c.HOWL_RENDER_CALL_MISSING_HANDLE;
    const prepare_value = prepare orelse return c.HOWL_RENDER_CALL_INVALID_ARGUMENT;
    const upload = out_upload orelse return c.HOWL_RENDER_CALL_INVALID_ARGUMENT;
    surface.prepare(prepare_value, upload) catch |err| return callStatusFromError(err);
    return c.HOWL_RENDER_CALL_OK;
}

export fn howl_render_text_submit(handle: c.HowlRenderTextHandle, host_surface: c.HowlRenderHostSurface, out_host_surface: ?*c.HowlRenderHostSurface) c.HowlRenderCallStatus {
    const surface = textSurfaceFromHandle(handle) orelse return c.HOWL_RENDER_CALL_MISSING_HANDLE;
    const out = out_host_surface orelse return c.HOWL_RENDER_CALL_INVALID_ARGUMENT;
    surface.submit(host_surface, out);
    return c.HOWL_RENDER_CALL_OK;
}

fn textSurfaceFromHandle(handle: c.HowlRenderTextHandle) ?*text_surface.TextSurface {
    const pointer = handle orelse return null;
    return @ptrCast(@alignCast(pointer));
}

fn callStatusFromError(err: anyerror) c.HowlRenderCallStatus {
    return switch (err) {
        error.InvalidArgument => c.HOWL_RENDER_CALL_INVALID_ARGUMENT,
        else => c.HOWL_RENDER_CALL_FAILED,
    };
}

test "render root re-exports owner modules only" {
    const cell = CellInput{ .codepoint = 'a', .fg = .{ .r = 1, .g = 2, .b = 3, .a = 255 }, .bg = .{ .r = 4, .g = 5, .b = 6, .a = 255 } };
    cell.assertValid();
    const scene = TextScene{ .sprite_draws = &.{}, .missing = &.{} };
    try std.testing.expect(scene.full_redraw);
}
