const std = @import("std");

const cell_input = @import("cell/input.zig");
const color = @import("cell/color.zig");
const effects = @import("cell/effects.zig");
const draw_primitives = @import("text/draw_primitives.zig");
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

pub const FontCellLayout = draw_primitives.FontCellLayout;
pub const FaceSize26Dot6 = draw_primitives.FaceSize26Dot6;
pub const DecorationGeometry = draw_primitives.DecorationGeometry;
pub const CursorGeometry = draw_primitives.CursorGeometry;
pub const CellLayout = draw_primitives.CellLayout;
pub const CellGrid = draw_primitives.CellGrid;

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

pub const FontFaceId = draw_primitives.FontFaceId;
pub const CellTextId = draw_primitives.CellTextId;
pub const SpriteKey = draw_primitives.SpriteKey;
pub const CellText = draw_primitives.CellText;
pub const LineTextCache = draw_primitives.LineTextCache;
pub const RenderableCell = draw_primitives.RenderableCell;
pub const CellCluster = draw_primitives.CellCluster;
pub const RunFont = draw_primitives.RunFont;
pub const TextRun = draw_primitives.TextRun;
pub const ResolvedRun = draw_primitives.ResolvedRun;
pub const GlyphInstance = draw_primitives.GlyphInstance;
pub const GlyphPlacement = draw_primitives.GlyphPlacement;
pub const GlyphGroupKind = draw_primitives.GlyphGroupKind;
pub const GlyphGroup = draw_primitives.GlyphGroup;
pub const SpriteColorMode = draw_primitives.SpriteColorMode;
pub const SpritePosition = draw_primitives.SpritePosition;
pub const TextSpriteDraw = draw_primitives.TextSpriteDraw;
pub const TextBackgroundDraw = draw_primitives.TextBackgroundDraw;
pub const TextClearDraw = draw_primitives.TextClearDraw;
pub const TextCursorDraw = draw_primitives.TextCursorDraw;
pub const TextDecorationDraw = draw_primitives.TextDecorationDraw;
pub const SpriteRasterKind = draw_primitives.SpriteRasterKind;
pub const DecorationSpriteRaster = draw_primitives.DecorationSpriteRaster;
pub const BoxDrawingStroke = draw_primitives.BoxDrawingStroke;
pub const SpriteRasterRequest = draw_primitives.SpriteRasterRequest;
pub const TextDrawList = draw_primitives.TextDrawList;
pub const SpecialSpriteRoute = draw_primitives.SpecialSpriteRoute;
pub const TextCluster = draw_primitives.TextCluster;
pub const ShapedGlyph = draw_primitives.ShapedGlyph;
pub const ShapedRun = draw_primitives.ShapedRun;
pub const MissingGlyphReason = draw_primitives.MissingGlyphReason;
pub const MissingGlyph = draw_primitives.MissingGlyph;

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

export fn howl_render_surface_layout(handle: c.HowlRenderTextHandle, surface_px: c.HowlRenderPixelSize, out_layout: ?*c.HowlRenderLayoutResponse) c.HowlRenderCallStatus {
    const surface = textSurfaceFromHandle(handle) orelse return c.HOWL_RENDER_CALL_MISSING_HANDLE;
    const layout = out_layout orelse return c.HOWL_RENDER_CALL_INVALID_ARGUMENT;
    surface.surfaceLayout(surface_px, layout) catch |err| return callStatusFromError(err);
    return c.HOWL_RENDER_CALL_OK;
}

export fn howl_render_surface_point_cell(handle: c.HowlRenderTextHandle, surface_px: c.HowlRenderPixelSize, point: c.HowlRenderSurfacePoint, out_cell: ?*c.HowlRenderSurfacePointCell) c.HowlRenderCallStatus {
    const surface = textSurfaceFromHandle(handle) orelse return c.HOWL_RENDER_CALL_MISSING_HANDLE;
    const cell = out_cell orelse return c.HOWL_RENDER_CALL_INVALID_ARGUMENT;
    surface.surfacePointCell(surface_px, point, cell) catch |err| return callStatusFromError(err);
    return c.HOWL_RENDER_CALL_OK;
}

export fn howl_render_text_prepare(handle: c.HowlRenderTextHandle, prepare: ?*const c.HowlRenderTextPrepare, out_upload: ?*c.HowlRenderTextPreparedUpload) c.HowlRenderCallStatus {
    const surface = textSurfaceFromHandle(handle) orelse return c.HOWL_RENDER_CALL_MISSING_HANDLE;
    const prepare_value = prepare orelse return c.HOWL_RENDER_CALL_INVALID_ARGUMENT;
    const upload = out_upload orelse return c.HOWL_RENDER_CALL_INVALID_ARGUMENT;
    surface.prepare(prepare_value, upload) catch |err| return callStatusFromError(err);
    return c.HOWL_RENDER_CALL_OK;
}

export fn howl_render_cell_surface_prepare(
    handle: c.HowlRenderTextHandle,
    prepare: ?*const c.HowlRenderCellSurfacePrepare,
    out_upload: ?*c.HowlRenderCellSurfacePreparedUpload,
) c.HowlRenderCallStatus {
    const surface = textSurfaceFromHandle(handle) orelse return c.HOWL_RENDER_CALL_MISSING_HANDLE;
    const prepare_value = prepare orelse return c.HOWL_RENDER_CALL_INVALID_ARGUMENT;
    const upload = out_upload orelse return c.HOWL_RENDER_CALL_INVALID_ARGUMENT;
    surface.prepareCellSurface(prepare_value, upload) catch |err| return callStatusFromError(err);
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
    const draw_list = TextDrawList{ .sprite_draws = &.{}, .missing = &.{} };
    try std.testing.expect(draw_list.full_redraw);
}
