const std = @import("std");
const surface_types = @import("../surface/types.zig");

pub const GeometryOwner = struct {
    render_px: surface_types.PixelSize = .{ .width = 0, .height = 0 },
    grid_px: surface_types.PixelSize = .{ .width = 0, .height = 0 },
    cell_px: surface_types.CellSize = .{ .width = 0, .height = 0 },
    geometry_epoch: u64 = 0,

    pub fn sync(self: *GeometryOwner, layout: surface_types.Geometry) surface_types.GeometryResponse {
        const changed = self.geometry_epoch == 0 or
            self.render_px.width != layout.render_px.width or
            self.render_px.height != layout.render_px.height or
            self.grid_px.width != layout.grid_px.width or
            self.grid_px.height != layout.grid_px.height or
            self.cell_px.width != layout.cell_px.width or
            self.cell_px.height != layout.cell_px.height;
        if (changed) {
            self.geometry_epoch +%= 1;
            self.render_px = layout.render_px;
            self.grid_px = layout.grid_px;
            self.cell_px = layout.cell_px;
        }
        return .{
            .changed = changed,
            .render_px = self.render_px,
            .grid_px = self.grid_px,
            .cell_px = self.cell_px,
            .geometry_epoch = self.geometry_epoch,
        };
    }

    pub fn prepareLayout(self: *const GeometryOwner, geometry_epoch: u64) surface_types.PrepareLayout {
        std.debug.assert(self.geometry_epoch != 0);
        std.debug.assert(self.geometry_epoch == geometry_epoch);
        std.debug.assert(self.render_px.width > 0);
        std.debug.assert(self.render_px.height > 0);
        std.debug.assert(self.cell_px.width > 0);
        std.debug.assert(self.cell_px.height > 0);
        return .{
            .render_px = self.render_px,
            .grid_px = self.grid_px,
            .cell_px = self.cell_px,
        };
    }
};
