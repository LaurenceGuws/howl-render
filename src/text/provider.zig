const std = @import("std");
const surface = @import("../surface.zig");
const font_session = @import("../session/session.zig");
const raster_operation = @import("raster/operation.zig");
const rasterizer = @import("raster/rasterizer.zig");
const shape_run = @import("shape/run.zig");

pub const FtHbSource = struct {
    ctx: *anyopaque,
    has_codepoint: *const fn (ctx: *anyopaque, face_id: font_session.FontFaceId, codepoint: u32) bool,
    shaper: shape_run.Shaper = shape_run.defaultShaper(),
    rasterizer: rasterizer.Rasterizer = rasterizer.defaultRasterizer(),
    glyph_lookup: LookupGlyphOp = defaultLookupGlyph(),
    glyph_raster: raster_operation.RasterizeGlyphOp = defaultGlyphRaster(),

    pub fn textProvider(self: *FtHbSource) TextProvider {
        return .{
            .face_provider = .{ .ctx = self, .has_cell_text = hasCellText },
            .shaper = self.shaper,
            .rasterizer = self.rasterizer,
            .glyph_lookup = self.glyph_lookup,
            .glyph_raster = self.glyph_raster,
        };
    }

    fn hasCellText(ctx: *anyopaque, face_id: font_session.FontFaceId, text: surface.CellText) bool {
        const self: *FtHbSource = @ptrCast(@alignCast(ctx));
        const cps = if (text.codepoints.len == 0) &[_]u32{text.first_cp} else text.codepoints;
        for (cps) |cp| {
            if (cp == 0xfe0e or cp == 0xfe0f) continue;
            if (!self.has_codepoint(self.ctx, face_id, cp)) return false;
        }
        return true;
    }
};

pub const LookupGlyphResult = struct {
    glyph_id: u32,
    advance_px: f32,
};

pub const LookupGlyphFn = *const fn (ctx: *anyopaque, face_id: surface.FontFaceId, codepoint: u32, cell_metrics: surface.CellMetrics) LookupGlyphResult;

pub const LookupGlyphOp = struct {
    ctx: *anyopaque,
    lookup_glyph: LookupGlyphFn,

    pub fn lookupGlyph(self: LookupGlyphOp, face_id: surface.FontFaceId, codepoint: u32, cell_metrics: surface.CellMetrics) LookupGlyphResult {
        return self.lookup_glyph(self.ctx, face_id, codepoint, cell_metrics);
    }
};

pub const TextProvider = struct {
    face_provider: ?font_session.FaceProvider = null,
    shaper: shape_run.Shaper = shape_run.defaultShaper(),
    rasterizer: rasterizer.Rasterizer = rasterizer.defaultRasterizer(),
    glyph_lookup: LookupGlyphOp = defaultLookupGlyph(),
    glyph_raster: raster_operation.RasterizeGlyphOp = defaultGlyphRaster(),

    pub fn applyToSession(self: TextProvider, session: font_session.FontSession) font_session.FontSession {
        var next = session;
        next.provider = self.face_provider;
        return next;
    }
};

pub fn defaultProvider() TextProvider {
    return .{};
}

pub fn defaultLookupGlyph() LookupGlyphOp {
    return .{ .ctx = undefined, .lookup_glyph = defaultLookupGlyphThunk };
}

pub fn defaultGlyphRaster() raster_operation.RasterizeGlyphOp {
    return .{ .ctx = undefined, .call = defaultGlyphRasterThunk };
}

fn defaultLookupGlyphThunk(_: *anyopaque, face_id: surface.FontFaceId, codepoint: u32, cell_metrics: surface.CellMetrics) LookupGlyphResult {
    _ = face_id;
    return .{
        .glyph_id = codepoint,
        .advance_px = @floatFromInt(@as(u32, @max(cell_metrics.cell_w_px, 1))),
    };
}

fn defaultGlyphRasterThunk(_: *anyopaque, allocator: std.mem.Allocator, req: raster_operation.RasterizeRequest) anyerror!raster_operation.RasterizeOutput {
    const width = @as(u16, @intCast(@as(u32, @max(req.cell_span, 1)) * @as(u32, @max(req.cell_metrics.cell_w_px, 1))));
    const height = @max(req.cell_metrics.cell_h_px, 1);
    const area = @as(u32, width) * @as(u32, height);
    const alpha = try allocator.alloc(u8, @intCast(area));
    @memset(alpha, 0x7f);
    return .{
        .allocator = allocator,
        .width_px = width,
        .height_px = height,
        .bearing_x_px = 0,
        .bearing_y_px = 0,
        .advance_px = @floatFromInt(@as(u32, @max(req.cell_metrics.cell_w_px, 1))),
        .alpha_mask = alpha,
    };
}

test "text provider applies face provider to session" {
    const Provider = struct {
        fn has(ctx: *anyopaque, face_id: surface.FontFaceId, text: surface.CellText) bool {
            _ = ctx;
            _ = face_id;
            return text.codepoints.len == 1;
        }
    };
    var dummy: u8 = 0;
    const provider = TextProvider{ .face_provider = .{ .ctx = &dummy, .has_cell_text = Provider.has } };
    const session = provider.applyToSession(.{});
    const face = font_session.FontFaceRecord{ .id = .{ .value = 1 }, .role = .primary };
    try @import("std").testing.expect(!session.hasCellText(face, .{ .id = .{ .value = 0 }, .first_cp = 'i', .codepoints = &.{ 'i', 0x0332 } }));
}
