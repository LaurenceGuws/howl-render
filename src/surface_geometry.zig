const c = @import("howl_render_c");
const handle_owner = @import("handle.zig");
const geometry_contract = @import("geometry/geometry_contract.zig");

pub fn deriveLayout(value: c.HowlRenderTextSessionHandle, render_px: c.HowlRenderPixelSize, grid_px: c.HowlRenderPixelSize) callconv(.c) c.HowlRenderLayoutResult {
    const owner = handle_owner.textSessionOwner(value) orelse return layoutFailure(c.HOWL_RENDER_CALL_MISSING_HANDLE);
    const layout = owner.session.deriveLayout(
        owner.config,
        pixelIn(render_px),
        pixelIn(grid_px),
    ) catch {
        return layoutFailure(c.HOWL_RENDER_CALL_INVALID_ARGUMENT);
    };
    return .{ .status = 0, .cell_px = .{ .width = layout.cell_px.width, .height = layout.cell_px.height }, .grid = .{ .cols = layout.grid.cols, .rows = layout.grid.rows } };
}

pub fn syncGeometry(value: c.HowlRenderTextSessionHandle, geometry: c.HowlRenderGeometry) callconv(.c) c.HowlRenderGeometryResponse {
    const owner = handle_owner.textSessionOwner(value) orelse return geometryFailure(c.HOWL_RENDER_CALL_MISSING_HANDLE);
    const layout = owner.session.deriveLayout(
        owner.config,
        pixelIn(geometry.render_px),
        pixelIn(geometry.grid_px),
    ) catch {
        return geometryFailure(c.HOWL_RENDER_CALL_INVALID_ARGUMENT);
    };
    return geometryOut(owner.syncGeometry(.{
        .render_px = pixelIn(geometry.render_px),
        .grid_px = pixelIn(geometry.grid_px),
        .cell_px = layout.cell_px,
    }) catch return geometryFailure(c.HOWL_RENDER_CALL_FAILED));
}

fn layoutFailure(status: c_int) c.HowlRenderLayoutResult {
    return .{
        .status = status,
        .cell_px = .{ .width = 0, .height = 0 },
        .grid = .{ .cols = 0, .rows = 0 },
    };
}

fn geometryFailure(status: c_int) c.HowlRenderGeometryResponse {
    return .{
        .status = status,
        .changed = 0,
        .render_px = .{ .width = 0, .height = 0 },
        .grid_px = .{ .width = 0, .height = 0 },
        .cell_px = .{ .width = 0, .height = 0 },
        .geometry_epoch = 0,
    };
}

pub fn pixelIn(value: c.HowlRenderPixelSize) geometry_contract.PixelSize {
    return .{ .width = value.width, .height = value.height };
}

pub fn geometryOut(value: geometry_contract.GeometryResponse) c.HowlRenderGeometryResponse {
    return .{
        .status = c.HOWL_RENDER_CALL_OK,
        .changed = @intFromBool(value.changed),
        .render_px = .{ .width = value.render_px.width, .height = value.render_px.height },
        .grid_px = .{ .width = value.grid_px.width, .height = value.grid_px.height },
        .cell_px = .{ .width = value.cell_px.width, .height = value.cell_px.height },
        .geometry_epoch = value.geometry_epoch,
    };
}
