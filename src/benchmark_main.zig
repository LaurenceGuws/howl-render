const std = @import("std");
const c = @import("howl_render_c");
const layout = @import("layout.zig");

const render = @import("text/draw_primitives.zig");
const surface_preparer = @import("surface/surface_preparer.zig");
const face_selection = @import("text/face_selection.zig");
const cluster = @import("text/shape/cluster.zig");

const RunCount = u32;

const OutputFormat = enum { ndjson, text };
const BenchmarkInput = union(enum) {
    cells: []render.CellInput,
    cell_texts: []const cluster.CellTextInput,
};

const Options = struct {
    runs: RunCount = 10,
    format: OutputFormat = .ndjson,
};

const RunObservation = struct {
    ns: u64,
    alloc_count: u64,
    alloc_bytes: u64,
    peak_live_bytes: u64,
};

const BenchmarkResult = struct {
    name: []const u8,
    grid_cols: u16,
    grid_rows: u16,
    dirty_cells_per_run: u32,
    runs: RunCount,
    cold_ns: u64,
    cold_alloc_count: u64,
    cold_alloc_bytes: u64,
    cold_peak_live_bytes: u64,
    cold_fills: u64,
    cold_glyphs: u64,
    cold_uploads: u64,
    warm_median_ns: u64,
    warm_p95_ns: u64,
    warm_median_alloc_count: u64,
    warm_median_alloc_bytes: u64,
    warm_median_peak_live_bytes: u64,
    warm_median_fills: u64,
    warm_median_glyphs: u64,
    warm_median_uploads: u64,
    fn dirtyCellsPerSecond(self: BenchmarkResult) f64 {
        const median_seconds = @as(f64, @floatFromInt(self.warm_median_ns)) / 1_000_000_000.0;
        if (median_seconds <= 0) return 0;
        return @as(f64, @floatFromInt(self.dirty_cells_per_run)) / median_seconds;
    }
};

const BenchmarkDamage = struct {
    full: bool,
    dirty_rows: []const bool,
    dirty_cols_start: []const u16,
    dirty_cols_end: []const u16,
};

const BenchmarkCase = struct {
    name: []const u8,
    input: BenchmarkInput,
    grid: render.CellGridMetrics,
    damage: BenchmarkDamage,
    cell_px: layout.CellSize,
    dirty_cells_per_run: u32,
};

const BenchmarkPrepareContext = struct {
    selection: face_selection.FaceSelection,
    options: surface_preparer.PrepareOptions,
    borrowed_cells: []render.CellInput = &.{},
};

const ColdRun = struct {
    observation: RunObservation,
    fills: u64,
    glyphs: u64,
    uploads: u64,
};

const WarmSummary = struct {
    median_ns: u64,
    p95_ns: u64,
    median_alloc_count: u64,
    median_alloc_bytes: u64,
    median_peak_live_bytes: u64,
    median_fills: u64,
    median_glyphs: u64,
    median_uploads: u64,
};

const CountingAllocator = struct {
    child: std.mem.Allocator,
    alloc_count: u64 = 0,
    alloc_bytes: u64 = 0,
    live_bytes: u64 = 0,
    peak_live_bytes: u64 = 0,
    window_alloc_count: u64 = 0,
    window_alloc_bytes: u64 = 0,
    window_peak_live_bytes: u64 = 0,
    window_live_baseline: u64 = 0,

    const vtable = std.mem.Allocator.VTable{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };

    fn init(child: std.mem.Allocator) CountingAllocator {
        return .{ .child = child };
    }

    fn allocator(self: *CountingAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn resetWindow(self: *CountingAllocator) void {
        self.window_alloc_count = 0;
        self.window_alloc_bytes = 0;
        self.window_peak_live_bytes = 0;
        self.window_live_baseline = self.live_bytes;
    }

    fn updateWindowPeak(self: *CountingAllocator) void {
        if (self.live_bytes >= self.window_live_baseline) {
            const delta = self.live_bytes - self.window_live_baseline;
            if (delta > self.window_peak_live_bytes) self.window_peak_live_bytes = delta;
        }
    }

    fn accountAlloc(self: *CountingAllocator, len: usize) void {
        self.alloc_count += 1;
        self.alloc_bytes += len;
        self.live_bytes += len;
        if (self.live_bytes > self.peak_live_bytes) self.peak_live_bytes = self.live_bytes;
        self.window_alloc_count += 1;
        self.window_alloc_bytes += len;
        self.updateWindowPeak();
    }

    fn accountResize(self: *CountingAllocator, old_len: usize, new_len: usize) void {
        if (new_len > old_len) {
            const delta = new_len - old_len;
            self.alloc_bytes += delta;
            self.window_alloc_bytes += delta;
            self.live_bytes += delta;
        } else {
            self.live_bytes -|= old_len - new_len;
        }
        self.updateWindowPeak();
    }

    // std.mem.Allocator owns architecture-sized lengths and return addresses at this callback seam.
    // We translate those edge values into fixed-width benchmark counters immediately below.
    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        const ptr = self.child.rawAlloc(len, alignment, ret_addr) orelse return null;
        self.accountAlloc(len);
        return ptr;
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        if (!self.child.rawResize(memory, alignment, new_len, ret_addr)) return false;
        self.accountResize(memory.len, new_len);
        return true;
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        const ptr = self.child.rawRemap(memory, alignment, new_len, ret_addr) orelse return null;
        self.accountResize(memory.len, new_len);
        return ptr;
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        self.child.rawFree(memory, alignment, ret_addr);
        self.live_bytes -|= memory.len;
        self.updateWindowPeak();
    }
};

fn lessU64(_: void, lhs: u64, rhs: u64) bool {
    return lhs < rhs;
}

fn medianU64(scratch: []u64) u64 {
    std.sort.heap(u64, scratch, {}, lessU64);
    return scratch[scratch.len / 2];
}

fn p95U64(scratch: []u64) u64 {
    std.sort.heap(u64, scratch, {}, lessU64);
    const n = scratch.len;
    const idx = ((95 * n) + 99) / 100 - 1;
    return scratch[@min(idx, n - 1)];
}

fn nowNs(io: std.Io) u64 {
    return @intCast(std.Io.Clock.awake.now(io).toNanoseconds());
}

fn rgba(r: u8, g: u8, b: u8) render.Rgba8 {
    return .{ .r = r, .g = g, .b = b, .a = 255 };
}

fn defaultCellMetrics(cell_px: layout.CellSize) render.CellMetrics {
    const h = @max(cell_px.height, 1);
    return .{
        .cell_w_px = @max(cell_px.width, 1),
        .cell_h_px = h,
        .baseline_px = @intCast(@max(h - @divFloor(h, 5), 1)),
    };
}

fn count32(items: anytype) u32 {
    std.debug.assert(items.len <= std.math.maxInt(u32));
    return @intCast(items.len);
}

fn count64(items: anytype) u64 {
    return count32(items);
}

fn cellCount(rows: u16, cols: u16) u32 {
    return @as(u32, rows) * @as(u32, cols);
}

fn initCells(allocator: std.mem.Allocator, rows: u16, cols: u16, bg: render.Rgba8) ![]render.CellInput {
    const len = cellCount(rows, cols);
    const cells = try allocator.alloc(render.CellInput, @intCast(len));
    for (cells) |*cell| {
        cell.* = .{ .codepoint = ' ', .fg = rgba(240, 240, 240), .bg = bg };
    }
    return cells;
}

fn initDirtyAll(allocator: std.mem.Allocator, rows: u16, cols: u16) !struct {
    rows: []bool,
    starts: []u16,
    ends: []u16,
} {
    const dirty_rows = try allocator.alloc(bool, rows);
    const dirty_starts = try allocator.alloc(u16, rows);
    const dirty_ends = try allocator.alloc(u16, rows);
    @memset(dirty_rows, true);
    @memset(dirty_starts, 0);
    @memset(dirty_ends, cols -| 1);
    return .{ .rows = dirty_rows, .starts = dirty_starts, .ends = dirty_ends };
}

fn initDirtySparse(allocator: std.mem.Allocator, rows: u16, active_rows: []const u16, start_col: u16, end_col: u16) !struct {
    rows: []bool,
    starts: []u16,
    ends: []u16,
} {
    const dirty_rows = try allocator.alloc(bool, rows);
    const dirty_starts = try allocator.alloc(u16, rows);
    const dirty_ends = try allocator.alloc(u16, rows);
    @memset(dirty_rows, false);
    @memset(dirty_starts, 0);
    @memset(dirty_ends, 0);
    for (active_rows) |row| {
        dirty_rows[row] = true;
        dirty_starts[row] = start_col;
        dirty_ends[row] = end_col;
    }
    return .{ .rows = dirty_rows, .starts = dirty_starts, .ends = dirty_ends };
}

fn benchmarkDamage(full: bool, dirty_rows: []const bool, dirty_cols_start: []const u16, dirty_cols_end: []const u16) BenchmarkDamage {
    return .{
        .full = full,
        .dirty_rows = dirty_rows,
        .dirty_cols_start = dirty_cols_start,
        .dirty_cols_end = dirty_cols_end,
    };
}

fn buildBenchmarkCase(name: []const u8, input: BenchmarkInput, grid: render.CellGridMetrics, full: bool, dirty_rows: []const bool, dirty_cols_start: []const u16, dirty_cols_end: []const u16, cell_px: layout.CellSize, dirty_cells_per_run: u32) BenchmarkCase {
    return .{
        .name = name,
        .input = input,
        .grid = grid,
        .damage = benchmarkDamage(full, dirty_rows, dirty_cols_start, dirty_cols_end),
        .cell_px = cell_px,
        .dirty_cells_per_run = dirty_cells_per_run,
    };
}

fn buildAsciiFullCase(allocator: std.mem.Allocator) !BenchmarkCase {
    const rows: u16 = 24;
    const cols: u16 = 80;
    const bg = rgba(12, 12, 18);
    const fg = rgba(235, 238, 242);
    const cells = try initCells(allocator, rows, cols, bg);
    const dirty = try initDirtyAll(allocator, rows, cols);
    var row: u16 = 0;
    while (row < rows) : (row += 1) {
        const row_base = @as(u32, row) * cols;
        var col: u16 = 0;
        while (col < cols) : (col += 1) {
            const idx = row_base + col;
            cells[@intCast(idx)].codepoint = @as(u21, 'A') + @as(u21, @intCast(col % 26));
            cells[@intCast(idx)].fg = fg;
        }
    }
    return buildBenchmarkCase(
        "ascii_full",
        .{ .cells = cells },
        .{ .cols = cols, .rows = rows },
        true,
        dirty.rows,
        dirty.starts,
        dirty.ends,
        .{ .width = 9, .height = 18 },
        cellCount(rows, cols),
    );
}

fn buildAsciiFullLargeCase(allocator: std.mem.Allocator) !BenchmarkCase {
    const rows: u16 = 120;
    const cols: u16 = 320;
    const bg = rgba(12, 12, 18);
    const fg = rgba(235, 238, 242);
    const cells = try initCells(allocator, rows, cols, bg);
    const dirty = try initDirtyAll(allocator, rows, cols);
    var row: u16 = 0;
    while (row < rows) : (row += 1) {
        const row_base = @as(u32, row) * cols;
        var col: u16 = 0;
        while (col < cols) : (col += 1) {
            const idx = row_base + col;
            cells[@intCast(idx)].codepoint = @as(u21, 'A') + @as(u21, @intCast(col % 26));
            cells[@intCast(idx)].fg = fg;
        }
    }
    return buildBenchmarkCase(
        "ascii_full_large",
        .{ .cells = cells },
        .{ .cols = cols, .rows = rows },
        true,
        dirty.rows,
        dirty.starts,
        dirty.ends,
        .{ .width = 9, .height = 18 },
        cellCount(rows, cols),
    );
}

fn buildLsdLikeCase(allocator: std.mem.Allocator, colored: bool) !BenchmarkCase {
    const rows: u16 = 52;
    const cols: u16 = 119;
    const bg = rgba(0, 0, 0);
    const fg = rgba(204, 204, 204);
    const dir_fg = rgba(97, 175, 239);
    const exec_fg = rgba(152, 195, 121);
    const link_fg = rgba(198, 120, 221);
    const perm_fg = rgba(224, 108, 117);
    const size_fg = rgba(229, 192, 123);
    const date_fg = rgba(86, 182, 194);
    const cells = try initCells(allocator, rows, cols, bg);
    const dirty = try initDirtyAll(allocator, rows, cols);

    var row: u16 = 0;
    while (row < rows) : (row += 1) {
        const row_base: u32 = @as(u32, row) * cols;
        var col: u16 = 0;
        const kind = row % 3;
        const name_fg = if (!colored)
            fg
        else switch (kind) {
            0 => dir_fg,
            1 => exec_fg,
            else => link_fg,
        };
        const size_color = if (colored) size_fg else fg;
        const date_color = if (colored) date_fg else fg;
        const perm_color = if (colored) perm_fg else fg;

        writeText(cells, row_base, cols, &col, if (kind == 1) "-rwxr-xr-x" else "drwxr-xr-x", perm_color, bg);
        padSpaces(cells, row_base, cols, &col, 1, name_fg, bg);
        writeText(cells, row_base, cols, &col, "user", fg, bg);
        padSpaces(cells, row_base, cols, &col, 1, name_fg, bg);
        writeText(cells, row_base, cols, &col, "group", fg, bg);
        padSpaces(cells, row_base, cols, &col, 2, name_fg, bg);
        writeText(cells, row_base, cols, &col, if (kind == 0) "4.0K" else "128K", size_color, bg);
        padSpaces(cells, row_base, cols, &col, 2, name_fg, bg);
        writeText(cells, row_base, cols, &col, "2026-05-18", date_color, bg);
        padSpaces(cells, row_base, cols, &col, 1, name_fg, bg);
        writeText(cells, row_base, cols, &col, if (kind == 0) "src" else if (kind == 1) "build.zig" else "README.md", name_fg, bg);
        if (kind == 2) {
            padSpaces(cells, row_base, cols, &col, 1, name_fg, bg);
            writeText(cells, row_base, cols, &col, "->", fg, bg);
            padSpaces(cells, row_base, cols, &col, 1, name_fg, bg);
            writeText(cells, row_base, cols, &col, "target", link_fg, bg);
        }
        padSpaces(cells, row_base, cols, &col, cols -| col, name_fg, bg);
    }

    return buildBenchmarkCase(
        if (colored) "lsd_like_color" else "lsd_like_plain",
        .{ .cells = cells },
        .{ .cols = cols, .rows = rows },
        true,
        dirty.rows,
        dirty.starts,
        dirty.ends,
        .{ .width = 9, .height = 18 },
        @intCast(@as(u32, rows) * cols),
    );
}

fn writeText(cells: []render.CellInput, row_base: u32, cols: u16, col: *u16, text: []const u8, fg: render.Rgba8, bg: render.Rgba8) void {
    for (text) |byte| {
        if (col.* >= cols) break;
        cells[@intCast(row_base + col.*)] = .{ .codepoint = byte, .fg = fg, .bg = bg };
        col.* += 1;
    }
}

fn padSpaces(cells: []render.CellInput, row_base: u32, cols: u16, col: *u16, count: u16, fg: render.Rgba8, bg: render.Rgba8) void {
    var left = count;
    while (left > 0 and col.* < cols) : (left -= 1) {
        cells[@intCast(row_base + col.*)] = .{ .codepoint = ' ', .fg = fg, .bg = bg };
        col.* += 1;
    }
}

fn buildSparseRowsCase(allocator: std.mem.Allocator) !BenchmarkCase {
    const rows: u16 = 30;
    const cols: u16 = 120;
    const bg = rgba(10, 14, 20);
    const fg = rgba(220, 230, 240);
    const accent = rgba(140, 200, 255);
    const cells = try initCells(allocator, rows, cols, bg);
    const active_rows = [_]u16{ 4, 17, 18 };
    const dirty = try initDirtySparse(allocator, rows, &active_rows, 8, 87);
    for (active_rows) |row| {
        var col: u16 = 8;
        while (col <= 87) : (col += 1) {
            const idx = @as(u32, row) * cols + col;
            cells[@intCast(idx)].codepoint = if ((col - 8) % 9 == 0) 0x2500 else 'x';
            cells[@intCast(idx)].fg = if ((col - 8) % 16 < 8) fg else accent;
            cells[@intCast(idx)].bg = if (row == 17) rgba(28, 18, 36) else bg;
        }
    }
    return buildBenchmarkCase(
        "sparse_rows",
        .{ .cells = cells },
        .{ .cols = cols, .rows = rows },
        false,
        dirty.rows,
        dirty.starts,
        dirty.ends,
        .{ .width = 9, .height = 18 },
        active_rows.len * 80,
    );
}

fn buildMixedBoxCase(allocator: std.mem.Allocator) !BenchmarkCase {
    const rows: u16 = 40;
    const cols: u16 = 100;
    const bg = rgba(15, 15, 15);
    const cells = try initCells(allocator, rows, cols, bg);
    const dirty = try initDirtyAll(allocator, rows, cols);
    const glyph_cycle = [_]u21{ 'A', 'B', 0x2500, 0x2502, 0x253C, 0x2588, 0x2592, 0x03BB };
    var row: u16 = 0;
    while (row < rows) : (row += 1) {
        const row_base = @as(u32, row) * cols;
        var col: u16 = 0;
        while (col < cols) : (col += 1) {
            const idx = row_base + col;
            cells[@intCast(idx)].codepoint = glyph_cycle[(row + col) % glyph_cycle.len];
            cells[@intCast(idx)].fg = rgba(@intCast(80 + (col % 120)), @intCast(90 + (row % 100)), @intCast(140 + ((row + col) % 100)));
            cells[@intCast(idx)].bg = if ((row / 4) % 2 == 0) bg else rgba(24, 24, 32);
        }
    }
    return buildBenchmarkCase(
        "mixed_box_full",
        .{ .cells = cells },
        .{ .cols = cols, .rows = rows },
        true,
        dirty.rows,
        dirty.starts,
        dirty.ends,
        .{ .width = 10, .height = 18 },
        cellCount(rows, cols),
    );
}

fn buildWideDirtySpansCase(allocator: std.mem.Allocator) !BenchmarkCase {
    const rows: u16 = 36;
    const cols: u16 = 132;
    const bg = rgba(7, 10, 13);
    const fg = rgba(225, 230, 235);
    const cells = try initCells(allocator, rows, cols, bg);
    const dirty_rows_list = [_]u16{ 5, 6, 7, 8, 14, 15, 16, 22, 23, 24, 25, 31 };
    const dirty = try initDirtySparse(allocator, rows, &dirty_rows_list, 12, 119);
    for (dirty_rows_list) |row| {
        var col: u16 = 12;
        while (col <= 119) : (col += 1) {
            const idx = @as(u32, row) * cols + col;
            cells[@intCast(idx)].codepoint = if (col % 17 == 0) 0x251C else if (col % 7 == 0) 0x2580 else 'm';
            cells[@intCast(idx)].fg = fg;
            cells[@intCast(idx)].bg = if ((col / 8) % 2 == 0) rgba(18, 24, 30) else rgba(32, 18, 18);
        }
    }
    return buildBenchmarkCase(
        "wide_dirty_spans",
        .{ .cells = cells },
        .{ .cols = cols, .rows = rows },
        false,
        dirty.rows,
        dirty.starts,
        dirty.ends,
        .{ .width = 9, .height = 17 },
        dirty_rows_list.len * 108,
    );
}

fn buildComplexTextCase(allocator: std.mem.Allocator) !BenchmarkCase {
    const rows: u16 = 12;
    const cols: u16 = 32;
    const bg = rgba(14, 12, 18);
    const fg = rgba(232, 236, 242);
    const combining = &[_]u32{ 'i', 0x0332 };
    const emoji = &[_]u32{0x1f642};
    const cells = try allocator.alloc(cluster.CellTextInput, @intCast(cellCount(rows, cols)));
    const dirty = try initDirtyAll(allocator, rows, cols);
    for (cells, 0..) |*cell, idx| {
        const cp = if (idx % 2 == 0) combining else emoji;
        cell.* = .{
            .codepoints = cp,
            .fg = fg,
            .bg = bg,
            .presentation = if (idx % 2 == 0) .any else .emoji,
        };
    }
    return buildBenchmarkCase(
        "complex_text_full",
        .{ .cell_texts = cells },
        .{ .cols = cols, .rows = rows },
        true,
        dirty.rows,
        dirty.starts,
        dirty.ends,
        .{ .width = 9, .height = 18 },
        count32(cells),
    );
}

fn buildCellTextAsciiFullCase(allocator: std.mem.Allocator) !BenchmarkCase {
    const rows: u16 = 24;
    const cols: u16 = 80;
    const bg = rgba(12, 12, 18);
    const fg = rgba(235, 238, 242);
    const ascii = [_]u32{'a'};
    const cells = try allocator.alloc(cluster.CellTextInput, @intCast(cellCount(rows, cols)));
    const dirty = try initDirtyAll(allocator, rows, cols);
    for (cells) |*cell| {
        cell.* = .{
            .codepoints = &ascii,
            .fg = fg,
            .bg = bg,
        };
    }
    return buildBenchmarkCase(
        "cell_text_ascii_full",
        .{ .cell_texts = cells },
        .{ .cols = cols, .rows = rows },
        true,
        dirty.rows,
        dirty.starts,
        dirty.ends,
        .{ .width = 9, .height = 18 },
        count32(cells),
    );
}

fn buildCellTextMixedCase(allocator: std.mem.Allocator) !BenchmarkCase {
    const rows: u16 = 16;
    const cols: u16 = 48;
    const bg = rgba(16, 14, 22);
    const fg = rgba(232, 236, 242);
    const accent = rgba(166, 212, 255);
    const ascii = [_]u32{'a'};
    const combining = [_]u32{ 'i', 0x0332 };
    const cells = try allocator.alloc(cluster.CellTextInput, @intCast(cellCount(rows, cols)));
    const dirty = try initDirtyAll(allocator, rows, cols);
    for (cells, 0..) |*cell, idx| {
        const even = idx % 2 == 0;
        cell.* = .{
            .codepoints = if (even) &ascii else &combining,
            .fg = if (even) fg else accent,
            .bg = bg,
            .presentation = .any,
        };
    }
    return buildBenchmarkCase(
        "cell_text_mixed",
        .{ .cell_texts = cells },
        .{ .cols = cols, .rows = rows },
        true,
        dirty.rows,
        dirty.starts,
        dirty.ends,
        .{ .width = 9, .height = 18 },
        count32(cells),
    );
}

fn buildCurlyUnderlineMixedCase(allocator: std.mem.Allocator) !BenchmarkCase {
    const rows: u16 = 18;
    const cols: u16 = 64;
    const bg = rgba(12, 16, 20);
    const fg = rgba(234, 238, 242);
    const accent = rgba(255, 180, 120);
    const cells = try initCells(allocator, rows, cols, bg);
    const dirty = try initDirtyAll(allocator, rows, cols);
    for (cells, 0..) |*cell, idx| {
        const curly = idx % 3 == 1;
        cell.* = .{
            .codepoint = if (curly) 'u' else 'n',
            .fg = if (curly) accent else fg,
            .bg = bg,
            .underline = curly,
            .underline_style = if (curly) .curly else .straight,
        };
    }
    return buildBenchmarkCase(
        "curly_underline_mixed",
        .{ .cells = cells },
        .{ .cols = cols, .rows = rows },
        true,
        dirty.rows,
        dirty.starts,
        dirty.ends,
        .{ .width = 9, .height = 18 },
        count32(cells),
    );
}

fn buildIconPuaMixedCase(allocator: std.mem.Allocator) !BenchmarkCase {
    const rows: u16 = 12;
    const cols: u16 = 48;
    const bg = rgba(14, 16, 22);
    const fg = rgba(236, 239, 243);
    const accent = rgba(255, 196, 96);
    const cells = try initCells(allocator, rows, cols, bg);
    const dirty = try initDirtyAll(allocator, rows, cols);
    for (cells, 0..) |*cell, idx| {
        const icon = idx % 4 == 1;
        cell.* = .{
            .codepoint = if (icon) 0xf101 else 'n',
            .fg = if (icon) accent else fg,
            .bg = bg,
        };
    }
    return buildBenchmarkCase(
        "icon_pua_mixed",
        .{ .cells = cells },
        .{ .cols = cols, .rows = rows },
        true,
        dirty.rows,
        dirty.starts,
        dirty.ends,
        .{ .width = 9, .height = 18 },
        count32(cells),
    );
}

fn initBenchmarkPrepareContext(benchmark_case: BenchmarkCase) BenchmarkPrepareContext {
    return .{
        .selection = .{
            .primary_face = .{ .value = 1 },
            .cell_metrics = defaultCellMetrics(benchmark_case.cell_px),
        },
        .options = .{
            .draw_list = .{
                .damage = .{
                    .full = benchmark_case.damage.full,
                    .dirty_rows = benchmark_case.damage.dirty_rows,
                    .dirty_cols_start = benchmark_case.damage.dirty_cols_start,
                    .dirty_cols_end = benchmark_case.damage.dirty_cols_end,
                },
            },
        },
    };
}

fn prepareBenchmarkCaseSurface(preparer: *surface_preparer.TextSurfacePreparer, benchmark_case: BenchmarkCase, context: BenchmarkPrepareContext) !surface_preparer.OwnedPreparedTextSurface {
    return switch (benchmark_case.input) {
        .cells => |cells| preparer.prepareCellsWithFaceSelection(
            cells,
            benchmark_case.grid,
            context.selection,
            context.options,
        ),
        .cell_texts => |cells| preparer.prepareCellTextInputsWithFaceSelection(
            cells,
            benchmark_case.grid,
            context.selection,
            context.options,
        ),
    };
}

fn extractObservation(duration_ns: u64, counting: CountingAllocator) RunObservation {
    return .{
        .ns = duration_ns,
        .alloc_count = counting.window_alloc_count,
        .alloc_bytes = counting.window_alloc_bytes,
        .peak_live_bytes = counting.window_peak_live_bytes,
    };
}

fn countDrawListFills(analysis: surface_preparer.OwnedPreparedTextSurface) u64 {
    return count64(analysis.draw_list.draw_list.background_draws) +
        count64(analysis.draw_list.draw_list.decoration_draws) +
        count64(analysis.draw_list.draw_list.cursor_draws);
}

fn markAtlasOutputs(preparer: *surface_preparer.TextSurfacePreparer, analysis: surface_preparer.OwnedPreparedTextSurface) void {
    for (analysis.raster_plan.outputs) |output| {
        _ = preparer.atlas.markRendered(output.key);
    }
}

fn runBenchmarkCaseCold(io: std.Io, counting: *CountingAllocator, preparer: *surface_preparer.TextSurfacePreparer, benchmark_case: BenchmarkCase, context: BenchmarkPrepareContext) !ColdRun {
    counting.resetWindow();
    const start_ns = nowNs(io);
    var analysis = try prepareBenchmarkCaseSurface(preparer, benchmark_case, context);
    defer analysis.deinit();
    const duration_ns = nowNs(io) - start_ns;
    const uploads = count64(analysis.raster_plan.outputs);
    const result: ColdRun = .{
        .observation = extractObservation(duration_ns, counting.*),
        .fills = countDrawListFills(analysis),
        .glyphs = count64(analysis.draw_list.draw_list.sprite_draws),
        .uploads = uploads,
    };
    markAtlasOutputs(preparer, analysis);
    return result;
}

fn runBenchmarkCaseWarm(
    io: std.Io,
    counting: *CountingAllocator,
    preparer: *surface_preparer.TextSurfacePreparer,
    benchmark_case: BenchmarkCase,
    context: BenchmarkPrepareContext,
    observations: []RunObservation,
    fill_values: []u64,
    glyph_values: []u64,
    upload_values: []u64,
) !void {
    for (observations, 0..) |*observation, idx| {
        counting.resetWindow();
        const start_ns = nowNs(io);
        var analysis = try prepareBenchmarkCaseSurface(preparer, benchmark_case, context);
        defer analysis.deinit();
        const duration_ns = nowNs(io) - start_ns;
        observation.* = extractObservation(duration_ns, counting.*);
        markAtlasOutputs(preparer, analysis);
        fill_values[idx] = countDrawListFills(analysis);
        glyph_values[idx] = count64(analysis.draw_list.draw_list.sprite_draws);
        upload_values[idx] = count64(analysis.raster_plan.outputs);
    }
}

fn summarizeWarmRuns(allocator: std.mem.Allocator, observations: []const RunObservation, fill_values: []u64, glyph_values: []u64, upload_values: []u64) !WarmSummary {
    const ns_values = try allocator.alloc(u64, observations.len);
    defer allocator.free(ns_values);
    const alloc_count_values = try allocator.alloc(u64, observations.len);
    defer allocator.free(alloc_count_values);
    const alloc_bytes_values = try allocator.alloc(u64, observations.len);
    defer allocator.free(alloc_bytes_values);
    const peak_live_values = try allocator.alloc(u64, observations.len);
    defer allocator.free(peak_live_values);
    for (observations, 0..) |observation, idx| {
        ns_values[idx] = observation.ns;
        alloc_count_values[idx] = observation.alloc_count;
        alloc_bytes_values[idx] = observation.alloc_bytes;
        peak_live_values[idx] = observation.peak_live_bytes;
    }

    return .{
        .median_ns = medianU64(ns_values),
        .p95_ns = p95U64(ns_values),
        .median_alloc_count = medianU64(alloc_count_values),
        .median_alloc_bytes = medianU64(alloc_bytes_values),
        .median_peak_live_bytes = medianU64(peak_live_values),
        .median_fills = medianU64(fill_values),
        .median_glyphs = medianU64(glyph_values),
        .median_uploads = medianU64(upload_values),
    };
}

fn runBenchmarkCaseInitState(allocator: std.mem.Allocator, benchmark_case: BenchmarkCase, counting: *CountingAllocator, preparer: *surface_preparer.TextSurfacePreparer, context: *BenchmarkPrepareContext) void {
    context.* = initBenchmarkPrepareContext(benchmark_case);
    counting.* = CountingAllocator.init(allocator);
    preparer.* = surface_preparer.TextSurfacePreparer.init(counting.allocator());
}

fn runBenchmarkCaseResult(benchmark_case: BenchmarkCase, runs: RunCount, cold: ColdRun, warm: WarmSummary) BenchmarkResult {
    return .{
        .name = benchmark_case.name,
        .grid_cols = benchmark_case.grid.cols,
        .grid_rows = benchmark_case.grid.rows,
        .dirty_cells_per_run = benchmark_case.dirty_cells_per_run,
        .runs = runs,
        .cold_ns = cold.observation.ns,
        .cold_alloc_count = cold.observation.alloc_count,
        .cold_alloc_bytes = cold.observation.alloc_bytes,
        .cold_peak_live_bytes = cold.observation.peak_live_bytes,
        .cold_fills = cold.fills,
        .cold_glyphs = cold.glyphs,
        .cold_uploads = cold.uploads,
        .warm_median_ns = warm.median_ns,
        .warm_p95_ns = warm.p95_ns,
        .warm_median_alloc_count = warm.median_alloc_count,
        .warm_median_alloc_bytes = warm.median_alloc_bytes,
        .warm_median_peak_live_bytes = warm.median_peak_live_bytes,
        .warm_median_fills = warm.median_fills,
        .warm_median_glyphs = warm.median_glyphs,
        .warm_median_uploads = warm.median_uploads,
    };
}

fn runBenchmarkCase(io: std.Io, allocator: std.mem.Allocator, benchmark_case: BenchmarkCase, runs: RunCount) !BenchmarkResult {
    const observations = try allocator.alloc(RunObservation, runs);
    defer allocator.free(observations);
    const fill_values = try allocator.alloc(u64, runs);
    defer allocator.free(fill_values);
    const glyph_values = try allocator.alloc(u64, runs);
    defer allocator.free(glyph_values);
    const upload_values = try allocator.alloc(u64, runs);
    defer allocator.free(upload_values);

    var context: BenchmarkPrepareContext = undefined;
    var counting: CountingAllocator = undefined;
    var preparer: surface_preparer.TextSurfacePreparer = undefined;
    runBenchmarkCaseInitState(allocator, benchmark_case, &counting, &preparer, &context);
    defer preparer.deinit();

    const cold = try runBenchmarkCaseCold(io, &counting, &preparer, benchmark_case, context);
    try runBenchmarkCaseWarm(io, &counting, &preparer, benchmark_case, context, observations, fill_values, glyph_values, upload_values);
    const warm = try summarizeWarmRuns(allocator, observations, fill_values, glyph_values, upload_values);
    std.debug.assert(cold.uploads >= warm.median_uploads);
    return runBenchmarkCaseResult(benchmark_case, runs, cold, warm);
}

fn parseArgs(argv: []const [:0]const u8) !Options {
    var opts = Options{};
    var args = argv[1..];
    while (args.len > 0) {
        const arg = args[0];
        args = args[1..];
        if (std.mem.eql(u8, arg, "--text")) {
            opts.format = .text;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--runs=")) {
            opts.runs = std.fmt.parseUnsigned(RunCount, arg["--runs=".len..], 10) catch return error.InvalidRuns;
            continue;
        }
        if (std.mem.eql(u8, arg, "--runs")) {
            if (args.len == 0) return error.MissingRuns;
            opts.runs = std.fmt.parseUnsigned(RunCount, args[0], 10) catch return error.InvalidRuns;
            args = args[1..];
            continue;
        }
        return error.UnknownArgument;
    }
    return opts;
}

fn printTextResult(result: BenchmarkResult) void {
    const cold_ms = @as(f64, @floatFromInt(result.cold_ns)) / 1_000_000.0;
    const warm_median_ms = @as(f64, @floatFromInt(result.warm_median_ns)) / 1_000_000.0;
    const warm_p95_ms = @as(f64, @floatFromInt(result.warm_p95_ns)) / 1_000_000.0;
    std.debug.print("benchmark_case={s}\n", .{result.name});
    std.debug.print("grid_cols={d}\n", .{result.grid_cols});
    std.debug.print("grid_rows={d}\n", .{result.grid_rows});
    std.debug.print("runs={d}\n", .{result.runs});
    std.debug.print("dirty_cells_per_run={d}\n", .{result.dirty_cells_per_run});
    std.debug.print("cold_ms={d:.3}\n", .{cold_ms});
    std.debug.print("cold_alloc_count={d}\n", .{result.cold_alloc_count});
    std.debug.print("cold_alloc_bytes={d}\n", .{result.cold_alloc_bytes});
    std.debug.print("cold_peak_live_bytes={d}\n", .{result.cold_peak_live_bytes});
    std.debug.print("cold_fills={d}\n", .{result.cold_fills});
    std.debug.print("cold_glyphs={d}\n", .{result.cold_glyphs});
    std.debug.print("cold_uploads={d}\n", .{result.cold_uploads});
    std.debug.print("warm_median_ms={d:.3}\n", .{warm_median_ms});
    std.debug.print("warm_p95_ms={d:.3}\n", .{warm_p95_ms});
    std.debug.print("dirty_cells_per_second={d:.0}\n", .{result.dirtyCellsPerSecond()});
    std.debug.print("warm_median_alloc_count={d}\n", .{result.warm_median_alloc_count});
    std.debug.print("warm_median_alloc_bytes={d}\n", .{result.warm_median_alloc_bytes});
    std.debug.print("warm_median_peak_live_bytes={d}\n", .{result.warm_median_peak_live_bytes});
    std.debug.print("warm_median_fills={d}\n", .{result.warm_median_fills});
    std.debug.print("warm_median_glyphs={d}\n", .{result.warm_median_glyphs});
    std.debug.print("warm_median_uploads={d}\n", .{result.warm_median_uploads});
    std.debug.print("---\n", .{});
}

fn printNdjsonResult(result: BenchmarkResult) void {
    std.debug.print("{{\"benchmark_case\":\"{s}\",\"grid_cols\":{d},\"grid_rows\":{d},", .{
        result.name,
        result.grid_cols,
        result.grid_rows,
    });
    std.debug.print("\"runs\":{d},\"dirty_cells_per_run\":{d},\"cold_ns\":{d},", .{
        result.runs,
        result.dirty_cells_per_run,
        result.cold_ns,
    });
    std.debug.print("\"cold_alloc_count\":{d},\"cold_alloc_bytes\":{d},", .{
        result.cold_alloc_count,
        result.cold_alloc_bytes,
    });
    std.debug.print("\"cold_peak_live_bytes\":{d},\"cold_fills\":{d},\"cold_glyphs\":{d},\"cold_uploads\":{d},\"warm_median_ns\":{d},\"warm_p95_ns\":{d},", .{
        result.cold_peak_live_bytes,
        result.cold_fills,
        result.cold_glyphs,
        result.cold_uploads,
        result.warm_median_ns,
        result.warm_p95_ns,
    });
    std.debug.print("\"dirty_cells_per_second\":{d:.0},\"warm_median_alloc_count\":{d},\"warm_median_alloc_bytes\":{d},\"warm_median_peak_live_bytes\":{d},", .{
        result.dirtyCellsPerSecond(),
        result.warm_median_alloc_count,
        result.warm_median_alloc_bytes,
        result.warm_median_peak_live_bytes,
    });
    std.debug.print("\"warm_median_fills\":{d},\"warm_median_glyphs\":{d},\"warm_median_uploads\":{d}}}\n", .{
        result.warm_median_fills,
        result.warm_median_glyphs,
        result.warm_median_uploads,
    });
}

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const argv = try init.minimal.args.toSlice(arena);
    const opts = try parseArgs(argv);
    const io = init.io;

    const benchmark_cases = [_]BenchmarkCase{
        try buildAsciiFullCase(arena),
        try buildAsciiFullLargeCase(arena),
        try buildLsdLikeCase(arena, false),
        try buildLsdLikeCase(arena, true),
        try buildCellTextAsciiFullCase(arena),
        try buildSparseRowsCase(arena),
        try buildMixedBoxCase(arena),
        try buildWideDirtySpansCase(arena),
        try buildCellTextMixedCase(arena),
        try buildCurlyUnderlineMixedCase(arena),
        try buildIconPuaMixedCase(arena),
        try buildComplexTextCase(arena),
    };

    for (benchmark_cases) |benchmark_case| {
        const result = try runBenchmarkCase(io, arena, benchmark_case, opts.runs);
        switch (opts.format) {
            .ndjson => printNdjsonResult(result),
            .text => printTextResult(result),
        }
    }
}
