const std = @import("std");
const geometry_mod = @import("../geometry/grid_geometry.zig");
const renderable_content = @import("../renderable_content/content.zig");
const renderable_color = @import("../renderable_content/color.zig");
const renderable_cursor = @import("../renderable_content/cursor.zig");
const tokens = @import("../geometry/tokens.zig");
const prepared_handle = @import("../prepared/handle.zig");
const render_geometry = @import("../geometry/geometry.zig");
const geometry_contract = @import("../geometry/geometry_contract.zig");
const source_cell = @import("../tv_surface/cell.zig");
const source_publication = @import("../vt_publication/publication.zig");
const source_slot = @import("../storage/publication_storage.zig");
const source_prepare = @import("../tv_surface/prepare_request.zig");
const publication_damage = @import("../damage/publication_damage.zig");
const prepared_surface = @import("../prepared/surface.zig");
const session_submitted = @import("submitted.zig");
const sprite_resource_store = @import("../prepared/sprite_resource_store.zig");
const contract = @import("../text/contract.zig");
const font_resolve = @import("../text/resolve.zig");
const text_paths = @import("../text/paths.zig");
const surface_preparer = @import("../text/surface_preparer.zig");
const font_session = @import("../text/session.zig");
const ft_hb_provider = @import("../text/ft_hb/provider.zig");
const provider = @import("../text/provider.zig");
const atlas_cache = @import("../text/raster/cache.zig");
const rasterizer = @import("../text/raster/rasterizer.zig");
const shape_run = @import("../text/shape/run.zig");
const text_support = @import("../text/ft_hb/support.zig");
const text_glyph_raster = @import("../text/ft_hb/glyph_raster.zig");
const text_raster_operation = @import("../text/raster/operation.zig");

const max_font_faces = text_support.fallbackFontLen(text_support.max_fallback_fonts) + 1;
const ft_hb_face_text_cache_entry_cap: u32 = 4096;
const ft_hb_glyph_cell_cache_entry_cap: u32 = 4096;
const ft_hb_shape_run_cache_entry_cap: u32 = 64;
const ft_hb_shape_input_codepoints_per_cluster_cap: u32 = 16;
const ft_hb_cached_glyphs_per_run_cap: u32 = 512;
const RdrSfcHandle = ?*anyopaque;

fn monotonicNs() u64 {
    var ts: std.posix.timespec = undefined;
    if (std.posix.errno(std.posix.system.clock_gettime(.MONOTONIC, &ts)) != .SUCCESS) return 0;
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

const DebugPrepareTiming = struct {
    enabled_known: bool = false,
    enabled: bool = false,
    count: u64 = 0,
    prepare_surface_ns_total: u64 = 0,
    prepare_surface_ns_max: u64 = 0,
    input_us_total: u64 = 0,
    session_preparer_us_total: u64 = 0,
    session_prepare_cells_us_total: u64 = 0,
    direct_normal_us_total: u64 = 0,
    direct_normal_scan_us_total: u64 = 0,
    direct_normal_backgrounds_us_total: u64 = 0,
    direct_normal_clears_us_total: u64 = 0,
    direct_normal_decorations_us_total: u64 = 0,
    direct_normal_cursor_us_total: u64 = 0,
    direct_normal_raster_us_total: u64 = 0,
    owner_create_ns_total: u64 = 0,
    owner_create_ns_max: u64 = 0,

    fn active(self: *DebugPrepareTiming) bool {
        if (!self.enabled_known) {
            self.enabled = std.c.getenv("HOWL_RENDER_DEBUG_TIMING") != null;
            self.enabled_known = true;
        }
        return self.enabled;
    }

    fn record(self: *DebugPrepareTiming, timings: surface_preparer.PrepareTimings, prepare_surface_ns: u64, owner_create_ns: u64) void {
        if (!self.active()) return;
        self.count += 1;
        self.prepare_surface_ns_total += prepare_surface_ns;
        self.prepare_surface_ns_max = @max(self.prepare_surface_ns_max, prepare_surface_ns);
        self.input_us_total += timings.input_us;
        self.session_preparer_us_total += timings.session_preparer_us;
        self.session_prepare_cells_us_total += timings.session_prepare_cells_us;
        self.direct_normal_us_total += timings.direct_normal_us;
        self.direct_normal_scan_us_total += timings.direct_normal_scan_us;
        self.direct_normal_backgrounds_us_total += timings.direct_normal_backgrounds_us;
        self.direct_normal_clears_us_total += timings.direct_normal_clears_us;
        self.direct_normal_decorations_us_total += timings.direct_normal_decorations_us;
        self.direct_normal_cursor_us_total += timings.direct_normal_cursor_us;
        self.direct_normal_raster_us_total += timings.direct_normal_raster_us;
        self.owner_create_ns_total += owner_create_ns;
        self.owner_create_ns_max = @max(self.owner_create_ns_max, owner_create_ns);
        if (self.count % 128 != 0) return;
        std.debug.print(
            "howl-render-debug prepare_handle count={} prepare_surface_avg_us={} prepare_surface_max_us={} input_avg_us={} session_preparer_avg_us={} session_prepare_cells_avg_us={} direct_normal_avg_us={} direct_normal_scan_avg_us={} direct_normal_backgrounds_avg_us={} direct_normal_clears_avg_us={} direct_normal_decorations_avg_us={} direct_normal_cursor_avg_us={} direct_normal_raster_avg_us={} owner_create_avg_us={} owner_create_max_us={}\n",
            .{
                self.count,
                self.prepare_surface_ns_total / self.count / std.time.ns_per_us,
                self.prepare_surface_ns_max / std.time.ns_per_us,
                self.input_us_total / self.count,
                self.session_preparer_us_total / self.count,
                self.session_prepare_cells_us_total / self.count,
                self.direct_normal_us_total / self.count,
                self.direct_normal_scan_us_total / self.count,
                self.direct_normal_backgrounds_us_total / self.count,
                self.direct_normal_clears_us_total / self.count,
                self.direct_normal_decorations_us_total / self.count,
                self.direct_normal_cursor_us_total / self.count,
                self.direct_normal_raster_us_total / self.count,
                self.owner_create_ns_total / self.count / std.time.ns_per_us,
                self.owner_create_ns_max / std.time.ns_per_us,
            },
        );
    }
};

var debug_prepare_timing: DebugPrepareTiming = .{};

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

pub const HostSurface = struct {
    host_surface_id: u64,
    width: u16,
    height: u16,
};

pub const SubmitResult = struct {
    damage_kind: tokens.DamageKind,
    host_surface: HostSurface,
};

pub const TextSession = struct {
    allocator: std.mem.Allocator,
    text_state: text_support.FtHbSupport,
    mutex: ThreadMutex = .{},
    text_preparer: ?surface_preparer.TextSurfacePreparer = null,
    cell_input_scratch: []contract.CellInput = &.{},

    const TextContext = struct {
        session: *TextSession,
        session_config: TextSessionConfig,
    };

    pub const SurfaceLayout = geometry_contract.SurfaceLayout;
    pub const DamageKind = enum { partial, scroll, full };
    pub const SubmitExecution = struct {
        host_surface: HostSurface,
    };
    pub const PrepareInput = struct {
        config: TextSessionConfig,
        request: tokens.RenderRequest,
        layout: geometry_contract.PrepareLayout,
        state: source_publication.PublicationSource,
    };

    pub fn init(allocator: std.mem.Allocator) TextSession {
        return .{
            .allocator = allocator,
            .text_state = text_support.FtHbSupport.init(allocator),
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
    ) geometry_mod.SurfaceGeometryError!SurfaceLayout {
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
        var faces: [max_font_faces]font_session.FontFaceRecord = undefined;
        var context = TextContext{ .session = self, .session_config = prepare.config };
        lockMutex(&self.mutex);
        errdefer self.mutex.unlock();
        var resolve: font_resolve.ResolveObservability = .{};
        const theme = renderable_color.themeFromPublicationColors(prepare.state.colors);
        const dirty_rows: []const bool = @ptrCast(prepare.state.dirty_rows);
        const options: surface_preparer.PrepareOptions = .{ .scene = .{
            .cursor = renderable_cursor.mapPublicationCursor(prepare.state, theme),
            .damage = .{
                .full = prepare.request.token.damage_kind == .full,
                .dirty_rows = dirty_rows,
                .dirty_cols_start = prepare.state.dirty_cols_start,
                .dirty_cols_end = prepare.state.dirty_cols_end,
            },
        } };
        const ensure_preparer_start_ns = monotonicNs();
        const preparer = try self.ensureTextPreparer(&context);
        const session_preparer_us = (monotonicNs() -| ensure_preparer_start_ns) / std.time.ns_per_us;
        if (try preparer.preparePublicationWithSessionOptions(
            prepare.state,
            .{ .cols = prepare.state.cols, .rows = prepare.state.rows },
            fontSession(&context, &faces, &resolve),
            options,
            theme,
        )) |prepared_direct| {
            var direct = prepared_direct;
            direct.timings.session_preparer_us += session_preparer_us;
            const owned_direct = ownPreparedSurface(self.allocator, prepare, .{ .cols = prepare.state.cols, .rows = prepare.state.rows }, direct, resolve);
            self.mutex.unlock();
            return owned_direct;
        }
        try self.ensureCellInputScratchCapacity(prepare.state.cells.len);
        const input_start_ns = monotonicNs();
        const text_input = renderable_content.publicationSourceToTextSceneInputBorrowedWithTheme(
            self.cell_input_scratch,
            prepare.state,
            prepare.request.token.damage_kind == .full,
            theme,
        );
        const input_us = (monotonicNs() -| input_start_ns) / std.time.ns_per_us;
        const prepare_cells_start_ns = monotonicNs();
        var prepared = try preparer.prepareCellsWithSessionOptions(text_input.cells, text_input.grid, fontSession(&context, &faces, &resolve), .{ .scene = text_input.options.scene });
        prepared.timings.input_us += input_us;
        prepared.timings.session_preparer_us += session_preparer_us;
        prepared.timings.session_prepare_cells_us += (monotonicNs() -| prepare_cells_start_ns) / std.time.ns_per_us;
        errdefer prepared.deinit();
        const owned = ownPreparedSurface(self.allocator, prepare, text_input.grid, prepared, resolve);
        self.mutex.unlock();
        return owned;
    }

    pub fn submitSurface(self: *TextSession, prepared: *prepared_surface.PreparedSurface, execution: SubmitExecution) !SubmitResult {
        lockMutex(&self.mutex);
        errdefer self.mutex.unlock();
        markRendered(&self.text_preparer.?.atlas, prepared.text_surface.raster_plan.outputs);
        const submitted = SubmitResult{
            .damage_kind = prepared.damageKind(),
            .host_surface = execution.host_surface,
        };
        self.mutex.unlock();
        return submitted;
    }

    fn markRendered(atlas: *atlas_cache.OwnedAtlasCache, outputs: []const rasterizer.RasterSpriteOutput) void {
        for (outputs) |output| {
            _ = atlas.storeRendered(output) catch {
                _ = atlas.markRendered(output.key);
                continue;
            };
        }
    }

    pub fn atlasRaster(self: *TextSession, key: contract.SpriteKey) ?atlas_cache.StoredRaster {
        lockMutex(&self.mutex);
        defer self.mutex.unlock();
        const preparer = self.text_preparer orelse return null;
        return preparer.atlas.rasterForKey(key);
    }

    fn ownPreparedSurface(
        allocator: std.mem.Allocator,
        prepare: PrepareInput,
        grid: contract.GridMetrics,
        prepared: surface_preparer.OwnedPreparedTextSurface,
        resolve: font_resolve.ResolveObservability,
    ) prepared_surface.PreparedSurface {
        return .{
            .allocator = allocator,
            .request = prepare.request,
            .geometry_epoch = prepare.request.token.geometry_epoch,
            .render_px = prepare.layout.render_px,
            .cell_px = prepare.layout.cell_px,
            .grid = .{ .cols = grid.cols, .rows = grid.rows },
            .text_surface = prepared,
            .resolve = resolve,
            .render_surface_emission_failure = .none,
        };
    }

    fn ensureTextPreparer(self: *TextSession, context: *TextContext) !*surface_preparer.TextSurfacePreparer {
        const capacity = ftHbCapacity(context);
        if (self.text_preparer == null) {
            var ft_hb = ftHbSource(context);
            self.text_preparer = try surface_preparer.TextSurfacePreparer.initWithProvider(self.allocator, 2048, ft_hb.textProvider());
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

    fn ftHbSource(context: *TextContext) ft_hb_provider.FtHbSource {
        return .{
            .ctx = context,
            .has_codepoint = providerHasCodepointThunk,
            .shaper = .{ .ctx = context, .shape_run = providerShapeRunThunk },
            .rasterizer = .{ .ctx = context, .rasterize_sprite = providerRasterizeSpriteThunk },
            .glyph_lookup = .{ .ctx = context, .lookup_glyph = providerLookupGlyphThunk },
            .glyph_raster = .{ .ctx = context, .call = providerRasterizeGlyphThunk },
        };
    }

    fn fontSession(context: *TextContext, faces: []font_session.FontFaceRecord, active_resolve: ?*font_resolve.ResolveObservability) font_session.FontSession {
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

    fn providerShapeRunThunk(
        ctx: *anyopaque,
        allocator: std.mem.Allocator,
        run: contract.ResolvedRun,
        text_cache_view: contract.LineTextCache,
        clusters: []const contract.CellCluster,
        cell_metrics: contract.CellMetrics,
    ) anyerror!shape_run.OwnedShapedRun {
        return text_support.providerShapeRun(TextContext, ctx, allocator, run, text_cache_view, clusters, cell_metrics);
    }

    fn providerRasterizeSpriteThunk(ctx: *anyopaque, allocator: std.mem.Allocator, req: contract.SpriteRasterRequest) anyerror!rasterizer.RasterSpriteOutput {
        return text_glyph_raster.providerRasterizeSprite(TextContext, ctx, allocator, req);
    }

    fn providerLookupGlyphThunk(ctx: *anyopaque, face_id: contract.FontFaceId, codepoint: u32, cell_metrics: contract.CellMetrics) provider.LookupGlyphResult {
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
    rdr_sfc_handle: RdrSfcHandle = null,
    prepared_handles: std.ArrayList(*prepared_handle.PreparedHandle) = .empty,
    font_paths: text_paths.FontPaths,
    render_surface_sprite_resources: sprite_resource_store.SpriteResourceStore = .init(),

    pub const SubmitPreparedResult = union(enum) {
        rendered: SubmitResult,
        needs_prepare,
        failed,
    };

    pub const SubmitHandleDecision = union(enum) {
        idle,
        stale,
        needs_full_prepare,
        submit: *prepared_handle.PreparedHandle,
        failed,
    };

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
            .font_paths = text_paths.FontPaths.init(allocator),
        };
        return owner;
    }

    pub fn destroy(self: *TextSessionOwner) void {
        self.rdr_sfc_handle = null;
        for (self.prepared_handles.items) |prepared| prepared.destroy();
        self.prepared_handles.deinit(self.allocator);
        self.prepared_handles = .empty;
        self.font_paths.deinit();
        self.prepare_requests.deinit();
        self.source_slot.deinit();
        self.session.deinit();
        self.allocator.destroy(self);
    }

    pub fn setFontSizePx(self: *TextSessionOwner, font_size_px: u16) void {
        std.debug.assert(font_size_px > 0);
        self.config.font_size_px = font_size_px;
        self.invalidateTextState();
    }

    pub fn setFontPathBytes(self: *TextSessionOwner, bytes: ?[]const u8) FontConfigError!void {
        try self.font_paths.setPrimaryBytes(bytes);
        self.syncFontPaths();
        self.invalidateTextState();
    }

    pub fn setFallbackFontPathPtrs(self: *TextSessionOwner, raw_paths: []const ?[*]const u8) FontConfigError!void {
        try self.font_paths.setFallbackPathPtrs(raw_paths);
        self.syncFontPaths();
        self.invalidateTextState();
    }

    pub fn isValidFont(self: *TextSessionOwner) bool {
        return self.session.isValidFont(self.config);
    }

    pub fn prepareHandle(self: *TextSessionOwner, token: tokens.SnapshotToken) !*prepared_handle.PreparedHandle {
        const consume = try self.prepare_requests.consumePrepare(
            self.geometry.prepareLayout(token.geometry_epoch),
            token,
        );
        errdefer _ = self.prepare_requests.retryTakenPrepare(token);
        const prepare_surface_start_ns = monotonicNs();
        var prepared = self.session.prepareSurface(.{
            .config = self.config,
            .request = consume.request,
            .layout = consume.layout,
            .state = consume.state,
        }) catch |err| {
            return err;
        };
        const prepare_surface_ns = monotonicNs() -| prepare_surface_start_ns;
        const prepare_timings = prepared.text_surface.timings;
        errdefer prepared.deinit();
        const owner_create_start_ns = monotonicNs();
        const owner = prepared_handle.PreparedHandle.create(self, &prepared) catch |err| return err;
        self.rdr_sfc_handle = @ptrCast(owner);
        debug_prepare_timing.record(prepare_timings, prepare_surface_ns, monotonicNs() -| owner_create_start_ns);
        return owner;
    }

    pub fn registerPreparedHandle(self: *TextSessionOwner, prepared: *prepared_handle.PreparedHandle) !void {
        try self.prepared_handles.append(self.allocator, prepared);
    }

    pub fn clearCachedPreparedHandle(self: *TextSessionOwner, prepared: *prepared_handle.PreparedHandle) void {
        const handle: RdrSfcHandle = @ptrCast(prepared);
        if (self.rdr_sfc_handle == handle) self.rdr_sfc_handle = null;
    }

    pub fn invalidateTextState(self: *TextSessionOwner) void {
        text_support.resetLoadedFace(&self.session);
        self.session.text_state.face_text_cache.clear();
        self.session.text_state.shape_run_cache.clear();
        self.session.text_state.glyph_cell_cache.clear();
        if (self.session.text_preparer) |*preparer| preparer.clearAtlas();
        self.render_surface_sprite_resources.clear();
    }

    pub fn adoptFallbackFontPaths(self: *TextSessionOwner, owned_paths: *std.ArrayList([:0]u8)) void {
        self.font_paths.adoptFallbacks(owned_paths);
        self.syncFontPaths();
        self.invalidateTextState();
    }

    pub fn setOwnedFontPath(self: *TextSessionOwner, owned: ?[:0]u8) void {
        self.font_paths.setOwnedPrimary(owned);
        self.syncFontPaths();
        self.invalidateTextState();
    }

    pub fn nextSourceDirtyEpoch(self: *TextSessionOwner) u64 {
        self.source_dirty_epoch +%= 1;
        if (self.source_dirty_epoch == 0) self.source_dirty_epoch = 1;
        return self.source_dirty_epoch;
    }

    pub fn submittedToken(self: *TextSessionOwner) ?tokens.SnapshotToken {
        return self.submitted.submittedToken();
    }

    pub fn syncGeometry(self: *TextSessionOwner, layout: geometry_contract.Geometry) !geometry_contract.GeometryResponse {
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
            changed = publication_damage.setSourceCursorBlinkVisible(source, visible) or changed;
        }
        changed = self.prepare_requests.setCursorBlinkVisible(visible) or changed;
        if (changed) self.prepare_requests.requestBlinkRefresh();
        return true;
    }

    pub fn prepare(self: *TextSessionOwner) ?tokens.RenderRequest {
        const submitted_token = self.submittedToken();
        const request = self.prepare_requests.takePrepareRequest(self.geometry.geometry_epoch) orelse return null;
        const effective_token = session_submitted.Submitted.prepareTokenForRetainedState(
            request.token,
            submitted_token,
        );
        if (!publication_damage.sameSnapshotToken(effective_token, request.token)) {
            self.prepare_requests.active_request = .{
                .token = effective_token,
                .allow_retained_reuse = request.allow_retained_reuse,
            };
        }
        return self.prepare_requests.active_request;
    }

    pub fn takeSubmitHandle(self: *TextSessionOwner) SubmitHandleDecision {
        const opaque_handle = self.rdr_sfc_handle orelse return .idle;
        const prepared = prepared_handle.PreparedHandle.fromHandle(opaque_handle) orelse return .failed;
        if (!prepared.belongsToSession(self)) return .failed;
        if (!prepared.isLive()) {
            self.rdr_sfc_handle = null;
            return .failed;
        }
        if (prepared.state != .prepared) return .failed;
        const prepared_token = prepared.preparedSurfaceToken();
        if (self.submitted.isStalePrepared(self.prepare_requests.latestToken(), prepared_token.token)) {
            self.rdr_sfc_handle = null;
            self.prepare_requests.retireAtOrBefore(prepared_token.token);
            return .stale;
        }
        const validation = self.submitted.validatePrepared(prepared_token);
        if (validation != .valid) {
            self.rdr_sfc_handle = null;
            _ = self.prepare_requests.requestFullPrepare(session_submitted.Submitted.forceFull);
            return .needs_full_prepare;
        }
        prepared.state = .submit_ready;
        return .{ .submit = prepared };
    }

    pub fn submitPrepared(self: *TextSessionOwner, prepared: *prepared_handle.PreparedHandle, prepared_token: tokens.PreparedSurfaceToken, execution: TextSession.SubmitExecution) SubmitPreparedResult {
        if (prepared.state != .prepared) return .failed;
        if (!prepared.belongsToSession(self)) return .failed;
        if (!samePreparedSurfaceToken(prepared.preparedSurfaceToken(), prepared_token)) return .needs_prepare;
        return self.executePreparedSubmit(prepared, execution);
    }

    pub fn submitPreparedHandle(self: *TextSessionOwner, prepared: *prepared_handle.PreparedHandle, execution: TextSession.SubmitExecution) SubmitPreparedResult {
        if (self.rdr_sfc_handle != @as(RdrSfcHandle, @ptrCast(prepared))) return .failed;
        if (!prepared.isLive()) {
            self.rdr_sfc_handle = null;
            return .failed;
        }
        if (prepared.state != .submit_ready) return .failed;
        const submitted = prepared.preparedSurfaceToken().token;
        return switch (self.executePreparedSubmit(prepared, execution)) {
            .rendered => |result| blk: {
                self.rdr_sfc_handle = null;
                self.acceptSubmitted(.{ .token = submitted });
                break :blk .{ .rendered = result };
            },
            .needs_prepare => .needs_prepare,
            .failed => .failed,
        };
    }

    pub fn acceptSubmitted(self: *TextSessionOwner, submitted: tokens.SubmittedSurfaceToken) void {
        if (submitted.token.geometry_epoch != self.geometry.geometry_epoch) {
            _ = self.prepare_requests.requestFullPrepare(session_submitted.Submitted.forceFull);
            return;
        }
        self.submitted.acceptSubmitted(submitted);
    }

    pub fn workState(self: *const TextSessionOwner) SessionWorkState {
        const submitted_work = self.submitted.workState();
        return .{
            .source_pending = self.source_slot.sourcePending(),
            .prepare_pending = self.prepare_requests.preparePending(),
            .submit_pending = submitted_work.submit_pending or self.rdr_sfc_handle != null,
        };
    }

    fn syncFontPaths(self: *TextSessionOwner) void {
        self.font_paths.syncPrimary(&self.config.font_path);
        self.font_paths.syncFallbacks(
            &self.session.text_state.fallback_font_paths,
            &self.session.text_state.fallback_font_paths_len,
        );
    }

    fn executePreparedSubmit(self: *TextSessionOwner, prepared: *prepared_handle.PreparedHandle, execution: TextSession.SubmitExecution) SubmitPreparedResult {
        if (!prepared.belongsToSession(self)) return .failed;
        _ = prepared.buffer();
        if (!executionMatchesPrepared(prepared.prepared.render_px, execution)) return .failed;
        const result = self.session.submitSurface(&prepared.prepared, execution) catch return .failed;
        prepared.consume();
        return .{ .rendered = result };
    }
};

fn samePreparedSurfaceToken(a: tokens.PreparedSurfaceToken, b: tokens.PreparedSurfaceToken) bool {
    return a.token.snapshot_seq == b.token.snapshot_seq and
        a.token.dirty_epoch == b.token.dirty_epoch and
        a.token.geometry_epoch == b.token.geometry_epoch and
        a.token.damage_base_seq == b.token.damage_base_seq and
        a.token.damage_kind == b.token.damage_kind and
        a.required_base_seq == b.required_base_seq;
}

fn executionMatchesPrepared(render_px: geometry_contract.PixelSize, execution: TextSession.SubmitExecution) bool {
    return execution.host_surface.width == render_px.width and execution.host_surface.height == render_px.height;
}

pub const testing = struct {
    pub fn ensureCellInputScratchCapacity(session: *TextSession, cell_count: usize) !void {
        return session.ensureCellInputScratchCapacity(cell_count);
    }

    pub fn ftHbCapacity(session: *TextSession, session_config: TextSessionConfig) text_support.FtHbCapacity {
        const context = TextSession.TextContext{
            .session = session,
            .session_config = session_config,
        };
        return TextSession.ftHbCapacity(@constCast(&context));
    }
};
