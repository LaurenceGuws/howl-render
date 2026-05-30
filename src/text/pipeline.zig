const std = @import("std");
const contract = @import("contract.zig");

pub const TextPrepareCounters = struct {
    cell_texts: u64 = 0,
    clusters: u64 = 0,
    resolved_runs: u64 = 0,
    shaped_runs: u64 = 0,
    shaped_glyphs: u64 = 0,
    glyph_groups: u64 = 0,
    sprite_cache_hits: u64 = 0,
    sprite_cache_misses: u64 = 0,
    rasterized_sprites: u64 = 0,
    missing_glyphs: u64 = 0,
};

pub const BuildRunsRequest = struct {
    cells: []const contract.RenderableCell,
    text_cache: contract.LineTextCache,
    cell_metrics: contract.CellMetrics,
};

pub const BuildRunsOutput = struct {
    allocator: std.mem.Allocator,
    clusters: []contract.CellCluster,
    runs: []contract.ResolvedRun,

    pub fn deinit(self: *BuildRunsOutput) void {
        self.allocator.free(self.clusters);
        self.allocator.free(self.runs);
        self.* = undefined;
    }
};

pub const GroupGlyphsRequest = struct {
    run: contract.ResolvedRun,
    glyphs: []const contract.GlyphInstance,
    clusters: []const contract.CellCluster,
};

pub const GroupGlyphsOutput = struct {
    allocator: std.mem.Allocator,
    groups: []contract.GlyphGroup,

    pub fn deinit(self: *GroupGlyphsOutput) void {
        self.allocator.free(self.groups);
        self.* = undefined;
    }
};

pub const ShapeRequest = struct {
    clusters: []const contract.TextCluster,
    font_metrics: contract.FontMetrics,
    cell_metrics: contract.CellMetrics,
};

pub const ShapeOutput = struct {
    allocator: std.mem.Allocator,
    runs: []contract.ShapedRun,
    glyphs: []contract.ShapedGlyph,
    missing: []contract.MissingGlyph,

    pub fn deinit(self: *ShapeOutput) void {
        self.allocator.free(self.runs);
        self.allocator.free(self.glyphs);
        self.allocator.free(self.missing);
        self.* = undefined;
    }
};

pub const RasterizeRequest = struct {
    face_id: u32,
    glyph_id: u32,
    atlas_key: u64,
    cell_metrics: contract.CellMetrics,
    cell_span: u8 = 1,
    sprite_key: ?contract.SpriteKey = null,
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

pub const ShapeClustersFn = *const fn (ctx: *anyopaque, allocator: std.mem.Allocator, req: ShapeRequest) anyerror!ShapeOutput;
pub const RasterizeGlyphFn = *const fn (ctx: *anyopaque, allocator: std.mem.Allocator, req: RasterizeRequest) anyerror!RasterizeOutput;

pub const ShapeClustersOp = struct {
    ctx: *anyopaque,
    call: ShapeClustersFn,

    pub fn shape(self: ShapeClustersOp, allocator: std.mem.Allocator, req: ShapeRequest) anyerror!ShapeOutput {
        return self.call(self.ctx, allocator, req);
    }
};

pub const RasterizeGlyphOp = struct {
    ctx: *anyopaque,
    call: RasterizeGlyphFn,

    pub fn rasterize(self: RasterizeGlyphOp, allocator: std.mem.Allocator, req: RasterizeRequest) anyerror!RasterizeOutput {
        return self.call(self.ctx, allocator, req);
    }
};

test "text pipeline ops dispatch and own output buffers" {
    const allocator = std.testing.allocator;

    const Stub = struct {
        hits: u8 = 0,

        fn shape(ctx: *anyopaque, gpa: std.mem.Allocator, req: ShapeRequest) anyerror!ShapeOutput {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.hits += 1;

            const glyphs = try gpa.alloc(contract.ShapedGlyph, 1);
            glyphs[0] = .{
                .glyph_id = req.clusters[0].first_cp,
                .atlas_key = 123,
                .x_offset_px = 0,
                .y_offset_px = 0,
                .x_advance_px = @floatFromInt(req.cell_metrics.cell_w_px),
                .face_id = 7,
            };
            const runs = try gpa.alloc(contract.ShapedRun, 1);
            runs[0] = .{
                .cluster_start = 0,
                .cluster_count = @intCast(req.clusters.len),
                .glyphs = glyphs,
            };

            return .{
                .allocator = gpa,
                .runs = runs,
                .glyphs = glyphs,
                .missing = try gpa.alloc(contract.MissingGlyph, 0),
            };
        }

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
    const shape_op = ShapeClustersOp{ .ctx = &stub, .call = Stub.shape };
    const raster_op = RasterizeGlyphOp{ .ctx = &stub, .call = Stub.rasterize };

    const req = ShapeRequest{
        .clusters = &.{.{ .grapheme_utf8 = "A", .first_cp = 'A' }},
        .font_metrics = .{
            .ascent_px = 10,
            .descent_px = 3,
            .line_gap_px = 2,
            .underline_pos_px = 1,
            .underline_thickness_px = 1,
            .strikethrough_pos_px = 6,
            .strikethrough_thickness_px = 1,
        },
        .cell_metrics = .{ .cell_w_px = 8, .cell_h_px = 16, .baseline_px = 12 },
    };

    var shaped = try shape_op.shape(allocator, req);
    defer shaped.deinit();
    try std.testing.expectEqual(@as(u32, 1), count32.of(shaped.runs));
    try std.testing.expectEqual(@as(u32, 1), count32.of(shaped.glyphs));
    try std.testing.expectEqual(@as(u32, 'A'), shaped.glyphs[0].glyph_id);

    var raster = try raster_op.rasterize(allocator, .{
        .face_id = 7,
        .glyph_id = shaped.glyphs[0].glyph_id,
        .atlas_key = shaped.glyphs[0].atlas_key,
        .cell_metrics = req.cell_metrics,
    });
    defer raster.deinit();
    try std.testing.expectEqual(@as(u32, 8 * 16), count32.of(raster.alpha_mask));
    try std.testing.expectEqual(@as(u8, 0x7f), raster.alpha_mask[0]);

    try std.testing.expectEqual(@as(u8, 2), stub.hits);
}
