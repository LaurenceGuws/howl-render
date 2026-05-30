const tokens = @import("../render/tokens.zig");
const font_resolve = @import("../text/font/resolve.zig");

pub const HostSurface = struct {
    host_surface_id: u64,
    width: u16,
    height: u16,
};

pub const Metrics = struct {
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

pub const SubmitResult = struct {
    damage_kind: tokens.DamageKind,
    uploads_committed: u64,
    resolve: font_resolve.ResolveObservability,
    host_surface: HostSurface,
    metrics: Metrics,
    render_us: u64,

    pub fn damageKind(self: SubmitResult) tokens.DamageKind {
        return self.damage_kind;
    }
};
