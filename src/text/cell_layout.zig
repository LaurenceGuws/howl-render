const std = @import("std");

const c = @import("howl_render_c");
const layout = @import("../layout.zig");

pub const CellLayout = struct {
    cell_width_px: u16,
    cell_height_px: u16,
    baseline_px: u16,
    underline_y_px: u16,
    underline_height_px: u16,
    strikethrough_y_px: u16,
    strikethrough_height_px: u16,
    sprite_slot_height_px: u16,

    pub fn fromLegacyCellFacts(cell: anytype) CellLayout {
        std.debug.assert(cell.cell_w_px > 0);
        std.debug.assert(cell.cell_h_px > 0);
        const cell_height_px = cell.cell_h_px;
        const baseline_px: u16 = if (cell_height_px > 1) @intCast(std.math.clamp(@as(i32, cell.baseline_px), 1, @as(i32, cell_height_px - 1))) else 0;
        const decoration_height_px = @max(@min(cell.box_thickness_px, cell_height_px), 1);
        const underline_y_px = @min(cell_height_px -| 1, baseline_px +| 1);
        const strikethrough_y_px = @min(cell_height_px -| 1, @max(@divFloor(baseline_px * 2, 3), 1));
        return .{
            .cell_width_px = cell.cell_w_px,
            .cell_height_px = cell_height_px,
            .baseline_px = baseline_px,
            .underline_y_px = underline_y_px,
            .underline_height_px = decoration_height_px,
            .strikethrough_y_px = strikethrough_y_px,
            .strikethrough_height_px = decoration_height_px,
            .sprite_slot_height_px = cell_height_px +| 1,
        };
    }

    pub fn fromCellSize(cell_px: c.HowlRenderCellSize, fallback: anytype) CellLayout {
        std.debug.assert(cell_px.width > 0);
        std.debug.assert(cell_px.height > 0);
        const cell = .{
            .cell_w_px = cell_px.width,
            .cell_h_px = cell_px.height,
            .baseline_px = fallback.baseline_px,
            .box_thickness_px = fallback.box_thickness_px,
        };
        return fromLegacyCellFacts(cell);
    }

    pub fn cellSize(self: CellLayout) layout.CellSize {
        self.assertValid();
        return .{ .width = self.cell_width_px, .height = self.cell_height_px };
    }

    pub fn toC(self: CellLayout) c.HowlRenderCellLayout {
        self.assertValid();
        return .{
            .cell_px = .{ .width = self.cell_width_px, .height = self.cell_height_px },
            .baseline_px = self.baseline_px,
            .underline_y_px = self.underline_y_px,
            .underline_height_px = self.underline_height_px,
            .strikethrough_y_px = self.strikethrough_y_px,
            .strikethrough_height_px = self.strikethrough_height_px,
            .sprite_slot_height_px = self.sprite_slot_height_px,
        };
    }

    pub fn assertValid(self: CellLayout) void {
        std.debug.assert(self.cell_width_px > 0);
        std.debug.assert(self.cell_height_px > 0);
        std.debug.assert(self.baseline_px < self.cell_height_px);
        std.debug.assert(self.underline_y_px < self.cell_height_px);
        std.debug.assert(self.underline_height_px > 0);
        std.debug.assert(self.strikethrough_y_px < self.cell_height_px);
        std.debug.assert(self.strikethrough_height_px > 0);
        std.debug.assert(self.sprite_slot_height_px == self.cell_height_px + 1);
    }
};

pub const SurfaceLayout = struct {
    surface_px: layout.PixelSize,
    render_px: layout.PixelSize,
    grid_px: layout.PixelSize,
    grid: c.HowlRenderCellGrid,
    cell: CellLayout,

    pub fn init(surface_px: layout.PixelSize, cell: CellLayout) SurfaceLayout {
        cell.assertValid();
        std.debug.assert(surface_px.width > 0);
        std.debug.assert(surface_px.height > 0);
        const cols = @max(@divFloor(surface_px.width, cell.cell_width_px), 1);
        const rows = @max(@divFloor(surface_px.height, cell.cell_height_px), 1);
        const grid_px = layout.PixelSize{
            .width = cols * cell.cell_width_px,
            .height = rows * cell.cell_height_px,
        };
        return .{
            .surface_px = surface_px,
            .render_px = grid_px,
            .grid_px = grid_px,
            .grid = .{ .cols = cols, .rows = rows },
            .cell = cell,
        };
    }

    pub fn toCResponse(self: SurfaceLayout, changed: bool, layout_epoch: u64) c.HowlRenderLayoutResponse {
        self.assertValid();
        return .{
            .status = c.HOWL_RENDER_CALL_OK,
            .changed = if (changed) 1 else 0,
            .reserved0 = 0,
            .reserved1 = 0,
            .reserved2 = 0,
            .reserved3 = 0,
            .render_px = pixelSizeOut(self.render_px),
            .grid_px = pixelSizeOut(self.grid_px),
            .grid = self.grid,
            .cell_layout = self.cell.toC(),
            .layout_epoch = layout_epoch,
        };
    }

    pub fn pointCell(self: SurfaceLayout, point: c.HowlRenderTermSurfacePoint) c.HowlRenderTermSurfacePointCell {
        self.assertValid();
        const inside_x = point.x_px >= 0 and point.x_px < self.render_px.width;
        const inside_y = point.y_px >= 0 and point.y_px < self.render_px.height;
        const x_px: u16 = if (point.x_px <= 0) 0 else @intCast(@min(point.x_px, @as(i32, self.render_px.width - 1)));
        const y_px: u16 = if (point.y_px <= 0) 0 else @intCast(@min(point.y_px, @as(i32, self.render_px.height - 1)));
        const col = x_px / self.cell.cell_width_px;
        const row = y_px / self.cell.cell_height_px;
        std.debug.assert(col < self.grid.cols);
        std.debug.assert(row < self.grid.rows);
        return .{
            .status = c.HOWL_RENDER_CALL_OK,
            .inside = if (inside_x and inside_y) 1 else 0,
            .reserved0 = 0,
            .reserved1 = 0,
            .row = row,
            .col = col,
        };
    }

    pub fn assertValid(self: SurfaceLayout) void {
        self.cell.assertValid();
        std.debug.assert(self.surface_px.width > 0);
        std.debug.assert(self.surface_px.height > 0);
        std.debug.assert(self.grid.cols > 0);
        std.debug.assert(self.grid.rows > 0);
        std.debug.assert(self.grid_px.width == self.grid.cols * self.cell.cell_width_px);
        std.debug.assert(self.grid_px.height == self.grid.rows * self.cell.cell_height_px);
        std.debug.assert(self.render_px.width == self.grid_px.width);
        std.debug.assert(self.render_px.height == self.grid_px.height);
    }
};

pub fn pixelSizeIn(value: c.HowlRenderPixelSize) layout.PixelSize {
    return .{ .width = value.width, .height = value.height };
}

fn pixelSizeOut(value: layout.PixelSize) c.HowlRenderPixelSize {
    return .{ .width = value.width, .height = value.height };
}

test "cell layout exposes nonzero baseline decorations and Kitty sprite slot" {
    const cell = CellLayout.fromLegacyCellFacts(.{ .cell_w_px = 8, .cell_h_px = 16, .baseline_px = 13, .box_thickness_px = 2 });
    try std.testing.expectEqual(@as(u16, 8), cell.cell_width_px);
    try std.testing.expectEqual(@as(u16, 16), cell.cell_height_px);
    try std.testing.expectEqual(@as(u16, 13), cell.baseline_px);
    try std.testing.expect(cell.underline_height_px > 0);
    try std.testing.expect(cell.strikethrough_height_px > 0);
    try std.testing.expectEqual(@as(u16, 17), cell.sprite_slot_height_px);
}

test "surface layout derives grid from surface pixels" {
    const cell = CellLayout.fromLegacyCellFacts(.{ .cell_w_px = 8, .cell_h_px = 16, .baseline_px = 13, .box_thickness_px = 2 });
    const surface = SurfaceLayout.init(.{ .width = 81, .height = 49 }, cell);
    try std.testing.expectEqual(@as(u16, 10), surface.grid.cols);
    try std.testing.expectEqual(@as(u16, 3), surface.grid.rows);
    try std.testing.expectEqual(@as(u16, 80), surface.grid_px.width);
    try std.testing.expectEqual(@as(u16, 48), surface.grid_px.height);
}

test "surface layout point query reports inside and clamps to rendered grid" {
    const cell = CellLayout.fromLegacyCellFacts(.{ .cell_w_px = 8, .cell_h_px = 16, .baseline_px = 13, .box_thickness_px = 2 });
    const surface = SurfaceLayout.init(.{ .width = 81, .height = 49 }, cell);

    const inside = surface.pointCell(.{ .x_px = 16, .y_px = 32 });
    try std.testing.expectEqual(@as(u8, 1), inside.inside);
    try std.testing.expectEqual(@as(u16, 2), inside.col);
    try std.testing.expectEqual(@as(u16, 2), inside.row);

    const negative = surface.pointCell(.{ .x_px = -1, .y_px = -1 });
    try std.testing.expectEqual(@as(u8, 0), negative.inside);
    try std.testing.expectEqual(@as(u16, 0), negative.col);
    try std.testing.expectEqual(@as(u16, 0), negative.row);

    const leftover = surface.pointCell(.{ .x_px = 80, .y_px = 48 });
    try std.testing.expectEqual(@as(u8, 0), leftover.inside);
    try std.testing.expectEqual(@as(u16, 9), leftover.col);
    try std.testing.expectEqual(@as(u16, 2), leftover.row);
}
