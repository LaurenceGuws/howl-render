const std = @import("std");
const geometry_contract = @import("../render/geometry_contract.zig");
const tokens = @import("../render/tokens.zig");
const font_resolve = @import("../text/font/resolve.zig");
const text = @import("../text/text.zig");

pub const PrepareMetrics = struct {
    sync_us: u64 = 0,
    copy_us: u64 = 0,
    us: u64 = 0,
    surface_us: u64 = 0,
    input_us: u64 = 0,
    sparse_us: u64 = 0,
    clusters_us: u64 = 0,
    resolve_us: u64 = 0,
    shape_us: u64 = 0,
    group_us: u64 = 0,
    scene_us: u64 = 0,
    raster_us: u64 = 0,
    atlas_us: u64 = 0,
};

pub const PreparedSurface = struct {
    allocator: std.mem.Allocator,
    request: tokens.RenderRequest,
    geometry_epoch: u64,
    render_px: geometry_contract.PixelSize,
    cell_px: geometry_contract.CellSize,
    grid: geometry_contract.GridSize,
    text_frame: text.OwnedPreparedTextFrame,
    resolve: font_resolve.ResolveObservability = .{},
    prepare_metrics: PrepareMetrics = .{},

    pub fn deinit(self: *PreparedSurface) void {
        self.text_frame.deinit();
        self.* = undefined;
    }

    pub fn damageKind(self: *const PreparedSurface) tokens.DamageKind {
        if (self.text_frame.scene.scene.full_redraw) return .full;
        return .partial;
    }

    pub fn preparedSurfaceToken(self: *const PreparedSurface) tokens.PreparedSurfaceToken {
        const damage_kind = self.damageKind();
        const damage_base_seq = if (damage_kind == .partial)
            self.request.token.damage_base_seq
        else
            0;
        return .{
            .token = .{
                .snapshot_seq = self.request.token.snapshot_seq,
                .dirty_epoch = self.request.token.dirty_epoch,
                .geometry_epoch = self.geometry_epoch,
                .damage_base_seq = damage_base_seq,
                .damage_kind = damage_kind,
            },
            .required_base_seq = damage_base_seq,
        };
    }
};

test "prepared surface owner stays separate from geometry contracts" {
    const pixels = geometry_contract.FramePixels{
        .render_width = 0,
        .render_height = -2,
        .grid_width = 80,
        .grid_height = 24,
    };
    try std.testing.expectEqual(@as(u16, 1), pixels.renderWidth());
    try std.testing.expect(@This().PreparedSurface != geometry_contract.FramePixels);
}
