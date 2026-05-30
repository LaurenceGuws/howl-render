const std = @import("std");
const contract = @import("contract.zig");

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

pub const ShapeClustersFn = *const fn (ctx: *anyopaque, allocator: std.mem.Allocator, req: ShapeRequest) anyerror!ShapeOutput;

pub const ShapeClustersOp = struct {
    ctx: *anyopaque,
    call: ShapeClustersFn,

    pub fn shape(self: ShapeClustersOp, allocator: std.mem.Allocator, req: ShapeRequest) anyerror!ShapeOutput {
        return self.call(self.ctx, allocator, req);
    }
};

test "shape clusters op dispatches and owns output buffers" {
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
    };

    const count32 = struct {
        fn of(items: anytype) u32 {
            std.debug.assert(items.len <= std.math.maxInt(u32));
            return @intCast(items.len);
        }
    };

    var stub = Stub{};
    const shape_op = ShapeClustersOp{ .ctx = &stub, .call = Stub.shape };

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

    try std.testing.expectEqual(@as(u8, 1), stub.hits);
}
