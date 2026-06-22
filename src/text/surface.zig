const std = @import("std");
const c = @import("howl_render_c");

const event = @import("../event.zig");
const layout = @import("../layout.zig");
const render = @import("draw_primitives.zig");
const prepared_surface = @import("../surface/prepared_surface.zig");
const surface_emitter = @import("../surface/emitter.zig");
const surface_preparer = @import("../surface/surface_preparer.zig");
const surface_resources = @import("../surface/resource_store.zig");
const face_selection = @import("face_selection.zig");
const font_resolver = @import("resolver.zig");
const glyph_raster = @import("glyph_raster.zig");
const raster_operation = @import("raster/operation.zig");
const rasterizer = @import("raster/rasterizer.zig");
const shape_cluster = @import("shape/cluster.zig");
const shape_run = @import("shape/run.zig");
const glyph_cache = @import("glyph_cache.zig");
const cell_layout = @import("cell_layout.zig");

const max_font_faces = glyph_cache.fallbackFontLen(glyph_cache.max_fallback_fonts) + 1;
const face_text_cache_entry_cap: u32 = 4096;
const glyph_cell_cache_entry_cap: u32 = 4096;
const shape_run_cache_entry_cap: u32 = 64;
const shape_input_codepoints_per_cluster_cap: u32 = 16;
const cached_glyphs_per_run_cap: u32 = 512;
const cell_text_flags_known = c.HOWL_RENDER_CELL_TEXT_UNDERLINE |
    c.HOWL_RENDER_CELL_TEXT_STRIKETHROUGH |
    c.HOWL_RENDER_CELL_TEXT_CONTINUATION |
    c.HOWL_RENDER_CELL_TEXT_EMPTY;

pub const PreparedUpload = c.HowlRenderTextPreparedUpload;
pub const TabBarSurfacePreparedUpload = c.HowlRenderTabBarSurfacePreparedUpload;
const Emitter = surface_emitter.Emitter(.{});

pub const TextSurface = struct {
    allocator: std.mem.Allocator,
    glyph_cache: glyph_cache.GlyphCache,
    preparer: ?surface_preparer.TextSurfacePreparer = null,
    resources: surface_resources.SpriteResourceStore = .init(),
    emitter: Emitter = .init(),
    prepared: ?prepared_surface.PreparedSurface = null,
    cell_input_scratch: []render.CellInput = &.{},
    cell_text_scratch: []shape_cluster.CellTextInput = &.{},
    cell_codepoints_scratch: [][4]u32 = &.{},
    dirty_rows_scratch: []bool = &.{},
    dirty_cols_start_scratch: []u16 = &.{},
    dirty_cols_end_scratch: []u16 = &.{},
    primary_font_path: ?[:0]u8 = null,
    fallback_font_paths: [glyph_cache.max_fallback_fonts]?[:0]u8 = [_]?[:0]u8{null} ** glyph_cache.max_fallback_fonts,
    fallback_font_path_count: glyph_cache.FallbackFontCount = 0,
    font_size_px: u16,
    next_cell_snapshot_seq: u64 = 1,
    surface_layout_epoch: u64 = 1,
    surface_layout_last: ?cell_layout.SurfaceLayout = null,

    pub fn create(allocator: std.mem.Allocator, config: *const c.HowlRenderTextConfig) !*TextSurface {
        if (config.font_size_px == 0) return error.InvalidArgument;
        if (config.fallback_font_path_count > glyph_cache.max_fallback_fonts) return error.InvalidArgument;
        const surface = try allocator.create(TextSurface);
        surface.* = .{
            .allocator = allocator,
            .glyph_cache = glyph_cache.GlyphCache.init(allocator),
            .font_size_px = config.font_size_px,
        };
        errdefer surface.destroy();
        if (config.primary_font_path) |path| surface.primary_font_path = try copyPath(allocator, path);
        if (config.fallback_font_path_count > 0) {
            const paths = config.fallback_font_paths orelse return error.InvalidArgument;
            var i: glyph_cache.FallbackFontCount = 0;
            while (i < config.fallback_font_path_count) : (i += 1) {
                surface.fallback_font_paths[i] = try copyPath(allocator, paths[i] orelse return error.InvalidArgument);
            }
            surface.fallback_font_path_count = @intCast(config.fallback_font_path_count);
            surface.glyph_cache.fallback_font_paths_len = surface.fallback_font_path_count;
            var j: glyph_cache.FallbackFontCount = 0;
            while (j < surface.fallback_font_path_count) : (j += 1) surface.glyph_cache.fallback_font_paths[j] = surface.fallback_font_paths[j];
        }
        return surface;
    }

    pub fn destroy(self: *TextSurface) void {
        self.releasePrepared();
        if (self.preparer) |*preparer| preparer.deinit();
        self.preparer = null;
        if (self.cell_input_scratch.len > 0) self.allocator.free(self.cell_input_scratch);
        if (self.cell_text_scratch.len > 0) self.allocator.free(self.cell_text_scratch);
        if (self.cell_codepoints_scratch.len > 0) self.allocator.free(self.cell_codepoints_scratch);
        if (self.dirty_rows_scratch.len > 0) self.allocator.free(self.dirty_rows_scratch);
        if (self.dirty_cols_start_scratch.len > 0) self.allocator.free(self.dirty_cols_start_scratch);
        if (self.dirty_cols_end_scratch.len > 0) self.allocator.free(self.dirty_cols_end_scratch);
        if (self.primary_font_path) |path| self.allocator.free(path);
        var i: glyph_cache.FallbackFontCount = 0;
        while (i < self.fallback_font_path_count) : (i += 1) if (self.fallback_font_paths[i]) |path| self.allocator.free(path);
        self.glyph_cache.deinit();
        const allocator = self.allocator;
        self.* = undefined;
        allocator.destroy(self);
    }

    pub fn prepare(self: *TextSurface, input: *const c.HowlRenderTextPrepare, out: *PreparedUpload) !void {
        if (input.render_state == null) return error.InvalidArgument;
        if (input.render_px.width == 0 or input.render_px.height == 0) return error.InvalidArgument;
        self.releasePrepared();

        const surface_layout = self.layoutForSurface(input.render_px);
        const grid = surface_layout.grid;

        const token = try readRenderStateToken(input.render_state.?);
        _ = try renderStateDirty(input.render_state.?);
        // The C text ABI has no submitted-base input yet. Rect damage is unsafe across skipped frames without that base.
        const full_damage = true;
        const text = try self.readRenderState(input.render_state.?, grid, full_damage);
        const options = surface_preparer.PrepareOptions{ .draw_list = .{
            .cursor = try readCursorPresentation(input.render_state.?, text.colors, input),
            .damage = .{ .full = full_damage, .dirty_rows = text.dirty_rows, .dirty_cols_start = text.dirty_cols_start, .dirty_cols_end = text.dirty_cols_end },
        } };
        const preparer = try self.ensurePreparer(grid);
        var faces: [max_font_faces]face_selection.FaceRecord = undefined;
        var resolve: font_resolver.ResolveObservability = .{};
        var owned_text = try preparer.prepareCellsWithFaceSelection(text.cells, .{ .cols = grid.cols, .rows = grid.rows }, self.faceSelection(&faces, &resolve, surface_layout.cell), options);
        errdefer owned_text.deinit();
        self.prepared = .{
            .allocator = self.allocator,
            .request = .{ .token = .{
                .snapshot_seq = token.snapshot_seq,
                .dirty_epoch = token.dirty_epoch,
                .layout_epoch = input.layout_epoch,
                .damage_base_seq = if (full_damage or token.snapshot_seq == 0) 0 else token.snapshot_seq - 1,
                .damage_kind = if (full_damage) .full else .partial,
            } },
            .layout_epoch = input.layout_epoch,
            .render_px = surface_layout.render_px,
            .cell_px = surface_layout.cell.cellSize(),
            .grid = .{ .cols = grid.cols, .rows = grid.rows },
            .dirty_rows = text.dirty_rows,
            .dirty_cols_start = text.dirty_cols_start,
            .dirty_cols_end = text.dirty_cols_end,
            .text_surface = owned_text,
            .resolve = resolve,
        };
        const prepared = &self.prepared.?;
        _ = try self.emitter.emitPreparedFresh(&self.resources, prepared);
        out.* = .{
            .status = c.HOWL_RENDER_CALL_OK,
            .term_surface_status = 0,
            .reserved0 = 0,
            .snapshot_seq = token.snapshot_seq,
            .render_px = .{ .width = surface_layout.render_px.width, .height = surface_layout.render_px.height },
            .term_surface_prepared = self.emitter.surface(),
        };
    }

    pub fn surfaceLayout(self: *TextSurface, surface_px: c.HowlRenderPixelSize, out: *c.HowlRenderLayoutResponse) !void {
        if (surface_px.width == 0 or surface_px.height == 0) return error.InvalidArgument;
        const next = self.layoutForSurface(surface_px);
        const changed = if (self.surface_layout_last) |current| surfaceLayoutChanged(current, next) else true;
        if (changed) {
            self.surface_layout_epoch +%= 1;
            if (self.surface_layout_epoch == 0) self.surface_layout_epoch = 1;
            self.surface_layout_last = next;
        }
        out.* = next.toCResponse(changed, self.surface_layout_epoch);
    }

    pub fn surfacePointCell(self: *TextSurface, surface_px: c.HowlRenderPixelSize, point: c.HowlRenderTermSurfacePoint, out: *c.HowlRenderTermSurfacePointCell) !void {
        if (surface_px.width == 0 or surface_px.height == 0) return error.InvalidArgument;
        out.* = self.layoutForSurface(surface_px).pointCell(point);
    }

    pub fn prepareTabBarSurface(self: *TextSurface, input: *const c.HowlRenderTabBarSurfacePrepare, out: *TabBarSurfacePreparedUpload) !void {
        if (input.render_px.width == 0 or input.render_px.height == 0) return error.InvalidArgument;
        if (input.cell_px.width == 0 or input.cell_px.height == 0) return error.InvalidArgument;
        if (input.grid.cols == 0 or input.grid.rows == 0) return error.InvalidArgument;
        if (!cellTextSpanValid(input.cells, input.grid)) return error.InvalidArgument;
        self.releasePrepared();

        const cell_count = input.cells.count;
        try self.ensureCellTextScratchCapacity(cell_count);
        try self.ensureDamageScratchCapacity(input.grid.rows);
        const cells = self.cell_text_scratch[0..cell_count];
        for (input.cells.ptr[0..cell_count], cells, self.cell_codepoints_scratch[0..cell_count]) |source, *target, *codepoints| target.* = try cellTextIn(source, codepoints);
        const dirty_rows = self.dirty_rows_scratch[0..input.grid.rows];
        const dirty_cols_start = self.dirty_cols_start_scratch[0..input.grid.rows];
        const dirty_cols_end = self.dirty_cols_end_scratch[0..input.grid.rows];
        markFullDamage(dirty_rows, dirty_cols_start, dirty_cols_end, input.grid.cols);

        const snapshot_seq = self.nextCellSnapshotSeq();
        const preparer = try self.ensurePreparer(input.grid);
        var faces: [max_font_faces]face_selection.FaceRecord = undefined;
        var resolve: font_resolver.ResolveObservability = .{};
        const cell = cell_layout.CellLayout.fromCellSize(input.cell_px, glyph_cache.deriveCellLayoutWithConfig(&self.glyph_cache, self.textConfig()));
        var owned_text = try preparer.prepareCellTextInputsWithFaceSelection(cells, .{ .cols = input.grid.cols, .rows = input.grid.rows }, self.faceSelection(&faces, &resolve, cell), .{});
        errdefer owned_text.deinit();
        self.prepared = .{
            .allocator = self.allocator,
            .request = .{ .token = .{ .snapshot_seq = snapshot_seq, .dirty_epoch = snapshot_seq, .layout_epoch = input.layout_epoch, .damage_base_seq = 0, .damage_kind = .full } },
            .layout_epoch = input.layout_epoch,
            .render_px = pixelSizeIn(input.render_px),
            .cell_px = cellSizeIn(input.cell_px),
            .grid = .{ .cols = input.grid.cols, .rows = input.grid.rows },
            .dirty_rows = dirty_rows,
            .dirty_cols_start = dirty_cols_start,
            .dirty_cols_end = dirty_cols_end,
            .text_surface = owned_text,
            .resolve = resolve,
        };
        _ = try self.emitter.emitPreparedFresh(&self.resources, &self.prepared.?);
        out.* = .{
            .status = c.HOWL_RENDER_CALL_OK,
            .tab_bar_surface_status = 0,
            .reserved0 = 0,
            .snapshot_seq = snapshot_seq,
            .render_px = input.render_px,
            .tab_bar_surface_prepared = @ptrCast(self.emitter.surface()),
        };
    }

    pub fn submitTermSurface(self: *TextSurface, term_surface: c.HowlRenderTermSurface, out_term_surface: *c.HowlRenderTermSurface) void {
        out_term_surface.* = term_surface;
        self.releasePrepared();
    }

    fn releasePrepared(self: *TextSurface) void {
        if (self.prepared) |*prepared| prepared.deinit();
        self.prepared = null;
    }

    fn ensurePreparer(self: *TextSurface, grid: c.HowlRenderCellGrid) !*surface_preparer.TextSurfacePreparer {
        if (self.preparer == null) {
            self.preparer = try surface_preparer.TextSurfacePreparer.initWithProvider(self.allocator, 2048, self.textProvider());
        }
        const ft_hb_capacity = self.capacity(grid);
        try self.glyph_cache.configureCapacity(ft_hb_capacity);
        try self.preparer.?.ensureClusterScratchCapacity(@as(u32, grid.cols) * @as(u32, grid.rows), ft_hb_capacity.max_shape_input_codepoints);
        try self.preparer.?.ensureResolverScratchCapacity(@as(u32, grid.cols) * @as(u32, grid.rows));
        return &self.preparer.?;
    }

    fn capacity(self: *TextSurface, grid: c.HowlRenderCellGrid) glyph_cache.Capacity {
        _ = self;
        const visible_cells = @as(u32, @max(grid.cols, 1)) * @as(u32, @max(grid.rows, 1));
        return .{
            .face_text_cache_entries = @min(visible_cells, face_text_cache_entry_cap),
            .shape_run_cache_entries = @min(visible_cells, shape_run_cache_entry_cap),
            .glyph_cell_cache_entries = @min(visible_cells, glyph_cell_cache_entry_cap),
            .max_shape_input_codepoints = @as(u32, @max(grid.cols, 1)) * shape_input_codepoints_per_cluster_cap,
            .max_glyphs_per_run = cached_glyphs_per_run_cap,
        };
    }

    fn nextCellSnapshotSeq(self: *TextSurface) u64 {
        const snapshot_seq = self.next_cell_snapshot_seq;
        std.debug.assert(snapshot_seq != 0);
        self.next_cell_snapshot_seq +%= 1;
        if (self.next_cell_snapshot_seq == 0) self.next_cell_snapshot_seq = 1;
        return snapshot_seq;
    }

    fn readRenderState(self: *TextSurface, state: c.HowlVtRenderStateHandle, grid: c.HowlRenderCellGrid, full_damage: bool) !RenderStateTextInput {
        const cell_count = try std.math.mul(usize, grid.cols, grid.rows);
        try self.ensureCellInputScratchCapacity(cell_count);
        try self.ensureDamageScratchCapacity(grid.rows);
        const cells = self.cell_input_scratch[0..cell_count];
        const dirty_rows = self.dirty_rows_scratch[0..grid.rows];
        const dirty_cols_start = self.dirty_cols_start_scratch[0..grid.rows];
        const dirty_cols_end = self.dirty_cols_end_scratch[0..grid.rows];
        const colors = try readRenderStateColors(state);
        var row_iterator: c.HowlVtRenderStateRowIteratorHandle = null;
        try requireVtOk(c.howl_vt_render_state_row_iterator_init(&row_iterator));
        defer c.howl_vt_render_state_row_iterator_deinit(row_iterator);
        try requireVtOk(c.howl_vt_render_state_get(state, c.HOWL_VT_RENDER_STATE_DATA_ROW_ITERATOR, @ptrCast(&row_iterator)));
        var row_index: u16 = 0;
        while (c.howl_vt_render_state_row_iterator_next(row_iterator) != 0) : (row_index += 1) {
            std.debug.assert(row_index < grid.rows);
            var row_dirty: u8 = 0;
            try requireVtOk(c.howl_vt_render_state_row_get(row_iterator, c.HOWL_VT_RENDER_STATE_ROW_DATA_DIRTY, @ptrCast(&row_dirty)));
            dirty_rows[row_index] = full_damage or row_dirty != 0;
            if (full_damage) {
                dirty_cols_start[row_index] = 0;
                dirty_cols_end[row_index] = if (grid.cols == 0) 0 else grid.cols - 1;
            } else {
                try requireVtOk(c.howl_vt_render_state_row_get(row_iterator, c.HOWL_VT_RENDER_STATE_ROW_DATA_DIRTY_COL_START, @ptrCast(&dirty_cols_start[row_index])));
                try requireVtOk(c.howl_vt_render_state_row_get(row_iterator, c.HOWL_VT_RENDER_STATE_ROW_DATA_DIRTY_COL_END, @ptrCast(&dirty_cols_end[row_index])));
            }
            var row_cells: c.HowlVtRenderStateRowCellsHandle = null;
            try requireVtOk(c.howl_vt_render_state_row_cells_init(&row_cells));
            defer c.howl_vt_render_state_row_cells_deinit(row_cells);
            try requireVtOk(c.howl_vt_render_state_row_get(row_iterator, c.HOWL_VT_RENDER_STATE_ROW_DATA_CELLS, @ptrCast(&row_cells)));
            var col: u16 = 0;
            while (c.howl_vt_render_state_row_cells_next(row_cells) != 0) : (col += 1) {
                if (col >= grid.cols) continue;
                const idx = @as(usize, row_index) * @as(usize, grid.cols) + col;
                var cell: c.HowlVtRenderStateCell = std.mem.zeroes(c.HowlVtRenderStateCell);
                var selected: u8 = 0;
                var highlighted: u8 = 0;
                try requireVtOk(c.howl_vt_render_state_row_cells_get(row_cells, c.HOWL_VT_RENDER_STATE_ROW_CELLS_DATA_CELL, @ptrCast(&cell)));
                try requireVtOk(c.howl_vt_render_state_row_cells_get(row_cells, c.HOWL_VT_RENDER_STATE_ROW_CELLS_DATA_SELECTED, @ptrCast(&selected)));
                try requireVtOk(c.howl_vt_render_state_row_cells_get(row_cells, c.HOWL_VT_RENDER_STATE_ROW_CELLS_DATA_HIGHLIGHTED, @ptrCast(&highlighted)));
                cells[idx] = mapCell(cell, colors, selected != 0, highlighted != 0);
            }
            while (col < grid.cols) : (col += 1) cells[@as(usize, row_index) * @as(usize, grid.cols) + col] = emptyCell(colors);
        }
        while (row_index < grid.rows) : (row_index += 1) {
            dirty_rows[row_index] = true;
            dirty_cols_start[row_index] = 0;
            dirty_cols_end[row_index] = if (grid.cols == 0) 0 else grid.cols - 1;
            var col: u16 = 0;
            while (col < grid.cols) : (col += 1) cells[@as(usize, row_index) * @as(usize, grid.cols) + col] = emptyCell(colors);
        }
        return .{ .cells = cells, .dirty_rows = dirty_rows, .dirty_cols_start = dirty_cols_start, .dirty_cols_end = dirty_cols_end, .colors = colors };
    }

    fn ensureCellInputScratchCapacity(self: *TextSurface, cell_count: usize) !void {
        if (self.cell_input_scratch.len >= cell_count) return;
        const scratch = try self.allocator.alloc(render.CellInput, cell_count);
        if (self.cell_input_scratch.len > 0) self.allocator.free(self.cell_input_scratch);
        self.cell_input_scratch = scratch;
    }

    fn ensureCellTextScratchCapacity(self: *TextSurface, cell_count: usize) !void {
        if (self.cell_text_scratch.len < cell_count) {
            const scratch = try self.allocator.alloc(shape_cluster.CellTextInput, cell_count);
            if (self.cell_text_scratch.len > 0) self.allocator.free(self.cell_text_scratch);
            self.cell_text_scratch = scratch;
        }
        if (self.cell_codepoints_scratch.len < cell_count) {
            const scratch = try self.allocator.alloc([4]u32, cell_count);
            if (self.cell_codepoints_scratch.len > 0) self.allocator.free(self.cell_codepoints_scratch);
            self.cell_codepoints_scratch = scratch;
        }
    }

    fn ensureDamageScratchCapacity(self: *TextSurface, rows: usize) !void {
        if (self.dirty_rows_scratch.len < rows) {
            const scratch = try self.allocator.alloc(bool, rows);
            if (self.dirty_rows_scratch.len > 0) self.allocator.free(self.dirty_rows_scratch);
            self.dirty_rows_scratch = scratch;
        }
        if (self.dirty_cols_start_scratch.len < rows) {
            const scratch = try self.allocator.alloc(u16, rows);
            if (self.dirty_cols_start_scratch.len > 0) self.allocator.free(self.dirty_cols_start_scratch);
            self.dirty_cols_start_scratch = scratch;
        }
        if (self.dirty_cols_end_scratch.len < rows) {
            const scratch = try self.allocator.alloc(u16, rows);
            if (self.dirty_cols_end_scratch.len > 0) self.allocator.free(self.dirty_cols_end_scratch);
            self.dirty_cols_end_scratch = scratch;
        }
    }

    fn textConfig(self: *TextSurface) glyph_cache.TextConfig {
        return .{ .surface_px = .{ .width = 1, .height = 1 }, .font_size_px = self.font_size_px, .font_path = self.primary_font_path };
    }

    fn textProvider(self: *TextSurface) @import("provider.zig").TextProvider {
        return .{
            .shaper = .{ .ctx = self, .shape_run = providerShapeRunThunk },
            .rasterizer = .{ .ctx = self, .rasterize_sprite = providerRasterizeSpriteThunk },
            .glyph_lookup = .{ .ctx = self, .lookup_glyph = providerLookupGlyphThunk },
            .glyph_raster = .{ .ctx = self, .call = providerRasterizeGlyphThunk },
        };
    }

    fn faceSelection(self: *TextSurface, faces: []face_selection.FaceRecord, active_resolve: ?*font_resolver.ResolveObservability, cell: cell_layout.CellLayout) face_selection.FaceSelection {
        self.glyph_cache.active_resolve = active_resolve;
        var len: glyph_cache.FallbackFontCount = 0;
        if (faces.len > glyph_cache.fallbackFontLen(len)) {
            faces[@intCast(glyph_cache.fallbackFontLen(len))] = .{ .id = .{ .value = glyph_cache.primary_face_id }, .role = .primary, .coverage = .all };
            len += 1;
        }
        var i: glyph_cache.FallbackFontCount = 0;
        while (i < self.glyph_cache.fallback_font_paths_len and glyph_cache.fallbackFontLen(len) < faces.len) : (i += 1) {
            if (self.glyph_cache.fallback_font_paths[i] == null) continue;
            faces[@intCast(glyph_cache.fallbackFontLen(len))] = .{ .id = .{ .value = i + 2 }, .role = .fallback, .coverage = .all };
            len += 1;
        }
        return .{
            .primary_face = .{ .value = glyph_cache.primary_face_id },
            .faces = faces[0..@intCast(glyph_cache.fallbackFontLen(len))],
            .provider = .{ .ctx = self, .has_cell_text = providerHasCellTextThunk },
            .cell_layout = cellFactsFromLayout(cell),
        };
    }

    fn layoutForSurface(self: *TextSurface, surface_px: c.HowlRenderPixelSize) cell_layout.SurfaceLayout {
        const cell = cell_layout.CellLayout.fromLegacyCellFacts(glyph_cache.deriveCellLayoutWithConfig(&self.glyph_cache, self.textConfig()));
        return cell_layout.SurfaceLayout.init(cell_layout.pixelSizeIn(surface_px), cell);
    }
};

fn cellFactsFromLayout(cell: cell_layout.CellLayout) render.CellLayout {
    cell.assertValid();
    return .{
        .cell_w_px = cell.cell_width_px,
        .cell_h_px = cell.cell_height_px,
        .baseline_px = @intCast(cell.baseline_px),
        .box_thickness_px = cell.underline_height_px,
    };
}

fn surfaceLayoutChanged(current: cell_layout.SurfaceLayout, next: cell_layout.SurfaceLayout) bool {
    return current.render_px.width != next.render_px.width or
        current.render_px.height != next.render_px.height or
        current.grid_px.width != next.grid_px.width or
        current.grid_px.height != next.grid_px.height or
        current.grid.cols != next.grid.cols or
        current.grid.rows != next.grid.rows or
        current.cell.cell_width_px != next.cell.cell_width_px or
        current.cell.cell_height_px != next.cell.cell_height_px or
        current.cell.baseline_px != next.cell.baseline_px or
        current.cell.underline_y_px != next.cell.underline_y_px or
        current.cell.underline_height_px != next.cell.underline_height_px or
        current.cell.strikethrough_y_px != next.cell.strikethrough_y_px or
        current.cell.strikethrough_height_px != next.cell.strikethrough_height_px or
        current.cell.sprite_slot_height_px != next.cell.sprite_slot_height_px;
}

test "text surface converts render-owned cell layout to legacy draw facts" {
    const cell = cell_layout.CellLayout.fromLegacyCellFacts(.{ .cell_w_px = 8, .cell_h_px = 16, .baseline_px = 13, .box_thickness_px = 2 });
    const facts = cellFactsFromLayout(cell);
    try std.testing.expectEqual(@as(u16, 8), facts.cell_w_px);
    try std.testing.expectEqual(@as(u16, 16), facts.cell_h_px);
    try std.testing.expectEqual(@as(i16, 13), facts.baseline_px);
    try std.testing.expectEqual(@as(u16, 2), facts.box_thickness_px);
}

const RenderStateToken = struct {
    snapshot_seq: u64,
    dirty_epoch: u64,
};

const RenderStateColors = struct {
    background: c.HowlVtRgb8,
    foreground: c.HowlVtRgb8,
    cursor: c.HowlVtRgb8,
    cursor_has_value: bool,
    palette: [256]c.HowlVtRgb8,
};

const RenderStateTextInput = struct {
    cells: []const render.CellInput,
    dirty_rows: []const bool,
    dirty_cols_start: []const u16,
    dirty_cols_end: []const u16,
    colors: RenderStateColors,
};

fn cellTextSpanValid(span: c.HowlRenderCellTextSpan, grid: c.HowlRenderCellGrid) bool {
    const grid_cells = std.math.mul(u32, grid.cols, grid.rows) catch return false;
    if (grid_cells == 0) return false;
    if (grid_cells > c.HOWL_RENDER_TAB_BAR_SURFACE_CELLS_MAX) return false;
    if (span.count != grid_cells) return false;
    if (span.count > span.count_max) return false;
    if (span.count_max > c.HOWL_RENDER_TAB_BAR_SURFACE_CELLS_MAX) return false;
    if (span.ptr == null) return false;
    return true;
}

fn cellTextIn(value: c.HowlRenderCellText, codepoints: *[4]u32) !shape_cluster.CellTextInput {
    if (value.combining_len > value.combining.len) return error.InvalidArgument;
    if ((value.flags & ~cell_text_flags_known) != 0) return error.InvalidArgument;
    if (!validCodepoint(value.codepoint)) return error.InvalidArgument;
    for (value.combining[0..value.combining_len]) |codepoint| if (!validCodepoint(codepoint)) return error.InvalidArgument;
    if ((value.flags & c.HOWL_RENDER_CELL_TEXT_EMPTY) != 0) return emptyCellTextIn(value, codepoints);
    codepoints[0] = value.codepoint;
    var i: usize = 0;
    while (i < value.combining_len) : (i += 1) codepoints[i + 1] = value.combining[i];
    const codepoint_count = @as(usize, value.combining_len) + 1;
    return .{
        .codepoints = codepoints[0..codepoint_count],
        .style = fontStyleIn(value.style),
        .presentation = presentationIn(value.presentation),
        .fg = rgba8In(value.foreground),
        .bg = rgba8In(value.background),
        .underline_color = rgba8In(value.underline_color),
        .underline_style = underlineStyle(value.underline_style),
        .underline = (value.flags & c.HOWL_RENDER_CELL_TEXT_UNDERLINE) != 0,
        .strikethrough = (value.flags & c.HOWL_RENDER_CELL_TEXT_STRIKETHROUGH) != 0,
        .continuation = (value.flags & c.HOWL_RENDER_CELL_TEXT_CONTINUATION) != 0,
    };
}

fn emptyCellTextIn(value: c.HowlRenderCellText, codepoints: *[4]u32) !shape_cluster.CellTextInput {
    if (value.codepoint != ' ') return error.InvalidArgument;
    if (value.combining_len != 0) return error.InvalidArgument;
    if ((value.flags & c.HOWL_RENDER_CELL_TEXT_UNDERLINE) != 0) return error.InvalidArgument;
    if ((value.flags & c.HOWL_RENDER_CELL_TEXT_STRIKETHROUGH) != 0) return error.InvalidArgument;
    if ((value.flags & c.HOWL_RENDER_CELL_TEXT_CONTINUATION) != 0) return error.InvalidArgument;
    codepoints[0] = ' ';
    return .{
        .codepoints = codepoints[0..1],
        .empty = true,
        .fg = .{ .r = 0, .g = 0, .b = 0, .a = 0 },
        .bg = .{ .r = 0, .g = 0, .b = 0, .a = 0 },
    };
}

fn validCodepoint(value: u32) bool {
    if (value == 0) return false;
    if (value > std.math.maxInt(u21)) return false;
    return true;
}

fn markFullDamage(dirty_rows: []bool, dirty_cols_start: []u16, dirty_cols_end: []u16, cols: u16) void {
    std.debug.assert(cols > 0);
    std.debug.assert(dirty_rows.len == dirty_cols_start.len);
    std.debug.assert(dirty_rows.len == dirty_cols_end.len);
    for (dirty_rows, dirty_cols_start, dirty_cols_end) |*dirty, *start, *end| {
        dirty.* = true;
        start.* = 0;
        end.* = cols - 1;
    }
}

fn rgba8In(value: c.HowlRenderRgba8) render.Rgba8 {
    return .{ .r = value.r, .g = value.g, .b = value.b, .a = value.a };
}

fn fontStyleIn(value: u8) render.FontStyle {
    return switch (value) {
        c.HOWL_RENDER_FONT_STYLE_BOLD => .bold,
        c.HOWL_RENDER_FONT_STYLE_ITALIC => .italic,
        c.HOWL_RENDER_FONT_STYLE_BOLD_ITALIC => .bold_italic,
        else => .regular,
    };
}

fn presentationIn(value: u8) render.TextPresentation {
    return switch (value) {
        c.HOWL_RENDER_TEXT_PRESENTATION_TEXT => .text,
        c.HOWL_RENDER_TEXT_PRESENTATION_EMOJI => .emoji,
        else => .any,
    };
}

fn copyPath(allocator: std.mem.Allocator, path: [*:0]const u8) ![:0]u8 {
    return try allocator.dupeZ(u8, std.mem.span(path));
}

fn pixelSizeIn(value: c.HowlRenderPixelSize) layout.PixelSize {
    return .{ .width = value.width, .height = value.height };
}

fn cellSizeIn(value: c.HowlRenderCellSize) layout.CellSize {
    return .{ .width = value.width, .height = value.height };
}

fn readRenderStateToken(state: c.HowlVtRenderStateHandle) !RenderStateToken {
    return .{
        .snapshot_seq = try renderStateU64(state, c.HOWL_VT_RENDER_STATE_DATA_SNAPSHOT_SEQ),
        .dirty_epoch = try renderStateU64(state, c.HOWL_VT_RENDER_STATE_DATA_DIRTY_GENERATION),
    };
}

fn renderStateDirty(state: c.HowlVtRenderStateHandle) !c_int {
    var dirty: c_int = c.HOWL_VT_RENDER_STATE_DIRTY_FULL;
    try requireVtOk(c.howl_vt_render_state_get(state, c.HOWL_VT_RENDER_STATE_DATA_DIRTY, @ptrCast(&dirty)));
    return dirty;
}

fn readRenderStateColors(state: c.HowlVtRenderStateHandle) !RenderStateColors {
    var colors: c.HowlVtRenderStateColors = .{ .size = @sizeOf(c.HowlVtRenderStateColors) };
    try requireVtOk(c.howl_vt_render_state_colors_get(state, &colors));
    return .{ .background = colors.background, .foreground = colors.foreground, .cursor = colors.cursor, .cursor_has_value = colors.cursor_has_value != 0, .palette = colors.palette };
}

fn readCursorPresentation(state: c.HowlVtRenderStateHandle, colors: RenderStateColors, input: *const c.HowlRenderTextPrepare) !?render.CursorPresentation {
    if (try renderStateByte(state, c.HOWL_VT_RENDER_STATE_DATA_CURSOR_VIEWPORT_HAS_VALUE) == 0) return null;
    const row = try renderStateU16(state, c.HOWL_VT_RENDER_STATE_DATA_CURSOR_VIEWPORT_Y);
    const col = try renderStateU16(state, c.HOWL_VT_RENDER_STATE_DATA_CURSOR_VIEWPORT_X);
    const wide_tail = try renderStateByte(state, c.HOWL_VT_RENDER_STATE_DATA_CURSOR_VIEWPORT_WIDE_TAIL) != 0;
    const visible = try renderStateByte(state, c.HOWL_VT_RENDER_STATE_DATA_CURSOR_VISIBLE) != 0;
    const blinking = try renderStateByte(state, c.HOWL_VT_RENDER_STATE_DATA_CURSOR_BLINKING) != 0;
    const shape = try renderStateCursorShape(state);
    return .{
        .focused = input.focused != 0,
        .visible = visible and input.cursor_opacity != 0,
        .blink = blinking,
        .shape = if (input.effective_shape != 0) cursorShapeIn(input.effective_shape) else shape,
        .beam_thickness = input.cursor_beam_thickness,
        .underline_thickness = input.cursor_underline_thickness,
        .cursor_opacity = input.cursor_opacity,
        .text_blink_opacity = input.text_blink_opacity,
        .cursor_color = if (input.cursor_color.kind != 0) cursorColorIn(input.cursor_color) else defaultCursorColor(colors),
        .cursor_text_color = cursorColorIn(input.cursor_text_color),
        .cursor_trail_color = cursorColorIn(input.cursor_trail_color),
        .default_foreground = rgb8(colors.foreground),
        .default_background = rgb8(colors.background),
        .primary_extent = .{ .row = row, .col = col, .rows = 1, .cols = if (wide_tail) 2 else 1 },
        .extra_cursors = [_]render.ExtraCursorPresentation{emptyExtraCursor()} ** render.max_extra_cursors,
        .extra_cursor_count = 0,
        .trail = cursorTrailSourceIn(input),
    };
}

fn cursorTrailSourceIn(input: *const c.HowlRenderTextPrepare) render.CursorTrailSource {
    var trail = render.CursorTrailSource{
        .rects = [_]render.CursorTrailRect{emptyCursorTrailRect()} ** render.max_cursor_trail_rects,
        .count = @intCast(@min(input.cursor_trail_count, render.max_cursor_trail_rects)),
    };
    for (0..trail.count) |i| trail.rects[i] = cursorTrailRectIn(input.cursor_trail_rects[i]);
    return trail;
}

fn cursorTrailRectIn(rect: c.HowlRenderCursorTrailRect) render.CursorTrailRect {
    return .{
        .extent = .{ .row = rect.row, .col = rect.col, .rows = rect.rows, .cols = rect.cols },
        .opacity = rect.opacity,
        .color = .{ .r = rect.color.r, .g = rect.color.g, .b = rect.color.b },
        .pixel_rect = rect.pixel_rect != 0,
        .x_px = rect.x_px,
        .y_px = rect.y_px,
        .width_px = rect.width_px,
        .height_px = rect.height_px,
    };
}

fn cursorColorIn(value: c.HowlVtColor) render.CursorColor {
    return .{ .kind = @enumFromInt(value.kind), .value = value.value };
}

fn cursorShapeIn(value: u8) render.CursorShape {
    return switch (value) {
        c.HOWL_VT_CURSOR_SHAPE_UNDERLINE => .underline,
        c.HOWL_VT_CURSOR_SHAPE_BEAM => .beam,
        c.HOWL_VT_CURSOR_SHAPE_NONE => .none,
        4 => .hollow,
        else => .block,
    };
}

fn renderStateU64(state: c.HowlVtRenderStateHandle, key: c.HowlVtRenderStateData) !u64 {
    var value: u64 = 0;
    try requireVtOk(c.howl_vt_render_state_get(state, key, &value));
    return value;
}

fn renderStateU16(state: c.HowlVtRenderStateHandle, key: c.HowlVtRenderStateData) !u16 {
    var value: u16 = 0;
    try requireVtOk(c.howl_vt_render_state_get(state, key, &value));
    return value;
}

fn renderStateByte(state: c.HowlVtRenderStateHandle, key: c.HowlVtRenderStateData) !u8 {
    var value: u8 = 0;
    try requireVtOk(c.howl_vt_render_state_get(state, key, &value));
    return value;
}

fn renderStateCursorShape(state: c.HowlVtRenderStateHandle) !render.CursorShape {
    var value: c_int = 0;
    try requireVtOk(c.howl_vt_render_state_get(state, c.HOWL_VT_RENDER_STATE_DATA_CURSOR_VISUAL_STYLE, &value));
    return switch (value) {
        0 => .beam,
        1 => .block,
        2 => .underline,
        3 => .hollow,
        else => .block,
    };
}

fn requireVtOk(status: c.HowlVtCallStatus) !void {
    if (status == c.HOWL_VT_CALL_OK) return;
    return error.InvalidRenderState;
}

fn colorFromRgb(value: c.HowlVtRgb8) render.Rgba8 {
    return .{ .r = value.r, .g = value.g, .b = value.b, .a = 255 };
}

fn rgb8(value: c.HowlVtRgb8) render.Rgb8 {
    return .{ .r = value.r, .g = value.g, .b = value.b };
}

fn rgbValue(value: c.HowlVtRgb8) u32 {
    return (@as(u32, value.r) << 16) | (@as(u32, value.g) << 8) | value.b;
}

fn defaultCursorColor(colors: RenderStateColors) render.CursorColor {
    return .{ .kind = if (colors.cursor_has_value) .rgb else .default, .value = if (colors.cursor_has_value) rgbValue(colors.cursor) else 0 };
}

fn emptyExtraCursor() render.ExtraCursorPresentation {
    return .{
        .extent = .{ .row = 0, .col = 0, .rows = 1, .cols = 1 },
        .shape = .none,
        .mode = .point,
        .shape_follows_main = false,
        .color_follows_main = false,
        .cursor_color = .{ .kind = .default, .value = 0 },
        .text_color = .{ .kind = .default, .value = 0 },
    };
}

fn emptyCursorTrailRect() render.CursorTrailRect {
    return .{ .extent = .{ .row = 0, .col = 0, .rows = 1, .cols = 1 }, .opacity = 0, .color = .{ .r = 0, .g = 0, .b = 0 } };
}

fn colorFromValue(value: c.HowlVtColor, colors: RenderStateColors, foreground: bool) render.Rgba8 {
    return switch (value.kind) {
        0 => if (foreground) colorFromRgb(colors.foreground) else colorFromRgb(colors.background),
        1 => colorFromRgb(colors.palette[@intCast(value.value & 0xff)]),
        2 => .{ .r = @intCast((value.value >> 16) & 0xff), .g = @intCast((value.value >> 8) & 0xff), .b = @intCast(value.value & 0xff), .a = 255 },
        else => if (foreground) colorFromRgb(colors.foreground) else colorFromRgb(colors.background),
    };
}

fn semanticColor(value: c.HowlVtColor) render.SemanticColor {
    return switch (value.kind) {
        0 => .{ .kind = .default },
        1 => .{ .kind = .indexed, .value = value.value & 0xff },
        2 => .{ .kind = .rgb, .value = value.value & 0xffffff },
        else => .{ .kind = .default },
    };
}

fn underlineStyle(value: u8) render.UnderlineStyle {
    return switch (value) {
        1 => .double,
        2 => .curly,
        3 => .dotted,
        4 => .dashed,
        else => .straight,
    };
}

fn fontStyle(cell: c.HowlVtRenderStateCell) render.FontStyle {
    if (cell.attrs.bold != 0 and cell.attrs.italic != 0) return .bold_italic;
    if (cell.attrs.bold != 0) return .bold;
    if (cell.attrs.italic != 0) return .italic;
    return .regular;
}

fn presentation(cell: c.HowlVtRenderStateCell) render.TextPresentation {
    for (cell.combining[0..cell.combining_len]) |cp| {
        if (cp == 0xfe0f) return .emoji;
        if (cp == 0xfe0e) return .text;
    }
    return .any;
}

fn mapCell(cell: c.HowlVtRenderStateCell, colors: RenderStateColors, selected: bool, highlighted: bool) render.CellInput {
    std.debug.assert(cell.combining_len <= cell.combining.len);
    const default_fg = cell.fg_color.kind == 0;
    const default_bg = cell.bg_color.kind == 0;
    const blank = cell.codepoint == ' ' or cell.codepoint == '\t';
    const visible_flags = cell.flags.continuation != 0 or
        cell.attrs.inverse != 0 or
        cell.attrs.underline != 0 or
        cell.attrs.strikethrough != 0 or
        cell.attrs.invisible != 0 or
        selected or
        highlighted;
    var out = render.CellInput{
        .codepoint = @intCast(cell.codepoint),
        .combining_len = cell.combining_len,
        .combining = cell.combining,
        .style = fontStyle(cell),
        .presentation = presentation(cell),
        .dim = cell.attrs.dim != 0,
        .invisible = cell.attrs.invisible != 0,
        .semantic_fg = semanticColor(cell.fg_color),
        .semantic_bg = semanticColor(cell.bg_color),
        .fg = colorFromValue(cell.fg_color, colors, true),
        .bg = colorFromValue(cell.bg_color, colors, false),
        .underline_color_set = cell.attrs.underline_color_set != 0,
        .semantic_underline_color = semanticColor(cell.underline_color),
        .underline_color = if (cell.attrs.underline_color_set != 0) colorFromValue(cell.underline_color, colors, true) else .{ .r = 0, .g = 0, .b = 0, .a = 0 },
        .underline_style = underlineStyle(cell.underline_style),
        .underline = cell.attrs.underline != 0 or highlighted,
        .strikethrough = cell.attrs.strikethrough != 0,
        .continuation = cell.flags.continuation != 0,
        .empty = blank and cell.combining_len == 0 and default_fg and default_bg and !visible_flags,
    };
    if (cell.attrs.inverse != 0) {
        const fg = out.fg;
        out.fg = out.bg;
        out.bg = fg;
        out.empty = false;
    }
    if (selected) {
        out.fg = colorFromRgb(colors.background);
        out.bg = colorFromRgb(colors.foreground);
        out.empty = false;
    }
    return out;
}

fn emptyCell(colors: RenderStateColors) render.CellInput {
    return .{ .codepoint = ' ', .fg = colorFromRgb(colors.foreground), .bg = colorFromRgb(colors.background), .empty = true };
}

fn providerHasCellTextThunk(ctx: *anyopaque, face_id: render.FontFaceId, text_value: render.CellText) bool {
    const surface: *TextSurface = @ptrCast(@alignCast(ctx));
    return glyph_cache.providerHasCellTextWithConfig(&surface.glyph_cache, surface.textConfig(), face_id, text_value);
}

fn providerShapeRunThunk(
    ctx: *anyopaque,
    allocator: std.mem.Allocator,
    run: render.ResolvedRun,
    text_cache_view: render.LineTextCache,
    clusters: []const render.CellCluster,
    glyph_cell_layout: render.CellLayout,
) anyerror!shape_run.OwnedShapedRun {
    const surface: *TextSurface = @ptrCast(@alignCast(ctx));
    return glyph_cache.providerShapeRunWithConfig(&surface.glyph_cache, surface.textConfig(), allocator, run, text_cache_view, clusters, glyph_cell_layout);
}

fn providerRasterizeSpriteThunk(ctx: *anyopaque, allocator: std.mem.Allocator, req: render.SpriteRasterRequest) anyerror!rasterizer.RasterSpriteOutput {
    const surface: *TextSurface = @ptrCast(@alignCast(ctx));
    return glyph_raster.providerRasterizeSpriteWithConfig(&surface.glyph_cache, surface.textConfig(), allocator, req);
}

fn providerLookupGlyphThunk(ctx: *anyopaque, face_id: render.FontFaceId, codepoint: u32, glyph_cell_layout: render.CellLayout) @import("provider.zig").LookupGlyphResult {
    const surface: *TextSurface = @ptrCast(@alignCast(ctx));
    return glyph_cache.providerLookupGlyphWithConfig(&surface.glyph_cache, surface.textConfig(), face_id, codepoint, glyph_cell_layout);
}

fn providerRasterizeGlyphThunk(ctx: *anyopaque, allocator: std.mem.Allocator, req: raster_operation.RasterizeRequest) anyerror!raster_operation.RasterizeOutput {
    const surface: *TextSurface = @ptrCast(@alignCast(ctx));
    const width = @as(u16, @intCast(@as(u32, @max(req.cell_span, 1)) * @as(u32, @max(req.cell_layout.cell_w_px, 1))));
    const height = @max(req.cell_layout.cell_h_px, 1);
    const alpha_len: u32 = @as(u32, width) * @as(u32, height);
    const alpha = try allocator.alloc(u8, @intCast(alpha_len));
    errdefer allocator.free(alpha);
    @memset(alpha, 0);
    _ = glyph_raster.rasterizeProviderGlyphWithConfig(
        &surface.glyph_cache,
        surface.textConfig(),
        alpha,
        width,
        height,
        req.cell_layout.baseline_px,
        .{ .value = req.face_id },
        req.glyph_id,
        0,
        0,
        0,
    );
    return .{
        .allocator = allocator,
        .width_px = width,
        .height_px = height,
        .bearing_x_px = 0,
        .bearing_y_px = 0,
        .advance_px = glyph_cache.providerGlyphAdvanceWithConfig(&surface.glyph_cache, surface.textConfig(), .{ .value = req.face_id }, req.glyph_id, req.cell_layout),
        .alpha_mask = alpha,
    };
}
