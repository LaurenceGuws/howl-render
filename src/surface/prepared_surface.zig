const std = @import("std");
const geometry = @import("../geometry.zig");
const event = @import("../event.zig");
const font_resolve = @import("../text/resolver.zig");
const surface_preparer = @import("surface_preparer.zig");
const render_surface_emitter = @import("emitter.zig");

pub const PreparedInfo = struct {
    snapshot_seq: u64,
    dirty_epoch: u64,
    geometry_epoch: u64,
    required_base_seq: u64,
    render_px: geometry.PixelSize,
    cell_px: geometry.CellSize,
    grid: geometry.GridSize,
    damage_kind: u8,
};

pub const PreparedBuffer = struct {
    uploads_required: u64,
};

pub const PreparedSurface = struct {
    allocator: std.mem.Allocator,
    request: event.RenderRequest,
    geometry_epoch: u64,
    render_px: geometry.PixelSize,
    cell_px: geometry.CellSize,
    grid: geometry.GridSize,
    text_surface: surface_preparer.OwnedPreparedTextSurface,
    resolve: font_resolve.ResolveObservability = .{},
    render_surface_emission_failure: render_surface_emitter.RenderSurfaceEmissionFailure = .none,

    pub fn deinit(self: *PreparedSurface) void {
        self.text_surface.deinit();
        self.* = undefined;
    }

    pub fn damageKind(self: *const PreparedSurface) event.DamageKind {
        self.assertValid();
        if (self.text_surface.scene.scene.full_redraw) return .full;
        return .partial;
    }

    pub fn preparedSurfaceToken(self: *const PreparedSurface) event.PreparedSurfaceToken {
        self.assertValid();
        const damage_kind = self.damageKind();
        const damage_base_seq = if (damage_kind == .partial)
            self.request.token.damage_base_seq
        else
            0;
        if (damage_kind == .partial) {
            std.debug.assert(damage_base_seq != 0);
        } else {
            std.debug.assert(self.request.token.damage_base_seq == 0);
        }
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

    pub fn info(self: *const PreparedSurface) PreparedInfo {
        self.assertValid();
        return .{
            .snapshot_seq = self.request.token.snapshot_seq,
            .dirty_epoch = self.request.token.dirty_epoch,
            .geometry_epoch = self.geometry_epoch,
            .required_base_seq = self.preparedSurfaceToken().required_base_seq,
            .render_px = self.render_px,
            .cell_px = self.cell_px,
            .grid = self.grid,
            .damage_kind = @intFromEnum(self.damageKind()),
        };
    }

    pub fn buffer(self: *const PreparedSurface) PreparedBuffer {
        self.assertValid();
        return .{
            .uploads_required = self.text_surface.raster_plan.outputs.len,
        };
    }

    fn assertValid(self: *const PreparedSurface) void {
        std.debug.assert(self.render_px.width > 0);
        std.debug.assert(self.render_px.height > 0);
        std.debug.assert(self.cell_px.width > 0);
        std.debug.assert(self.cell_px.height > 0);
        std.debug.assert(self.grid.cols > 0);
        std.debug.assert(self.grid.rows > 0);
    }
};

test "prepared surface owner stays separate from geometry" {
    const pixels = geometry.SurfacePixels{
        .render_width = 0,
        .render_height = -2,
        .grid_width = 80,
        .grid_height = 24,
    };
    try std.testing.expectEqual(@as(u16, 1), pixels.renderWidth());
    try std.testing.expect(@This().PreparedSurface != geometry.SurfacePixels);
}
