const std = @import("std");
const c = @import("ffi.zig").c;
const prepared_feedback = @import("prepared/feedback.zig");
const surface_text = @import("surface/text.zig");

pub fn surfaceMetricsOut(value: prepared_feedback.RenderMetrics) c.HowlRenderSurfaceMetrics {
    return .{
        .sync_us = value.sync_us,
        .copy_us = value.copy_us,
        .render_us = value.render_us,
        .glyphs = value.glyphs,
        .fills = value.fills,
        .clear_fills = value.clear_fills,
        .background_fills = value.background_fills,
        .decoration_fills = value.decoration_fills,
        .cursor_fills = value.cursor_fills,
        .uploads = value.uploads,
        .face_checks = value.face_checks,
        .face_cache_hits = value.face_cache_hits,
        .shape_requests = value.shape_requests,
        .shape_cache_hits = value.shape_cache_hits,
        .fallback_hits = value.fallback_hits,
        .fallback_misses = value.fallback_misses,
        .missing_glyphs = value.missing_glyphs,
    };
}

pub fn surfaceFeedbackOut(value: prepared_feedback.RenderSurfaceFeedback) c.HowlRenderSurfaceFeedback {
    return .{
        .status = c.HOWL_RENDER_CALL_OK,
        .damage_kind = @intFromEnum(value.damageKind()),
        .surface = .{ .host_surface_id = value.surface.host_surface_id, .width = value.surface.width, .height = value.surface.height },
        .metrics = surfaceMetricsOut(value.metrics),
    };
}

pub fn failedSurfaceFeedback() c.HowlRenderSurfaceFeedback {
    return .{
        .status = c.HOWL_RENDER_CALL_FAILED,
        .damage_kind = 0,
        .surface = .{ .host_surface_id = 0, .width = 0, .height = 0 },
        .metrics = std.mem.zeroes(c.HowlRenderSurfaceMetrics),
    };
}

pub fn executionInputIn(
    value: c.HowlRenderSurfaceExecutionInput,
) surface_text.SurfaceText.RenderSurfaceExecutionInput {
    return .{
        .surface = .{ .host_surface_id = value.surface.host_surface_id, .width = value.surface.width, .height = value.surface.height },
        .uploads_committed = value.uploads_committed,
        .render_us = value.render_us,
    };
}
