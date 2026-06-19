const std = @import("std");
const render = @import("../../grid/scene.zig");

pub const RasterizeRequest = struct {
    face_id: u32,
    glyph_id: u32,
    atlas_key: u64,
    cell_metrics: render.CellMetrics,
    cell_span: u8 = 1,
    sprite_key: ?render.SpriteKey = null,
};

pub const RasterizeOutput = struct {
    allocator: std.mem.Allocator,
    width_px: u16,
    height_px: u16,
    bearing_x_px: i16,
    bearing_y_px: i16,
    advance_px: f32,
    alpha_mask: []u8,

    pub fn deinit(self: *RasterizeOutput) void {
        self.allocator.free(self.alpha_mask);
        self.* = undefined;
    }
};

pub const RasterizeGlyphFn = *const fn (ctx: *anyopaque, allocator: std.mem.Allocator, req: RasterizeRequest) anyerror!RasterizeOutput;

pub const RasterizeGlyphOp = struct {
    ctx: *anyopaque,
    call: RasterizeGlyphFn,

    pub fn rasterize(self: RasterizeGlyphOp, allocator: std.mem.Allocator, req: RasterizeRequest) anyerror!RasterizeOutput {
        return self.call(self.ctx, allocator, req);
    }
};

test "rasterize glyph op dispatches and owns output buffer" {
    const allocator = std.testing.allocator;

    const Stub = struct {
        hits: u8 = 0,

        fn rasterize(ctx: *anyopaque, gpa: std.mem.Allocator, req: RasterizeRequest) anyerror!RasterizeOutput {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.hits += 1;

            const area: u32 = @as(u32, req.cell_metrics.cell_w_px) * @as(u32, req.cell_metrics.cell_h_px);
            const alpha = try gpa.alloc(u8, @intCast(area));
            @memset(alpha, 0x7f);
            return .{
                .allocator = gpa,
                .width_px = req.cell_metrics.cell_w_px,
                .height_px = req.cell_metrics.cell_h_px,
                .bearing_x_px = 0,
                .bearing_y_px = 0,
                .advance_px = @floatFromInt(req.cell_metrics.cell_w_px),
                .alpha_mask = alpha,
            };
        }
    };

    const count32 = struct {
        fn of(items: anytype) u32 {
            std.debug.assert(items.len <= std.math.maxInt(u32));
            return @intCast(items.len);
        }
    };

    var stub = Stub{};
    const raster_op = RasterizeGlyphOp{ .ctx = &stub, .call = Stub.rasterize };

    var raster = try raster_op.rasterize(allocator, .{
        .face_id = 7,
        .glyph_id = 'A',
        .atlas_key = 123,
        .cell_metrics = .{ .cell_w_px = 8, .cell_h_px = 16, .baseline_px = 12 },
    });
    defer raster.deinit();
    try std.testing.expectEqual(@as(u32, 8 * 16), count32.of(raster.alpha_mask));
    try std.testing.expectEqual(@as(u8, 0x7f), raster.alpha_mask[0]);
    try std.testing.expectEqual(@as(u8, 1), stub.hits);
}
