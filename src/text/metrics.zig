const std = @import("std");

pub const FontMetrics = struct {
    ascent_px: f32,
    descent_px: f32,
    line_gap_px: f32,
    underline_pos_px: f32,
    underline_thickness_px: f32,
    strikethrough_pos_px: f32,
    strikethrough_thickness_px: f32,
};

pub const FaceMetrics26Dot6 = struct {
    ascender: i32,
    descender: i32,
    height: i32,
    max_advance: i32,
    fallback_font_px: u16,
};

pub const DecorationGeometry = struct {
    underline_y_px: i32,
    underline_h_px: u16,
    strikethrough_y_px: i32,
    strikethrough_h_px: u16,
};

pub const CursorGeometry = struct {
    beam_w_px: u16,
    underline_h_px: u16,
    hollow_stroke_px: u16,
};

pub const CellMetrics = struct {
    cell_w_px: u16,
    cell_h_px: u16,
    baseline_px: i16,
    box_thickness_px: u16 = 0,
};

pub const GridMetrics = struct {
    cols: u16,
    rows: u16 = 1,
};

test "metrics fixtures are nonzero where required" {
    const font = FontMetrics{
        .ascent_px = 12,
        .descent_px = 4,
        .line_gap_px = 1,
        .underline_pos_px = 14,
        .underline_thickness_px = 1,
        .strikethrough_pos_px = 8,
        .strikethrough_thickness_px = 1,
    };
    const face = FaceMetrics26Dot6{ .ascender = 10, .descender = -3, .height = 14, .max_advance = 9, .fallback_font_px = 16 };
    const decoration = DecorationGeometry{ .underline_y_px = 14, .underline_h_px = 1, .strikethrough_y_px = 8, .strikethrough_h_px = 1 };
    const cursor = CursorGeometry{ .beam_w_px = 1, .underline_h_px = 1, .hollow_stroke_px = 1 };
    const cell = CellMetrics{ .cell_w_px = 8, .cell_h_px = 16, .baseline_px = 12, .box_thickness_px = 2 };
    const grid = GridMetrics{ .cols = 80, .rows = 24 };

    try std.testing.expect(font.ascent_px > 0);
    try std.testing.expect(face.height > 0);
    try std.testing.expect(decoration.underline_h_px > 0);
    try std.testing.expect(cursor.beam_w_px > 0);
    try std.testing.expect(cell.cell_w_px > 0);
    try std.testing.expect(cell.cell_h_px > 0);
    try std.testing.expect(grid.cols > 0);
    try std.testing.expect(grid.rows > 0);
}
