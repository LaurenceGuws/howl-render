const std = @import("std");
const geometry_contract = @import("../render/geometry_contract.zig");
const tokens = @import("../render/tokens.zig");
const font_resolve = @import("../text/font/resolve.zig");
const frame_preparer = @import("../text/frame_preparer.zig");
const render_surface_emitter = @import("render_surface_emitter.zig");

pub const PreparedInfo = struct {
    snapshot_seq: u64,
    dirty_epoch: u64,
    geometry_epoch: u64,
    required_base_seq: u64,
    render_px: geometry_contract.PixelSize,
    cell_px: geometry_contract.CellSize,
    grid: geometry_contract.GridSize,
    damage_kind: u8,
};

pub const PreparedBuffer = struct {
    uploads_required: u64,
};

pub const PreparedSurface = struct {
    allocator: std.mem.Allocator,
    request: tokens.RenderRequest,
    geometry_epoch: u64,
    render_px: geometry_contract.PixelSize,
    cell_px: geometry_contract.CellSize,
    grid: geometry_contract.GridSize,
    text_frame: frame_preparer.OwnedPreparedTextFrame,
    resolve: font_resolve.ResolveObservability = .{},
    render_surface_emission_failure: render_surface_emitter.RenderSurfaceEmissionFailure = .none,

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

    pub fn info(self: *const PreparedSurface) PreparedInfo {
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
        return .{
            .uploads_required = self.text_frame.raster_plan.outputs.len,
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
