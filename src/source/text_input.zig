const std = @import("std");
const source_vt = @import("vt.zig");
const source_cell = @import("cell.zig");
const publication_cell_map = @import("publication_cell_map.zig");
const contract = @import("../text/contract.zig");
const frame_preparer = @import("../text/frame_preparer.zig");
const scene = @import("../text/scene.zig");

pub const FrameTheme = publication_cell_map.FrameTheme;
pub const default_theme = defaultTheme();

fn indexed256(idx: u8, t: FrameTheme) contract.Rgba8 {
    return t.palette[idx];
}

fn defaultTheme() FrameTheme {
    const palette = defaultPalette();
    return .{
        .default_fg = .{ .r = 204, .g = 204, .b = 204, .a = 255 },
        .default_bg = .{ .r = 0, .g = 0, .b = 0, .a = 255 },
        .cursor_color = .{ .r = 204, .g = 204, .b = 204, .a = 255 },
        .palette = palette,
    };
}

fn defaultPalette() [256]contract.Rgba8 {
    @setEvalBranchQuota(4096);
    var palette: [256]contract.Rgba8 = undefined;
    var idx: u16 = 0;
    while (idx < 256) : (idx += 1) palette[idx] = indexedDefaultColor(@intCast(idx));
    return palette;
}

fn indexedDefaultColor(idx: u8) contract.Rgba8 {
    if (idx < 16) return switch (idx) {
        0 => .{ .r = 0, .g = 0, .b = 0, .a = 255 },
        1 => .{ .r = 170, .g = 0, .b = 0, .a = 255 },
        2 => .{ .r = 0, .g = 170, .b = 0, .a = 255 },
        3 => .{ .r = 170, .g = 85, .b = 0, .a = 255 },
        4 => .{ .r = 0, .g = 0, .b = 170, .a = 255 },
        5 => .{ .r = 170, .g = 0, .b = 170, .a = 255 },
        6 => .{ .r = 0, .g = 170, .b = 170, .a = 255 },
        7 => .{ .r = 170, .g = 170, .b = 170, .a = 255 },
        8 => .{ .r = 85, .g = 85, .b = 85, .a = 255 },
        9 => .{ .r = 255, .g = 85, .b = 85, .a = 255 },
        10 => .{ .r = 85, .g = 255, .b = 85, .a = 255 },
        11 => .{ .r = 255, .g = 255, .b = 85, .a = 255 },
        12 => .{ .r = 85, .g = 85, .b = 255, .a = 255 },
        13 => .{ .r = 255, .g = 85, .b = 255, .a = 255 },
        14 => .{ .r = 85, .g = 255, .b = 255, .a = 255 },
        else => .{ .r = 255, .g = 255, .b = 255, .a = 255 },
    };
    if (idx < 232) {
        const i: u32 = idx - 16;
        const r: u8 = @intCast((i / 36) * 51);
        const g: u8 = @intCast(((i / 6) % 6) * 51);
        const b: u8 = @intCast((i % 6) * 51);
        return .{ .r = r, .g = g, .b = b, .a = 255 };
    }
    const gray: u8 = @intCast((@as(u32, idx) - 232) * 10 + 8);
    return .{ .r = gray, .g = gray, .b = gray, .a = 255 };
}

fn rgbaFromVtRgb(color: source_vt.SourceRgb) contract.Rgba8 {
    return .{ .r = color.r, .g = color.g, .b = color.b, .a = 255 };
}

fn themeFromPublicationColors(colors: source_vt.SourceColors) FrameTheme {
    return publication_cell_map.themeFromPublicationColors(colors);
}

fn colorToRgba8(color: anytype, is_fg: bool, t: FrameTheme) contract.Rgba8 {
    return switch (color.kind) {
        .default => if (is_fg) t.default_fg else t.default_bg,
        .indexed => indexed256(@intCast(color.value & 0xFF), t),
        .rgb => .{
            .r = @intCast((color.value >> 16) & 0xFF),
            .g = @intCast((color.value >> 8) & 0xFF),
            .b = @intCast(color.value & 0xFF),
            .a = 255,
        },
    };
}

fn colorToTextSceneRgba8(color: anytype, is_fg: bool, t: FrameTheme) contract.Rgba8 {
    return colorToRgba8(color, is_fg, t);
}

fn mapCursorShape(shape: anytype) scene.CursorShape {
    return switch (shape) {
        .block => .block,
        .underline => .underline,
        .beam => .beam,
        .hollow_block => .hollow_block,
    };
}

fn mapTextSceneCursorShape(shape: anytype) scene.CursorShape {
    const name = @tagName(shape);
    if (std.mem.eql(u8, name, "underline")) return .underline;
    if (std.mem.eql(u8, name, "beam")) return .beam;
    if (std.mem.eql(u8, name, "hollow_block")) return .hollow_block;
    return .block;
}

fn mapUnderlineStyle(style: source_cell.UnderlineStyle) contract.UnderlineStyle {
    return switch (style) {
        .straight => .straight,
        .double => .double,
        .curly => .curly,
        .dotted => .dotted,
        .dashed => .dashed,
    };
}

fn publicationColorToRgba8(color: source_vt.SourceColor, is_fg: bool, t: FrameTheme) contract.Rgba8 {
    return switch (color.kind) {
        0 => if (is_fg) t.default_fg else t.default_bg,
        1 => indexed256(@intCast(color.value & 0xFF), t),
        2 => .{
            .r = @intCast((color.value >> 16) & 0xFF),
            .g = @intCast((color.value >> 8) & 0xFF),
            .b = @intCast(color.value & 0xFF),
            .a = 255,
        },
        else => unreachable,
    };
}

fn publicationColorToTextSceneRgba8(color: source_vt.SourceColor, is_fg: bool, t: FrameTheme) contract.Rgba8 {
    return publicationColorToRgba8(color, is_fg, t);
}

fn publicationUnderlineStyle(style: u8) contract.UnderlineStyle {
    return switch (style) {
        0 => .straight,
        1 => .double,
        2 => .curly,
        3 => .dotted,
        4 => .dashed,
        else => unreachable,
    };
}

fn emptyCellInput() contract.CellInput {
    return .{
        .codepoint = 0,
        .style = .regular,
        .presentation = .any,
        .fg = .{ .r = 0, .g = 0, .b = 0, .a = 0 },
        .bg = .{ .r = 0, .g = 0, .b = 0, .a = 0 },
        .empty = true,
    };
}

fn mapFontStyle(bold: bool, italic: bool) contract.FontStyle {
    if (bold) {
        if (italic) return .bold_italic;
        return .bold;
    }
    if (italic) return .italic;
    return .regular;
}

fn dimColor(color: contract.Rgba8) contract.Rgba8 {
    return .{
        .r = @intCast(@as(u16, color.r) * 66 / 100),
        .g = @intCast(@as(u16, color.g) * 66 / 100),
        .b = @intCast(@as(u16, color.b) * 66 / 100),
        .a = color.a,
    };
}

fn applyDimStyle(cell: *contract.CellInput) void {
    cell.fg = dimColor(cell.fg);
    if (cell.underline_color.a != 0) cell.underline_color = dimColor(cell.underline_color);
}

fn applyInvisibleStyle(cell: *contract.CellInput) void {
    cell.codepoint = ' ';
    cell.combining_len = 0;
    cell.combining = [_]u32{0} ** 3;
    cell.underline = false;
    cell.underline_color = .{ .r = 0, .g = 0, .b = 0, .a = 0 };
    cell.strikethrough = false;
}

fn detectCellPresentation(codepoint: u21, combining_len: u8, combining: [3]u32) contract.TextPresentation {
    _ = codepoint;
    std.debug.assert(combining_len <= combining.len);
    for (combining[0..combining_len]) |cp| {
        if (cp == 0xFE0F) return .emoji;
        if (cp == 0xFE0E) return .text;
    }
    return .any;
}

fn mapCellInput(src: source_cell.Cell, t: FrameTheme) contract.CellInput {
    std.debug.assert(src.combining_len <= src.combining.len);
    const truth = publication_cell_map.vtCellTruth(src);
    if (truth.empty) std.debug.assert(truth.default_fg);
    if (truth.empty) std.debug.assert(truth.default_bg);
    const bg = colorToTextSceneRgba8(src.bg_color, false, t);
    var out: contract.CellInput = .{
        .codepoint = src.codepoint,
        .combining_len = src.combining_len,
        .combining = src.combining,
        .style = mapFontStyle(src.attrs.bold, src.attrs.italic),
        .presentation = detectCellPresentation(src.codepoint, src.combining_len, src.combining),
        .fg = colorToTextSceneRgba8(src.fg_color, true, t),
        .bg = bg,
        .underline_color = if (src.attrs.underline_color_set) colorToTextSceneRgba8(src.underline_color, true, t) else .{ .r = 0, .g = 0, .b = 0, .a = 0 },
        .underline_style = mapUnderlineStyle(src.underline_style),
        .underline = src.attrs.underline,
        .strikethrough = src.attrs.strikethrough,
        .continuation = src.flags.continuation,
        .empty = truth.empty,
    };
    publication_cell_map.assertSemanticEmptyClassification(truth, t, out.bg, out.empty);
    if (src.attrs.inverse) publication_cell_map.applyInverseStyle(&out, t, truth);
    if (src.attrs.dim) applyDimStyle(&out);
    if (src.attrs.selected) publication_cell_map.applySelectionStyle(&out, t, truth);
    if (src.attrs.invisible) applyInvisibleStyle(&out);
    return out;
}

fn mapPublicationCellInput(src: source_vt.SourceCell, t: FrameTheme) contract.CellInput {
    return publication_cell_map.mapPublicationCellInput(src, t);
}

fn canMapDirtyOnly(state: anytype) bool {
    const rows = state.grid.rows;
    return !state.damage.full and
        count16(state.damage.dirty_rows) == rows and
        count16(state.damage.dirty_cols_start) == rows and
        count16(state.damage.dirty_cols_end) == rows;
}

fn mapDirtyCellsOnly(
    dst: []contract.CellInput,
    cells: []const source_cell.Cell,
    grid_cols: u16,
    grid_rows: u16,
    dirty_rows: []const bool,
    dirty_cols_start: []const u16,
    dirty_cols_end: []const u16,
    t: FrameTheme,
) void {
    const cols: u16 = @max(grid_cols, 1);
    const rows = grid_rows;
    const cell_len = count32(cells);
    var row: u16 = 0;
    while (row < rows) : (row += 1) {
        if (!dirty_rows[@intCast(row)]) continue;
        const base = @as(u32, row) * @as(u32, cols);
        if (base >= cell_len) continue;
        const start_col = @min(dirty_cols_start[@intCast(row)], cols - 1);
        const end_col = @min(dirty_cols_end[@intCast(row)], cols - 1);
        if (end_col < start_col) continue;
        var idx = base + @as(u32, start_col);
        const end_idx = @min(base + @as(u32, end_col) + 1, cell_len);
        while (idx < end_idx) : (idx += 1) {
            dst[@intCast(idx)] = mapCellInput(cells[@intCast(idx)], t);
        }
    }
}

fn count16(items: anytype) u16 {
    std.debug.assert(items.len <= std.math.maxInt(u16));
    return @intCast(items.len);
}

fn count32(items: anytype) u32 {
    std.debug.assert(items.len <= std.math.maxInt(u32));
    return @intCast(items.len);
}

fn assertDirtyRowsBoolBytes(dirty_rows: []const u8) void {
    for (dirty_rows) |dirty| {
        std.debug.assert(dirty <= 1);
    }
}

pub const OwnedFrameTextInput = struct {
    allocator: std.mem.Allocator,
    cells: []contract.CellInput,
    grid: contract.GridMetrics,
    options: frame_preparer.PrepareOptions,

    pub fn deinit(self: *OwnedFrameTextInput) void {
        self.allocator.free(self.cells);
        self.* = undefined;
    }
};

pub const OwnedTextSceneInput = OwnedFrameTextInput;

pub const BorrowedFrameTextInput = struct {
    cells: []const contract.CellInput,
    grid: contract.GridMetrics,
    options: frame_preparer.PrepareOptions,
};

pub const BorrowedTextSceneInput = BorrowedFrameTextInput;

pub fn vtStateToTextSceneInput(allocator: std.mem.Allocator, state: anytype) !OwnedTextSceneInput {
    return vtStateToTextSceneInputWithTheme(allocator, state, default_theme);
}

pub fn publicationSourceToTextSceneInput(allocator: std.mem.Allocator, source: source_vt.PublicationSource, full_damage: bool) !OwnedTextSceneInput {
    return publicationSourceToTextSceneInputWithTheme(allocator, source, full_damage, themeFromPublicationColors(source.colors));
}

pub fn vtStateToFrameTextInput(allocator: std.mem.Allocator, state: anytype) !OwnedFrameTextInput {
    return vtStateToFrameTextInputWithTheme(allocator, state, default_theme);
}

pub fn publicationSourceToTextSceneInputWithTheme(allocator: std.mem.Allocator, source: source_vt.PublicationSource, full_damage: bool, t: FrameTheme) !OwnedTextSceneInput {
    const cell_inputs = try allocator.alloc(contract.CellInput, source.cells.len);
    errdefer allocator.free(cell_inputs);

    const mapped = publicationSourceToTextSceneInputBorrowedWithTheme(cell_inputs, source, full_damage, t);
    return .{
        .allocator = allocator,
        .cells = mapped.cells,
        .grid = mapped.grid,
        .options = mapped.options,
    };
}

pub fn publicationSourceToTextSceneInputBorrowed(cell_inputs: []contract.CellInput, source: source_vt.PublicationSource, full_damage: bool) BorrowedTextSceneInput {
    return publicationSourceToTextSceneInputBorrowedWithTheme(cell_inputs, source, full_damage, themeFromPublicationColors(source.colors));
}

pub fn publicationSourceToTextSceneInputBorrowedWithTheme(cell_inputs: []contract.CellInput, source: source_vt.PublicationSource, full_damage: bool, t: FrameTheme) BorrowedTextSceneInput {
    std.debug.assert(cell_inputs.len >= source.cells.len);
    const mapped_cells = cell_inputs[0..source.cells.len];

    assertDirtyRowsBoolBytes(source.dirty_rows);
    const dirty_rows: []const bool = @ptrCast(source.dirty_rows);

    const damage = scene.DamageInput{
        .full = full_damage,
        .dirty_rows = dirty_rows,
        .dirty_cols_start = source.dirty_cols_start,
        .dirty_cols_end = source.dirty_cols_end,
    };

    const cursor_visible = source.cursor.visible and (!source.cursor.blink or source.cursor_phase_visible);
    const cursor: ?scene.CursorInput = if (cursor_visible) .{
        .cell_col = source.cursor.col,
        .cell_row = source.cursor.row,
        .shape = mapTextSceneCursorShape(source.cursor.shape),
        .color = t.cursor_color,
        .blink = source.cursor.blink,
    } else null;

    if (!full_damage and count16(dirty_rows) == source.rows and count16(source.dirty_cols_start) == source.rows and count16(source.dirty_cols_end) == source.rows) {
        @memset(mapped_cells, emptyCellInput());
        const cols: u16 = @max(source.cols, 1);
        const rows = source.rows;
        const cell_len = count32(source.cells);
        var row: u16 = 0;
        while (row < rows) : (row += 1) {
            if (!dirty_rows[@intCast(row)]) continue;
            const base = @as(u32, row) * @as(u32, cols);
            if (base >= cell_len) continue;
            const start_col = @min(source.dirty_cols_start[@intCast(row)], cols - 1);
            const end_col = @min(source.dirty_cols_end[@intCast(row)], cols - 1);
            if (end_col < start_col) continue;
            var idx = base + @as(u32, start_col);
            const end_idx = @min(base + @as(u32, end_col) + 1, cell_len);
            while (idx < end_idx) : (idx += 1) {
                mapped_cells[@intCast(idx)] = mapPublicationCellInput(source.cells[@intCast(idx)], t);
            }
        }
    } else {
        for (source.cells, mapped_cells) |src, *dst| {
            dst.* = mapPublicationCellInput(src, t);
        }
    }

    return .{
        .cells = mapped_cells,
        .grid = .{ .cols = source.cols, .rows = source.rows },
        .options = .{ .scene = .{
            .cursor = cursor,
            .damage = damage,
        } },
    };
}

pub fn vtStateToTextSceneInputWithTheme(allocator: std.mem.Allocator, state: anytype, t: FrameTheme) !OwnedTextSceneInput {
    return vtStateToFrameTextInputWithTheme(allocator, state, t);
}

pub fn vtStateToFrameTextInputWithTheme(allocator: std.mem.Allocator, state: anytype, t: FrameTheme) !OwnedFrameTextInput {
    const cell_inputs = try allocator.alloc(contract.CellInput, state.grid.cells.len);
    errdefer allocator.free(cell_inputs);

    if (canMapDirtyOnly(state)) {
        @memset(cell_inputs, emptyCellInput());
        mapDirtyCellsOnly(
            cell_inputs,
            state.grid.cells,
            state.grid.cols,
            state.grid.rows,
            state.damage.dirty_rows,
            state.damage.dirty_cols_start,
            state.damage.dirty_cols_end,
            t,
        );
    } else {
        for (state.grid.cells, cell_inputs) |src, *dst| {
            dst.* = mapCellInput(src, t);
        }
    }

    const cursor: ?scene.CursorInput = if (state.cursor.visible) .{
        .cell_col = state.cursor.col,
        .cell_row = state.cursor.row,
        .shape = mapTextSceneCursorShape(state.cursor.shape),
        .color = t.cursor_color,
        .blink = state.cursor.blink,
    } else null;

    return .{
        .allocator = allocator,
        .cells = cell_inputs,
        .grid = .{ .cols = state.grid.cols, .rows = state.grid.rows },
        .options = .{ .scene = .{
            .cursor = cursor,
            .damage = .{
                .full = state.damage.full,
                .dirty_rows = state.damage.dirty_rows,
                .dirty_cols_start = state.damage.dirty_cols_start,
                .dirty_cols_end = state.damage.dirty_cols_end,
            },
        } },
    };
}

test "source text input converts VT source to text scene input" {
    const cells = [_]source_cell.Cell{.{
        .codepoint = 'A',
        .underline_color = .{ .kind = .rgb, .value = 0xCC3366 },
        .attrs = .{ .underline = true, .underline_color_set = true },
    }};
    const state = .{
        .grid = .{ .cells = &cells, .cols = 1, .rows = 1 },
        .cursor = .{ .visible = true, .col = 0, .row = 0, .shape = .beam, .blink = true },
        .damage = .{ .full = true, .dirty_rows = &[_]bool{}, .dirty_cols_start = &[_]u16{}, .dirty_cols_end = &[_]u16{} },
    };
    var input = try vtStateToTextSceneInput(std.testing.allocator, state);
    defer input.deinit();
    try std.testing.expectEqual(@as(u32, 1), count32(input.cells));
    try std.testing.expectEqual(@as(u21, 'A'), input.cells[0].codepoint);
    try std.testing.expect(input.cells[0].underline);
    try std.testing.expectEqual(@as(u8, 0xCC), input.cells[0].underline_color.r);
    try std.testing.expectEqual(default_theme.default_bg.r, input.cells[0].bg.r);
    try std.testing.expectEqual(default_theme.default_bg.g, input.cells[0].bg.g);
    try std.testing.expectEqual(default_theme.default_bg.b, input.cells[0].bg.b);
    try std.testing.expectEqual(@as(u8, 255), input.cells[0].bg.a);
    try std.testing.expect(!input.cells[0].empty);
    try std.testing.expect(input.options.scene.cursor != null);
    try std.testing.expect(input.options.scene.cursor.?.blink);
    try std.testing.expect(input.options.scene.damage.full);
}

test "source text input maps inverse VT source colors" {
    const cells = [_]source_cell.Cell{.{
        .codepoint = 'R',
        .fg_color = .{ .kind = .rgb, .value = 0x102030 },
        .bg_color = .{ .kind = .rgb, .value = 0xA0B0C0 },
        .attrs = .{ .inverse = true },
    }};
    const state = .{
        .grid = .{ .cells = &cells, .cols = 1, .rows = 1 },
        .cursor = .{ .visible = false, .col = 0, .row = 0, .shape = .beam, .blink = false },
        .damage = .{ .full = true, .dirty_rows = &[_]bool{}, .dirty_cols_start = &[_]u16{}, .dirty_cols_end = &[_]u16{} },
    };
    var input = try vtStateToTextSceneInput(std.testing.allocator, state);
    defer input.deinit();

    try std.testing.expectEqual(@as(u8, 0xA0), input.cells[0].fg.r);
    try std.testing.expectEqual(@as(u8, 0xB0), input.cells[0].fg.g);
    try std.testing.expectEqual(@as(u8, 0xC0), input.cells[0].fg.b);
    try std.testing.expectEqual(@as(u8, 0x10), input.cells[0].bg.r);
    try std.testing.expectEqual(@as(u8, 0x20), input.cells[0].bg.g);
    try std.testing.expectEqual(@as(u8, 0x30), input.cells[0].bg.b);
    try std.testing.expect(!input.cells[0].empty);
}

test "source text input keeps opaque default background for blank VT cell" {
    const cells = [_]source_cell.Cell{.{
        .codepoint = ' ',
        .bg_color = .{ .kind = .default, .value = 0 },
    }};
    const state = .{
        .grid = .{ .cells = &cells, .cols = 1, .rows = 1 },
        .cursor = .{ .visible = false, .col = 0, .row = 0, .shape = .block },
        .damage = .{ .full = true, .dirty_rows = &[_]bool{}, .dirty_cols_start = &[_]u16{}, .dirty_cols_end = &[_]u16{} },
    };

    var input = try vtStateToTextSceneInput(std.testing.allocator, state);
    defer input.deinit();

    try std.testing.expectEqual(default_theme.default_bg.r, input.cells[0].bg.r);
    try std.testing.expectEqual(default_theme.default_bg.g, input.cells[0].bg.g);
    try std.testing.expectEqual(default_theme.default_bg.b, input.cells[0].bg.b);
    try std.testing.expectEqual(@as(u8, 255), input.cells[0].bg.a);
    try std.testing.expect(input.cells[0].empty);
}

test "source text input keeps opaque default background for blank publication cell" {
    var cells = [_]source_vt.SourceCell{.{
        .codepoint = ' ',
        .flags = .{ .continuation = 0 },
        .fg_color = .{ .kind = 0, .value = 0 },
        .bg_color = .{ .kind = 0, .value = 0 },
        .underline_color = .{ .kind = 0, .value = 0 },
        .underline_style = 0,
        .attrs = .{ .bold = 0, .dim = 0, .italic = 0, .underline = 0, .underline_color_set = 0, .blink = 0, .inverse = 0, .invisible = 0, .strikethrough = 0, .selected = 0 },
        .link_id = 0,
    }};
    var colors = std.mem.zeroes(source_vt.SourceColors);
    colors.background = .{ .r = default_theme.default_bg.r, .g = default_theme.default_bg.g, .b = default_theme.default_bg.b };

    var storage: [1]contract.CellInput = undefined;
    const dirty_rows = [_]u8{1};
    const dirty_starts = [_]u16{0};
    const dirty_ends = [_]u16{0};
    const mapped = publicationSourceToTextSceneInputBorrowed(storage[0..], .{
        .cols = 1,
        .rows = 1,
        .history_count = 0,
        .scroll_row = 0,
        .snapshot_seq = 1,
        .dirty_epoch = 1,
        .is_alternate_screen = false,
        .cells = cells[0..],
        .cursor = .{ .visible = false, .row = 0, .col = 0, .shape = .block },
        .colors = colors,
        .selection = .{ .active = 0, .selecting = 0, .start = .{ .row = 0, .col = 0 }, .end = .{ .row = 0, .col = 0 } },
        .cursor_phase_visible = true,
        .dirty_rows = @constCast(&dirty_rows),
        .dirty_cols_start = @constCast(&dirty_starts),
        .dirty_cols_end = @constCast(&dirty_ends),
    }, false);

    try std.testing.expectEqual(default_theme.default_bg.r, mapped.cells[0].bg.r);
    try std.testing.expectEqual(default_theme.default_bg.g, mapped.cells[0].bg.g);
    try std.testing.expectEqual(default_theme.default_bg.b, mapped.cells[0].bg.b);
    try std.testing.expectEqual(@as(u8, 255), mapped.cells[0].bg.a);
    try std.testing.expect(mapped.cells[0].empty);
}

test "source text input keeps default background truth through inverse VT cell" {
    const cells = [_]source_cell.Cell{.{
        .codepoint = 'I',
        .fg_color = .{ .kind = .default, .value = 0 },
        .bg_color = .{ .kind = .default, .value = 0 },
        .attrs = .{ .inverse = true },
    }};
    const state = .{
        .grid = .{ .cells = &cells, .cols = 1, .rows = 1 },
        .cursor = .{ .visible = false, .col = 0, .row = 0, .shape = .block },
        .damage = .{ .full = true, .dirty_rows = &[_]bool{}, .dirty_cols_start = &[_]u16{}, .dirty_cols_end = &[_]u16{} },
    };

    var input = try vtStateToTextSceneInput(std.testing.allocator, state);
    defer input.deinit();

    try std.testing.expectEqual(default_theme.default_bg.r, input.cells[0].fg.r);
    try std.testing.expectEqual(default_theme.default_bg.g, input.cells[0].fg.g);
    try std.testing.expectEqual(default_theme.default_bg.b, input.cells[0].fg.b);
    try std.testing.expectEqual(default_theme.default_fg.r, input.cells[0].bg.r);
    try std.testing.expectEqual(default_theme.default_fg.g, input.cells[0].bg.g);
    try std.testing.expectEqual(default_theme.default_fg.b, input.cells[0].bg.b);
    try std.testing.expectEqual(@as(u8, 255), input.cells[0].bg.a);
    try std.testing.expect(!input.cells[0].empty);
}

test "source text input keeps default background truth through publication selection" {
    var cells = [_]source_vt.SourceCell{.{
        .codepoint = 'S',
        .flags = .{ .continuation = 0 },
        .fg_color = .{ .kind = 0, .value = 0 },
        .bg_color = .{ .kind = 0, .value = 0 },
        .underline_color = .{ .kind = 0, .value = 0 },
        .underline_style = 0,
        .attrs = .{ .bold = 0, .dim = 0, .italic = 0, .underline = 0, .underline_color_set = 0, .blink = 0, .inverse = 0, .invisible = 0, .strikethrough = 0, .selected = 1 },
        .link_id = 0,
    }};
    var colors = std.mem.zeroes(source_vt.SourceColors);
    colors.foreground = .{ .r = default_theme.default_fg.r, .g = default_theme.default_fg.g, .b = default_theme.default_fg.b };
    colors.background = .{ .r = default_theme.default_bg.r, .g = default_theme.default_bg.g, .b = default_theme.default_bg.b };

    var storage: [1]contract.CellInput = undefined;
    const dirty_rows = [_]u8{1};
    const dirty_starts = [_]u16{0};
    const dirty_ends = [_]u16{0};
    const mapped = publicationSourceToTextSceneInputBorrowed(storage[0..], .{
        .cols = 1,
        .rows = 1,
        .history_count = 0,
        .scroll_row = 0,
        .snapshot_seq = 1,
        .dirty_epoch = 1,
        .is_alternate_screen = false,
        .cells = cells[0..],
        .cursor = .{ .visible = false, .row = 0, .col = 0, .shape = .block },
        .colors = colors,
        .selection = .{ .active = 0, .selecting = 0, .start = .{ .row = 0, .col = 0 }, .end = .{ .row = 0, .col = 0 } },
        .cursor_phase_visible = true,
        .dirty_rows = @constCast(&dirty_rows),
        .dirty_cols_start = @constCast(&dirty_starts),
        .dirty_cols_end = @constCast(&dirty_ends),
    }, false);

    try std.testing.expectEqual(default_theme.default_bg.r, mapped.cells[0].fg.r);
    try std.testing.expectEqual(default_theme.default_bg.g, mapped.cells[0].fg.g);
    try std.testing.expectEqual(default_theme.default_bg.b, mapped.cells[0].fg.b);
    try std.testing.expectEqual(default_theme.default_fg.r, mapped.cells[0].bg.r);
    try std.testing.expectEqual(default_theme.default_fg.g, mapped.cells[0].bg.g);
    try std.testing.expectEqual(default_theme.default_fg.b, mapped.cells[0].bg.b);
    try std.testing.expectEqual(@as(u8, 255), mapped.cells[0].bg.a);
    try std.testing.expect(!mapped.cells[0].empty);
}

test "source text input maps publication combining truth" {
    var cells = [_]source_vt.SourceCell{.{
        .codepoint = 'o',
        .combining_len = 1,
        .combining = .{ 0x0300, 0, 0 },
        .flags = .{ .continuation = 0 },
        .fg_color = .{ .kind = 0, .value = 0 },
        .bg_color = .{ .kind = 0, .value = 0 },
        .underline_color = .{ .kind = 0, .value = 0 },
        .underline_style = 0,
        .attrs = .{ .bold = 0, .dim = 0, .italic = 0, .underline = 0, .underline_color_set = 0, .blink = 0, .inverse = 0, .invisible = 0, .strikethrough = 0, .selected = 0 },
        .link_id = 0,
    }};
    var storage: [1]contract.CellInput = undefined;
    const dirty_rows = [_]u8{1};
    const dirty_starts = [_]u16{0};
    const dirty_ends = [_]u16{0};
    const mapped = publicationSourceToTextSceneInputBorrowed(storage[0..], .{
        .cols = 1,
        .rows = 1,
        .history_count = 0,
        .scroll_row = 0,
        .snapshot_seq = 1,
        .dirty_epoch = 1,
        .is_alternate_screen = false,
        .cells = cells[0..],
        .cursor = .{ .visible = false, .row = 0, .col = 0, .shape = .block },
        .colors = std.mem.zeroes(source_vt.SourceColors),
        .selection = .{ .active = 0, .selecting = 0, .start = .{ .row = 0, .col = 0 }, .end = .{ .row = 0, .col = 0 } },
        .cursor_phase_visible = true,
        .dirty_rows = @constCast(&dirty_rows),
        .dirty_cols_start = @constCast(&dirty_starts),
        .dirty_cols_end = @constCast(&dirty_ends),
    }, false);

    try std.testing.expectEqual(@as(u21, 'o'), mapped.cells[0].codepoint);
    try std.testing.expectEqual(@as(u8, 1), mapped.cells[0].combining_len);
    try std.testing.expectEqual(@as(u32, 0x0300), mapped.cells[0].combining[0]);
}

test "source text input maps publication style and presentation truth" {
    var cells = [_]source_vt.SourceCell{.{
        .codepoint = 0x2716,
        .combining_len = 1,
        .combining = .{ 0xFE0F, 0, 0 },
        .flags = .{ .continuation = 0 },
        .fg_color = .{ .kind = 0, .value = 0 },
        .bg_color = .{ .kind = 0, .value = 0 },
        .underline_color = .{ .kind = 0, .value = 0 },
        .underline_style = 0,
        .attrs = .{ .bold = 1, .dim = 0, .italic = 1, .underline = 0, .underline_color_set = 0, .blink = 0, .inverse = 0, .invisible = 0, .strikethrough = 0, .selected = 0 },
        .link_id = 0,
    }};
    var storage: [1]contract.CellInput = undefined;
    const dirty_rows = [_]u8{1};
    const dirty_starts = [_]u16{0};
    const dirty_ends = [_]u16{0};
    const mapped = publicationSourceToTextSceneInputBorrowed(storage[0..], .{
        .cols = 1,
        .rows = 1,
        .history_count = 0,
        .scroll_row = 0,
        .snapshot_seq = 1,
        .dirty_epoch = 1,
        .is_alternate_screen = false,
        .cells = cells[0..],
        .cursor = .{ .visible = false, .row = 0, .col = 0, .shape = .block },
        .colors = std.mem.zeroes(source_vt.SourceColors),
        .selection = .{ .active = 0, .selecting = 0, .start = .{ .row = 0, .col = 0 }, .end = .{ .row = 0, .col = 0 } },
        .cursor_phase_visible = true,
        .dirty_rows = @constCast(&dirty_rows),
        .dirty_cols_start = @constCast(&dirty_starts),
        .dirty_cols_end = @constCast(&dirty_ends),
    }, false);

    try std.testing.expectEqual(contract.FontStyle.bold_italic, mapped.cells[0].style);
    try std.testing.expectEqual(contract.TextPresentation.emoji, mapped.cells[0].presentation);
}

test "source text input maps publication style attrs dim and invisible" {
    var cells = [_]source_vt.SourceCell{
        .{
            .codepoint = 'I',
            .flags = .{ .continuation = 0 },
            .fg_color = .{ .kind = 2, .value = 0x6496C8 },
            .bg_color = .{ .kind = 0, .value = 0 },
            .underline_color = .{ .kind = 2, .value = 0x325078 },
            .underline_style = 0,
            .attrs = .{ .bold = 0, .dim = 1, .italic = 1, .underline = 1, .underline_color_set = 1, .blink = 0, .inverse = 0, .invisible = 0, .strikethrough = 1, .selected = 0 },
            .link_id = 0,
        },
        .{
            .codepoint = 'H',
            .combining_len = 2,
            .combining = .{ 0x0300, 0x0301, 0 },
            .flags = .{ .continuation = 0 },
            .fg_color = .{ .kind = 2, .value = 0xFFFFFF },
            .bg_color = .{ .kind = 2, .value = 0x112233 },
            .underline_color = .{ .kind = 2, .value = 0x445566 },
            .underline_style = 0,
            .attrs = .{ .bold = 0, .dim = 0, .italic = 0, .underline = 1, .underline_color_set = 1, .blink = 0, .inverse = 0, .invisible = 1, .strikethrough = 1, .selected = 0 },
            .link_id = 0,
        },
    };
    var storage: [2]contract.CellInput = undefined;
    const dirty_rows = [_]u8{1};
    const dirty_starts = [_]u16{0};
    const dirty_ends = [_]u16{1};
    const mapped = publicationSourceToTextSceneInputBorrowed(storage[0..], .{
        .cols = 2,
        .rows = 1,
        .history_count = 0,
        .scroll_row = 0,
        .snapshot_seq = 1,
        .dirty_epoch = 1,
        .is_alternate_screen = false,
        .cells = cells[0..],
        .cursor = .{ .visible = false, .row = 0, .col = 0, .shape = .block },
        .colors = std.mem.zeroes(source_vt.SourceColors),
        .selection = .{ .active = 0, .selecting = 0, .start = .{ .row = 0, .col = 0 }, .end = .{ .row = 0, .col = 0 } },
        .cursor_phase_visible = true,
        .dirty_rows = @constCast(&dirty_rows),
        .dirty_cols_start = @constCast(&dirty_starts),
        .dirty_cols_end = @constCast(&dirty_ends),
    }, false);

    try std.testing.expectEqual(contract.FontStyle.italic, mapped.cells[0].style);
    try std.testing.expect(mapped.cells[0].strikethrough);
    try std.testing.expectEqual(@as(u8, 66), mapped.cells[0].fg.r);
    try std.testing.expectEqual(@as(u8, 99), mapped.cells[0].fg.g);
    try std.testing.expectEqual(@as(u8, 132), mapped.cells[0].fg.b);
    try std.testing.expectEqual(@as(u8, 255), mapped.cells[0].fg.a);
    try std.testing.expectEqual(@as(u8, 33), mapped.cells[0].underline_color.r);

    try std.testing.expectEqual(@as(u21, ' '), mapped.cells[1].codepoint);
    try std.testing.expectEqual(@as(u8, 0), mapped.cells[1].combining_len);
    try std.testing.expectEqual(@as(u32, 0), mapped.cells[1].combining[0]);
    try std.testing.expectEqual(false, mapped.cells[1].underline);
    try std.testing.expectEqual(false, mapped.cells[1].strikethrough);
    try std.testing.expectEqual(@as(u8, 0x11), mapped.cells[1].bg.r);
    try std.testing.expectEqual(@as(u8, 0x22), mapped.cells[1].bg.g);
    try std.testing.expectEqual(@as(u8, 0x33), mapped.cells[1].bg.b);
}

test "source text input maps inverse publication colors" {
    var cells = [_]source_vt.SourceCell{
        .{
            .codepoint = 'R',
            .flags = .{ .continuation = 0 },
            .fg_color = .{ .kind = 2, .value = 0x102030 },
            .bg_color = .{ .kind = 2, .value = 0xA0B0C0 },
            .underline_color = .{ .kind = 0, .value = 0 },
            .underline_style = 0,
            .attrs = .{ .bold = 0, .dim = 0, .italic = 0, .underline = 0, .underline_color_set = 0, .blink = 0, .inverse = 1, .invisible = 0, .strikethrough = 0, .selected = 0 },
            .link_id = 0,
        },
        .{
            .codepoint = 'D',
            .flags = .{ .continuation = 0 },
            .fg_color = .{ .kind = 0, .value = 0 },
            .bg_color = .{ .kind = 0, .value = 0 },
            .underline_color = .{ .kind = 0, .value = 0 },
            .underline_style = 0,
            .attrs = .{ .bold = 0, .dim = 0, .italic = 0, .underline = 0, .underline_color_set = 0, .blink = 0, .inverse = 1, .invisible = 0, .strikethrough = 0, .selected = 0 },
            .link_id = 0,
        },
    };
    var colors = std.mem.zeroes(source_vt.SourceColors);
    colors.foreground = .{ .r = 0xCC, .g = 0xDD, .b = 0xEE };
    colors.background = .{ .r = 0x11, .g = 0x22, .b = 0x33 };

    var storage: [2]contract.CellInput = undefined;
    const dirty_rows = [_]u8{1};
    const dirty_starts = [_]u16{0};
    const dirty_ends = [_]u16{1};
    const mapped = publicationSourceToTextSceneInputBorrowed(storage[0..], .{
        .cols = 2,
        .rows = 1,
        .history_count = 0,
        .scroll_row = 0,
        .snapshot_seq = 1,
        .dirty_epoch = 1,
        .is_alternate_screen = false,
        .cells = cells[0..],
        .cursor = .{ .visible = false, .row = 0, .col = 0, .shape = .block },
        .colors = colors,
        .selection = .{ .active = 0, .selecting = 0, .start = .{ .row = 0, .col = 0 }, .end = .{ .row = 0, .col = 0 } },
        .cursor_phase_visible = true,
        .dirty_rows = @constCast(&dirty_rows),
        .dirty_cols_start = @constCast(&dirty_starts),
        .dirty_cols_end = @constCast(&dirty_ends),
    }, false);

    try std.testing.expectEqual(@as(u8, 0xA0), mapped.cells[0].fg.r);
    try std.testing.expectEqual(@as(u8, 0xB0), mapped.cells[0].fg.g);
    try std.testing.expectEqual(@as(u8, 0xC0), mapped.cells[0].fg.b);
    try std.testing.expectEqual(@as(u8, 0x10), mapped.cells[0].bg.r);
    try std.testing.expectEqual(@as(u8, 0x20), mapped.cells[0].bg.g);
    try std.testing.expectEqual(@as(u8, 0x30), mapped.cells[0].bg.b);

    try std.testing.expectEqual(@as(u8, 0x11), mapped.cells[1].fg.r);
    try std.testing.expectEqual(@as(u8, 0x22), mapped.cells[1].fg.g);
    try std.testing.expectEqual(@as(u8, 0x33), mapped.cells[1].fg.b);
    try std.testing.expectEqual(@as(u8, 0xCC), mapped.cells[1].bg.r);
    try std.testing.expectEqual(@as(u8, 0xDD), mapped.cells[1].bg.g);
    try std.testing.expectEqual(@as(u8, 0xEE), mapped.cells[1].bg.b);
}

test "source text input marks Alacritty-empty cells before color mapping" {
    const cells = [_]source_cell.Cell{
        .{},
        .{ .codepoint = '\t' },
        .{ .codepoint = ' ', .bg_color = .{ .kind = .rgb, .value = 0 } },
        .{ .codepoint = ' ', .attrs = .{ .underline = true } },
        .{ .codepoint = ' ', .flags = .{ .continuation = true } },
    };
    const state = .{
        .grid = .{ .cells = &cells, .cols = 5, .rows = 1 },
        .cursor = .{ .visible = false, .col = 0, .row = 0, .shape = .block },
        .damage = .{ .full = true, .dirty_rows = &[_]bool{}, .dirty_cols_start = &[_]u16{}, .dirty_cols_end = &[_]u16{} },
    };

    var input = try vtStateToTextSceneInput(std.testing.allocator, state);
    defer input.deinit();

    try std.testing.expect(input.cells[0].empty);
    try std.testing.expect(input.cells[1].empty);
    try std.testing.expect(!input.cells[2].empty);
    try std.testing.expect(!input.cells[3].empty);
    try std.testing.expect(!input.cells[4].empty);
}

test "source text input treats foreground-colored blanks as non-empty" {
    const cells = [_]source_cell.Cell{
        .{ .codepoint = ' ', .fg_color = .{ .kind = .indexed, .value = 2 } },
        .{ .codepoint = '\t', .fg_color = .{ .kind = .rgb, .value = 0x33AAFF } },
    };
    const state = .{
        .grid = .{ .cells = &cells, .cols = 2, .rows = 1 },
        .cursor = .{ .visible = false, .col = 0, .row = 0, .shape = .block },
        .damage = .{ .full = true, .dirty_rows = &[_]bool{}, .dirty_cols_start = &[_]u16{}, .dirty_cols_end = &[_]u16{} },
    };

    var input = try vtStateToTextSceneInput(std.testing.allocator, state);
    defer input.deinit();

    try std.testing.expect(!input.cells[0].empty);
    try std.testing.expect(!input.cells[1].empty);
}

test "source text input threads partial damage into text scene input" {
    const cells = [_]source_cell.Cell{ .{}, .{} };
    const dirty_rows = [_]bool{ false, true };
    const dirty_starts = [_]u16{ 0, 2 };
    const dirty_ends = [_]u16{ 0, 5 };
    const state = .{
        .grid = .{ .cells = &cells, .cols = 6, .rows = 2 },
        .cursor = .{ .visible = false, .col = 0, .row = 0, .shape = .block },
        .damage = .{
            .full = false,
            .dirty_rows = &dirty_rows,
            .dirty_cols_start = &dirty_starts,
            .dirty_cols_end = &dirty_ends,
        },
    };
    var input = try vtStateToTextSceneInput(std.testing.allocator, state);
    defer input.deinit();
    try std.testing.expect(!input.options.scene.damage.full);
    try std.testing.expectEqual(@as(u16, 2), count16(input.options.scene.damage.dirty_rows));
    try std.testing.expectEqual(@as(u16, 2), input.options.scene.damage.dirty_cols_start[1]);
}

test "source text input maps only dirty ranges for partial damage" {
    const cells = [_]source_cell.Cell{
        .{ .codepoint = 'A' },
        .{ .codepoint = 'B' },
        .{ .codepoint = 'C' },
        .{ .codepoint = 'D' },
    };
    const dirty_rows = [_]bool{ false, true };
    const dirty_starts = [_]u16{ 0, 1 };
    const dirty_ends = [_]u16{ 0, 1 };
    const state = .{
        .grid = .{ .cells = &cells, .cols = 2, .rows = 2 },
        .cursor = .{ .visible = false, .col = 0, .row = 0, .shape = .block },
        .damage = .{
            .full = false,
            .dirty_rows = &dirty_rows,
            .dirty_cols_start = &dirty_starts,
            .dirty_cols_end = &dirty_ends,
        },
    };
    var input = try vtStateToTextSceneInput(std.testing.allocator, state);
    defer input.deinit();

    try std.testing.expect(input.cells[0].empty);
    try std.testing.expect(input.cells[1].empty);
    try std.testing.expect(input.cells[2].empty);
    try std.testing.expectEqual(@as(u21, 'D'), input.cells[3].codepoint);
    try std.testing.expect(!input.cells[3].empty);
}

test "source text input borrowed publication mapping reuses caller storage" {
    var cells = [_]source_vt.SourceCell{
        .{
            .codepoint = 'A',
            .flags = .{ .continuation = 0 },
            .fg_color = .{ .kind = 0, .value = 0 },
            .bg_color = .{ .kind = 0, .value = 0 },
            .underline_color = .{ .kind = 0, .value = 0 },
            .underline_style = 0,
            .attrs = .{ .bold = 0, .dim = 0, .italic = 0, .underline = 0, .underline_color_set = 0, .blink = 0, .inverse = 0, .invisible = 0, .strikethrough = 0, .selected = 0 },
            .link_id = 0,
        },
        .{
            .codepoint = ' ',
            .flags = .{ .continuation = 0 },
            .fg_color = .{ .kind = 0, .value = 0 },
            .bg_color = .{ .kind = 0, .value = 0 },
            .underline_color = .{ .kind = 0, .value = 0 },
            .underline_style = 0,
            .attrs = .{ .bold = 0, .dim = 0, .italic = 0, .underline = 0, .underline_color_set = 0, .blink = 0, .inverse = 0, .invisible = 0, .strikethrough = 0, .selected = 0 },
            .link_id = 0,
        },
    };
    var storage: [4]contract.CellInput = undefined;
    const dirty_rows = [_]u8{1};
    const dirty_starts = [_]u16{0};
    const dirty_ends = [_]u16{0};
    var colors = std.mem.zeroes(source_vt.SourceColors);
    colors.foreground = .{ .r = default_theme.default_fg.r, .g = default_theme.default_fg.g, .b = default_theme.default_fg.b };
    colors.background = .{ .r = default_theme.default_bg.r, .g = default_theme.default_bg.g, .b = default_theme.default_bg.b };
    colors.cursor = .{ .r = default_theme.cursor_color.r, .g = default_theme.cursor_color.g, .b = default_theme.cursor_color.b };
    const mapped = publicationSourceToTextSceneInputBorrowed(storage[0..], .{
        .cols = 2,
        .rows = 1,
        .history_count = 0,
        .scroll_row = 0,
        .snapshot_seq = 1,
        .dirty_epoch = 1,
        .is_alternate_screen = false,
        .cells = cells[0..],
        .cursor = .{ .visible = false, .row = 0, .col = 0, .shape = .block },
        .colors = colors,
        .selection = .{ .active = 0, .selecting = 0, .start = .{ .row = 0, .col = 0 }, .end = .{ .row = 0, .col = 0 } },
        .cursor_phase_visible = true,
        .dirty_rows = @constCast(&dirty_rows),
        .dirty_cols_start = @constCast(&dirty_starts),
        .dirty_cols_end = @constCast(&dirty_ends),
    }, false);

    try std.testing.expectEqual(@intFromPtr(&storage[0]), @intFromPtr(&mapped.cells[0]));
    try std.testing.expectEqual(@as(u21, 'A'), mapped.cells[0].codepoint);
    try std.testing.expect(mapped.cells[1].empty);
}

test "source text input borrowed publication mapping preserves cursor blink truth" {
    var cells = [_]source_vt.SourceCell{.{
        .codepoint = 'A',
        .flags = .{ .continuation = 0 },
        .fg_color = .{ .kind = 0, .value = 0 },
        .bg_color = .{ .kind = 0, .value = 0 },
        .underline_color = .{ .kind = 0, .value = 0 },
        .underline_style = 0,
        .attrs = .{ .bold = 0, .dim = 0, .italic = 0, .underline = 0, .underline_color_set = 0, .blink = 0, .inverse = 0, .invisible = 0, .strikethrough = 0, .selected = 0 },
        .link_id = 0,
    }};
    var storage: [1]contract.CellInput = undefined;
    const dirty_rows = [_]u8{1};
    const dirty_starts = [_]u16{0};
    const dirty_ends = [_]u16{0};
    var colors = std.mem.zeroes(source_vt.SourceColors);
    colors.foreground = .{ .r = default_theme.default_fg.r, .g = default_theme.default_fg.g, .b = default_theme.default_fg.b };
    colors.background = .{ .r = default_theme.default_bg.r, .g = default_theme.default_bg.g, .b = default_theme.default_bg.b };
    colors.cursor = .{ .r = default_theme.cursor_color.r, .g = default_theme.cursor_color.g, .b = default_theme.cursor_color.b };
    const mapped = publicationSourceToTextSceneInputBorrowed(storage[0..], .{
        .cols = 1,
        .rows = 1,
        .history_count = 0,
        .scroll_row = 0,
        .snapshot_seq = 1,
        .dirty_epoch = 1,
        .is_alternate_screen = false,
        .cells = cells[0..],
        .cursor = .{ .visible = true, .row = 0, .col = 0, .shape = .beam, .blink = true },
        .colors = colors,
        .selection = .{ .active = 0, .selecting = 0, .start = .{ .row = 0, .col = 0 }, .end = .{ .row = 0, .col = 0 } },
        .cursor_phase_visible = true,
        .dirty_rows = @constCast(&dirty_rows),
        .dirty_cols_start = @constCast(&dirty_starts),
        .dirty_cols_end = @constCast(&dirty_ends),
    }, false);

    try std.testing.expect(mapped.options.scene.cursor != null);
    try std.testing.expectEqual(scene.CursorShape.beam, mapped.options.scene.cursor.?.shape);
    try std.testing.expect(mapped.options.scene.cursor.?.blink);
}

test "source text input borrowed publication mapping hides blinking cursor when host phase is off" {
    var cells = [_]source_vt.SourceCell{.{
        .codepoint = 'A',
        .flags = .{ .continuation = 0 },
        .fg_color = .{ .kind = 0, .value = 0 },
        .bg_color = .{ .kind = 0, .value = 0 },
        .underline_color = .{ .kind = 0, .value = 0 },
        .underline_style = 0,
        .attrs = .{ .bold = 0, .dim = 0, .italic = 0, .underline = 0, .underline_color_set = 0, .blink = 0, .inverse = 0, .invisible = 0, .strikethrough = 0, .selected = 0 },
        .link_id = 0,
    }};
    var storage: [1]contract.CellInput = undefined;
    const dirty_rows = [_]u8{1};
    const dirty_starts = [_]u16{0};
    const dirty_ends = [_]u16{0};
    const mapped = publicationSourceToTextSceneInputBorrowed(storage[0..], .{
        .cols = 1,
        .rows = 1,
        .history_count = 0,
        .scroll_row = 0,
        .snapshot_seq = 1,
        .dirty_epoch = 2,
        .is_alternate_screen = false,
        .cells = cells[0..],
        .cursor = .{ .visible = true, .row = 0, .col = 0, .shape = .beam, .blink = true },
        .colors = std.mem.zeroes(source_vt.SourceColors),
        .selection = .{ .active = 0, .selecting = 0, .start = .{ .row = 0, .col = 0 }, .end = .{ .row = 0, .col = 0 } },
        .cursor_phase_visible = false,
        .dirty_rows = @constCast(&dirty_rows),
        .dirty_cols_start = @constCast(&dirty_starts),
        .dirty_cols_end = @constCast(&dirty_ends),
    }, false);

    try std.testing.expectEqual(@as(?scene.CursorInput, null), mapped.options.scene.cursor);
}

test "source text input borrowed publication mapping applies selection styling across scrollback rows" {
    var cells = [_]source_vt.SourceCell{
        .{
            .codepoint = 'A',
            .flags = .{ .continuation = 0 },
            .fg_color = .{ .kind = 2, .value = 0x102030 },
            .bg_color = .{ .kind = 0, .value = 0 },
            .underline_color = .{ .kind = 0, .value = 0 },
            .underline_style = 0,
            .attrs = .{ .bold = 0, .dim = 0, .italic = 0, .underline = 0, .underline_color_set = 0, .blink = 0, .inverse = 0, .invisible = 0, .strikethrough = 0, .selected = 1 },
            .link_id = 0,
        },
        .{
            .codepoint = 'B',
            .flags = .{ .continuation = 0 },
            .fg_color = .{ .kind = 2, .value = 0x405060 },
            .bg_color = .{ .kind = 0, .value = 0 },
            .underline_color = .{ .kind = 0, .value = 0 },
            .underline_style = 0,
            .attrs = .{ .bold = 0, .dim = 0, .italic = 0, .underline = 0, .underline_color_set = 0, .blink = 0, .inverse = 0, .invisible = 0, .strikethrough = 0, .selected = 0 },
            .link_id = 0,
        },
    };
    var storage: [2]contract.CellInput = undefined;
    const dirty_rows = [_]u8{1};
    const dirty_starts = [_]u16{0};
    const dirty_ends = [_]u16{1};
    var colors = std.mem.zeroes(source_vt.SourceColors);
    colors.foreground = .{ .r = default_theme.default_fg.r, .g = default_theme.default_fg.g, .b = default_theme.default_fg.b };
    colors.background = .{ .r = default_theme.default_bg.r, .g = default_theme.default_bg.g, .b = default_theme.default_bg.b };
    colors.cursor = .{ .r = default_theme.cursor_color.r, .g = default_theme.cursor_color.g, .b = default_theme.cursor_color.b };
    const mapped = publicationSourceToTextSceneInputBorrowed(storage[0..], .{
        .cols = 2,
        .rows = 1,
        .history_count = 1,
        .scroll_row = 1,
        .snapshot_seq = 1,
        .dirty_epoch = 1,
        .is_alternate_screen = false,
        .cells = cells[0..],
        .cursor = .{ .visible = false, .row = 0, .col = 0, .shape = .block },
        .colors = colors,
        .selection = .{ .active = 0, .selecting = 0, .start = .{ .row = 0, .col = 0 }, .end = .{ .row = 0, .col = 0 } },
        .cursor_phase_visible = true,
        .dirty_rows = @constCast(&dirty_rows),
        .dirty_cols_start = @constCast(&dirty_starts),
        .dirty_cols_end = @constCast(&dirty_ends),
    }, false);

    try std.testing.expectEqual(default_theme.default_bg.r, mapped.cells[0].fg.r);
    try std.testing.expectEqual(default_theme.default_fg.r, mapped.cells[0].bg.r);
    try std.testing.expectEqual(@as(u21, 'B'), mapped.cells[1].codepoint);
}

test "source text input borrowed publication mapping uses vt-owned color state" {
    var cells = [_]source_vt.SourceCell{.{
        .codepoint = 'A',
        .flags = .{ .continuation = 0 },
        .fg_color = .{ .kind = 0, .value = 0 },
        .bg_color = .{ .kind = 1, .value = 1 },
        .underline_color = .{ .kind = 0, .value = 0 },
        .underline_style = 0,
        .attrs = .{ .bold = 0, .dim = 0, .italic = 0, .underline = 0, .underline_color_set = 0, .blink = 0, .inverse = 0, .invisible = 0, .strikethrough = 0, .selected = 0 },
        .link_id = 0,
    }};
    var storage: [1]contract.CellInput = undefined;
    const dirty_rows = [_]u8{1};
    const dirty_starts = [_]u16{0};
    const dirty_ends = [_]u16{0};
    var colors = std.mem.zeroes(source_vt.SourceColors);
    colors.foreground = .{ .r = 1, .g = 2, .b = 3 };
    colors.background = .{ .r = 4, .g = 5, .b = 6 };
    colors.cursor = .{ .r = 7, .g = 8, .b = 9 };
    colors.palette[1] = .{ .r = 10, .g = 11, .b = 12 };
    const mapped = publicationSourceToTextSceneInputBorrowed(storage[0..], .{
        .cols = 1,
        .rows = 1,
        .history_count = 0,
        .scroll_row = 0,
        .snapshot_seq = 1,
        .dirty_epoch = 1,
        .is_alternate_screen = false,
        .cells = cells[0..],
        .cursor = .{ .visible = true, .row = 0, .col = 0, .shape = .block, .blink = false },
        .colors = colors,
        .selection = .{ .active = 0, .selecting = 0, .start = .{ .row = 0, .col = 0 }, .end = .{ .row = 0, .col = 0 } },
        .cursor_phase_visible = true,
        .dirty_rows = @constCast(&dirty_rows),
        .dirty_cols_start = @constCast(&dirty_starts),
        .dirty_cols_end = @constCast(&dirty_ends),
    }, false);

    try std.testing.expectEqual(@as(u8, 1), mapped.cells[0].fg.r);
    try std.testing.expectEqual(@as(u8, 10), mapped.cells[0].bg.r);
    try std.testing.expectEqual(@as(u8, 7), mapped.options.scene.cursor.?.color.r);
}

test "source text input remaps semantic default and indexed cells when vt colors change" {
    var cells = [_]source_vt.SourceCell{.{
        .codepoint = 'A',
        .flags = .{ .continuation = 0 },
        .fg_color = .{ .kind = 0, .value = 0 },
        .bg_color = .{ .kind = 1, .value = 3 },
        .underline_color = .{ .kind = 0, .value = 0 },
        .underline_style = 0,
        .attrs = .{ .bold = 0, .dim = 0, .italic = 0, .underline = 0, .underline_color_set = 0, .blink = 0, .inverse = 0, .invisible = 0, .strikethrough = 0, .selected = 0 },
        .link_id = 0,
    }};
    var storage_a: [1]contract.CellInput = undefined;
    var storage_b: [1]contract.CellInput = undefined;
    const dirty_rows = [_]u8{1};
    const dirty_starts = [_]u16{0};
    const dirty_ends = [_]u16{0};

    var colors_a = std.mem.zeroes(source_vt.SourceColors);
    colors_a.foreground = .{ .r = 1, .g = 2, .b = 3 };
    colors_a.background = .{ .r = 4, .g = 5, .b = 6 };
    colors_a.palette[3] = .{ .r = 7, .g = 8, .b = 9 };
    const mapped_a = publicationSourceToTextSceneInputBorrowed(storage_a[0..], .{
        .cols = 1,
        .rows = 1,
        .history_count = 0,
        .scroll_row = 0,
        .snapshot_seq = 1,
        .dirty_epoch = 1,
        .is_alternate_screen = false,
        .cells = cells[0..],
        .cursor = .{ .visible = false, .row = 0, .col = 0, .shape = .block },
        .colors = colors_a,
        .selection = .{ .active = 0, .selecting = 0, .start = .{ .row = 0, .col = 0 }, .end = .{ .row = 0, .col = 0 } },
        .cursor_phase_visible = true,
        .dirty_rows = @constCast(&dirty_rows),
        .dirty_cols_start = @constCast(&dirty_starts),
        .dirty_cols_end = @constCast(&dirty_ends),
    }, false);

    var colors_b = colors_a;
    colors_b.foreground = .{ .r = 10, .g = 11, .b = 12 };
    colors_b.palette[3] = .{ .r = 13, .g = 14, .b = 15 };
    const mapped_b = publicationSourceToTextSceneInputBorrowed(storage_b[0..], .{
        .cols = 1,
        .rows = 1,
        .history_count = 0,
        .scroll_row = 0,
        .snapshot_seq = 2,
        .dirty_epoch = 2,
        .is_alternate_screen = false,
        .cells = cells[0..],
        .cursor = .{ .visible = false, .row = 0, .col = 0, .shape = .block },
        .colors = colors_b,
        .selection = .{ .active = 0, .selecting = 0, .start = .{ .row = 0, .col = 0 }, .end = .{ .row = 0, .col = 0 } },
        .cursor_phase_visible = true,
        .dirty_rows = @constCast(&dirty_rows),
        .dirty_cols_start = @constCast(&dirty_starts),
        .dirty_cols_end = @constCast(&dirty_ends),
    }, false);

    try std.testing.expectEqual(@as(u8, 1), mapped_a.cells[0].fg.r);
    try std.testing.expectEqual(@as(u8, 7), mapped_a.cells[0].bg.r);
    try std.testing.expectEqual(@as(u8, 10), mapped_b.cells[0].fg.r);
    try std.testing.expectEqual(@as(u8, 13), mapped_b.cells[0].bg.r);
}
