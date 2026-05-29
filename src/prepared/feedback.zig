const tokens = @import("../surface/tokens.zig");
const text_pipeline = @import("../text/pipeline.zig");

pub const RenderSurfaceHandle = struct {
    host_surface_id: u64,
    width: u16,
    height: u16,
};

pub const RenderMetrics = struct {
    sync_us: u64 = 0,
    copy_us: u64 = 0,
    render_us: u64 = 0,
    glyphs: u64 = 0,
    fills: u64 = 0,
    clear_fills: u64 = 0,
    background_fills: u64 = 0,
    decoration_fills: u64 = 0,
    cursor_fills: u64 = 0,
    uploads: u64 = 0,
    face_checks: u64 = 0,
    face_cache_hits: u64 = 0,
    shape_requests: u64 = 0,
    shape_cache_hits: u64 = 0,
    fallback_hits: u64 = 0,
    fallback_misses: u64 = 0,
    missing_glyphs: u64 = 0,
};

pub const RenderSurfaceFeedback = struct {
    damage_kind: tokens.DamageKind,
    uploads_committed: u64,
    resolve: text_pipeline.ResolveObservability,
    surface: RenderSurfaceHandle,
    metrics: RenderMetrics,
    render_us: u64,

    pub fn damageKind(self: RenderSurfaceFeedback) tokens.DamageKind {
        return self.damage_kind;
    }
};
