const std = @import("std");
const contract = @import("../contract.zig");
const scene = @import("../scene.zig");
const lane = @import("../classify/lane.zig");
const source_text_input = @import("../../vt_publication/text_input.zig");
const source_theme = @import("../../vt_publication/theme.zig");
const source_vt = @import("../../vt_publication/abi.zig");

const VS15: u32 = 0xfe0e;
const VS16: u32 = 0xfe0f;
const blank_codepoints = [_]u32{0};

pub const CellTextInput = struct {
    codepoints: []const u32,
    semantic_fg: contract.SemanticColor = .{},
    semantic_bg: contract.SemanticColor = .{},
    fg: contract.Rgba8,
    bg: contract.Rgba8,
    underline_color_set: bool = false,
    semantic_underline_color: contract.SemanticColor = .{},
    underline_color: contract.Rgba8 = .{ .r = 0, .g = 0, .b = 0, .a = 0 },
    style: contract.FontStyle = .regular,
    presentation: contract.TextPresentation = .any,
    underline: bool = false,
    underline_style: contract.UnderlineStyle = .straight,
    strikethrough: bool = false,
    cell_span: u8 = 1,
    continuation: bool = false,
};

pub const OwnedLineTextCache = struct {
    allocator: std.mem.Allocator,
    texts: []contract.CellText,
    codepoints: []u32,
    owned: bool = true,

    pub fn view(self: OwnedLineTextCache) contract.LineTextCache {
        return .{ .texts = self.texts };
    }

    pub fn deinit(self: *OwnedLineTextCache) void {
        if (self.owned) {
            self.allocator.free(self.texts);
            self.allocator.free(self.codepoints);
        }
        self.* = undefined;
    }
};

pub const OwnedRenderableCells = struct {
    allocator: std.mem.Allocator,
    cells: []contract.RenderableCell,
    owned: bool = true,

    pub fn deinit(self: *OwnedRenderableCells) void {
        if (self.owned) self.allocator.free(self.cells);
        self.* = undefined;
    }
};

pub const OwnedClusters = struct {
    allocator: std.mem.Allocator,
    clusters: []contract.CellCluster,
    owned: bool = true,

    pub fn deinit(self: *OwnedClusters) void {
        if (self.owned) self.allocator.free(self.clusters);
        self.* = undefined;
    }
};

pub const OwnedRuns = struct {
    allocator: std.mem.Allocator,
    runs: []contract.ResolvedRun,

    pub fn deinit(self: *OwnedRuns) void {
        self.allocator.free(self.runs);
        self.* = undefined;
    }
};

pub const ComplexSelection = struct {
    allocator: std.mem.Allocator,
    cells: []contract.RenderableCell,
    clusters: []contract.CellCluster,

    pub fn deinit(self: *ComplexSelection) void {
        self.allocator.free(self.cells);
        self.allocator.free(self.clusters);
        self.* = undefined;
    }
};

pub const SparseCells = struct {
    text_cache: OwnedLineTextCache,
    renderable: OwnedRenderableCells,

    pub fn deinit(self: *SparseCells) void {
        self.renderable.deinit();
        self.text_cache.deinit();
        self.* = undefined;
    }
};

pub const RenderableText = struct {
    renderable: contract.RenderableCell,
    text: contract.CellText,
    inline_codepoints: [4]u32 = [_]u32{0} ** 4,
};

pub const RetainedScratch = struct {
    renderable: []contract.RenderableCell = &.{},
    clusters: []contract.CellCluster = &.{},
    runs: []contract.ResolvedRun = &.{},
    texts: []contract.CellText = &.{},
    codepoints: []u32 = &.{},
    max_items: u32 = 0,
    max_codepoints: u32 = 0,

    pub fn deinit(self: *RetainedScratch, allocator: std.mem.Allocator) void {
        if (self.codepoints.len > 0) allocator.free(self.codepoints);
        if (self.texts.len > 0) allocator.free(self.texts);
        if (self.runs.len > 0) allocator.free(self.runs);
        if (self.clusters.len > 0) allocator.free(self.clusters);
        if (self.renderable.len > 0) allocator.free(self.renderable);
        self.* = undefined;
    }

    pub fn configure(self: *RetainedScratch, allocator: std.mem.Allocator, max_items: u32, max_codepoints: u32) !void {
        try self.configureItems(allocator, max_items);
        try self.configureCodepoints(allocator, max_codepoints);
    }

    fn configureItems(self: *RetainedScratch, allocator: std.mem.Allocator, max_items: u32) !void {
        if (max_items <= self.max_items) return;
        const capacity: usize = @intCast(max_items);
        const renderable = try allocator.alloc(contract.RenderableCell, capacity);
        errdefer allocator.free(renderable);
        const clusters = try allocator.alloc(contract.CellCluster, capacity);
        errdefer allocator.free(clusters);
        const runs = try allocator.alloc(contract.ResolvedRun, capacity);
        errdefer allocator.free(runs);
        const texts = try allocator.alloc(contract.CellText, capacity);
        errdefer allocator.free(texts);

        if (self.renderable.len > 0) allocator.free(self.renderable);
        if (self.clusters.len > 0) allocator.free(self.clusters);
        if (self.runs.len > 0) allocator.free(self.runs);
        if (self.texts.len > 0) allocator.free(self.texts);

        self.renderable = renderable;
        self.clusters = clusters;
        self.runs = runs;
        self.texts = texts;
        self.max_items = max_items;
    }

    fn configureCodepoints(self: *RetainedScratch, allocator: std.mem.Allocator, max_codepoints: u32) !void {
        if (max_codepoints <= self.max_codepoints) return;
        const codepoints = try allocator.alloc(u32, @intCast(max_codepoints));
        if (self.codepoints.len > 0) allocator.free(self.codepoints);
        self.codepoints = codepoints;
        self.max_codepoints = max_codepoints;
    }

    fn require(self: RetainedScratch, item_count: u32, codepoint_count: u32) !void {
        if (item_count > self.max_items) return error.ClusterScratchOverflow;
        if (codepoint_count > self.max_codepoints) return error.ClusterScratchOverflow;
    }
};

const InputRenderableAssembly = struct {
    allocator: std.mem.Allocator,
    cells: []contract.RenderableCell,
    cell_count: u32 = 0,

    fn init(allocator: std.mem.Allocator, input_count: u32) !InputRenderableAssembly {
        return .{ .allocator = allocator, .cells = try allocator.alloc(contract.RenderableCell, @intCast(input_count)) };
    }

    fn deinit(self: *InputRenderableAssembly) void {
        self.allocator.free(self.cells);
        self.* = undefined;
    }

    fn append(self: *InputRenderableAssembly, cell: contract.RenderableCell) void {
        self.cells[@intCast(self.cell_count)] = cell;
        self.cell_count += 1;
    }

    fn toOwnedRenderableCells(self: *InputRenderableAssembly) OwnedRenderableCells {
        std.debug.assert(self.cell_count == self.cells.len);
        return .{ .allocator = self.allocator, .cells = self.cells };
    }
};

const CellLineTextCacheAssembly = struct {
    allocator: std.mem.Allocator,
    texts: []contract.CellText,
    codepoints: []u32,
    text_count: u32 = 0,
    codepoint_count: u32 = 0,

    fn init(allocator: std.mem.Allocator, cell_count: u32, codepoint_count: u32) !CellLineTextCacheAssembly {
        const texts = try allocator.alloc(contract.CellText, @intCast(cell_count));
        errdefer allocator.free(texts);
        const codepoints = try allocator.alloc(u32, @intCast(codepoint_count));
        errdefer allocator.free(codepoints);
        return .{ .allocator = allocator, .texts = texts, .codepoints = codepoints };
    }

    fn deinit(self: *CellLineTextCacheAssembly) void {
        self.allocator.free(self.texts);
        self.allocator.free(self.codepoints);
        self.* = undefined;
    }

    fn appendCell(self: *CellLineTextCacheAssembly, cell: contract.CellInput) void {
        var scratch: [4]u32 = undefined;
        const cps = cellCodepoints(cell, &scratch);
        const text_idx = self.text_count;
        const cp_start = self.codepoint_count;
        const cp_len: u32 = @intCast(cps.len);
        @memcpy(self.codepoints[@intCast(cp_start)..@intCast(cp_start + cp_len)], cps);
        self.texts[@intCast(text_idx)] = .{
            .id = .{ .value = text_idx },
            .first_cp = cps[0],
            .codepoints = self.codepoints[@intCast(cp_start)..@intCast(cp_start + cp_len)],
        };
        self.text_count += 1;
        self.codepoint_count += cp_len;
    }

    fn toOwnedLineTextCache(self: *CellLineTextCacheAssembly) OwnedLineTextCache {
        std.debug.assert(self.text_count == self.texts.len);
        std.debug.assert(self.codepoint_count == self.codepoints.len);
        const texts = self.texts;
        const codepoints = self.codepoints;
        self.texts = &.{};
        self.codepoints = &.{};
        return .{ .allocator = self.allocator, .texts = texts, .codepoints = codepoints };
    }
};

pub fn singleCodepointText(id: u32, cp: u32) contract.CellText {
    return .{
        .id = .{ .value = id },
        .first_cp = cp,
        .codepoints = &.{cp},
    };
}

pub fn clusterForCell(text: contract.CellText, first_cell: u32, span: u8, style: contract.FontStyle) contract.CellCluster {
    return .{
        .text_id = text.id,
        .first_cell = first_cell,
        .cell_span = span,
        .first_cp = text.first_cp,
        .style = style,
        .presentation = detectPresentation(text.codepoints, .any),
    };
}

pub fn buildLineTextCacheFromCells(allocator: std.mem.Allocator, cells: []const contract.CellInput) !OwnedLineTextCache {
    var assembly = try CellLineTextCacheAssembly.init(allocator, @intCast(cells.len), countCellInputCodepoints(cells));
    errdefer assembly.deinit();

    for (cells) |cell| assembly.appendCell(cell);

    return assembly.toOwnedLineTextCache();
}

pub fn buildSparseCellsWithDamage(allocator: std.mem.Allocator, cells: []const contract.CellInput, grid_metrics: contract.GridMetrics, damage: scene.DamageInput) !SparseCells {
    var scratch = RetainedScratch{};
    defer scratch.deinit(allocator);
    const total_cells = count32(cells);
    try scratch.configure(allocator, total_cells, countCellInputCodepoints(cells));
    return buildSparseCellsWithDamageScratch(allocator, &scratch, cells, grid_metrics, damage);
}

pub fn buildSparseCellsWithDamageScratch(
    allocator: std.mem.Allocator,
    scratch: *RetainedScratch,
    cells: []const contract.CellInput,
    grid_metrics: contract.GridMetrics,
    damage: scene.DamageInput,
) !SparseCells {
    const damage_filter = DamageFilter.init(damage, grid_metrics);
    const total_cells = count32(cells);
    try scratch.require(total_cells, countCellInputCodepoints(cells));

    var text_count: u32 = 0;
    var codepoint_count: u32 = 0;
    var renderable_count: u32 = 0;
    var cell_idx: u32 = 0;
    while (cell_idx < total_cells) {
        if (damage_filter.cleanRowSkip(cell_idx, total_cells)) |next_idx| {
            cell_idx = next_idx;
            continue;
        }
        const idx = cell_idx;
        cell_idx += 1;
        const cell = cells[@intCast(idx)];
        if (cell.continuation) continue;
        const first_cell = idx;
        const span = inferredCellSpan(cells, first_cell);
        if (!damage_filter.includeSpan(first_cell, span)) continue;
        var scratch_codepoints: [4]u32 = undefined;
        const cps = cellCodepointsForRenderableOwnership(cell, &scratch_codepoints);
        const text_id = findText(scratch.texts[0..@intCast(text_count)], cps) orelse blk: {
            const next_id = text_count;
            appendScratchText(scratch, &text_count, &codepoint_count, cps);
            break :blk contract.CellTextId{ .value = next_id };
        };
        scratch.renderable[@intCast(renderable_count)] = renderableFromCellInput(text_id, first_cell, span, cell, false);
        renderable_count += 1;
    }

    const renderable = try allocator.dupe(contract.RenderableCell, scratch.renderable[0..@intCast(renderable_count)]);
    errdefer allocator.free(renderable);
    const text_cache = try cloneTextCache(allocator, scratch.texts[0..@intCast(text_count)], scratch.codepoints[0..@intCast(codepoint_count)]);
    errdefer text_cache.deinit();
    return .{
        .text_cache = text_cache,
        .renderable = .{ .allocator = allocator, .cells = renderable },
    };
}

pub fn buildSparsePublicationCellsWithDamageScratch(
    allocator: std.mem.Allocator,
    scratch: *RetainedScratch,
    cells: []const source_vt.SourceCell,
    theme: source_theme.SurfaceTheme,
    grid_metrics: contract.GridMetrics,
    damage: scene.DamageInput,
) !SparseCells {
    const damage_filter = DamageFilter.init(damage, grid_metrics);
    const total_cells = count32(cells);
    try scratch.require(total_cells, countPublicationCodepoints(cells));

    var text_count: u32 = 0;
    var codepoint_count: u32 = 0;
    var renderable_count: u32 = 0;
    var cell_idx: u32 = 0;
    while (cell_idx < total_cells) {
        if (damage_filter.cleanRowSkip(cell_idx, total_cells)) |next_idx| {
            cell_idx = next_idx;
            continue;
        }
        const idx = cell_idx;
        cell_idx += 1;
        const source_cell_value = cells[@intCast(idx)];
        if (source_cell_value.flags.continuation != 0) continue;
        const mapped = source_text_input.mapPublicationCellInput(source_cell_value, theme);
        const first_cell = idx;
        const span = inferredPublicationCellSpan(cells, first_cell);
        if (!damage_filter.includeSpan(first_cell, span)) continue;
        var scratch_codepoints: [4]u32 = undefined;
        const cps = cellCodepointsForRenderableOwnership(mapped, &scratch_codepoints);
        const text_id = findText(scratch.texts[0..@intCast(text_count)], cps) orelse blk: {
            const next_id = text_count;
            appendScratchText(scratch, &text_count, &codepoint_count, cps);
            break :blk contract.CellTextId{ .value = next_id };
        };
        scratch.renderable[@intCast(renderable_count)] = renderableFromCellInput(text_id, first_cell, span, mapped, false);
        renderable_count += 1;
    }

    const renderable = try allocator.dupe(contract.RenderableCell, scratch.renderable[0..@intCast(renderable_count)]);
    errdefer allocator.free(renderable);
    const text_cache = try cloneTextCache(allocator, scratch.texts[0..@intCast(text_count)], scratch.codepoints[0..@intCast(codepoint_count)]);
    errdefer text_cache.deinit();
    return .{
        .text_cache = text_cache,
        .renderable = .{ .allocator = allocator, .cells = renderable },
    };
}

pub fn buildLineTextCacheFromInputs(allocator: std.mem.Allocator, inputs: []const CellTextInput) !OwnedLineTextCache {
    var scratch = RetainedScratch{};
    defer scratch.deinit(allocator);
    const input_count = count32(inputs);
    const total_codepoints = countNormalizedInputCodepoints(inputs);
    try scratch.configure(allocator, input_count, total_codepoints);
    return buildLineTextCacheFromInputsScratch(allocator, &scratch, inputs);
}

pub fn buildLineTextCacheFromInputsScratch(allocator: std.mem.Allocator, scratch: *RetainedScratch, inputs: []const CellTextInput) !OwnedLineTextCache {
    const input_count = count32(inputs);
    const total_codepoints = countNormalizedInputCodepoints(inputs);
    try scratch.require(input_count, total_codepoints);

    var text_count: u32 = 0;
    var codepoint_count: u32 = 0;
    for (inputs) |input| {
        const cps = normalizedCodepoints(input.codepoints);
        if (findText(scratch.texts[0..@intCast(text_count)], cps) != null) continue;
        appendScratchText(scratch, &text_count, &codepoint_count, cps);
    }

    return cloneTextCache(allocator, scratch.texts[0..@intCast(text_count)], scratch.codepoints[0..@intCast(codepoint_count)]);
}

fn normalizedCodepoints(cps: []const u32) []const u32 {
    return if (cps.len == 0) &.{0} else cps;
}

fn inputCellText(input: CellTextInput) contract.CellText {
    const cps = normalizedCodepoints(input.codepoints);
    return .{ .id = .{ .value = 0 }, .first_cp = cps[0], .codepoints = cps };
}

fn initRenderableTextFromCellInput(renderable: contract.RenderableCell, cell: contract.CellInput) RenderableText {
    var item = RenderableText{
        .renderable = renderable,
        .text = .{ .id = .{ .value = 0 }, .first_cp = cell.codepoint, .codepoints = &.{} },
    };
    const cps = cellCodepointsForRenderableOwnership(cell, &item.inline_codepoints);
    std.mem.copyForwards(u32, item.inline_codepoints[0..cps.len], cps);
    item.text.first_cp = cps[0];
    item.text.codepoints = item.inline_codepoints[0..cps.len];
    return item;
}

fn cellCodepoints(cell: contract.CellInput, scratch: *[4]u32) []const u32 {
    std.debug.assert(cell.combining_len <= cell.combining.len);
    scratch[0] = cell.codepoint;
    for (cell.combining[0..cell.combining_len], 1..) |cp, idx| scratch[idx] = cp;
    return scratch[0 .. @as(usize, cell.combining_len) + 1];
}

fn cellCodepointsForRenderableOwnership(cell: contract.CellInput, scratch: *[4]u32) []const u32 {
    if (cell.empty) return &blank_codepoints;
    return cellCodepoints(cell, scratch);
}

fn findText(texts: []const contract.CellText, cps: []const u32) ?contract.CellTextId {
    for (texts, 0..) |text, idx| {
        if (std.mem.eql(u32, text.codepoints, cps)) return .{ .value = @intCast(idx) };
    }
    return null;
}

pub fn buildRenderableCellsFromCells(allocator: std.mem.Allocator, cells: []const contract.CellInput, cache: contract.LineTextCache) !OwnedRenderableCells {
    var assembly = try InputRenderableAssembly.init(allocator, count32(cells));
    errdefer assembly.deinit();

    for (cells, 0..) |cell, idx| {
        const text = cache.texts[idx];
        const first_cell: u32 = @intCast(idx);
        const cell_span = inferredCellSpan(cells, first_cell);
        assembly.append(renderableFromCellInput(text.id, first_cell, cell_span, cell, cell.continuation));
    }

    return assembly.toOwnedRenderableCells();
}

pub fn buildRenderableCellsFromInputs(allocator: std.mem.Allocator, inputs: []const CellTextInput, cache: contract.LineTextCache) !OwnedRenderableCells {
    var assembly = try InputRenderableAssembly.init(allocator, count32(inputs));
    errdefer assembly.deinit();

    for (inputs, 0..) |input, idx| {
        const cps = normalizedCodepoints(input.codepoints);
        const first_cell: u32 = @intCast(idx);
        const text_id = findText(cache.texts, cps) orelse unreachable;
        const cell_span = @max(@max(input.cell_span, 1), inferredInputCellSpan(inputs, first_cell));
        assembly.append(renderableFromInput(
            text_id,
            first_cell,
            cell_span,
            detectPresentation(cps, input.presentation),
            input,
        ));
    }

    return assembly.toOwnedRenderableCells();
}

pub fn detectPresentation(cps: []const u32, fallback: contract.TextPresentation) contract.TextPresentation {
    for (cps) |cp| {
        if (cp == VS16) return .emoji;
        if (cp == VS15) return .text;
    }
    return fallback;
}

pub fn extractClusters(allocator: std.mem.Allocator, cells: []const contract.RenderableCell, cache: contract.LineTextCache) !OwnedClusters {
    return extractClustersWithDamage(allocator, cells, cache, .{ .cols = @intCast(@max(cells.len, 1)), .rows = 1 }, .{});
}

pub fn extractClustersWithDamage(
    allocator: std.mem.Allocator,
    cells: []const contract.RenderableCell,
    cache: contract.LineTextCache,
    grid_metrics: contract.GridMetrics,
    damage: scene.DamageInput,
) !OwnedClusters {
    var scratch = RetainedScratch{};
    defer scratch.deinit(allocator);
    try scratch.configure(allocator, count32(cells), 0);
    return extractClustersWithDamageScratch(allocator, &scratch, cells, cache, grid_metrics, damage);
}

pub fn extractClustersWithDamageScratch(
    allocator: std.mem.Allocator,
    scratch: *RetainedScratch,
    cells: []const contract.RenderableCell,
    cache: contract.LineTextCache,
    grid_metrics: contract.GridMetrics,
    damage: scene.DamageInput,
) !OwnedClusters {
    const damage_filter = DamageFilter.init(damage, grid_metrics);
    try scratch.require(count32(cells), 0);
    var cluster_count: u32 = 0;
    for (cells, 0..) |cell, idx| {
        if (cell.continuation) continue;
        if (!damage_filter.includeSpan(cell.first_cell, cell.cell_span)) continue;
        const text = textForCell(cell, cache);
        if (isBlankText(text)) continue;
        const inferred_span = inferredRenderableCellSpan(cells, @intCast(idx));
        std.debug.assert(cell.cell_span == inferred_span);
        scratch.clusters[@intCast(cluster_count)] = renderableCluster(cell, text, cell.cell_span);
        cluster_count += 1;
    }

    return .{ .allocator = allocator, .clusters = try allocator.dupe(contract.CellCluster, scratch.clusters[0..@intCast(cluster_count)]) };
}

pub fn selectComplexWithDamage(
    allocator: std.mem.Allocator,
    cells: []const contract.RenderableCell,
    cache: contract.LineTextCache,
    clusters: []const contract.CellCluster,
    grid_metrics: contract.GridMetrics,
    damage: scene.DamageInput,
) !ComplexSelection {
    var scratch = RetainedScratch{};
    defer scratch.deinit(allocator);
    try scratch.configure(allocator, count32(cells), 0);
    return selectComplexWithDamageScratch(allocator, &scratch, cells, cache, clusters, grid_metrics, damage);
}

pub fn sourceRenderableTextFromCells(cells: []const contract.CellInput, idx: u32) ?RenderableText {
    const cell = cells[idx];
    if (cell.continuation) return null;
    const cell_span = inferredCellSpan(cells, idx);
    return initRenderableTextFromCellInput(renderableFromCellInput(.{ .value = 0 }, idx, cell_span, cell, false), cell);
}

pub fn sourceRenderableTextFromPublication(cells: []const source_vt.SourceCell, theme: source_theme.SurfaceTheme, idx: u32) ?RenderableText {
    const cell = cells[idx];
    if (cell.flags.continuation != 0) return null;
    const mapped = source_text_input.mapPublicationCellInput(cell, theme);
    const cell_span = inferredPublicationCellSpan(cells, idx);
    return initRenderableTextFromCellInput(renderableFromCellInput(.{ .value = 0 }, idx, cell_span, mapped, false), mapped);
}

pub fn sourceRenderableTextFromInputs(inputs: []const CellTextInput, idx: u32) ?RenderableText {
    const input = inputs[idx];
    if (input.continuation) return null;
    const text = inputCellText(input);
    const cell_span = @max(@max(input.cell_span, 1), inferredInputCellSpan(inputs, idx));
    return .{
        .renderable = renderableFromInput(.{ .value = 0 }, idx, cell_span, detectPresentation(text.codepoints, input.presentation), input),
        .text = text,
    };
}

pub fn sourceRenderableTextFromPrepared(cells: []const contract.RenderableCell, cache: contract.LineTextCache, idx: u32) ?RenderableText {
    const renderable = cells[idx];
    if (renderable.continuation) return null;
    const inferred_span = inferredRenderableCellSpan(cells, idx);
    std.debug.assert(renderable.cell_span == inferred_span);
    return .{ .renderable = renderable, .text = textForCell(renderable, cache) };
}

pub fn includeDamage(grid_metrics: contract.GridMetrics, damage: scene.DamageInput, renderable: contract.RenderableCell) bool {
    return DamageFilter.init(damage, grid_metrics).includeSpan(renderable.first_cell, renderable.cell_span);
}

pub fn selectComplexWithDamageScratch(
    allocator: std.mem.Allocator,
    scratch: *RetainedScratch,
    cells: []const contract.RenderableCell,
    cache: contract.LineTextCache,
    clusters: []const contract.CellCluster,
    grid_metrics: contract.GridMetrics,
    damage: scene.DamageInput,
) !ComplexSelection {
    const damage_filter = DamageFilter.init(damage, grid_metrics);
    try scratch.require(@max(count32(cells), count32(clusters)), 0);
    var cell_count: u32 = 0;
    var cluster_count: u32 = 0;
    for (cells) |cell| {
        if (cell.continuation) continue;
        if (!damage_filter.includeSpan(cell.first_cell, cell.cell_span)) continue;
        if (!classifyComplexCell(cell, cache)) continue;
        scratch.renderable[@intCast(cell_count)] = cell;
        cell_count += 1;
    }

    for (clusters) |cluster_value| {
        if (!classifyComplexCluster(cells, cluster_value, cache)) continue;
        scratch.clusters[@intCast(cluster_count)] = cluster_value;
        cluster_count += 1;
    }

    const selected_cells = try allocator.dupe(contract.RenderableCell, scratch.renderable[0..@intCast(cell_count)]);
    errdefer allocator.free(selected_cells);
    const selected_clusters = try allocator.dupe(contract.CellCluster, scratch.clusters[0..@intCast(cluster_count)]);
    return .{
        .allocator = allocator,
        .cells = selected_cells,
        .clusters = selected_clusters,
    };
}

fn textForCell(cell: contract.RenderableCell, cache: contract.LineTextCache) contract.CellText {
    const text_idx = cell.text_id.value;
    std.debug.assert(text_idx < count32(cache.texts));
    return cache.texts[@intCast(text_idx)];
}

fn textForCluster(cluster: contract.CellCluster, cache: contract.LineTextCache) contract.CellText {
    const idx = cluster.text_id.value;
    std.debug.assert(idx < count32(cache.texts));
    return cache.texts[@intCast(idx)];
}

fn isBlankText(text: contract.CellText) bool {
    const cps = if (text.codepoints.len == 0) &[_]u32{text.first_cp} else text.codepoints;
    for (cps) |cp| {
        if (cp != 0 and cp != ' ') return false;
    }
    return true;
}

const DamageFilter = struct {
    cols: u32,
    dirty_rows: []const bool,
    dirty_cols_start: []const u16,
    dirty_cols_end: []const u16,
    valid: bool,

    fn init(damage: scene.DamageInput, grid_metrics: contract.GridMetrics) DamageFilter {
        const row_count = grid_metrics.rows;
        const valid = !damage.full and
            count16(damage.dirty_rows) == row_count and
            count16(damage.dirty_cols_start) == row_count and
            count16(damage.dirty_cols_end) == row_count;
        return .{
            .cols = @max(@as(u32, grid_metrics.cols), 1),
            .dirty_rows = damage.dirty_rows,
            .dirty_cols_start = damage.dirty_cols_start,
            .dirty_cols_end = damage.dirty_cols_end,
            .valid = valid,
        };
    }

    fn cleanRowSkip(self: DamageFilter, idx: u32, cells_len: u32) ?u32 {
        if (!self.valid) return null;
        const row = idx / self.cols;
        if (row >= count32(self.dirty_rows)) return cells_len;
        if (self.dirty_rows[@intCast(row)]) return null;
        return @min((row + 1) * self.cols, cells_len);
    }

    fn includeSpan(self: DamageFilter, first_cell: u32, cell_span: u8) bool {
        if (!self.valid) return true;
        const row = first_cell / self.cols;
        if (row >= count32(self.dirty_rows) or !self.dirty_rows[@intCast(row)]) return false;
        const start_col = @as(u16, @intCast(first_cell % self.cols));
        const end_col = start_col +| (@max(cell_span, 1) - 1);
        return !(end_col < self.dirty_cols_start[@intCast(row)] or start_col > self.dirty_cols_end[@intCast(row)]);
    }
};

fn renderableFromCellInput(text_id: contract.CellTextId, first_cell: u32, cell_span: u8, cell: contract.CellInput, continuation: bool) contract.RenderableCell {
    return renderableCell(
        text_id,
        first_cell,
        cell_span,
        cell.style,
        cell.presentation,
        cell.dim,
        cell.invisible,
        cell.semantic_fg,
        cell.semantic_bg,
        cell.fg,
        cell.bg,
        cell.underline_color_set,
        cell.semantic_underline_color,
        cell.underline_color,
        switch (cell.underline_style) {
            .straight => .straight,
            .double => .double,
            .curly => .curly,
            .dotted => .dotted,
            .dashed => .dashed,
        },
        cell.underline,
        cell.strikethrough,
        continuation,
    );
}

fn renderableFromInput(text_id: contract.CellTextId, first_cell: u32, cell_span: u8, presentation: contract.TextPresentation, input: CellTextInput) contract.RenderableCell {
    return renderableCell(
        text_id,
        first_cell,
        cell_span,
        input.style,
        presentation,
        false,
        false,
        input.semantic_fg,
        input.semantic_bg,
        input.fg,
        input.bg,
        input.underline_color_set,
        input.semantic_underline_color,
        input.underline_color,
        input.underline_style,
        input.underline,
        input.strikethrough,
        input.continuation,
    );
}

fn renderableCell(text_id: contract.CellTextId, first_cell: u32, cell_span: u8, style: contract.FontStyle, presentation: contract.TextPresentation, dim: bool, invisible: bool, semantic_fg: contract.SemanticColor, semantic_bg: contract.SemanticColor, fg: contract.Rgba8, bg: contract.Rgba8, underline_color_set: bool, semantic_underline_color: contract.SemanticColor, underline_color: contract.Rgba8, underline_style: contract.UnderlineStyle, underline: bool, strikethrough: bool, continuation: bool) contract.RenderableCell {
    return .{
        .text_id = text_id,
        .first_cell = first_cell,
        .cell_span = cell_span,
        .style = style,
        .presentation = presentation,
        .dim = dim,
        .invisible = invisible,
        .semantic_fg = semantic_fg,
        .semantic_bg = semantic_bg,
        .fg = fg,
        .bg = bg,
        .underline_color_set = underline_color_set,
        .semantic_underline_color = semantic_underline_color,
        .underline_color = underline_color,
        .underline_style = underline_style,
        .underline = underline,
        .strikethrough = strikethrough,
        .continuation = continuation,
    };
}

fn renderableCluster(cell: contract.RenderableCell, text: contract.CellText, cell_span: u8) contract.CellCluster {
    return .{
        .text_id = cell.text_id,
        .first_cell = cell.first_cell,
        .cell_span = @max(cell.cell_span, cell_span),
        .first_cp = text.first_cp,
        .style = cell.style,
        .presentation = cell.presentation,
    };
}

fn classifyComplexCell(cell: contract.RenderableCell, cache: contract.LineTextCache) bool {
    return lane.classifyRenderableCell(cell, textForCell(cell, cache)).lane == .complex;
}

fn classifyComplexCluster(cells: []const contract.RenderableCell, cluster_value: contract.CellCluster, cache: contract.LineTextCache) bool {
    return lane.classifyClusterInCells(cells, cluster_value, textForCluster(cluster_value, cache)).lane == .complex;
}

fn inferredCellSpan(cells: []const contract.CellInput, idx: u32) u8 {
    var span: u32 = 1;
    const total = count32(cells);
    while (idx + span < total and cells[@intCast(idx + span)].continuation) : (span += 1) {}
    return @intCast(@min(span, std.math.maxInt(u8)));
}

fn inferredInputCellSpan(inputs: []const CellTextInput, idx: u32) u8 {
    var span: u32 = 1;
    const total = count32(inputs);
    while (idx + span < total and inputs[@intCast(idx + span)].continuation) : (span += 1) {}
    return @intCast(@min(span, std.math.maxInt(u8)));
}

fn inferredPublicationCellSpan(cells: []const source_vt.SourceCell, idx: u32) u8 {
    var span: u32 = 1;
    const total = count32(cells);
    while (idx + span < total and cells[@intCast(idx + span)].flags.continuation != 0) : (span += 1) {}
    return @intCast(@min(span, std.math.maxInt(u8)));
}

fn inferredRenderableCellSpan(cells: []const contract.RenderableCell, idx: u32) u8 {
    var span: u32 = 1;
    const total = count32(cells);
    while (idx + span < total and cells[@intCast(idx + span)].continuation) : (span += 1) {}
    return @intCast(@min(span, std.math.maxInt(u8)));
}

pub fn buildProvisionalRuns(allocator: std.mem.Allocator, clusters: []const contract.CellCluster, face_id: contract.FontFaceId) !OwnedRuns {
    if (clusters.len == 0) {
        return .{ .allocator = allocator, .runs = try allocator.alloc(contract.ResolvedRun, 0) };
    }

    var scratch = RetainedScratch{};
    defer scratch.deinit(allocator);
    try scratch.configure(allocator, count32(clusters), 0);
    return buildProvisionalRunsScratch(allocator, &scratch, clusters, face_id);
}

pub fn buildProvisionalRunsScratch(allocator: std.mem.Allocator, scratch: *RetainedScratch, clusters: []const contract.CellCluster, face_id: contract.FontFaceId) !OwnedRuns {
    if (clusters.len == 0) {
        return .{ .allocator = allocator, .runs = try allocator.alloc(contract.ResolvedRun, 0) };
    }
    try scratch.require(count32(clusters), 0);

    var prev = clusters[0];
    var start: u32 = 0;
    var run_count: u32 = 0;
    for (clusters[1..], 1..) |cluster, idx| {
        if (cluster.style != prev.style or cluster.presentation != prev.presentation) {
            scratch.runs[@intCast(run_count)] = resolvedRun(start, @intCast(idx - start), face_id, prev.style, prev.presentation);
            run_count += 1;
            start = @intCast(idx);
        }
        prev = cluster;
    }
    scratch.runs[@intCast(run_count)] = resolvedRun(start, @intCast(clusters.len - start), face_id, prev.style, prev.presentation);
    run_count += 1;

    return .{ .allocator = allocator, .runs = try allocator.dupe(contract.ResolvedRun, scratch.runs[0..@intCast(run_count)]) };
}

fn resolvedRun(cluster_start: u32, cluster_count: u32, face_id: contract.FontFaceId, style: contract.FontStyle, presentation: contract.TextPresentation) contract.ResolvedRun {
    return .{ .run = .{
        .cluster_start = cluster_start,
        .cluster_count = cluster_count,
        .font = .{
            .face_id = face_id,
            .style = style,
            .presentation = presentation,
        },
    } };
}

fn count32(items: anytype) u32 {
    std.debug.assert(items.len <= std.math.maxInt(u32));
    return @intCast(items.len);
}

fn count16(items: anytype) u16 {
    std.debug.assert(items.len <= std.math.maxInt(u16));
    return @intCast(items.len);
}

fn appendScratchText(scratch: *RetainedScratch, text_count: *u32, codepoint_count: *u32, cps: []const u32) void {
    const cp_start = codepoint_count.*;
    const cp_len: u32 = @intCast(cps.len);
    @memcpy(scratch.codepoints[@intCast(cp_start)..@intCast(cp_start + cp_len)], cps);
    scratch.texts[@intCast(text_count.*)] = .{
        .id = .{ .value = text_count.* },
        .first_cp = cps[0],
        .codepoints = scratch.codepoints[@intCast(cp_start)..@intCast(cp_start + cp_len)],
    };
    text_count.* += 1;
    codepoint_count.* += cp_len;
}

fn cloneTextCache(allocator: std.mem.Allocator, texts: []const contract.CellText, codepoints: []const u32) !OwnedLineTextCache {
    const final_codepoints = try allocator.dupe(u32, codepoints);
    errdefer allocator.free(final_codepoints);
    const final_texts = try allocator.alloc(contract.CellText, texts.len);
    errdefer allocator.free(final_texts);

    var codepoint_offset: u32 = 0;
    for (texts, 0..) |text, idx| {
        const cp_len: u32 = @intCast(text.codepoints.len);
        final_texts[idx] = .{
            .id = .{ .value = @intCast(idx) },
            .first_cp = text.first_cp,
            .codepoints = final_codepoints[@intCast(codepoint_offset)..@intCast(codepoint_offset + cp_len)],
        };
        codepoint_offset += cp_len;
    }
    std.debug.assert(codepoint_offset == @as(u32, @intCast(codepoints.len)));
    return .{ .allocator = allocator, .texts = final_texts, .codepoints = final_codepoints };
}

fn countNormalizedInputCodepoints(inputs: []const CellTextInput) u32 {
    var total_codepoints: u32 = 0;
    for (inputs) |input| total_codepoints += @intCast(@max(input.codepoints.len, 1));
    return total_codepoints;
}

fn countCellInputCodepoints(cells: []const contract.CellInput) u32 {
    var total_codepoints: u32 = 0;
    for (cells) |cell| total_codepoints += @as(u32, cell.combining_len) + 1;
    return total_codepoints;
}

fn countPublicationCodepoints(cells: []const source_vt.SourceCell) u32 {
    var total_codepoints: u32 = 0;
    for (cells) |cell| total_codepoints += @as(u32, cell.combining_len) + 1;
    return total_codepoints;
}

test "single codepoint text preserves first codepoint" {
    const text = singleCodepointText(7, 'A');
    try @import("std").testing.expectEqual(@as(u32, 'A'), text.first_cp);
}

test "cell inputs build text cache renderable cells clusters and runs" {
    const allocator = std.testing.allocator;
    const white = contract.Rgba8{ .r = 255, .g = 255, .b = 255, .a = 255 };
    const black = contract.Rgba8{ .r = 0, .g = 0, .b = 0, .a = 255 };
    const cells = [_]contract.CellInput{
        .{ .codepoint = 'A', .fg = white, .bg = black },
        .{ .codepoint = 'B', .fg = white, .bg = black },
        .{ .codepoint = 'C', .fg = white, .bg = black, .continuation = true },
    };

    var cache = try buildLineTextCacheFromCells(allocator, &cells);
    defer cache.deinit();
    var renderable = try buildRenderableCellsFromCells(allocator, &cells, cache.view());
    defer renderable.deinit();
    var clusters = try extractClusters(allocator, renderable.cells, cache.view());
    defer clusters.deinit();
    var runs = try buildProvisionalRuns(allocator, clusters.clusters, .{ .value = 1 });
    defer runs.deinit();

    try std.testing.expectEqual(@as(u32, 3), count32(cache.texts));
    try std.testing.expectEqual(@as(u32, 2), count32(clusters.clusters));
    try std.testing.expectEqual(@as(u32, 1), count32(runs.runs));
    try std.testing.expectEqual(@as(u32, 2), runs.runs[0].run.cluster_count);
    try std.testing.expectEqual(contract.SemanticColorKind.default, renderable.cells[0].semantic_fg.kind);
    try std.testing.expectEqual(contract.SemanticColorKind.default, renderable.cells[0].semantic_bg.kind);
}

test "cell inputs retain combining sequences in text cache" {
    const allocator = std.testing.allocator;
    const white = contract.Rgba8{ .r = 255, .g = 255, .b = 255, .a = 255 };
    const black = contract.Rgba8{ .r = 0, .g = 0, .b = 0, .a = 255 };
    const cells = [_]contract.CellInput{.{
        .codepoint = 'i',
        .combining_len = 1,
        .combining = .{ 0x0332, 0, 0 },
        .fg = white,
        .bg = black,
    }};

    var cache = try buildLineTextCacheFromCells(allocator, &cells);
    defer cache.deinit();

    try std.testing.expectEqual(@as(u32, 'i'), cache.texts[0].first_cp);
    try std.testing.expectEqualSlices(u32, &.{ 'i', 0x0332 }, cache.texts[0].codepoints);
}

test "cell inputs preserve style and presentation into renderables clusters and runs" {
    const allocator = std.testing.allocator;
    const white = contract.Rgba8{ .r = 255, .g = 255, .b = 255, .a = 255 };
    const black = contract.Rgba8{ .r = 0, .g = 0, .b = 0, .a = 255 };
    const cells = [_]contract.CellInput{
        .{ .codepoint = 'A', .style = .bold, .presentation = .text, .fg = white, .bg = black },
        .{ .codepoint = 'B', .style = .italic, .presentation = .emoji, .fg = white, .bg = black },
    };

    var cache = try buildLineTextCacheFromCells(allocator, &cells);
    defer cache.deinit();
    var renderable = try buildRenderableCellsFromCells(allocator, &cells, cache.view());
    defer renderable.deinit();
    var clusters = try extractClusters(allocator, renderable.cells, cache.view());
    defer clusters.deinit();
    var runs = try buildProvisionalRuns(allocator, clusters.clusters, .{ .value = 9 });
    defer runs.deinit();

    try std.testing.expectEqual(contract.FontStyle.bold, renderable.cells[0].style);
    try std.testing.expectEqual(contract.TextPresentation.text, renderable.cells[0].presentation);
    try std.testing.expectEqual(contract.FontStyle.italic, renderable.cells[1].style);
    try std.testing.expectEqual(contract.TextPresentation.emoji, renderable.cells[1].presentation);

    try std.testing.expectEqual(contract.FontStyle.bold, clusters.clusters[0].style);
    try std.testing.expectEqual(contract.TextPresentation.text, clusters.clusters[0].presentation);
    try std.testing.expectEqual(contract.FontStyle.italic, clusters.clusters[1].style);
    try std.testing.expectEqual(contract.TextPresentation.emoji, clusters.clusters[1].presentation);

    try std.testing.expectEqual(@as(usize, 2), runs.runs.len);
    try std.testing.expectEqual(contract.FontStyle.bold, runs.runs[0].run.font.style);
    try std.testing.expectEqual(contract.TextPresentation.text, runs.runs[0].run.font.presentation);
    try std.testing.expectEqual(contract.FontStyle.italic, runs.runs[1].run.font.style);
    try std.testing.expectEqual(contract.TextPresentation.emoji, runs.runs[1].run.font.presentation);
}

test "blank cells do not produce text clusters" {
    const allocator = std.testing.allocator;
    const white = contract.Rgba8{ .r = 255, .g = 255, .b = 255, .a = 255 };
    const black = contract.Rgba8{ .r = 0, .g = 0, .b = 0, .a = 255 };
    const cells = [_]contract.CellInput{
        .{ .codepoint = ' ', .fg = white, .bg = black },
        .{ .codepoint = 'A', .fg = white, .bg = black },
        .{ .codepoint = 0, .fg = white, .bg = black },
    };

    var cache = try buildLineTextCacheFromCells(allocator, &cells);
    defer cache.deinit();
    var renderable = try buildRenderableCellsFromCells(allocator, &cells, cache.view());
    defer renderable.deinit();
    var clusters = try extractClusters(allocator, renderable.cells, cache.view());
    defer clusters.deinit();

    try std.testing.expectEqual(@as(u32, 1), count32(clusters.clusters));
    try std.testing.expectEqual(@as(u32, 'A'), clusters.clusters[0].first_cp);
    try std.testing.expectEqual(@as(u32, 1), clusters.clusters[0].first_cell);
}

test "continuation cells expand base cell spans" {
    const allocator = std.testing.allocator;
    const white = contract.Rgba8{ .r = 255, .g = 255, .b = 255, .a = 255 };
    const black = contract.Rgba8{ .r = 0, .g = 0, .b = 0, .a = 255 };
    const cells = [_]contract.CellInput{
        .{ .codepoint = 0x4f60, .fg = white, .bg = black },
        .{ .codepoint = 0, .fg = white, .bg = black, .continuation = true },
        .{ .codepoint = 'x', .fg = white, .bg = black },
    };

    var cache = try buildLineTextCacheFromCells(allocator, &cells);
    defer cache.deinit();
    var renderable = try buildRenderableCellsFromCells(allocator, &cells, cache.view());
    defer renderable.deinit();
    var clusters = try extractClusters(allocator, renderable.cells, cache.view());
    defer clusters.deinit();

    try std.testing.expectEqual(@as(u8, 2), renderable.cells[0].cell_span);
    try std.testing.expectEqual(@as(u32, 2), count32(clusters.clusters));
    try std.testing.expectEqual(@as(u32, 0), clusters.clusters[0].first_cell);
    try std.testing.expectEqual(@as(u8, 2), clusters.clusters[0].cell_span);
    try std.testing.expectEqual(@as(u32, 2), clusters.clusters[1].first_cell);
}

test "partial damage filters clean clusters before shaping" {
    const allocator = std.testing.allocator;
    const white = contract.Rgba8{ .r = 255, .g = 255, .b = 255, .a = 255 };
    const black = contract.Rgba8{ .r = 0, .g = 0, .b = 0, .a = 255 };
    const cells = [_]contract.CellInput{
        .{ .codepoint = 'A', .fg = white, .bg = black },
        .{ .codepoint = 'B', .fg = white, .bg = black },
        .{ .codepoint = 'C', .fg = white, .bg = black },
        .{ .codepoint = 'D', .fg = white, .bg = black },
    };
    const dirty_rows = [_]bool{ false, true };
    const dirty_starts = [_]u16{ 0, 0 };
    const dirty_ends = [_]u16{ 0, 0 };

    var cache = try buildLineTextCacheFromCells(allocator, &cells);
    defer cache.deinit();
    var renderable = try buildRenderableCellsFromCells(allocator, &cells, cache.view());
    defer renderable.deinit();
    var clusters = try extractClustersWithDamage(allocator, renderable.cells, cache.view(), .{ .cols = 2, .rows = 2 }, .{
        .full = false,
        .dirty_rows = &dirty_rows,
        .dirty_cols_start = &dirty_starts,
        .dirty_cols_end = &dirty_ends,
    });
    defer clusters.deinit();

    try std.testing.expectEqual(@as(u32, 1), count32(clusters.clusters));
    try std.testing.expectEqual(@as(u32, 2), clusters.clusters[0].first_cell);
    try std.testing.expectEqual(@as(u32, 'C'), clusters.clusters[0].first_cp);
}

test "sparse cells keep only damaged base cells" {
    const allocator = std.testing.allocator;
    const white = contract.Rgba8{ .r = 255, .g = 255, .b = 255, .a = 255 };
    const black = contract.Rgba8{ .r = 0, .g = 0, .b = 0, .a = 255 };
    const cells = [_]contract.CellInput{
        .{ .codepoint = 'A', .fg = white, .bg = black },
        .{ .codepoint = 0, .fg = white, .bg = black, .continuation = true },
        .{ .codepoint = 'B', .fg = white, .bg = black },
        .{ .codepoint = 'C', .fg = white, .bg = black },
    };
    const dirty_rows = [_]bool{ true, false };
    const dirty_starts = [_]u16{ 0, 0 };
    const dirty_ends = [_]u16{ 1, 0 };

    var sparse = try buildSparseCellsWithDamage(allocator, &cells, .{ .cols = 2, .rows = 2 }, .{
        .full = false,
        .dirty_rows = &dirty_rows,
        .dirty_cols_start = &dirty_starts,
        .dirty_cols_end = &dirty_ends,
    });
    defer sparse.deinit();

    try std.testing.expectEqual(@as(u32, 1), count32(sparse.renderable.cells));
    try std.testing.expectEqual(@as(u32, 1), count32(sparse.text_cache.texts));
    try std.testing.expectEqual(@as(u32, 0), sparse.renderable.cells[0].first_cell);
    try std.testing.expectEqual(@as(u8, 2), sparse.renderable.cells[0].cell_span);
    try std.testing.expectEqual(@as(u32, 'A'), sparse.text_cache.texts[0].first_cp);
}

test "sparse cells intern repeated codepoints" {
    const allocator = std.testing.allocator;
    const white = contract.Rgba8{ .r = 255, .g = 255, .b = 255, .a = 255 };
    const black = contract.Rgba8{ .r = 0, .g = 0, .b = 0, .a = 255 };
    const cells = [_]contract.CellInput{
        .{ .codepoint = 'Z', .fg = white, .bg = black },
        .{ .codepoint = 'Z', .fg = white, .bg = black },
        .{ .codepoint = 'Y', .fg = white, .bg = black },
    };

    var sparse = try buildSparseCellsWithDamage(allocator, &cells, .{ .cols = 3, .rows = 1 }, .{ .full = true });
    defer sparse.deinit();

    try std.testing.expectEqual(@as(u32, 2), count32(sparse.text_cache.texts));
    try std.testing.expectEqual(sparse.renderable.cells[0].text_id.value, sparse.renderable.cells[1].text_id.value);
    try std.testing.expect(sparse.renderable.cells[2].text_id.value != sparse.renderable.cells[0].text_id.value);
}

test "sparse cells keep empty background witnesses for scene ownership" {
    const allocator = std.testing.allocator;
    const white = contract.Rgba8{ .r = 255, .g = 255, .b = 255, .a = 255 };
    const black = contract.Rgba8{ .r = 0, .g = 0, .b = 0, .a = 255 };
    const transparent_bg = contract.Rgba8{ .r = 0x44, .g = 0x55, .b = 0x66, .a = 0 };
    const cells = [_]contract.CellInput{
        .{ .codepoint = ' ', .fg = white, .bg = transparent_bg, .empty = true },
        .{ .codepoint = 'A', .fg = white, .bg = black },
        .{ .codepoint = '\t', .fg = white, .bg = transparent_bg, .empty = true },
    };

    var sparse = try buildSparseCellsWithDamage(allocator, &cells, .{ .cols = 3, .rows = 1 }, .{ .full = true });
    defer sparse.deinit();

    try std.testing.expectEqual(@as(u32, 3), count32(sparse.renderable.cells));
    try std.testing.expectEqual(@as(u32, 2), count32(sparse.text_cache.texts));
    try std.testing.expectEqual(@as(u32, 0), sparse.renderable.cells[0].first_cell);
    try std.testing.expectEqual(@as(u32, 1), sparse.renderable.cells[1].first_cell);
    try std.testing.expectEqual(@as(u32, 2), sparse.renderable.cells[2].first_cell);
    try std.testing.expectEqual(transparent_bg.r, sparse.renderable.cells[0].bg.r);
    try std.testing.expectEqual(transparent_bg.g, sparse.renderable.cells[2].bg.g);
    try std.testing.expectEqual(@as(u32, 0), sparse.text_cache.texts[sparse.renderable.cells[0].text_id.value].first_cp);
    try std.testing.expectEqual(@as(u32, 0), sparse.text_cache.texts[sparse.renderable.cells[2].text_id.value].first_cp);
    try std.testing.expectEqual(sparse.renderable.cells[0].text_id.value, sparse.renderable.cells[2].text_id.value);
    try std.testing.expectEqual(@as(u32, 'A'), sparse.text_cache.texts[sparse.renderable.cells[1].text_id.value].first_cp);
}

test "rich cell text interning deduplicates codepoint sequences" {
    const allocator = std.testing.allocator;
    const white = contract.Rgba8{ .r = 255, .g = 255, .b = 255, .a = 255 };
    const black = contract.Rgba8{ .r = 0, .g = 0, .b = 0, .a = 255 };
    const underline_i = [_]u32{ 'i', 0x0332, 0x0308 };
    const inputs = [_]CellTextInput{
        .{ .codepoints = &underline_i, .fg = white, .bg = black },
        .{ .codepoints = &underline_i, .fg = white, .bg = black },
    };
    var cache = try buildLineTextCacheFromInputs(allocator, &inputs);
    defer cache.deinit();
    var renderable = try buildRenderableCellsFromInputs(allocator, &inputs, cache.view());
    defer renderable.deinit();
    var clusters = try extractClusters(allocator, renderable.cells, cache.view());
    defer clusters.deinit();

    try std.testing.expectEqual(@as(u32, 1), count32(cache.texts));
    try std.testing.expectEqual(@as(u32, 3), count32(cache.codepoints));
    try std.testing.expectEqual(cache.texts[0].id.value, renderable.cells[1].text_id.value);
    try std.testing.expectEqual(@as(u32, 'i'), clusters.clusters[0].first_cp);
}

test "rich cell text renderables resolve exact interned text ids" {
    const allocator = std.testing.allocator;
    const white = contract.Rgba8{ .r = 255, .g = 255, .b = 255, .a = 255 };
    const black = contract.Rgba8{ .r = 0, .g = 0, .b = 0, .a = 255 };
    const alpha = [_]u32{'a'};
    const beta = [_]u32{ 'b', 0x0332 };
    const inputs = [_]CellTextInput{
        .{ .codepoints = &alpha, .fg = white, .bg = black },
        .{ .codepoints = &beta, .fg = white, .bg = black },
        .{ .codepoints = &alpha, .fg = white, .bg = black },
    };

    var cache = try buildLineTextCacheFromInputs(allocator, &inputs);
    defer cache.deinit();
    var renderable = try buildRenderableCellsFromInputs(allocator, &inputs, cache.view());
    defer renderable.deinit();

    try std.testing.expectEqual(cache.texts[0].id.value, renderable.cells[0].text_id.value);
    try std.testing.expectEqual(cache.texts[1].id.value, renderable.cells[1].text_id.value);
    try std.testing.expectEqual(cache.texts[0].id.value, renderable.cells[2].text_id.value);
}

test "rich cell text detects emoji and text presentation selectors" {
    const allocator = std.testing.allocator;
    const white = contract.Rgba8{ .r = 255, .g = 255, .b = 255, .a = 255 };
    const black = contract.Rgba8{ .r = 0, .g = 0, .b = 0, .a = 255 };
    const text_x = [_]u32{ 0x2716, VS15 };
    const emoji_x = [_]u32{ 0x2716, VS16 };
    const inputs = [_]CellTextInput{
        .{ .codepoints = &text_x, .fg = white, .bg = black },
        .{ .codepoints = &emoji_x, .fg = white, .bg = black },
    };
    var cache = try buildLineTextCacheFromInputs(allocator, &inputs);
    defer cache.deinit();
    var renderable = try buildRenderableCellsFromInputs(allocator, &inputs, cache.view());
    defer renderable.deinit();
    try std.testing.expectEqual(contract.TextPresentation.text, renderable.cells[0].presentation);
    try std.testing.expectEqual(contract.TextPresentation.emoji, renderable.cells[1].presentation);
}

test "retained scratch bounds sparse cell assembly" {
    const allocator = std.testing.allocator;
    var scratch = RetainedScratch{};
    defer scratch.deinit(allocator);
    try scratch.configure(allocator, 1, 1);
    const white = contract.Rgba8{ .r = 255, .g = 255, .b = 255, .a = 255 };
    const black = contract.Rgba8{ .r = 0, .g = 0, .b = 0, .a = 255 };
    const cells = [_]contract.CellInput{
        .{ .codepoint = 'A', .fg = white, .bg = black },
        .{ .codepoint = 'B', .fg = white, .bg = black },
    };

    try std.testing.expectError(error.ClusterScratchOverflow, buildSparseCellsWithDamageScratch(allocator, &scratch, &cells, .{ .cols = 2, .rows = 1 }, .{ .full = true }));
}

test "retained scratch bounds rich input codepoint assembly" {
    const allocator = std.testing.allocator;
    var scratch = RetainedScratch{};
    defer scratch.deinit(allocator);
    try scratch.configure(allocator, 1, 1);
    const white = contract.Rgba8{ .r = 255, .g = 255, .b = 255, .a = 255 };
    const black = contract.Rgba8{ .r = 0, .g = 0, .b = 0, .a = 255 };
    const combining = [_]u32{ 'i', 0x0332 };
    const inputs = [_]CellTextInput{.{ .codepoints = &combining, .fg = white, .bg = black }};

    try std.testing.expectError(error.ClusterScratchOverflow, buildLineTextCacheFromInputsScratch(allocator, &scratch, &inputs));
}
