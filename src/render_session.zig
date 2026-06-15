const std = @import("std");
const geometry_mod = @import("grid_geometry.zig");
const source_text_input = @import("vt_publication/text_input.zig");
const source_theme = @import("vt_publication/theme.zig");
const source_cursor = @import("vt_publication/cursor.zig");
const tokens = @import("tokens.zig");
const prepared_handle = @import("surface/handle.zig");
const render_geometry = @import("geometry.zig");
const geometry_contract = @import("geometry_contract.zig");
const source_publication = @import("vt_publication/publication.zig");
const publication_damage = @import("vt_publication/damage.zig");
const prepared_surface = @import("surface/prepared_surface.zig");
const submitted_surface = @import("submitted_surface.zig");
const sprite_resource_store = @import("surface/resource_store.zig");
const source_abi = @import("vt_publication/abi.zig");
const contract = @import("text/contract.zig");
const font_resolve = @import("text/resolve.zig");
const text_paths = @import("text/paths.zig");
const surface_preparer = @import("text/surface_preparer.zig");
const font_session = @import("text/session.zig");
const ft_hb_provider = @import("text/ft_hb/provider.zig");
const provider = @import("text/provider.zig");
const atlas_cache = @import("text/raster/atlas.zig");
const rasterizer = @import("text/raster/rasterizer.zig");
const shape_run = @import("text/shape/run.zig");
const text_support = @import("text/ft_hb/support.zig");
const text_glyph_raster = @import("text/ft_hb/glyph_raster.zig");
const text_raster_operation = @import("text/raster/operation.zig");
const c = @import("howl_render_c");

const max_font_faces = text_support.fallbackFontLen(text_support.max_fallback_fonts) + 1;
const ft_hb_face_text_cache_entry_cap: u32 = 4096;
const ft_hb_glyph_cell_cache_entry_cap: u32 = 4096;
const ft_hb_shape_run_cache_entry_cap: u32 = 64;
const ft_hb_shape_input_codepoints_per_cluster_cap: u32 = 16;
const ft_hb_cached_glyphs_per_run_cap: u32 = 512;
const RdrSfcHandle = ?*anyopaque;

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
    locked: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    fn unlock(self: *ThreadMutex) void {
        std.debug.assert(self.locked.load(.acquire));
        self.locked.store(false, .release);
        std.Io.Threaded.mutexUnlock(&self.state);
    }
};

fn lockMutex(mutex: *ThreadMutex) void {
    std.Io.Threaded.mutexLock(&mutex.state);
    const was_locked = mutex.locked.cmpxchgWeak(false, true, .acq_rel, .acquire);
    std.debug.assert(was_locked == null);
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
        cursor_theme: source_theme.CursorThemeConfig = .{},
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
        const cell_px = text_support.deriveCellSize(&self.text_state, config);
        const layout = geometry_contract.SurfaceLayout{ .cell_px = cell_px, .grid = geometry_mod.deriveGridSize(grid_px, cell_px) };
        std.debug.assert(layout.cell_px.width != 0);
        std.debug.assert(layout.cell_px.height != 0);
        std.debug.assert(layout.grid.cols != 0);
        std.debug.assert(layout.grid.rows != 0);
        return .{ .cell_px = layout.cell_px, .grid = layout.grid };
    }

    pub fn isValidFont(self: *TextSession, config: TextSessionConfig) bool {
        lockMutex(&self.mutex);
        defer self.mutex.unlock();
        if (text_support.ensurePrimaryFontWithConfig(&self.text_state, config)) return true;
        var i: text_support.FallbackFontCount = 0;
        while (i < self.text_state.fallback_font_paths_len) : (i += 1) {
            if (text_support.ensureFallbackFaceWithConfig(&self.text_state, config, i) != null) return true;
        }
        return false;
    }

    pub fn prepareSurface(self: *TextSession, prepare: PrepareInput) !prepared_surface.PreparedSurface {
        var faces: [max_font_faces]font_session.FontFaceRecord = undefined;
        var context = TextContext{ .session = self, .session_config = prepare.config };
        lockMutex(&self.mutex);
        errdefer self.mutex.unlock();
        var resolve: font_resolve.ResolveObservability = .{};
        const theme = source_theme.themeFromPublicationColorsWithCursorConfig(prepare.state.colors, prepare.cursor_theme);
        const dirty_rows: []const bool = @ptrCast(prepare.state.dirty_rows);
        const options: surface_preparer.PrepareOptions = .{ .scene = .{
            .cursor = source_cursor.mapPublicationCursor(prepare.state, theme),
            .damage = .{
                .full = prepare.request.token.damage_kind == .full,
                .dirty_rows = dirty_rows,
                .dirty_cols_start = prepare.state.dirty_cols_start,
                .dirty_cols_end = prepare.state.dirty_cols_end,
            },
        } };
        const preparer = try self.ensureTextPreparer(&context);
        if (try preparer.preparePublicationWithSessionOptions(
            prepare.state,
            .{ .cols = prepare.state.cols, .rows = prepare.state.rows },
            fontSession(&context, &faces, &resolve),
            options,
            theme,
        )) |prepared_direct| {
            const owned_direct = ownPreparedSurface(self.allocator, prepare, .{ .cols = prepare.state.cols, .rows = prepare.state.rows }, prepared_direct, resolve);
            self.mutex.unlock();
            return owned_direct;
        }
        try self.ensureCellInputScratchCapacity(prepare.state.cells.len);
        const cell_input_scratch = self.cell_input_scratch[0..prepare.state.cells.len];
        std.debug.assert(cell_input_scratch.len == prepare.state.cells.len);
        const text_input = source_text_input.publicationSourceToTextSceneInputBorrowedWithTheme(
            cell_input_scratch,
            prepare.state,
            prepare.request.token.damage_kind == .full,
            theme,
        );
        var prepared = try preparer.prepareCellsWithSessionOptions(text_input.cells, text_input.grid, fontSession(&context, &faces, &resolve), .{ .scene = text_input.options.scene });
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
        const cell_px = text_support.deriveCellSize(&context.session.text_state, context.session_config);
        const grid = geometry_mod.deriveGridSize(context.session_config.surface_px, cell_px);
        return @as(u32, @max(grid.cols, 1)) * @as(u32, @max(grid.rows, 1));
    }

    fn ftHbCapacity(context: *TextContext) text_support.FtHbCapacity {
        const cell_px = text_support.deriveCellSize(&context.session.text_state, context.session_config);
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
        std.debug.assert(context.session.text_state.fallback_font_paths_len <= text_support.max_fallback_fonts);
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
            .metrics = text_support.deriveCellMetricsWithConfig(&context.session.text_state, context.session_config),
        };
    }

    fn providerHasCodepointThunk(ctx: *anyopaque, face_id: contract.FontFaceId, codepoint: u32) bool {
        const context: *TextContext = @ptrCast(@alignCast(ctx));
        return text_support.providerHasCodepointWithConfig(&context.session.text_state, context.session_config, face_id, codepoint);
    }

    fn providerHasCellTextThunk(ctx: *anyopaque, face_id: contract.FontFaceId, text_value: contract.CellText) bool {
        const context: *TextContext = @ptrCast(@alignCast(ctx));
        return text_support.providerHasCellTextWithConfig(&context.session.text_state, context.session_config, face_id, text_value);
    }

    fn providerShapeRunThunk(
        ctx: *anyopaque,
        allocator: std.mem.Allocator,
        run: contract.ResolvedRun,
        text_cache_view: contract.LineTextCache,
        clusters: []const contract.CellCluster,
        cell_metrics: contract.CellMetrics,
    ) anyerror!shape_run.OwnedShapedRun {
        const context: *TextContext = @ptrCast(@alignCast(ctx));
        return text_support.providerShapeRunWithConfig(&context.session.text_state, context.session_config, allocator, run, text_cache_view, clusters, cell_metrics);
    }

    fn providerRasterizeSpriteThunk(ctx: *anyopaque, allocator: std.mem.Allocator, req: contract.SpriteRasterRequest) anyerror!rasterizer.RasterSpriteOutput {
        const context: *TextContext = @ptrCast(@alignCast(ctx));
        return text_glyph_raster.providerRasterizeSpriteWithConfig(&context.session.text_state, context.session_config, allocator, req);
    }

    fn providerLookupGlyphThunk(ctx: *anyopaque, face_id: contract.FontFaceId, codepoint: u32, cell_metrics: contract.CellMetrics) provider.LookupGlyphResult {
        const context: *TextContext = @ptrCast(@alignCast(ctx));
        return text_support.providerLookupGlyphWithConfig(&context.session.text_state, context.session_config, face_id, codepoint, cell_metrics);
    }

    fn providerRasterizeGlyphThunk(ctx: *anyopaque, allocator: std.mem.Allocator, req: text_raster_operation.RasterizeRequest) anyerror!text_raster_operation.RasterizeOutput {
        const context: *TextContext = @ptrCast(@alignCast(ctx));
        const width = @as(u16, @intCast(@as(u32, @max(req.cell_span, 1)) * @as(u32, @max(req.cell_metrics.cell_w_px, 1))));
        const height = @max(req.cell_metrics.cell_h_px, 1);
        const alpha_len: u32 = @as(u32, width) * @as(u32, height);
        const alpha = try allocator.alloc(u8, @intCast(alpha_len));
        errdefer allocator.free(alpha);
        @memset(alpha, 0);
        _ = text_glyph_raster.rasterizeProviderGlyphWithConfig(&context.session.text_state, context.session_config, alpha, width, height, req.cell_metrics.baseline_px, .{ .value = req.face_id }, req.glyph_id, 0, 0, 0);
        return .{
            .allocator = allocator,
            .width_px = width,
            .height_px = height,
            .bearing_x_px = 0,
            .bearing_y_px = 0,
            .advance_px = text_support.providerGlyphAdvanceWithConfig(&context.session.text_state, context.session_config, .{ .value = req.face_id }, req.glyph_id, req.cell_metrics),
            .alpha_mask = alpha,
        };
    }
};

pub const TextSessionOwner = struct {
    pub const HostCursorCadenceRect = source_abi.SourceCursorTrailRect;
    pub const HostCursorCadence = struct {
        focused: bool,
        cursor_opacity: u8,
        text_blink_opacity: u8,
        effective_shape: source_abi.SourceCursorShape,
        cursor_color: source_abi.SourceColor,
        cursor_text_color: source_abi.SourceColor,
        cursor_trail_color: source_abi.SourceColor,
        cursor_beam_thickness: f32,
        cursor_underline_thickness: f32,
        cursor_trail_count: u16,
        cursor_trail_rects: [source_abi.max_cursor_trail_rects]HostCursorCadenceRect,
    };

    allocator: std.mem.Allocator,
    session: TextSession,
    geometry: render_geometry.GeometryOwner,
    latest_source: ?source_publication.PublicationSource = null,
    latest_source_dirty_epoch: u64 = 0,
    prepare_request: ?tokens.RenderRequest = null,
    prepared_candidate: ?*prepared_handle.PreparedHandle = null,
    submitted: submitted_surface.SubmittedSurface,
    cursor_focused: bool = true,
    cursor_opacity: u8 = 255,
    text_blink_opacity: u8 = 255,
    cursor_effective_shape: source_abi.SourceCursorShape = .block,
    cursor_color: source_abi.SourceColor = .{ .kind = 2, .value = 0xCCCCCC },
    cursor_text_color: source_abi.SourceColor = .{ .kind = 2, .value = 0x111111 },
    cursor_trail_color: source_abi.SourceColor = .{ .kind = 0, .value = 0 },
    cursor_beam_thickness: f32 = 1.5,
    cursor_underline_thickness: f32 = 2.0,
    cursor_trail_count: u16 = 0,
    cursor_trail_rects: [source_abi.max_cursor_trail_rects]HostCursorCadenceRect = [_]HostCursorCadenceRect{std.mem.zeroes(HostCursorCadenceRect)} ** source_abi.max_cursor_trail_rects,
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
            .submitted = .{},
            .config = config,
            .font_paths = text_paths.FontPaths.init(allocator),
        };
        return owner;
    }

    pub fn destroy(self: *TextSessionOwner) void {
        self.rdr_sfc_handle = null;
        self.clearPreparedCandidate();
        self.clearLatestSource();
        for (self.prepared_handles.items) |prepared| prepared.destroy();
        self.prepared_handles.deinit(self.allocator);
        self.prepared_handles = .empty;
        self.font_paths.deinit();
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
        if (self.prepared_candidate != null) return error.PreparedCandidateBusy;
        const request = self.prepare_request orelse return error.MissingPrepareSource;
        const source = self.latest_source orelse return error.MissingPrepareSource;
        if (!publication_damage.sameSnapshotToken(request.token, token)) return error.MismatchedPrepareSource;
        var prepared = self.session.prepareSurface(.{
            .config = self.config,
            .request = request,
            .layout = self.geometry.prepareLayout(token.geometry_epoch),
            .state = source,
            .cursor_theme = .{
                .cursor_color = self.cursor_color,
                .cursor_text_color = self.cursor_text_color,
                .cursor_trail_color = self.cursor_trail_color,
                .cursor_beam_thickness = self.cursor_beam_thickness,
                .cursor_underline_thickness = self.cursor_underline_thickness,
            },
        }) catch |err| {
            return err;
        };
        errdefer prepared.deinit();
        std.debug.assert(!self.session.mutex.locked.load(.acquire));
        const owner = prepared_handle.PreparedHandle.create(self, &prepared) catch |err| return err;
        self.rdr_sfc_handle = @ptrCast(owner);
        self.prepared_candidate = owner;
        self.prepare_request = null;
        return owner;
    }

    pub fn registerPreparedHandle(self: *TextSessionOwner, prepared: *prepared_handle.PreparedHandle) !void {
        try self.prepared_handles.append(self.allocator, prepared);
    }

    pub fn clearCachedPreparedHandle(self: *TextSessionOwner, prepared: *prepared_handle.PreparedHandle) void {
        const handle: RdrSfcHandle = @ptrCast(prepared);
        if (self.rdr_sfc_handle == handle) self.rdr_sfc_handle = null;
        if (self.prepared_candidate == prepared) self.prepared_candidate = null;
    }

    pub fn invalidateTextState(self: *TextSessionOwner) void {
        text_support.resetLoadedFace(&self.session.text_state);
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
        self.latest_source_dirty_epoch +%= 1;
        if (self.latest_source_dirty_epoch == 0) self.latest_source_dirty_epoch = 1;
        return self.latest_source_dirty_epoch;
    }

    pub fn submittedToken(self: *TextSessionOwner) ?tokens.SnapshotToken {
        return self.submitted.submittedToken();
    }

    fn updateBool(target: *bool, next: bool) bool {
        if (target.* == next) return false;
        target.* = next;
        return true;
    }

    fn updateByte(target: *u8, next: u8) bool {
        if (target.* == next) return false;
        target.* = next;
        return true;
    }

    fn updateF32(target: *f32, next: f32) bool {
        if (target.* == next) return false;
        target.* = next;
        return true;
    }

    pub fn syncGeometry(self: *TextSessionOwner, layout: geometry_contract.Geometry) !geometry_contract.GeometryResponse {
        const response = self.geometry.sync(layout);
        if (response.changed) self.recomputePrepareRequest();
        return response;
    }

    pub fn setHostCursorCadence(self: *TextSessionOwner, cadence: HostCursorCadence) bool {
        var changed = false;
        changed = updateBool(&self.cursor_focused, cadence.focused) or changed;
        changed = updateByte(&self.cursor_opacity, cadence.cursor_opacity) or changed;
        changed = updateByte(&self.text_blink_opacity, cadence.text_blink_opacity) or changed;
        if (!std.mem.eql(u8, std.mem.asBytes(&self.cursor_color), std.mem.asBytes(&cadence.cursor_color))) {
            self.cursor_color = cadence.cursor_color;
            changed = true;
        }
        if (!std.mem.eql(u8, std.mem.asBytes(&self.cursor_text_color), std.mem.asBytes(&cadence.cursor_text_color))) {
            self.cursor_text_color = cadence.cursor_text_color;
            changed = true;
        }
        if (!std.mem.eql(u8, std.mem.asBytes(&self.cursor_trail_color), std.mem.asBytes(&cadence.cursor_trail_color))) {
            self.cursor_trail_color = cadence.cursor_trail_color;
            changed = true;
        }
        changed = updateF32(&self.cursor_beam_thickness, cadence.cursor_beam_thickness) or changed;
        changed = updateF32(&self.cursor_underline_thickness, cadence.cursor_underline_thickness) or changed;
        if (self.cursor_effective_shape != cadence.effective_shape) {
            self.cursor_effective_shape = cadence.effective_shape;
            changed = true;
        }
        if (self.cursor_trail_count != cadence.cursor_trail_count) {
            self.cursor_trail_count = cadence.cursor_trail_count;
            changed = true;
        }
        if (!std.mem.eql(u8, std.mem.asBytes(&self.cursor_trail_rects), std.mem.asBytes(&cadence.cursor_trail_rects))) {
            self.cursor_trail_rects = cadence.cursor_trail_rects;
            changed = true;
        }

        if (changed) self.recomputePrepareRequest();
        return changed;
    }

    pub fn applyHostCursorCadenceToSource(self: *TextSessionOwner, source: *source_publication.PublicationSource) bool {
        var changed = false;
        if (source.cursor.focused != self.cursor_focused) {
            source.cursor.focused = self.cursor_focused;
            changed = true;
        }
        if (source.cursor.cursor_opacity != self.cursor_opacity) {
            source.cursor.cursor_opacity = self.cursor_opacity;
            changed = true;
        }
        if (source.cursor.text_blink_opacity != self.text_blink_opacity) {
            source.cursor.text_blink_opacity = self.text_blink_opacity;
            changed = true;
        }
        if (source.cursor.effective_shape != self.cursor_effective_shape) {
            source.cursor.effective_shape = self.cursor_effective_shape;
            changed = true;
        }
        if (source.cursor_phase_visible != (self.cursor_opacity != 0)) {
            source.cursor_phase_visible = self.cursor_opacity != 0;
            changed = true;
        }
        if (source.cursor_trail_count != self.cursor_trail_count) {
            source.cursor_trail_count = self.cursor_trail_count;
            changed = true;
        }
        if (!std.mem.eql(u8, std.mem.asBytes(&source.cursor_trail_rects), std.mem.asBytes(&self.cursor_trail_rects))) {
            source.cursor_trail_rects = self.cursor_trail_rects;
            changed = true;
        }
        return changed;
    }

    pub fn ingestPublishedSource(self: *TextSessionOwner, result: c.HowlVtSurfaceResult) !?tokens.RenderRequest {
        var source = try source_publication.ownedSourceFromSurfaceResult(self.allocator, result, self.cursor_opacity != 0);
        errdefer source.deinit(self.allocator);
        _ = self.applyHostCursorCadenceToSource(&source);
        publication_damage.canonicalizeDirtyMetadata(source.rows, source.dirty_rows, source.dirty_cols_start, source.dirty_cols_end);
        try source_publication.validatePublicationSourceBoundary(source);

        const prior = self.latest_source;
        const damage_kind = self.classifySourceDamage(source);
        if (damage_kind == .none) {
            source.deinit(self.allocator);
            return null;
        }
        self.invalidatePreparedCandidateForSource(source.snapshot_seq);
        self.clearLatestSource();
        self.latest_source = source;
        self.prepare_request = self.renderRequestForSource(self.latest_source.?, damage_kind, prior != null);
        return self.prepare_request;
    }

    pub fn takeSubmitHandle(self: *TextSessionOwner) SubmitHandleDecision {
        const prepared = self.prepared_candidate orelse return .idle;
        const opaque_handle = self.rdr_sfc_handle orelse return .failed;
        if (@as(RdrSfcHandle, @ptrCast(prepared)) != opaque_handle) return .failed;
        if (!prepared.belongsToSession(self)) return .failed;
        if (!prepared.isLive()) {
            self.clearPreparedCandidate();
            return .failed;
        }
        if (prepared.state != .prepared) return .failed;
        const prepared_token = prepared.preparedSurfaceToken();
        const latest_token = if (self.prepare_request) |request| request.token else null;
        if (self.submitted.isStalePrepared(latest_token, prepared_token.token)) {
            self.clearPreparedCandidate();
            return .stale;
        }
        const validation = self.submitted.validatePrepared(prepared_token);
        if (validation != .valid) {
            self.clearPreparedCandidate();
            if (self.prepare_request) |request| self.prepare_request = .{ .token = submitted_surface.SubmittedSurface.forceFull(request.token), .allow_retained_reuse = false };
            return .needs_full_prepare;
        }
        prepared.state = .submit_ready;
        return .{ .submit = prepared };
    }

    pub fn submitPreparedHandle(self: *TextSessionOwner, prepared: *prepared_handle.PreparedHandle, execution: TextSession.SubmitExecution) SubmitPreparedResult {
        if (self.rdr_sfc_handle != @as(RdrSfcHandle, @ptrCast(prepared))) return .failed;
        if (self.prepared_candidate != prepared) return .failed;
        if (!prepared.isLive()) {
            self.clearPreparedCandidate();
            return .failed;
        }
        if (prepared.state != .submit_ready) return .failed;
        const submitted = prepared.preparedSurfaceToken().token;
        return switch (self.executePreparedSubmit(prepared, execution)) {
            .rendered => |result| blk: {
                self.clearPreparedCandidateAfterConsume();
                self.acceptSubmittedToken(.{ .token = submitted });
                self.prepare_request = null;
                break :blk .{ .rendered = result };
            },
            .needs_prepare => .needs_prepare,
            .failed => .failed,
        };
    }

    fn acceptSubmittedToken(self: *TextSessionOwner, submitted: tokens.SubmittedSurfaceToken) void {
        if (submitted.token.geometry_epoch != self.geometry.geometry_epoch) {
            if (self.prepare_request) |request| self.prepare_request = .{ .token = submitted_surface.SubmittedSurface.forceFull(request.token), .allow_retained_reuse = false };
            return;
        }
        self.submitted.acceptSubmitted(submitted);
    }

    pub fn workState(self: *const TextSessionOwner) SessionWorkState {
        const source_pending = if (self.latest_source) |source|
            self.prepare_request == null and self.prepared_candidate == null and !self.sourceSubmitted(source.snapshot_seq)
        else
            false;
        return .{
            .source_pending = source_pending,
            .prepare_pending = self.prepare_request != null,
            .submit_pending = self.prepared_candidate != null,
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

    fn clearLatestSource(self: *TextSessionOwner) void {
        if (self.latest_source) |*source| source.deinit(self.allocator);
        self.latest_source = null;
        self.prepare_request = null;
    }

    fn clearPreparedCandidate(self: *TextSessionOwner) void {
        const prepared = self.prepared_candidate orelse {
            self.rdr_sfc_handle = null;
            return;
        };
        self.prepared_candidate = null;
        self.rdr_sfc_handle = null;
        prepared.release();
    }

    fn clearPreparedCandidateAfterConsume(self: *TextSessionOwner) void {
        self.prepared_candidate = null;
        self.rdr_sfc_handle = null;
    }

    fn invalidatePreparedCandidateForSource(self: *TextSessionOwner, snapshot_seq: u64) void {
        const prepared = self.prepared_candidate orelse return;
        if (prepared.preparedSurfaceToken().token.snapshot_seq == snapshot_seq) return;
        self.clearPreparedCandidate();
    }

    fn classifySourceDamage(self: *const TextSessionOwner, source: source_publication.PublicationSource) tokens.DamageKind {
        const damage_kind = publication_damage.classifyDirty(source.snapshot());
        const prior = self.latest_source orelse return damage_kind;
        const prior_snapshot = prior.snapshot();
        const submitted_token = self.submitted.submittedToken();
        const prior_matches_submitted = if (submitted_token) |token| prior_snapshot.snapshot_seq == token.snapshot_seq else false;
        if (self.prepare_request) |request| {
            if (request.token.geometry_epoch != self.geometry.geometry_epoch) return .full;
        }
        if (source.snapshot_seq == prior_snapshot.snapshot_seq) {
            if (publication_damage.samePublicationSource(prior, source)) return .none;
            if (publication_damage.cursorPresentationChanged(prior, source)) return .full;
            if (publication_damage.colorPresentationChanged(prior, source)) return .full;
            if (damage_kind == .partial and !prior_matches_submitted) return .full;
            return damage_kind;
        }
        if (publication_damage.cursorPresentationChanged(prior, source)) return .full;
        if (publication_damage.colorPresentationChanged(prior, source)) return .full;
        if (source.cols != prior.cols or source.rows != prior.rows) return .full;
        if (source.is_alternate_screen != prior.is_alternate_screen) return .full;
        if (source.scroll_row != prior.scroll_row) return .full;
        if (damage_kind == .partial and !prior_matches_submitted) return .full;
        return damage_kind;
    }

    fn renderRequestForSource(self: *const TextSessionOwner, source: source_publication.PublicationSource, damage_kind: tokens.DamageKind, had_prior_source: bool) tokens.RenderRequest {
        std.debug.assert(damage_kind != .none);
        const submitted_token = self.submitted.submittedToken();
        const token = tokens.SnapshotToken{
            .snapshot_seq = source.snapshot_seq,
            .dirty_epoch = source.dirty_epoch,
            .geometry_epoch = self.geometry.geometry_epoch,
            .damage_base_seq = if (damage_kind == .partial) if (submitted_token) |value| value.snapshot_seq else 0 else 0,
            .damage_kind = damage_kind,
        };
        const effective_token = submitted_surface.SubmittedSurface.prepareTokenForRetainedState(token, submitted_token);
        return .{ .token = effective_token, .allow_retained_reuse = had_prior_source and effective_token.damage_kind == .partial };
    }

    fn recomputePrepareRequest(self: *TextSessionOwner) void {
        const source = self.latest_source orelse return;
        self.prepare_request = self.renderRequestForSource(source, .full, true);
    }

    fn sourceSubmitted(self: *const TextSessionOwner, snapshot_seq: u64) bool {
        const token = self.submitted.submittedToken() orelse return false;
        return token.snapshot_seq == snapshot_seq;
    }
};

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

test "ft hb retained capacities separate cache slots from run scratch" {
    var session = TextSession.init(std.testing.allocator);
    defer session.deinit();

    const capacity = testing.ftHbCapacity(&session, .{
        .surface_px = .{ .width = 80, .height = 32 },
        .font_size_px = 16,
    });
    try std.testing.expectEqual(@as(u32, 20), capacity.face_text_cache_entries);
    try std.testing.expectEqual(@as(u32, 20), capacity.glyph_cell_cache_entries);
    try std.testing.expectEqual(@as(u32, 20), capacity.shape_run_cache_entries);
    try std.testing.expectEqual(@as(u32, 160), capacity.max_shape_input_codepoints);
    try std.testing.expectEqual(@as(u32, 512), capacity.max_glyphs_per_run);
}

test "render session owner keeps source and submitted owners separate" {
    const owner = TextSessionOwner.create(
        std.testing.allocator,
        .{ .surface_px = .{ .width = 8, .height = 16 } },
    ) orelse return error.OutOfMemory;
    defer owner.destroy();

    try std.testing.expect(owner.latest_source == null);
    try std.testing.expect(owner.prepare_request == null);
    try std.testing.expect(owner.prepared_candidate == null);
    try std.testing.expect(owner.submitted.submitted_token == null);
}

test "render session owner invalidation clears sprite resource store" {
    const owner = TextSessionOwner.create(
        std.testing.allocator,
        .{ .surface_px = .{ .width = 8, .height = 16 } },
    ) orelse return error.OutOfMemory;
    defer owner.destroy();

    const sprite = sprite_resource_store.PreparedSprite{
        .key = .{ .value = 1 },
        .pixels = &[_]u8{255},
        .width_px = 1,
        .height_px = 1,
        .stride_bytes = 1,
        .color_mode = .alpha,
        .visual_bounds = .{},
    };
    _ = try owner.render_surface_sprite_resources.atlasRegionFor(sprite, 1, 1, &[_]u8{255});
    try std.testing.expectEqual(@as(u32, 1), owner.render_surface_sprite_resources.atlas_count);
    const next_value = owner.render_surface_sprite_resources.value_next;

    owner.invalidateTextState();
    try std.testing.expectEqual(@as(u32, 0), owner.render_surface_sprite_resources.atlas_count);
    try std.testing.expectEqual(@as(u32, 0), owner.render_surface_sprite_resources.count);
    try std.testing.expectEqual(next_value, owner.render_surface_sprite_resources.value_next);
}

test "render session owner stores configured cursor theme inputs" {
    const owner = TextSessionOwner.create(
        std.testing.allocator,
        .{ .surface_px = .{ .width = 8, .height = 16 } },
    ) orelse return error.OutOfMemory;
    defer owner.destroy();

    _ = owner.setHostCursorCadence(.{
        .focused = true,
        .cursor_opacity = 255,
        .text_blink_opacity = 255,
        .effective_shape = .beam,
        .cursor_color = .{ .kind = 2, .value = 0x102030 },
        .cursor_text_color = .{ .kind = 2, .value = 0x405060 },
        .cursor_trail_color = .{ .kind = 2, .value = 0x708090 },
        .cursor_beam_thickness = 2.5,
        .cursor_underline_thickness = 3.5,
        .cursor_trail_count = 0,
        .cursor_trail_rects = [_]TextSessionOwner.HostCursorCadenceRect{std.mem.zeroes(TextSessionOwner.HostCursorCadenceRect)} ** source_abi.max_cursor_trail_rects,
    });

    try std.testing.expectEqual(@as(u32, 0x102030), owner.cursor_color.value);
    try std.testing.expectEqual(@as(u32, 0x405060), owner.cursor_text_color.value);
    try std.testing.expectEqual(@as(u32, 0x708090), owner.cursor_trail_color.value);
    try std.testing.expectEqual(@as(f32, 2.5), owner.cursor_beam_thickness);
    try std.testing.expectEqual(@as(f32, 3.5), owner.cursor_underline_thickness);
}

test "render session owner rejects prepared work after resize publication" {
    const owner = TextSessionOwner.create(
        std.testing.allocator,
        .{ .surface_px = .{ .width = 8, .height = 16 } },
    ) orelse return error.OutOfMemory;
    defer owner.destroy();

    const initial_geometry = try owner.syncGeometry(.{
        .render_px = .{ .width = 8, .height = 16 },
        .grid_px = .{ .width = 8, .height = 16 },
        .cell_px = .{ .width = 8, .height = 16 },
    });
    try std.testing.expect(initial_geometry.changed);
    try std.testing.expectEqual(@as(u64, 1), initial_geometry.geometry_epoch);

    var first_cells = [_]source_abi.SourceCell{testCell('A')};
    var first_source = source_publication.validSurfaceResult(first_cells[0..], &[_]u8{1}, &[_]u16{0}, &[_]u16{0});
    first_source.source.cols = 1;
    first_source.source.cursor.col = 0;
    first_source.snapshot_seq = 1;
    first_source.dirty_generation = 1;
    const old_request = try owner.ingestPublishedSource(first_source) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u64, 1), old_request.token.snapshot_seq);
    try std.testing.expectEqual(@as(u64, 1), old_request.token.geometry_epoch);
    try std.testing.expect(owner.workState().prepare_pending);
    try std.testing.expect(!owner.workState().submit_pending);
    const old_rdr_sfc_handle = try owner.prepareHandle(old_request.token);
    defer old_rdr_sfc_handle.release();
    try std.testing.expect(!owner.workState().prepare_pending);
    try std.testing.expect(owner.workState().submit_pending);

    const resized_geometry = try owner.syncGeometry(.{
        .render_px = .{ .width = 16, .height = 16 },
        .grid_px = .{ .width = 8, .height = 16 },
        .cell_px = .{ .width = 8, .height = 16 },
    });
    try std.testing.expect(resized_geometry.changed);
    try std.testing.expect(resized_geometry.geometry_epoch > old_request.token.geometry_epoch);

    var resized_cells = [_]source_abi.SourceCell{testCell('A')};
    var resized_source = source_publication.validSurfaceResult(resized_cells[0..], &[_]u8{1}, &[_]u16{0}, &[_]u16{0});
    resized_source.source.cols = 1;
    resized_source.source.cursor.col = 0;
    resized_source.snapshot_seq = 2;
    resized_source.dirty_generation = 2;
    const resized_request = try owner.ingestPublishedSource(resized_source) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(tokens.DamageKind.full, resized_request.token.damage_kind);
    try std.testing.expectEqual(resized_geometry.geometry_epoch, resized_request.token.geometry_epoch);

    const decision = owner.takeSubmitHandle();
    switch (decision) {
        .idle => {},
        else => return error.TestUnexpectedResult,
    }
    try std.testing.expect(!owner.workState().submit_pending);

    try std.testing.expectEqual(@as(u64, 2), resized_request.token.snapshot_seq);
    try std.testing.expectEqual(resized_geometry.geometry_epoch, resized_request.token.geometry_epoch);
    try std.testing.expectEqual(tokens.DamageKind.full, resized_request.token.damage_kind);
    try std.testing.expectEqual(@as(u64, 0), resized_request.token.damage_base_seq);
    try std.testing.expect(!resized_request.allow_retained_reuse);
}

test "render session owner drops duplicate copied source without mutating latest source" {
    const owner = TextSessionOwner.create(
        std.testing.allocator,
        .{ .surface_px = .{ .width = 8, .height = 16 } },
    ) orelse return error.OutOfMemory;
    defer owner.destroy();

    _ = try owner.syncGeometry(.{
        .render_px = .{ .width = 8, .height = 16 },
        .grid_px = .{ .width = 8, .height = 16 },
        .cell_px = .{ .width = 8, .height = 16 },
    });

    var cells = [_]source_abi.SourceCell{testCell('A')};
    var source = source_publication.validSurfaceResult(cells[0..], &[_]u8{1}, &[_]u16{0}, &[_]u16{0});
    source.source.cols = 1;
    source.source.cursor.col = 0;
    source.snapshot_seq = 1;
    source.dirty_generation = 1;

    const first = try owner.ingestPublishedSource(source) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u64, 1), first.token.snapshot_seq);
    const latest_cells = owner.latest_source.?.cells.ptr;
    const latest_dirty_rows = owner.latest_source.?.dirty_rows.ptr;

    try std.testing.expect((try owner.ingestPublishedSource(source)) == null);
    try std.testing.expect(owner.latest_source != null);
    try std.testing.expectEqual(latest_cells, owner.latest_source.?.cells.ptr);
    try std.testing.expectEqual(latest_dirty_rows, owner.latest_source.?.dirty_rows.ptr);
    try std.testing.expectEqual(@as(u64, 1), owner.latest_source.?.snapshot_seq);
    try std.testing.expect(owner.prepare_request != null);
    try std.testing.expectEqual(@as(u64, 1), owner.prepare_request.?.token.snapshot_seq);
}

test "render session owner cadence change does not hide duplicate source damage" {
    const owner = TextSessionOwner.create(
        std.testing.allocator,
        .{ .surface_px = .{ .width = 8, .height = 16 } },
    ) orelse return error.OutOfMemory;
    defer owner.destroy();

    _ = try owner.syncGeometry(.{
        .render_px = .{ .width = 8, .height = 16 },
        .grid_px = .{ .width = 8, .height = 16 },
        .cell_px = .{ .width = 8, .height = 16 },
    });

    var cells = [_]source_abi.SourceCell{testCell('A')};
    var source = source_publication.validSurfaceResult(cells[0..], &[_]u8{1}, &[_]u16{0}, &[_]u16{0});
    source.source.cols = 1;
    source.source.cursor.col = 0;
    source.snapshot_seq = 1;
    source.dirty_generation = 1;

    _ = try owner.ingestPublishedSource(source) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u8, 255), owner.latest_source.?.cursor.cursor_opacity);

    _ = owner.setHostCursorCadence(.{
        .focused = true,
        .cursor_opacity = 0,
        .text_blink_opacity = 255,
        .effective_shape = .beam,
        .cursor_color = .{ .kind = 0, .value = 0 },
        .cursor_text_color = .{ .kind = 0, .value = 0 },
        .cursor_trail_color = .{ .kind = 0, .value = 0 },
        .cursor_beam_thickness = 1.5,
        .cursor_underline_thickness = 2.0,
        .cursor_trail_count = 0,
        .cursor_trail_rects = [_]TextSessionOwner.HostCursorCadenceRect{std.mem.zeroes(TextSessionOwner.HostCursorCadenceRect)} ** source_abi.max_cursor_trail_rects,
    });
    try std.testing.expectEqual(@as(u8, 255), owner.latest_source.?.cursor.cursor_opacity);

    const cursor_request = try owner.ingestPublishedSource(source) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u64, 1), cursor_request.token.snapshot_seq);
    try std.testing.expectEqual(tokens.DamageKind.full, cursor_request.token.damage_kind);
    try std.testing.expectEqual(@as(u8, 0), owner.latest_source.?.cursor.cursor_opacity);
}

fn testCell(codepoint: u21) source_abi.SourceCell {
    var cell = std.mem.zeroes(source_abi.SourceCell);
    cell.codepoint = codepoint;
    return cell;
}

fn testSource(allocator: std.mem.Allocator, snapshot_seq: u64, codepoint: u21) !source_publication.PublicationSource {
    _ = testCell(codepoint);
    return source_publication.ownedTestSource(allocator, snapshot_seq, codepoint);
}

test "render session owner rejects partial rdr_sfc handle with wrong submitted base" {
    const owner = TextSessionOwner.create(
        std.testing.allocator,
        .{ .surface_px = .{ .width = 8, .height = 16 } },
    ) orelse return error.OutOfMemory;
    defer owner.destroy();

    owner.submitted.acceptSubmitted(.{
        .token = .{ .snapshot_seq = 9, .dirty_epoch = 9, .geometry_epoch = 1, .damage_base_seq = 0, .damage_kind = .full },
    });
    var prepared_value = @import("c/test_support.zig").preparedSurface(.{ .width_px = 8, .height_px = 16, .full_redraw = false });
    prepared_value.request.token = .{ .snapshot_seq = 10, .dirty_epoch = 10, .geometry_epoch = 1, .damage_base_seq = 1, .damage_kind = .partial };
    const rdr_sfc_handle = try prepared_handle.PreparedHandle.create(owner, &prepared_value);
    defer rdr_sfc_handle.release();
    owner.rdr_sfc_handle = @ptrCast(rdr_sfc_handle);
    owner.prepared_candidate = rdr_sfc_handle;

    switch (owner.takeSubmitHandle()) {
        .needs_full_prepare => {},
        else => return error.TestUnexpectedResult,
    }
    try std.testing.expect(owner.rdr_sfc_handle == null);
}

test "ft hb retained capacities cap shape run cache slots" {
    var session = TextSession.init(std.testing.allocator);
    defer session.deinit();

    const capacity = testing.ftHbCapacity(&session, .{
        .surface_px = .{ .width = 4096, .height = 4096 },
        .font_size_px = 16,
    });
    try std.testing.expectEqual(@as(u32, 64), capacity.shape_run_cache_entries);
    try std.testing.expectEqual(@as(u32, 4096), capacity.face_text_cache_entries);
    try std.testing.expectEqual(@as(u32, 4096), capacity.glyph_cell_cache_entries);
}

test "render session retains translated cell scratch across prepares" {
    var session = TextSession.init(std.testing.allocator);
    defer session.deinit();

    try testing.ensureCellInputScratchCapacity(&session, 4);
    const first_ptr = @intFromPtr(session.cell_input_scratch.ptr);
    try testing.ensureCellInputScratchCapacity(&session, 4);
    try std.testing.expectEqual(first_ptr, @intFromPtr(session.cell_input_scratch.ptr));
    try std.testing.expectEqual(@as(usize, 4), session.cell_input_scratch[0..4].len);

    try testing.ensureCellInputScratchCapacity(&session, 8);
    try std.testing.expectEqual(@as(usize, 8), session.cell_input_scratch[0..8].len);
}

test "render session derive layout rejects zero dimensions" {
    var session = TextSession.init(std.testing.allocator);
    defer session.deinit();

    try std.testing.expectError(error.InvalidSurfaceSize, session.deriveLayout(.{ .surface_px = .{ .width = 16, .height = 16 }, .font_size_px = 8 }, .{ .width = 0, .height = 16 }, .{ .width = 16, .height = 16 }));
    try std.testing.expectError(error.InvalidGridSize, session.deriveLayout(.{ .surface_px = .{ .width = 16, .height = 16 }, .font_size_px = 8 }, .{ .width = 16, .height = 16 }, .{ .width = 0, .height = 16 }));
}
