const geometry_contract = @import("../render/geometry_contract.zig");

pub const FrameGeometryError = error{
    InvalidSurfaceSize,
    InvalidGridSize,
};

pub fn deriveGridSize(
    grid_px: geometry_contract.PixelSize,
    cell_px: geometry_contract.CellSize,
) geometry_contract.GridSize {
    const cell_w: u16 = if (cell_px.width == 0) 1 else cell_px.width;
    const cell_h: u16 = if (cell_px.height == 0) 1 else cell_px.height;
    return .{
        .cols = @max(1, @divTrunc(grid_px.width, cell_w)),
        .rows = @max(1, @divTrunc(grid_px.height, cell_h)),
    };
}

pub fn deriveGridForFrame(
    render_px: geometry_contract.PixelSize,
    grid_px: geometry_contract.PixelSize,
    cell_px: geometry_contract.CellSize,
) FrameGeometryError!geometry_contract.GridSize {
    if (render_px.width == 0 or render_px.height == 0) return error.InvalidSurfaceSize;
    if (grid_px.width == 0 or grid_px.height == 0) return error.InvalidGridSize;
    return deriveGridSize(grid_px, cell_px);
}
