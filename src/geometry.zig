const std = @import("std");
pub const CellSize = struct {
    width: u16,
    height: u16,
};

pub const PixelSize = struct {
    width: u16,
    height: u16,
};

pub const GridSize = struct {
    cols: u16,
    rows: u16,
};

pub const SurfacePixels = struct {
    render_width: i32,
    render_height: i32,
    grid_width: i32,
    grid_height: i32,

    pub fn renderWidth(self: SurfacePixels) u16 {
        return @intCast(@max(self.render_width, 1));
    }

    pub fn renderHeight(self: SurfacePixels) u16 {
        return @intCast(@max(self.render_height, 1));
    }

    pub fn gridWidth(self: SurfacePixels) u16 {
        return @intCast(@max(self.grid_width, 1));
    }

    pub fn gridHeight(self: SurfacePixels) u16 {
        return @intCast(@max(self.grid_height, 1));
    }
};

pub const GeometryLayout = struct {
    render_px: PixelSize,
    grid_px: PixelSize,
    cell_px: CellSize,
};

pub const GeometryResponse = struct {
    changed: bool,
    render_px: PixelSize,
    grid_px: PixelSize,
    cell_px: CellSize,
    geometry_epoch: u64,
};

pub const PrepareLayout = struct {
    render_px: PixelSize,
    grid_px: PixelSize,
    cell_px: CellSize,
};

pub const SurfaceLayout = struct {
    cell_px: CellSize,
    grid: GridSize,
};

pub const Geometry = struct {
    render_px: PixelSize = .{ .width = 0, .height = 0 },
    grid_px: PixelSize = .{ .width = 0, .height = 0 },
    cell_px: CellSize = .{ .width = 0, .height = 0 },
    geometry_epoch: u64 = 0,

    pub fn sync(self: *Geometry, layout: GeometryLayout) GeometryResponse {
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

    pub fn prepareLayout(self: *const Geometry, geometry_epoch: u64) PrepareLayout {
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

pub const SurfaceGeometryError = error{
    InvalidSurfaceSize,
    InvalidGridSize,
};

pub fn deriveGridSize(grid_px: PixelSize, cell_px: CellSize) GridSize {
    const cell_w: u16 = if (cell_px.width == 0) 1 else cell_px.width;
    const cell_h: u16 = if (cell_px.height == 0) 1 else cell_px.height;
    return .{
        .cols = @max(1, @divTrunc(grid_px.width, cell_w)),
        .rows = @max(1, @divTrunc(grid_px.height, cell_h)),
    };
}

pub fn deriveGridForSurface(render_px: PixelSize, grid_px: PixelSize, cell_px: CellSize) SurfaceGeometryError!GridSize {
    if (render_px.width == 0 or render_px.height == 0) return error.InvalidSurfaceSize;
    if (grid_px.width == 0 or grid_px.height == 0) return error.InvalidGridSize;
    return deriveGridSize(grid_px, cell_px);
}

test "render surface pixel geometry clamps to drawable size" {
    const pixels = SurfacePixels{ .render_width = 0, .render_height = -2, .grid_width = 80, .grid_height = 24 };
    try std.testing.expectEqual(@as(u16, 1), pixels.renderWidth());
    try std.testing.expectEqual(@as(u16, 1), pixels.renderHeight());
    try std.testing.expectEqual(@as(u16, 80), pixels.gridWidth());
    try std.testing.expectEqual(@as(u16, 24), pixels.gridHeight());
}

test "surface geometry derives grid deterministically" {
    const grid = deriveGridSize(.{ .width = 80, .height = 48 }, .{ .width = 8, .height = 16 });
    try std.testing.expectEqual(@as(u16, 10), grid.cols);
    try std.testing.expectEqual(@as(u16, 3), grid.rows);

    const surface_grid = try deriveGridForSurface(
        .{ .width = 800, .height = 600 },
        .{ .width = 640, .height = 320 },
        .{ .width = 8, .height = 16 },
    );
    try std.testing.expectEqual(@as(u16, 80), surface_grid.cols);
    try std.testing.expectEqual(@as(u16, 20), surface_grid.rows);
}
