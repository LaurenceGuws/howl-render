const std = @import("std");
const source_abi = @import("abi.zig");
const source_publication = @import("publication.zig");
const contract = @import("../text/contract.zig");
const scene = @import("../text/scene.zig");
const scene_damage = @import("../text/scene_damage.zig");
const color = @import("theme.zig");
const cursor = @import("cursor.zig");

pub const SurfaceTheme = color.SurfaceTheme;
pub const default_theme = color.default_theme;
pub const CellSemanticTruth = color.CellSemanticTruth;

pub const PrepareOptions = struct {
    scene: scene.BuildOptions = .{},
};

pub const OwnedSurfaceTextInput = struct {
    allocator: std.mem.Allocator,
    cells: []contract.CellInput,
    grid: contract.GridMetrics,
    options: PrepareOptions,

    pub fn deinit(self: *OwnedSurfaceTextInput) void {
        self.allocator.free(self.cells);
        self.* = undefined;
    }
};

pub const OwnedTextSceneInput = OwnedSurfaceTextInput;

pub const BorrowedSurfaceTextInput = struct {
    cells: []const contract.CellInput,
    grid: contract.GridMetrics,
    options: PrepareOptions,
};

pub const BorrowedTextSceneInput = BorrowedSurfaceTextInput;

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
    if (bold and italic) return .bold_italic;
    if (bold) return .bold;
    if (italic) return .italic;
    return .regular;
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

fn mapSourceCellInput(src: source_abi.SourceCell, theme: SurfaceTheme) contract.CellInput {
    std.debug.assert(src.combining_len <= src.combining.len);
    const truth = color.publicationCellTruth(src);
    const bg = color.mapPublicationColor(src.bg_color, false, theme);
    var out: contract.CellInput = .{
        .codepoint = @intCast(src.codepoint),
        .combining_len = src.combining_len,
        .combining = src.combining,
        .style = mapFontStyle(src.attrs.bold != 0, src.attrs.italic != 0),
        .presentation = detectCellPresentation(@intCast(src.codepoint), src.combining_len, src.combining),
        .dim = src.attrs.dim != 0,
        .invisible = src.attrs.invisible != 0,
        .semantic_fg = color.semanticColorFromPublicationColor(src.fg_color),
        .semantic_bg = color.semanticColorFromPublicationColor(src.bg_color),
        .fg = color.mapPublicationColor(src.fg_color, true, theme),
        .bg = bg,
        .underline_color_set = src.attrs.underline_color_set != 0,
        .semantic_underline_color = color.semanticColorFromPublicationColor(src.underline_color),
        .underline_color = if (src.attrs.underline_color_set != 0) color.mapPublicationColor(src.underline_color, true, theme) else .{ .r = 0, .g = 0, .b = 0, .a = 0 },
        .underline_style = color.mapPublicationUnderlineStyle(src.underline_style),
        .underline = src.attrs.underline != 0,
        .strikethrough = src.attrs.strikethrough != 0,
        .continuation = src.flags.continuation != 0,
        .empty = truth.empty,
    };
    color.assertSemanticEmptyClassification(truth, theme, out.bg, out.empty);
    if (src.attrs.inverse != 0) color.applyInverseStyle(&out, theme, truth);
    if (src.attrs.selected != 0) color.applySelectionStyle(&out, theme, truth);
    return out;
}

pub fn mapCellInput(src: source_abi.SourceCell, theme: SurfaceTheme) contract.CellInput {
    return mapSourceCellInput(src, theme);
}

pub fn mapPublicationCellInput(src: source_abi.SourceCell, theme: SurfaceTheme) contract.CellInput {
    return mapSourceCellInput(src, theme);
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
    for (dirty_rows) |dirty| std.debug.assert(dirty <= 1);
}

fn canMapDirtyOnly(state: anytype) bool {
    const rows = state.grid.rows;
    return !state.damage.full and count16(state.damage.dirty_rows) == rows and count16(state.damage.dirty_cols_start) == rows and count16(state.damage.dirty_cols_end) == rows;
}

fn mapDirtyCellsOnly(dst: []contract.CellInput, cells: []const source_abi.SourceCell, grid_cols: u16, grid_rows: u16, dirty_rows: []const bool, dirty_cols_start: []const u16, dirty_cols_end: []const u16, theme: SurfaceTheme) void {
    const cols: u16 = @max(grid_cols, 1);
    const cell_len = count32(cells);
    var row: u16 = 0;
    while (row < grid_rows) : (row += 1) {
        if (!dirty_rows[@intCast(row)]) continue;
        const base = @as(u32, row) * @as(u32, cols);
        if (base >= cell_len) continue;
        const start_col = @min(dirty_cols_start[@intCast(row)], cols - 1);
        const end_col = @min(dirty_cols_end[@intCast(row)], cols - 1);
        if (end_col < start_col) continue;
        var idx = base + @as(u32, start_col);
        const end_idx = @min(base + @as(u32, end_col) + 1, cell_len);
        while (idx < end_idx) : (idx += 1) dst[@intCast(idx)] = mapCellInput(cells[@intCast(idx)], theme);
    }
}

pub fn vtStateToTextSceneInput(allocator: std.mem.Allocator, state: anytype) !OwnedTextSceneInput {
    return vtStateToTextSceneInputWithTheme(allocator, state, default_theme);
}

pub fn vtStateToSurfaceTextInput(allocator: std.mem.Allocator, state: anytype) !OwnedSurfaceTextInput {
    return vtStateToSurfaceTextInputWithTheme(allocator, state, default_theme);
}

pub fn vtStateToTextSceneInputWithTheme(allocator: std.mem.Allocator, state: anytype, theme: SurfaceTheme) !OwnedTextSceneInput {
    return vtStateToSurfaceTextInputWithTheme(allocator, state, theme);
}

pub fn vtStateToSurfaceTextInputWithTheme(allocator: std.mem.Allocator, state: anytype, theme: SurfaceTheme) !OwnedSurfaceTextInput {
    const cell_inputs = try allocator.alloc(contract.CellInput, state.grid.cells.len);
    errdefer allocator.free(cell_inputs);

    if (canMapDirtyOnly(state)) {
        @memset(cell_inputs, emptyCellInput());
        mapDirtyCellsOnly(cell_inputs, state.grid.cells, state.grid.cols, state.grid.rows, state.damage.dirty_rows, state.damage.dirty_cols_start, state.damage.dirty_cols_end, theme);
    } else {
        for (state.grid.cells, cell_inputs) |src, *dst| dst.* = mapCellInput(src, theme);
    }

    const cursor_presentation = cursor.mapStateCursor(state, theme);
    return .{
        .allocator = allocator,
        .cells = cell_inputs,
        .grid = .{ .cols = state.grid.cols, .rows = state.grid.rows },
        .options = .{ .scene = .{
            .cursor = cursor_presentation,
            .damage = .{
                .full = state.damage.full,
                .dirty_rows = state.damage.dirty_rows,
                .dirty_cols_start = state.damage.dirty_cols_start,
                .dirty_cols_end = state.damage.dirty_cols_end,
            },
        } },
    };
}

pub fn publicationSourceToTextSceneInput(allocator: std.mem.Allocator, source: source_publication.PublicationSource, full_damage: bool) !OwnedTextSceneInput {
    return publicationSourceToTextSceneInputWithTheme(allocator, source, full_damage, color.themeFromPublicationColors(source.colors));
}

pub fn publicationSourceToTextSceneInputWithTheme(allocator: std.mem.Allocator, source: source_publication.PublicationSource, full_damage: bool, theme: SurfaceTheme) !OwnedTextSceneInput {
    const cell_inputs = try allocator.alloc(contract.CellInput, source.cells.len);
    errdefer allocator.free(cell_inputs);

    const mapped = publicationSourceToTextSceneInputBorrowedWithTheme(cell_inputs, source, full_damage, theme);
    return .{ .allocator = allocator, .cells = mapped.cells, .grid = mapped.grid, .options = mapped.options };
}

pub fn publicationSourceToTextSceneInputBorrowed(cell_inputs: []contract.CellInput, source: source_publication.PublicationSource, full_damage: bool) BorrowedTextSceneInput {
    return publicationSourceToTextSceneInputBorrowedWithTheme(cell_inputs, source, full_damage, color.themeFromPublicationColors(source.colors));
}

pub fn publicationSourceToTextSceneInputBorrowedWithTheme(cell_inputs: []contract.CellInput, source: source_publication.PublicationSource, full_damage: bool, theme: SurfaceTheme) BorrowedTextSceneInput {
    std.debug.assert(cell_inputs.len >= source.cells.len);
    const mapped_cells = cell_inputs[0..source.cells.len];

    assertDirtyRowsBoolBytes(source.dirty_rows);
    const dirty_rows: []const bool = @ptrCast(source.dirty_rows);
    const damage = scene_damage.DamageInput{
        .full = full_damage,
        .dirty_rows = dirty_rows,
        .dirty_cols_start = source.dirty_cols_start,
        .dirty_cols_end = source.dirty_cols_end,
    };

    if (!full_damage and count16(dirty_rows) == source.rows and count16(source.dirty_cols_start) == source.rows and count16(source.dirty_cols_end) == source.rows) {
        @memset(mapped_cells, emptyCellInput());
        const cols: u16 = @max(source.cols, 1);
        const cell_len = count32(source.cells);
        var row: u16 = 0;
        while (row < source.rows) : (row += 1) {
            if (!dirty_rows[@intCast(row)]) continue;
            const base = @as(u32, row) * @as(u32, cols);
            if (base >= cell_len) continue;
            const start_col = @min(source.dirty_cols_start[@intCast(row)], cols - 1);
            const end_col = @min(source.dirty_cols_end[@intCast(row)], cols - 1);
            if (end_col < start_col) continue;
            var idx = base + @as(u32, start_col);
            const end_idx = @min(base + @as(u32, end_col) + 1, cell_len);
            while (idx < end_idx) : (idx += 1) mapped_cells[@intCast(idx)] = mapPublicationCellInput(source.cells[@intCast(idx)], theme);
        }
    } else {
        for (source.cells, mapped_cells) |src, *dst| dst.* = mapPublicationCellInput(src, theme);
    }

    const cursor_presentation = cursor.mapPublicationCursor(source, theme);
    return .{
        .cells = mapped_cells,
        .grid = .{ .cols = source.cols, .rows = source.rows },
        .options = .{ .scene = .{ .cursor = cursor_presentation, .damage = damage } },
    };
}

test "renderable content converts VT source to text scene input" {
    const cells = [_]source_abi.SourceCell{.{
        .codepoint = 'A',
        .underline_color = .{ .kind = 2, .value = 0xCC3366 },
        .attrs = .{ .underline = 1, .underline_color_set = 1 },
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
    try std.testing.expect(!input.cells[0].empty);
    try std.testing.expect(input.options.scene.cursor != null);
    try std.testing.expectEqual(cursor.CursorShape.beam, input.options.scene.cursor.?.shape);
}

test "renderable content maps inverse VT source colors" {
    const cells = [_]source_abi.SourceCell{.{
        .codepoint = 'R',
        .fg_color = .{ .kind = 2, .value = 0x102030 },
        .bg_color = .{ .kind = 2, .value = 0xA0B0C0 },
        .attrs = .{ .inverse = 1 },
    }};
    const state = .{
        .grid = .{ .cells = &cells, .cols = 1, .rows = 1 },
        .cursor = .{ .visible = false, .col = 0, .row = 0, .shape = .beam, .blink = false },
        .damage = .{ .full = true, .dirty_rows = &[_]bool{}, .dirty_cols_start = &[_]u16{}, .dirty_cols_end = &[_]u16{} },
    };
    var input = try vtStateToTextSceneInput(std.testing.allocator, state);
    defer input.deinit();
    try std.testing.expectEqual(@as(u8, 0xA0), input.cells[0].fg.r);
    try std.testing.expectEqual(@as(u8, 0x10), input.cells[0].bg.r);
    try std.testing.expect(!input.cells[0].empty);
}

test "renderable content keeps opaque default background for blank VT cell" {
    const cells = [_]source_abi.SourceCell{.{ .codepoint = ' ', .bg_color = .{ .kind = 0, .value = 0 } }};
    const state = .{
        .grid = .{ .cells = &cells, .cols = 1, .rows = 1 },
        .cursor = .{ .visible = false, .col = 0, .row = 0, .shape = .block },
        .damage = .{ .full = true, .dirty_rows = &[_]bool{}, .dirty_cols_start = &[_]u16{}, .dirty_cols_end = &[_]u16{} },
    };
    var input = try vtStateToTextSceneInput(std.testing.allocator, state);
    defer input.deinit();
    try std.testing.expectEqual(default_theme.default_bg.r, input.cells[0].bg.r);
    try std.testing.expectEqual(@as(u8, 255), input.cells[0].bg.a);
    try std.testing.expect(input.cells[0].empty);
}

test "renderable content keeps default background truth through inverse VT cell" {
    const cells = [_]source_abi.SourceCell{.{
        .codepoint = 'I',
        .fg_color = .{ .kind = 0, .value = 0 },
        .bg_color = .{ .kind = 0, .value = 0 },
        .attrs = .{ .inverse = 1 },
    }};
    const state = .{
        .grid = .{ .cells = &cells, .cols = 1, .rows = 1 },
        .cursor = .{ .visible = false, .col = 0, .row = 0, .shape = .block },
        .damage = .{ .full = true, .dirty_rows = &[_]bool{}, .dirty_cols_start = &[_]u16{}, .dirty_cols_end = &[_]u16{} },
    };
    var input = try vtStateToTextSceneInput(std.testing.allocator, state);
    defer input.deinit();
    try std.testing.expectEqual(default_theme.default_bg.r, input.cells[0].fg.r);
    try std.testing.expectEqual(default_theme.default_fg.r, input.cells[0].bg.r);
}

test "renderable content publication mapping preserves combining truth" {
    var cells = [_]source_abi.SourceCell{.{
        .codepoint = 'o',
        .combining_len = 1,
        .combining = .{ 0x0300, 0, 0 },
        .flags = .{ .continuation = 0 },
        .fg_color = .{ .kind = 0, .value = 0 },
        .bg_color = .{ .kind = 0, .value = 0 },
        .underline_color = .{ .kind = 0, .value = 0 },
        .underline_style = 0,
        .attrs = std.mem.zeroes(source_abi.SourceCellAttrs),
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
        .colors = std.mem.zeroes(source_abi.SourceColors),
        .selection = std.mem.zeroes(source_abi.SourceSelection),
        .cursor_phase_visible = true,
        .dirty_rows = @constCast(&dirty_rows),
        .dirty_cols_start = @constCast(&dirty_starts),
        .dirty_cols_end = @constCast(&dirty_ends),
    }, false);
    try std.testing.expectEqual(@as(u8, 1), mapped.cells[0].combining_len);
    try std.testing.expectEqual(@as(u32, 0x0300), mapped.cells[0].combining[0]);
}

test "renderable content publication mapping threads explicit no-shape cursor truth" {
    var cells = [_]source_abi.SourceCell{std.mem.zeroes(source_abi.SourceCell)};
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
        .cursor = .{ .visible = true, .row = 0, .col = 0, .shape = .none, .effective_shape = .none },
        .colors = std.mem.zeroes(source_abi.SourceColors),
        .selection = std.mem.zeroes(source_abi.SourceSelection),
        .cursor_phase_visible = true,
        .dirty_rows = @constCast(&dirty_rows),
        .dirty_cols_start = @constCast(&dirty_starts),
        .dirty_cols_end = @constCast(&dirty_ends),
    }, false);
    try std.testing.expect(mapped.options.scene.cursor != null);
    try std.testing.expectEqual(cursor.CursorShape.none, mapped.options.scene.cursor.?.shape);
    try std.testing.expect(mapped.options.scene.cursor.?.visible);
}

test "renderable content publication mapping threads partial damage" {
    const cells = [_]source_abi.SourceCell{ .{}, .{} };
    const dirty_rows = [_]bool{ false, true };
    const dirty_starts = [_]u16{ 0, 2 };
    const dirty_ends = [_]u16{ 0, 5 };
    const state = .{
        .grid = .{ .cells = &cells, .cols = 6, .rows = 2 },
        .cursor = .{ .visible = false, .col = 0, .row = 0, .shape = .block },
        .damage = .{ .full = false, .dirty_rows = &dirty_rows, .dirty_cols_start = &dirty_starts, .dirty_cols_end = &dirty_ends },
    };
    var input = try vtStateToTextSceneInput(std.testing.allocator, state);
    defer input.deinit();
    try std.testing.expect(!input.options.scene.damage.full);
    try std.testing.expectEqual(@as(u16, 2), count16(input.options.scene.damage.dirty_rows));
}

test "renderable content maps only dirty ranges for partial damage" {
    const cells = [_]source_abi.SourceCell{ .{ .codepoint = 'A' }, .{ .codepoint = 'B' }, .{ .codepoint = 'C' }, .{ .codepoint = 'D' } };
    const dirty_rows = [_]bool{ false, true };
    const dirty_starts = [_]u16{ 0, 1 };
    const dirty_ends = [_]u16{ 0, 1 };
    const state = .{
        .grid = .{ .cells = &cells, .cols = 2, .rows = 2 },
        .cursor = .{ .visible = false, .col = 0, .row = 0, .shape = .block },
        .damage = .{ .full = false, .dirty_rows = &dirty_rows, .dirty_cols_start = &dirty_starts, .dirty_cols_end = &dirty_ends },
    };
    var input = try vtStateToTextSceneInput(std.testing.allocator, state);
    defer input.deinit();
    try std.testing.expect(input.cells[0].empty);
    try std.testing.expectEqual(@as(u21, 'D'), input.cells[3].codepoint);
}

test "renderable content borrowed publication mapping reuses caller storage" {
    var cells = [_]source_abi.SourceCell{ std.mem.zeroes(source_abi.SourceCell), std.mem.zeroes(source_abi.SourceCell) };
    cells[0].codepoint = 'A';
    cells[1].codepoint = ' ';
    var storage: [4]contract.CellInput = undefined;
    const dirty_rows = [_]u8{1};
    const dirty_starts = [_]u16{0};
    const dirty_ends = [_]u16{0};
    var colors = std.mem.zeroes(source_abi.SourceColors);
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
        .selection = std.mem.zeroes(source_abi.SourceSelection),
        .cursor_phase_visible = true,
        .dirty_rows = @constCast(&dirty_rows),
        .dirty_cols_start = @constCast(&dirty_starts),
        .dirty_cols_end = @constCast(&dirty_ends),
    }, false);
    try std.testing.expectEqual(@intFromPtr(&storage[0]), @intFromPtr(&mapped.cells[0]));
}

test "renderable content uses VT-owned color state and selection styling" {
    var cells = [_]source_abi.SourceCell{ std.mem.zeroes(source_abi.SourceCell), std.mem.zeroes(source_abi.SourceCell) };
    cells[0].codepoint = 'A';
    cells[0].fg_color = .{ .kind = 0, .value = 0 };
    cells[0].bg_color = .{ .kind = 1, .value = 1 };
    cells[0].attrs.selected = 1;
    cells[1].codepoint = 'B';
    var storage: [2]contract.CellInput = undefined;
    const dirty_rows = [_]u8{1};
    const dirty_starts = [_]u16{0};
    const dirty_ends = [_]u16{1};
    var colors = std.mem.zeroes(source_abi.SourceColors);
    colors.foreground = .{ .r = 1, .g = 2, .b = 3 };
    colors.background = .{ .r = 4, .g = 5, .b = 6 };
    colors.cursor = .{ .r = 7, .g = 8, .b = 9 };
    colors.palette[1] = .{ .r = 10, .g = 11, .b = 12 };
    const mapped = publicationSourceToTextSceneInputBorrowed(storage[0..], .{
        .cols = 2,
        .rows = 1,
        .history_count = 1,
        .scroll_row = 1,
        .snapshot_seq = 1,
        .dirty_epoch = 1,
        .is_alternate_screen = false,
        .cells = cells[0..],
        .cursor = .{ .visible = true, .row = 0, .col = 0, .shape = .block, .blink = false, .cursor_color = .{ .kind = 2, .value = 0x070809 }, .cursor_text_color = .{ .kind = 1, .value = 1 } },
        .colors = colors,
        .selection = std.mem.zeroes(source_abi.SourceSelection),
        .cursor_phase_visible = true,
        .dirty_rows = @constCast(&dirty_rows),
        .dirty_cols_start = @constCast(&dirty_starts),
        .dirty_cols_end = @constCast(&dirty_ends),
    }, false);
    try std.testing.expectEqual(colors.background.r, mapped.cells[0].fg.r);
    try std.testing.expectEqual(colors.foreground.r, mapped.cells[0].bg.r);
    try std.testing.expectEqual(@as(u32, 0x070809), mapped.options.scene.cursor.?.cursor_color.value);
}

test "renderable content threads configured cursor defaults into publication cursor" {
    var storage: [1]contract.CellInput = undefined;
    const colors = std.mem.zeroes(source_abi.SourceColors);
    var cells = [_]source_abi.SourceCell{std.mem.zeroes(source_abi.SourceCell)};
    const dirty_rows = [_]u8{1};
    const dirty_starts = [_]u16{0};
    const dirty_ends = [_]u16{0};
    const theme = color.themeFromPublicationColorsWithCursorConfig(colors, .{
        .cursor_color = .{ .kind = 2, .value = 0x102030 },
        .cursor_text_color = .{ .kind = 2, .value = 0x405060 },
        .cursor_trail_color = .{ .kind = 2, .value = 0x708090 },
        .cursor_beam_thickness = 2.5,
        .cursor_underline_thickness = 3.5,
    });
    const mapped = publicationSourceToTextSceneInputBorrowedWithTheme(storage[0..], .{
        .cols = 1,
        .rows = 1,
        .history_count = 0,
        .scroll_row = 0,
        .snapshot_seq = 1,
        .dirty_epoch = 1,
        .is_alternate_screen = false,
        .cells = cells[0..],
        .cursor = .{ .visible = true, .row = 0, .col = 0, .shape = .block, .cursor_color = .{ .kind = 0, .value = 0 }, .cursor_text_color = .{ .kind = 0, .value = 0 } },
        .colors = colors,
        .selection = std.mem.zeroes(source_abi.SourceSelection),
        .cursor_phase_visible = true,
        .dirty_rows = @constCast(&dirty_rows),
        .dirty_cols_start = @constCast(&dirty_starts),
        .dirty_cols_end = @constCast(&dirty_ends),
    }, false, theme);
    try std.testing.expectEqual(@as(u32, 0x102030), mapped.options.scene.cursor.?.cursor_color.value);
    try std.testing.expectEqual(@as(u32, 0x405060), mapped.options.scene.cursor.?.cursor_text_color.value);
    try std.testing.expectEqual(@as(u32, 0x708090), mapped.options.scene.cursor.?.cursor_trail_color.value);
}

fn rgbValue(value: contract.Rgba8) u32 {
    return (@as(u32, value.r) << 16) | (@as(u32, value.g) << 8) | value.b;
}

test "renderable content semantic empty truth does not treat invisible or continuation cells as empty" {
    const invisible = mapPublicationCellInput(.{ .codepoint = ' ', .attrs = .{ .invisible = 1 } }, default_theme);
    try std.testing.expect(!invisible.empty);

    var publication = std.mem.zeroes(source_abi.SourceCell);
    publication.codepoint = ' ';
    publication.flags.continuation = 1;
    const mapped = mapPublicationCellInput(publication, default_theme);
    try std.testing.expect(!mapped.empty);
}
