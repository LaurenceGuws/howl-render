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

pub const FramePixels = struct {
    render_width: i32,
    render_height: i32,
    grid_width: i32,
    grid_height: i32,

    pub fn renderWidth(self: FramePixels) u16 {
        return @intCast(@max(self.render_width, 1));
    }

    pub fn renderHeight(self: FramePixels) u16 {
        return @intCast(@max(self.render_height, 1));
    }

    pub fn gridWidth(self: FramePixels) u16 {
        return @intCast(@max(self.grid_width, 1));
    }

    pub fn gridHeight(self: FramePixels) u16 {
        return @intCast(@max(self.grid_height, 1));
    }
};

pub const Geometry = struct {
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
