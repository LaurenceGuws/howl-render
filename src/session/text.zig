const std = @import("std");
const geometry_mod = @import("../render/grid_geometry.zig");
const input = @import("../source/text_input.zig");
const tokens = @import("../render/tokens.zig");
const prepared_owner = @import("../prepared/owner.zig");
const prepared_submit = @import("../prepared/submit.zig");
const render_geometry = @import("../render/geometry.zig");
const geometry_contract = @import("../render/geometry_contract.zig");
const source_cell = @import("../source/cell.zig");
const source_vt = @import("../source/vt.zig");
const source_slot = @import("../source/slot.zig");
const source_prepare = @import("../source/prepare_request.zig");
const prepared_surface = @import("../prepared/surface.zig");
const prepared_submit_result = @import("../prepared/submit_result.zig");
const session_submitted = @import("submitted.zig");
const contract = @import("../text/contract.zig");
const font_resolve = @import("../text/font/resolve.zig");
const text = @import("../text/text.zig");
const text_support = @import("../text/font/ft_hb/support.zig");
const text_glyph_raster = @import("../text/font/ft_hb/glyph_raster.zig");
const text_raster_operation = @import("../text/raster/operation.zig");

const max_font_faces = text_support.fallbackFontLen(text_support.max_fallback_fonts) + 1;
const ft_hb_face_text_cache_entry_cap: u32 = 4096;
const ft_hb_glyph_cell_cache_entry_cap: u32 = 4096;
const ft_hb_shape_run_cache_entry_cap: u32 = 64;
const ft_hb_shape_input_codepoints_per_cluster_cap: u32 = 16;
const ft_hb_cached_glyphs_per_run_cap: u32 = 512;
const PreparedSurfaceHandle = ?*anyopaque;

pub const SessionWorkState = struct {
    source_pending: bool,
    prepare_pending: bool,
    submit_pending: bool,
};

fn count32(items: anytype) u32 {
    std.debug.assert(items.len <= std.math.maxInt(u32));
    return @intCast(items.len);
}

comptime {
    std.debug.assert(max_font_faces <= std.math.maxInt(u8));
}

const ThreadMutex = struct {
    state: std.Io.Mutex = .init,

    fn unlock(self: *ThreadMutex) void {
        std.Io.Threaded.mutexUnlock(&self.state);
    }
};

fn lockMutex(mutex: *ThreadMutex) void {
    std.Io.Threaded.mutexLock(&mutex.state);
}

pub const TextSessionConfig = struct {
    surface_px: geometry_contract.PixelSize,
    font_size_px: u16 = 16,
    font_path: ?[:0]const u8 = null,
};

pub const TextSession = struct {
    allocator: std.mem.Allocator,
    text_state: text_support.State,
    mutex: ThreadMutex = .{},
    text_preparer: ?text.TextFramePreparer = null,
    cell_input_scratch: []contract.CellInput = &.{},

    const TextContext = struct {
        session: *TextSession,
        session_config: TextSessionConfig,
    };

    pub const FrameLayout = geometry_contract.SurfaceLayout;
    pub const PreparedTimings = prepared_surface.PrepareMetrics;
    pub const DamageKind = enum { partial, scroll, full };
    pub const SubmitExecution = struct {
        host_surface: prepared_submit_result.HostSurface,
        uploads_committed: u64,
        render_us: u64,
    };
    pub const PrepareInput = struct {
        config: TextSessionConfig,
        request: tokens.RenderRequest,
        layout: geometry_contract.PrepareLayout,
        state: source_vt.PublicationSource,
    };

    pub fn init(allocator: std.mem.Allocator) TextSession {
        return .{
            .allocator = allocator,
            .text_state = text_support.State.init(allocator),
        };
    }

    pub fn deinit(self: *TextSession) void {
        lockMutex(&self.mutex);
        defer self.mutex.unlock();
        if (self.text_preparer) |*preparer| {
            preparer.deinit();
            self.text_preparer = null;
        }
        if (self.cell_input_scratch.len > 0) self.allocator.free(self.cell_input_scratch);
        self.cell_input_scratch = &.{};
        self.text_state.deinit();
    }

    pub fn deriveLayout(
        self: *TextSession,
        config: TextSessionConfig,
        render_px: geometry_contract.PixelSize,
        grid_px: geometry_contract.PixelSize,
    ) geometry_mod.FrameGeometryError!FrameLayout {
        lockMutex(&self.mutex);
        defer self.mutex.unlock();
        if (render_px.width == 0 or render_px.height == 0) return error.InvalidSurfaceSize;
        if (grid_px.width == 0 or grid_px.height == 0) return error.InvalidGridSize;
        var context = TextContext{ .session = self, .session_config = config };
        const cell_px = text_support.deriveCellSize(&context);
        const layout = geometry_contract.SurfaceLayout{ .cell_px = cell_px, .grid = geometry_mod.deriveGridSize(grid_px, cell_px) };
        return .{ .cell_px = layout.cell_px, .grid = layout.grid };
    }

    pub fn isValidFont(self: *TextSession, config: TextSessionConfig) bool {
        lockMutex(&self.mutex);
        defer self.mutex.unlock();
        var context = TextContext{ .session = self, .session_config = config };
        if (text_support.ensurePrimaryFont(&context)) return true;
        var i: text_support.FallbackFontCount = 0;
        while (i < self.text_state.fallback_font_paths_len) : (i += 1) {
            if (text_support.ensureFallbackFace(&context, i) != null) return true;
        }
        return false;
    }

    pub fn prepareSurface(self: *TextSession, prepare: PrepareInput) !prepared_surface.PreparedSurface {
        var faces: [max_font_faces]text.FontSession.FontFaceRecord = undefined;
        var context = TextContext{ .session = self, .session_config = prepare.config };
        lockMutex(&self.mutex);
        errdefer self.mutex.unlock();
        try self.ensureCellInputScratchCapacity(prepare.state.cells.len);
        const text_input = input.publicationSourceToTextSceneInputBorrowed(self.cell_input_scratch, prepare.state, prepare.request.token.damage_kind == .full);
        var resolve: font_resolve.ResolveObservability = .{};
        const preparer = try self.ensureTextPreparer(&context);
        var prepared = try preparer.prepareCellsWithSessionOptions(text_input.cells, text_input.grid, fontSession(&context, &faces, &resolve), text_input.options);
        errdefer prepared.deinit();
        const owned = ownPreparedSurface(self.allocator, prepare, text_input.grid, prepared, resolve);
        self.mutex.unlock();
        return owned;
    }

    pub fn submitSurface(
        self: *TextSession,
        prepared: *prepared_surface.PreparedSurface,
        execution: SubmitExecution,
    ) !prepared_submit_result.SubmitResult {
        lockMutex(&self.mutex);
        errdefer self.mutex.unlock();
        prepared_submit.markRendered(&self.text_preparer.?.atlas, prepared.text_frame.raster_plan.outputs);
        const submitted = prepared_submit_result.SubmitResult{
            .damage_kind = prepared_submit.damageKind(prepared),
            .uploads_committed = execution.uploads_committed,
            .resolve = prepared.resolve,
            .host_surface = execution.host_surface,
            .metrics = undefined,
            .render_us = execution.render_us,
        };
        var final = submitted;
        final.metrics = prepared_submit.metrics(
            prepared_submit_result.Metrics,
            prepared.prepare_metrics,
            prepared,
            final.uploads_committed,
            final.resolve.counters,
            final.render_us,
        );
        self.mutex.unlock();
        return final;
    }

    pub fn atlasRaster(self: *TextSession, key: contract.SpriteKey) ?text.AtlasCache.StoredRaster {
        lockMutex(&self.mutex);
        defer self.mutex.unlock();
        const preparer = self.text_preparer orelse return null;
        return preparer.atlas.rasterForKey(key);
    }

    fn ownPreparedSurface(
        allocator: std.mem.Allocator,
        prepare: PrepareInput,
        grid: contract.GridMetrics,
        prepared: text.OwnedPreparedTextFrame,
        resolve: font_resolve.ResolveObservability,
    ) prepared_surface.PreparedSurface {
        return .{
            .allocator = allocator,
            .request = prepare.request,
            .geometry_epoch = prepare.request.token.geometry_epoch,
            .render_px = prepare.layout.render_px,
            .cell_px = prepare.layout.cell_px,
            .grid = .{ .cols = grid.cols, .rows = grid.rows },
            .text_frame = prepared,
            .resolve = resolve,
            .prepare_metrics = prepareMetrics(prepared.timings),
        };
    }

    fn ensureTextPreparer(self: *TextSession, context: *TextContext) !*text.TextFramePreparer {
        const capacity = ftHbCapacity(context);
        if (self.text_preparer == null) {
            var ft_hb = ftHbSource(context);
            self.text_preparer = try text.TextFramePreparer.initWithProvider(self.allocator, 2048, ft_hb.textProvider());
        }
        try self.text_state.configureFtHbCapacity(capacity);
        try self.text_preparer.?.ensureClusterScratchCapacity(maxResolveClusters(context), capacity.max_shape_input_codepoints);
        try self.text_preparer.?.ensureResolverScratchCapacity(maxResolveClusters(context));
        return &self.text_preparer.?;
    }

    fn maxResolveClusters(context: *TextContext) u32 {
        const cell_px = text_support.deriveCellSize(context);
        const grid = geometry_mod.deriveGridSize(context.session_config.surface_px, cell_px);
        return @as(u32, @max(grid.cols, 1)) * @as(u32, @max(grid.rows, 1));
    }

    fn ftHbCapacity(context: *TextContext) text_support.FtHbCapacity {
        const cell_px = text_support.deriveCellSize(context);
        const grid = geometry_mod.deriveGridSize(context.session_config.surface_px, cell_px);
        const cols = @as(u32, @max(grid.cols, 1));
        const visible_cells = cols * @as(u32, @max(grid.rows, 1));
        return .{
            .face_text_cache_entries = @min(visible_cells, ft_hb_face_text_cache_entry_cap),
            .shape_run_cache_entries = @min(visible_cells, ft_hb_shape_run_cache_entry_cap),
            .glyph_cell_cache_entries = @min(visible_cells, ft_hb_glyph_cell_cache_entry_cap),
            .max_shape_input_codepoints = cols * ft_hb_shape_input_codepoints_per_cluster_cap,
            .max_glyphs_per_run = ft_hb_cached_glyphs_per_run_cap,
        };
    }

    fn ensureCellInputScratchCapacity(self: *TextSession, cell_count: usize) !void {
        if (self.cell_input_scratch.len >= cell_count) return;
        const scratch = try self.allocator.alloc(contract.CellInput, cell_count);
        if (self.cell_input_scratch.len > 0) self.allocator.free(self.cell_input_scratch);
        self.cell_input_scratch = scratch;
    }

    fn ftHbSource(context: *TextContext) text.FtHbProvider.FtHbSource {
        return .{
            .ctx = context,
            .has_codepoint = providerHasCodepointThunk,
            .shaper = .{ .ctx = context, .shape_run = providerShapeRunThunk },
            .rasterizer = .{ .ctx = context, .rasterize_sprite = providerRasterizeSpriteThunk },
            .glyph_lookup = .{ .ctx = context, .lookup_glyph = providerLookupGlyphThunk },
            .glyph_raster = .{ .ctx = context, .call = providerRasterizeGlyphThunk },
        };
    }

    fn fontSession(context: *TextContext, faces: []text.FontSession.FontFaceRecord, active_resolve: ?*font_resolve.ResolveObservability) text.FontSession.FontSession {
        context.session.text_state.active_resolve = active_resolve;
        var len: text_support.FallbackFontCount = 0;
        if (count32(faces) > text_support.fallbackFontLen(len)) {
            faces[@intCast(text_support.fallbackFontLen(len))] = .{ .id = .{ .value = text_support.primary_face_id }, .role = .primary, .coverage = .all };
            len += 1;
        }
        var i: text_support.FallbackFontCount = 0;
        while (i < context.session.text_state.fallback_font_paths_len and text_support.fallbackFontLen(len) < count32(faces)) : (i += 1) {
            if (context.session.text_state.fallback_font_paths[i] == null) continue;
            faces[@intCast(text_support.fallbackFontLen(len))] = .{ .id = .{ .value = i + 2 }, .role = .fallback, .coverage = .all };
            len += 1;
        }
        return .{
            .primary_face = .{ .value = text_support.primary_face_id },
            .faces = faces[0..@intCast(text_support.fallbackFontLen(len))],
            .provider = .{ .ctx = context, .has_cell_text = providerHasCellTextThunk },
            .metrics = text_support.deriveCellMetrics(context),
        };
    }

    fn providerHasCodepointThunk(ctx: *anyopaque, face_id: contract.FontFaceId, codepoint: u32) bool {
        return text_support.providerHasCodepoint(TextContext, ctx, face_id, codepoint);
    }

    fn providerHasCellTextThunk(ctx: *anyopaque, face_id: contract.FontFaceId, text_value: contract.CellText) bool {
        return text_support.providerHasCellText(TextContext, ctx, face_id, text_value);
    }

    fn providerShapeRunThunk(ctx: *anyopaque, allocator: std.mem.Allocator, run: contract.ResolvedRun, text_cache_view: contract.LineTextCache, clusters: []const contract.CellCluster, cell_metrics: contract.CellMetrics) anyerror!text.ShapeRun.OwnedShapedRun {
        return text_support.providerShapeRun(TextContext, ctx, allocator, run, text_cache_view, clusters, cell_metrics);
    }

    fn providerRasterizeSpriteThunk(ctx: *anyopaque, allocator: std.mem.Allocator, req: contract.SpriteRasterRequest) anyerror!text.Rasterizer.RasterSpriteOutput {
        return text_glyph_raster.providerRasterizeSprite(TextContext, ctx, allocator, req);
    }

    fn providerLookupGlyphThunk(ctx: *anyopaque, face_id: contract.FontFaceId, codepoint: u32, cell_metrics: contract.CellMetrics) text.Provider.LookupGlyphResult {
        return text_support.providerLookupGlyph(TextContext, ctx, face_id, codepoint, cell_metrics);
    }

    fn providerRasterizeGlyphThunk(ctx: *anyopaque, allocator: std.mem.Allocator, req: text_raster_operation.RasterizeRequest) anyerror!text_raster_operation.RasterizeOutput {
        const context: *TextContext = @ptrCast(@alignCast(ctx));
        const width = @as(u16, @intCast(@as(u32, @max(req.cell_span, 1)) * @as(u32, @max(req.cell_metrics.cell_w_px, 1))));
        const height = @max(req.cell_metrics.cell_h_px, 1);
        const alpha_len: u32 = @as(u32, width) * @as(u32, height);
        const alpha = try allocator.alloc(u8, @intCast(alpha_len));
        errdefer allocator.free(alpha);
        @memset(alpha, 0);
        _ = text_glyph_raster.rasterizeProviderGlyph(context, alpha, width, height, req.cell_metrics.baseline_px, .{ .value = req.face_id }, req.glyph_id, 0, 0, 0);
        return .{
            .allocator = allocator,
            .width_px = width,
            .height_px = height,
            .bearing_x_px = 0,
            .bearing_y_px = 0,
            .advance_px = text_support.providerGlyphAdvance(context, .{ .value = req.face_id }, req.glyph_id, req.cell_metrics),
            .alpha_mask = alpha,
        };
    }

    fn prepareMetrics(timings: text.PrepareTimings) prepared_surface.PrepareMetrics {
        const total = timings.input_us + timings.sparse_us + timings.clusters_us + timings.resolve_us + timings.shape_us + timings.group_us + timings.scene_us + timings.raster_us + timings.atlas_us;
        return .{
            .sync_us = timings.input_us,
            .copy_us = timings.sparse_us + timings.clusters_us,
            .us = total,
            .surface_us = total,
            .input_us = timings.input_us,
            .sparse_us = timings.sparse_us,
            .clusters_us = timings.clusters_us,
            .resolve_us = timings.resolve_us,
            .shape_us = timings.shape_us,
            .group_us = timings.group_us,
            .scene_us = timings.scene_us,
            .raster_us = timings.raster_us,
            .atlas_us = timings.atlas_us,
        };
    }
};

pub const TextSessionOwner = struct {
    allocator: std.mem.Allocator,
    session: TextSession,
    geometry: render_geometry.GeometryOwner,
    source_slot: source_slot.SourceSlot,
    prepare_requests: source_prepare.PrepareRequests,
    submitted: session_submitted.Submitted,
    source_dirty_epoch: u64 = 0,
    cursor_blink_visible: bool = true,
    config: TextSessionConfig,
    prepared_publish_handle: PreparedSurfaceHandle = null,
    prepared_submit_handle: PreparedSurfaceHandle = null,
    prepared_handles: std.ArrayList(*prepared_owner.Owner) = .empty,
    font_path: ?[:0]u8 = null,
    fallback_font_paths: std.ArrayList([:0]u8) = .empty,
    retained_surface_pixels: []u8 = &.{},
    retained_surface_width: u16 = 0,
    retained_surface_height: u16 = 0,
    retained_surface_snapshot_seq: u64 = 0,

    pub const FontConfigError = error{ InvalidArgument, OutOfMemory };

    pub fn create(allocator: std.mem.Allocator, config: TextSessionConfig) ?*TextSessionOwner {
        std.debug.assert(config.font_size_px > 0);
        const owner = allocator.create(TextSessionOwner) catch return null;
        owner.* = .{
            .allocator = allocator,
            .session = TextSession.init(allocator),
            .geometry = .{},
            .source_slot = source_slot.SourceSlot.init(allocator),
            .prepare_requests = source_prepare.PrepareRequests.init(allocator),
            .submitted = .{},
            .config = config,
        };
        return owner;
    }

    pub fn destroy(self: *TextSessionOwner) void {
        self.prepared_publish_handle = null;
        self.prepared_submit_handle = null;
        for (self.prepared_handles.items) |prepared| prepared.destroy();
        self.prepared_handles.deinit(self.allocator);
        self.prepared_handles = .empty;
        if (self.font_path) |path| self.allocator.free(path);
        self.font_path = null;
        freeOwnedFallbackFontPaths(self.allocator, &self.fallback_font_paths);
        self.prepare_requests.deinit();
        self.source_slot.deinit();
        self.clearRetainedSurface();
        self.session.deinit();
        self.allocator.destroy(self);
    }

    pub fn setFontSizePx(self: *TextSessionOwner, font_size_px: u16) void {
        std.debug.assert(font_size_px > 0);
        self.config.font_size_px = font_size_px;
        self.invalidateTextState();
    }

    pub fn setFontPathBytes(self: *TextSessionOwner, bytes: ?[]const u8) FontConfigError!void {
        const value = bytes orelse {
            self.setOwnedFontPath(null);
            return;
        };
        if (value.len == 0) {
            self.setOwnedFontPath(null);
            return;
        }
        const owned = self.allocator.dupeZ(u8, value) catch return error.OutOfMemory;
        self.setOwnedFontPath(owned);
    }

    pub fn setFallbackFontPathPtrs(self: *TextSessionOwner, raw_paths: []const ?[*]const u8) FontConfigError!void {
        const path_count = text_support.fallbackFontCount(count32(raw_paths)) orelse return error.InvalidArgument;
        var staged = std.ArrayList([:0]u8).empty;
        defer freeOwnedFallbackFontPaths(self.allocator, &staged);
        if (path_count == 0) {
            self.adoptFallbackFontPaths(&staged);
            return;
        }
        staged.ensureTotalCapacity(self.allocator, @intCast(text_support.fallbackFontLen(path_count))) catch return error.OutOfMemory;
        var i: text_support.FallbackFontCount = 0;
        while (i < path_count) : (i += 1) {
            const raw = raw_paths[i] orelse return error.InvalidArgument;
            const owned = self.allocator.dupeZ(u8, std.mem.sliceTo(raw, 0)) catch {
                return error.OutOfMemory;
            };
            staged.appendAssumeCapacity(owned);
        }
        self.adoptFallbackFontPaths(&staged);
    }

    pub fn isValidFont(self: *TextSessionOwner) bool {
        return self.session.isValidFont(self.config);
    }

    pub fn prepareHandle(self: *TextSessionOwner, token: tokens.SnapshotToken) !*prepared_owner.Owner {
        const consume = try self.prepare_requests.consumePrepare(
            self.geometry.prepareLayout(token.geometry_epoch),
            token,
        );
        errdefer _ = self.prepare_requests.retryTakenPrepare(token);
        var prepared = try self.session.prepareSurface(.{
            .config = self.config,
            .request = consume.request,
            .layout = consume.layout,
            .state = consume.state,
        });
        errdefer prepared.deinit();
        return prepared_owner.Owner.create(self, &prepared);
    }

    pub fn registerPreparedHandle(self: *TextSessionOwner, prepared: *prepared_owner.Owner) !void {
        try self.prepared_handles.append(self.allocator, prepared);
    }

    pub fn clearCachedPreparedHandle(self: *TextSessionOwner, prepared: *prepared_owner.Owner) void {
        const handle: PreparedSurfaceHandle = @ptrCast(prepared);
        if (self.prepared_publish_handle == handle) self.prepared_publish_handle = null;
        if (self.prepared_submit_handle == handle) self.prepared_submit_handle = null;
    }

    pub fn invalidateTextState(self: *TextSessionOwner) void {
        text_support.resetLoadedFace(&self.session);
        self.session.text_state.face_text_cache.clear();
        self.session.text_state.shape_run_cache.clear();
        self.session.text_state.glyph_cell_cache.clear();
        if (self.session.text_preparer) |*preparer| preparer.clearAtlas();
        self.clearRetainedSurface();
    }

    pub fn setOwnedFontPath(self: *TextSessionOwner, owned: ?[:0]u8) void {
        if (owned) |path| std.debug.assert(path.len > 0);
        const old = self.font_path;
        self.font_path = owned;
        self.config.font_path = owned;
        self.invalidateTextState();
        if (old) |path| self.allocator.free(path);
    }

    pub fn adoptFallbackFontPaths(self: *TextSessionOwner, owned_paths: *std.ArrayList([:0]u8)) void {
        var old = self.fallback_font_paths;
        self.fallback_font_paths = owned_paths.*;
        owned_paths.* = .empty;
        self.syncFallbackFontPaths();
        self.invalidateTextState();
        freeOwnedFallbackFontPaths(self.allocator, &old);
    }

    pub fn requiredRetainedSurfaceBase(
        self: *const TextSessionOwner,
        prepared: *const prepared_surface.PreparedSurface,
    ) []const u8 {
        std.debug.assert(prepared.damageKind() == .partial);
        // Queue validation already proved that partial prepares must compose
        // against the last submitted full pixels from this render owner.
        std.debug.assert(self.retained_surface_snapshot_seq == prepared.preparedSurfaceToken().required_base_seq);
        std.debug.assert(self.retained_surface_width == prepared.render_px.width);
        std.debug.assert(self.retained_surface_height == prepared.render_px.height);
        const pixels_len: u64 = @as(u64, prepared.render_px.width) * @as(u64, prepared.render_px.height) * 4;
        const retained_len: u64 = @intCast(self.retained_surface_pixels.len);
        std.debug.assert(retained_len == pixels_len);
        return self.retained_surface_pixels;
    }

    pub fn retainSurfacePixels(self: *TextSessionOwner, pixels: *[]u8, width: u16, height: u16, snapshot_seq: u64) void {
        std.debug.assert(width > 0);
        std.debug.assert(height > 0);
        const pixels_len: u64 = @as(u64, width) * @as(u64, height) * 4;
        const incoming_len: u64 = @intCast(pixels.*.len);
        std.debug.assert(pixels_len > 0);
        std.debug.assert(incoming_len == pixels_len);
        self.clearRetainedSurface();
        self.retained_surface_pixels = pixels.*;
        self.retained_surface_width = width;
        self.retained_surface_height = height;
        self.retained_surface_snapshot_seq = snapshot_seq;
        pixels.* = &.{};
    }

    pub fn clearRetainedSurface(self: *TextSessionOwner) void {
        if (self.retained_surface_pixels.len > 0) self.allocator.free(self.retained_surface_pixels);
        self.retained_surface_pixels = &.{};
        self.retained_surface_width = 0;
        self.retained_surface_height = 0;
        self.retained_surface_snapshot_seq = 0;
    }

    pub fn nextSourceDirtyEpoch(self: *TextSessionOwner) u64 {
        self.source_dirty_epoch +%= 1;
        if (self.source_dirty_epoch == 0) self.source_dirty_epoch = 1;
        return self.source_dirty_epoch;
    }

    pub fn submittedToken(self: *TextSessionOwner) ?tokens.SnapshotToken {
        return self.submitted.submittedToken();
    }

    pub fn syncGeometry(
        self: *TextSessionOwner,
        layout: geometry_contract.Geometry,
    ) !geometry_contract.GeometryResponse {
        const response = self.geometry.sync(layout);
        if (response.changed) {
            const cols = @max(1, @divTrunc(layout.grid_px.width, @max(layout.cell_px.width, 1)));
            const rows = @max(1, @divTrunc(layout.grid_px.height, @max(layout.cell_px.height, 1)));
            try self.source_slot.syncReservedSlotCapacity(cols, rows);
            self.prepare_requests.refreshRetainedSlotViews(&self.source_slot);
        }
        return response;
    }

    pub fn setCursorBlinkVisible(self: *TextSessionOwner, visible: bool) bool {
        if (self.cursor_blink_visible == visible) return false;
        self.cursor_blink_visible = visible;
        var changed = false;
        if (self.source_slot.reservedSource()) |source| {
            changed = @import("../source/damage.zig").setSourceCursorBlinkVisible(source, visible) or changed;
        }
        changed = self.prepare_requests.setCursorBlinkVisible(visible) or changed;
        if (changed) self.prepare_requests.requestBlinkRefresh();
        return true;
    }

    pub fn reserveVtSurfaceSlot(self: *TextSessionOwner, cols: u16, rows: u16) !source_slot.VtSurfaceSlot {
        if (self.prepare_requests.retainedSlotInUse()) return error.VtSurfaceSlotBusy;
        return try self.source_slot.reserveSourceSlot(cols, rows);
    }

    pub fn commitVtSurface(self: *TextSessionOwner, meta: source_vt.ReservedSourceMeta) !source_vt.VtSurfacePublishResult {
        var source = try self.source_slot.commitReservedSource(meta, self.nextSourceDirtyEpoch());
        source.cursor_phase_visible = self.cursor_blink_visible;
        return self.prepare_requests.acceptSource(source, self.submittedToken(), self.geometry.geometry_epoch);
    }

    pub fn cancelVtSurface(self: *TextSessionOwner) void {
        self.source_slot.cancelReservedSource();
    }

    pub fn rejectVtSurface(self: *TextSessionOwner, snapshot_seq: u64) source_vt.VtSurfacePublishResult {
        std.debug.assert(snapshot_seq != 0);
        self.source_slot.cancelReservedSource();
        return .{
            .published = false,
            .queued = false,
            .damage_kind = .none,
            .snapshot_seq = snapshot_seq,
            .geometry_epoch = self.geometry.geometry_epoch,
        };
    }

    pub fn prepare(self: *TextSessionOwner) ?tokens.RenderRequest {
        const submitted_token = self.submittedToken();
        const request = self.prepare_requests.takePrepareRequest(
            self.geometry.geometry_epoch,
            submitted_token,
        ) orelse return null;
        const effective_token = session_submitted.Submitted.prepareTokenForRetainedState(
            request.token,
            submitted_token,
        );
        if (!@import("../source/damage.zig").sameSnapshotToken(effective_token, request.token)) {
            self.prepare_requests.active.?.request = .{
                .token = effective_token,
                .allow_retained_reuse = request.allow_retained_reuse,
            };
        }
        return self.prepare_requests.active.?.request;
    }

    pub fn publishPrepared(self: *TextSessionOwner, prepared: tokens.PreparedSurfaceToken) void {
        self.submitted.publishPrepared(prepared);
    }

    pub fn submit(self: *TextSessionOwner) session_submitted.SubmitDecision {
        const decision = self.submitted.takeValidatedSubmitWithLatest(self.prepare_requests.latestToken());
        switch (decision) {
            .stale => |token| self.prepare_requests.retireAtOrBefore(token),
            .needs_full_prepare => _ = self.prepare_requests.requestFullPrepare(
                session_submitted.Submitted.forceFull,
            ),
            else => {},
        }
        return decision;
    }

    pub fn acceptSubmitted(self: *TextSessionOwner, submitted: tokens.SubmittedSurfaceToken) void {
        if (submitted.token.geometry_epoch != self.geometry.geometry_epoch) {
            _ = self.prepare_requests.requestFullPrepare(session_submitted.Submitted.forceFull);
            return;
        }
        self.prepare_requests.retirePendingAtOrBefore(submitted.token);
        self.submitted.acceptSubmitted(submitted);
    }

    pub fn workState(self: *const TextSessionOwner) SessionWorkState {
        const submitted_work = self.submitted.workState();
        return .{
            .source_pending = self.source_slot.sourcePending() or self.prepare_requests.sourcePending(),
            .prepare_pending = self.prepare_requests.preparePending(),
            .submit_pending = submitted_work.submit_pending,
        };
    }

    fn syncFallbackFontPaths(self: *TextSessionOwner) void {
        const count = text_support.fallbackFontCount(count32(self.fallback_font_paths.items)) orelse unreachable;
        self.session.text_state.fallback_font_paths_len = count;
        var slot: text_support.FallbackFontCount = 0;
        while (slot < count) : (slot += 1) {
            self.session.text_state.fallback_font_paths[slot] = self.fallback_font_paths.items[slot];
        }
        while (slot < text_support.max_fallback_fonts) : (slot += 1) {
            self.session.text_state.fallback_font_paths[slot] = null;
        }
    }

    fn freeOwnedFallbackFontPaths(allocator: std.mem.Allocator, paths: *std.ArrayList([:0]u8)) void {
        for (paths.items) |path| allocator.free(path);
        paths.deinit(allocator);
        paths.* = .empty;
    }
};

test "retainSurfacePixels adopts full pixels for later partial prepares" {
    var owner = TextSessionOwner{
        .allocator = std.heap.c_allocator,
        .session = TextSession.init(std.heap.c_allocator),
        .geometry = .{},
        .source_slot = source_slot.SourceSlot.init(std.heap.c_allocator),
        .prepare_requests = source_prepare.PrepareRequests.init(std.heap.c_allocator),
        .submitted = .{},
        .config = .{ .surface_px = .{ .width = 2, .height = 3 } },
    };
    defer owner.clearRetainedSurface();
    defer owner.prepare_requests.deinit();
    defer owner.source_slot.deinit();
    defer owner.session.deinit();

    const pixels = try std.heap.c_allocator.alloc(u8, 2 * 3 * 4);
    for (pixels, 0..) |*pixel, i| pixel.* = @intCast(i);
    var owned_pixels = pixels;
    owner.retainSurfacePixels(&owned_pixels, 2, 3, 1);

    try std.testing.expect(owned_pixels.len == 0);
    try std.testing.expectEqual(@as(u16, 2), owner.retained_surface_width);
    try std.testing.expectEqual(@as(u16, 3), owner.retained_surface_height);
    try std.testing.expectEqual(@as(u64, 1), owner.retained_surface_snapshot_seq);

    const prepared = prepared_surface.PreparedSurface{
        .allocator = std.heap.c_allocator,
        .request = .{
            .token = .{ .snapshot_seq = 2, .dirty_epoch = 2, .geometry_epoch = 1, .damage_base_seq = 1, .damage_kind = .partial },
        },
        .geometry_epoch = 1,
        .render_px = .{ .width = 2, .height = 3 },
        .cell_px = .{ .width = 1, .height = 1 },
        .grid = .{ .cols = 2, .rows = 3 },
        .text_frame = .{
            .scene = .{
                .allocator = std.heap.c_allocator,
                .owned = false,
                .scene = .{
                    .clear_draws = &.{},
                    .background_draws = &.{},
                    .sprite_draws = &.{},
                    .decoration_draws = &.{},
                    .cursor_draws = &.{},
                    .raster_requests = &.{},
                    .missing = &.{},
                    .full_redraw = false,
                },
            },
            .raster_plan = .{ .allocator = std.heap.c_allocator, .outputs = &.{}, .owned = false },
        },
    };

    const base = owner.requiredRetainedSurfaceBase(&prepared);
    try std.testing.expectEqualSlices(u8, pixels, base);
}

fn testPublicationSource(allocator: std.mem.Allocator, snapshot_seq: u64, codepoint: u21) !source_vt.PublicationSource {
    const cells = try allocator.alloc(source_vt.SourceCell, 1);
    errdefer allocator.free(cells);
    cells[0] = std.mem.zeroes(source_vt.SourceCell);
    cells[0].codepoint = codepoint;
    const dirty_rows = try allocator.dupe(u8, &.{1});
    errdefer allocator.free(dirty_rows);
    const dirty_cols_start = try allocator.dupe(u16, &.{0});
    errdefer allocator.free(dirty_cols_start);
    const dirty_cols_end = try allocator.dupe(u16, &.{0});
    errdefer allocator.free(dirty_cols_end);
    return .{
        .cols = 1,
        .rows = 1,
        .history_count = 0,
        .scroll_row = 0,
        .snapshot_seq = snapshot_seq,
        .dirty_epoch = snapshot_seq,
        .is_alternate_screen = false,
        .cells = cells,
        .cursor = std.mem.zeroes(source_cell.CursorInfo),
        .colors = std.mem.zeroes(source_vt.SourceColors),
        .selection = std.mem.zeroes(source_vt.SourceSelection),
        .cursor_phase_visible = true,
        .dirty_rows = dirty_rows,
        .dirty_cols_start = dirty_cols_start,
        .dirty_cols_end = dirty_cols_end,
    };
}

test "ft hb retained capacities separate cache slots from run scratch" {
    var session = TextSession.init(std.testing.allocator);
    defer session.deinit();

    var context = TextSession.TextContext{
        .session = &session,
        .session_config = .{
            .surface_px = .{ .width = 80, .height = 32 },
            .font_size_px = 16,
        },
    };

    const capacity = TextSession.ftHbCapacity(&context);
    try std.testing.expectEqual(@as(u32, 20), capacity.face_text_cache_entries);
    try std.testing.expectEqual(@as(u32, 20), capacity.glyph_cell_cache_entries);
    try std.testing.expectEqual(@as(u32, 20), capacity.shape_run_cache_entries);
    try std.testing.expectEqual(@as(u32, 160), capacity.max_shape_input_codepoints);
    try std.testing.expectEqual(@as(u32, 512), capacity.max_glyphs_per_run);
}

test "surface text owner keeps source and submitted owners separate" {
    const owner = TextSessionOwner.create(
        std.testing.allocator,
        .{ .surface_px = .{ .width = 8, .height = 16 } },
    ) orelse return error.OutOfMemory;
    defer owner.destroy();

    try std.testing.expect(owner.source_slot.reserved == null);
    try std.testing.expect(owner.prepare_requests.pending == null);
    try std.testing.expect(owner.submitted.submitted_token == null);
}

test "ft hb retained capacities cap shape run cache slots" {
    var session = TextSession.init(std.testing.allocator);
    defer session.deinit();

    var context = TextSession.TextContext{
        .session = &session,
        .session_config = .{
            .surface_px = .{ .width = 4096, .height = 4096 },
            .font_size_px = 16,
        },
    };

    const capacity = TextSession.ftHbCapacity(&context);
    try std.testing.expectEqual(@as(u32, ft_hb_shape_run_cache_entry_cap), capacity.shape_run_cache_entries);
    try std.testing.expectEqual(@as(u32, ft_hb_face_text_cache_entry_cap), capacity.face_text_cache_entries);
    try std.testing.expectEqual(@as(u32, ft_hb_glyph_cell_cache_entry_cap), capacity.glyph_cell_cache_entries);
}

test "surface text retains translated cell scratch across prepares" {
    var session = TextSession.init(std.testing.allocator);
    defer session.deinit();

    try session.ensureCellInputScratchCapacity(4);
    const first_ptr = @intFromPtr(session.cell_input_scratch.ptr);
    try session.ensureCellInputScratchCapacity(4);
    try std.testing.expectEqual(first_ptr, @intFromPtr(session.cell_input_scratch.ptr));
    try std.testing.expectEqual(@as(usize, 4), session.cell_input_scratch.len);

    try session.ensureCellInputScratchCapacity(8);
    try std.testing.expectEqual(@as(usize, 8), session.cell_input_scratch.len);
}

test "invalidateTextState clears retained pixel state" {
    var owner = TextSessionOwner{
        .allocator = std.heap.c_allocator,
        .session = TextSession.init(std.heap.c_allocator),
        .geometry = .{},
        .source_slot = source_slot.SourceSlot.init(std.heap.c_allocator),
        .prepare_requests = source_prepare.PrepareRequests.init(std.heap.c_allocator),
        .submitted = .{},
        .config = .{ .surface_px = .{ .width = 1, .height = 1 } },
    };
    defer owner.clearRetainedSurface();
    defer owner.prepare_requests.deinit();
    defer owner.source_slot.deinit();
    defer owner.session.deinit();

    const pixels = try std.heap.c_allocator.alloc(u8, 4);
    @memset(pixels, 9);
    var owned_pixels = pixels;
    owner.retainSurfacePixels(&owned_pixels, 1, 1, 1);

    owner.invalidateTextState();

    try std.testing.expect(owner.retained_surface_pixels.len == 0);
    try std.testing.expectEqual(@as(u16, 0), owner.retained_surface_width);
    try std.testing.expectEqual(@as(u16, 0), owner.retained_surface_height);
    try std.testing.expectEqual(@as(u64, 0), owner.retained_surface_snapshot_seq);
}

test "setOwnedFontPath keeps owner and config font paths aligned" {
    const owner = TextSessionOwner.create(std.heap.c_allocator, .{ .surface_px = .{ .width = 1, .height = 1 } }) orelse return error.OutOfMemory;
    defer owner.destroy();

    const first = try std.heap.c_allocator.dupeZ(u8, "first-font");
    owner.setOwnedFontPath(first);
    try std.testing.expect(owner.font_path != null);
    try std.testing.expect(owner.config.font_path != null);
    try std.testing.expectEqualStrings("first-font", owner.font_path.?);
    try std.testing.expectEqualStrings("first-font", owner.config.font_path.?);

    const second = try std.heap.c_allocator.dupeZ(u8, "second-font");
    owner.setOwnedFontPath(second);
    try std.testing.expectEqualStrings("second-font", owner.font_path.?);
    try std.testing.expectEqualStrings("second-font", owner.config.font_path.?);

    owner.setOwnedFontPath(null);
    try std.testing.expect(owner.font_path == null);
    try std.testing.expect(owner.config.font_path == null);
}

test "adoptFallbackFontPaths syncs state and clears stale slots" {
    const owner = TextSessionOwner.create(std.heap.c_allocator, .{ .surface_px = .{ .width = 1, .height = 1 } }) orelse return error.OutOfMemory;
    defer owner.destroy();

    var first = std.ArrayList([:0]u8).empty;
    first.append(std.heap.c_allocator, try std.heap.c_allocator.dupeZ(u8, "mono")) catch return error.OutOfMemory;
    first.append(std.heap.c_allocator, try std.heap.c_allocator.dupeZ(u8, "emoji")) catch return error.OutOfMemory;
    owner.adoptFallbackFontPaths(&first);

    try std.testing.expectEqual(@as(text_support.FallbackFontCount, 2), owner.session.text_state.fallback_font_paths_len);
    try std.testing.expectEqualStrings("mono", owner.session.text_state.fallback_font_paths[0].?);
    try std.testing.expectEqualStrings("emoji", owner.session.text_state.fallback_font_paths[1].?);

    var second = std.ArrayList([:0]u8).empty;
    second.append(std.heap.c_allocator, try std.heap.c_allocator.dupeZ(u8, "symbols")) catch return error.OutOfMemory;
    owner.adoptFallbackFontPaths(&second);

    try std.testing.expectEqual(@as(text_support.FallbackFontCount, 1), owner.session.text_state.fallback_font_paths_len);
    try std.testing.expectEqualStrings("symbols", owner.session.text_state.fallback_font_paths[0].?);
    try std.testing.expect(owner.session.text_state.fallback_font_paths[1] == null);
}

test "setFallbackFontPathPtrs rejects overflow and null entries" {
    const owner = TextSessionOwner.create(std.heap.c_allocator, .{ .surface_px = .{ .width = 1, .height = 1 } }) orelse return error.OutOfMemory;
    defer owner.destroy();

    var overflow_paths: [text_support.max_fallback_fonts + 1]?[*]const u8 = [_]?[*]const u8{"font".ptr} ** (text_support.max_fallback_fonts + 1);
    try std.testing.expectError(error.InvalidArgument, owner.setFallbackFontPathPtrs(&overflow_paths));

    const bad_paths = [_]?[*]const u8{null};
    try std.testing.expectError(error.InvalidArgument, owner.setFallbackFontPathPtrs(&bad_paths));
}
