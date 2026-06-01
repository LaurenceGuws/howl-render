const std = @import("std");
const geometry_contract = @import("../render/geometry_contract.zig");
const tokens = @import("../render/tokens.zig");
const font_resolve = @import("../text/font/resolve.zig");
const text = @import("../text/text.zig");

pub const PreparedSurface = struct {
    allocator: std.mem.Allocator,
    request: tokens.RenderRequest,
    geometry_epoch: u64,
    render_px: geometry_contract.PixelSize,
    cell_px: geometry_contract.CellSize,
    grid: geometry_contract.GridSize,
    text_frame: text.OwnedPreparedTextFrame,
    resolve: font_resolve.ResolveObservability = .{},

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
