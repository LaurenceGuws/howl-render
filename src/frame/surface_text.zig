const std = @import("std");
const abi = @import("../ffi_types.zig");
const geometry_mod = @import("geometry.zig");
const input = @import("input.zig");
const pipeline = @import("pipeline.zig");
const prepared_surface_owner = @import("prepared_surface_owner.zig");
const queue = @import("queue.zig");
const submit_feedback = @import("submit_feedback.zig");
const surface = @import("surface.zig");
const contract = @import("../text/contract.zig");
const text_pipeline = @import("../text/pipeline.zig");
const text = @import("../text/text.zig");
const text_support = @import("../text/font/ft_hb/support.zig");
const text_glyph_raster = @import("../text/font/ft_hb/glyph_raster.zig");

const max_font_faces = text_support.fallbackFontLen(text_support.max_fallback_fonts) + 1;

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

pub const SurfaceTextConfig = struct {
    surface_px: surface.PixelSize,
    font_size_px: u16 = 16,
    font_path: ?[:0]const u8 = null,
};

pub const SurfaceText = struct {
    allocator: std.mem.Allocator,
    text_state: text_support.State,
    mutex: ThreadMutex = .{},
    text_preparer: ?text.TextFramePreparer = null,

    const TextContext = struct {
        session: *SurfaceText,
        session_config: SurfaceTextConfig,
    };

    pub const FrameLayout = surface.SurfaceLayout;
    pub const PreparedTimings = surface.PrepareMetrics;
    pub const DamageKind = enum { partial, scroll, full };
    pub const SubmittedReport = surface.SurfaceExecutionReport;
    pub const RenderSurfaceExecutionInput = struct {
        surface: surface.RenderSurfaceHandle,
        uploads_committed: u64,
        render_us: u64,
    };
    pub const PrepareInput = struct {
        config: SurfaceTextConfig,
        request: pipeline.RenderRequest,
        layout: surface.PrepareLayout,
        state: queue.PublicationSource,
    };

    pub fn init(allocator: std.mem.Allocator) SurfaceText {
        return .{ .allocator = allocator, .text_state = text_support.State.init(allocator) };
    }

    pub fn deinit(self: *SurfaceText) void {
        lockMutex(&self.mutex);
        defer self.mutex.unlock();
        if (self.text_preparer) |*preparer| {
            preparer.deinit();
            self.text_preparer = null;
        }
        self.text_state.deinit();
    }

    pub fn deriveFrameLayout(
        self: *SurfaceText,
        config: SurfaceTextConfig,
        render_px: surface.PixelSize,
        grid_px: surface.PixelSize,
    ) geometry_mod.FrameGeometryError!FrameLayout {
        lockMutex(&self.mutex);
        defer self.mutex.unlock();
        if (render_px.width == 0 or render_px.height == 0) return error.InvalidSurfaceSize;
        if (grid_px.width == 0 or grid_px.height == 0) return error.InvalidGridSize;
        var context = TextContext{ .session = self, .session_config = config };
        const cell_px = text_support.deriveCellSize(&context);
        const layout = surface.SurfaceLayout{ .cell_px = cell_px, .grid = geometry_mod.deriveGridSize(grid_px, cell_px) };
        return .{ .cell_px = layout.cell_px, .grid = layout.grid };
    }

    pub fn isValidFont(self: *SurfaceText, config: SurfaceTextConfig) bool {
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

    pub fn prepareSurface(self: *SurfaceText, prepare: PrepareInput) !surface.PreparedSurface {
        var faces: [max_font_faces]text.FontSession.FontFaceRecord = undefined;
        var context = TextContext{ .session = self, .session_config = prepare.config };
        lockMutex(&self.mutex);
        errdefer self.mutex.unlock();
        var text_input = try input.publicationSourceToTextSceneInput(self.allocator, prepare.state, prepare.request.token.damage_kind == .full);
        defer text_input.deinit();
        var resolve: text_pipeline.ResolveObservability = .{};
        const preparer = try self.ensureTextPreparer(&context);
        var prepared = try preparer.prepareCellsWithSessionOptions(text_input.cells, text_input.grid, fontSession(&context, &faces, &resolve), text_input.options);
        errdefer prepared.deinit();
        const owned = ownPreparedSurface(self.allocator, prepare, text_input.grid, prepared, resolve);
        self.mutex.unlock();
        return owned;
    }

    pub fn submitSurface(self: *SurfaceText, prepared: *surface.PreparedSurface, execution: RenderSurfaceExecutionInput) !surface.RenderSurfaceFeedback {
        lockMutex(&self.mutex);
        errdefer self.mutex.unlock();
        submit_feedback.markRendered(&self.text_preparer.?.atlas, prepared.text_frame.raster_plan.outputs);
        const submitted = surface.RenderSurfaceFeedback{
            .damage_kind = submit_feedback.damageKind(prepared),
            .uploads_committed = execution.uploads_committed,
            .resolve = prepared.resolve,
            .surface = execution.surface,
            .metrics = undefined,
            .render_us = execution.render_us,
        };
        var final = submitted;
        final.metrics = submit_feedback.renderMetrics(
            surface.RenderMetrics,
            prepared.prepare_metrics,
            prepared,
            final.uploads_committed,
            final.resolve.counters,
            final.render_us,
        );
        self.mutex.unlock();
        return final;
    }

    pub fn atlasRaster(self: *SurfaceText, key: contract.SpriteKey) ?text.AtlasCache.StoredRaster {
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
        resolve: text_pipeline.ResolveObservability,
    ) surface.PreparedSurface {
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

    fn ensureTextPreparer(self: *SurfaceText, context: *TextContext) !*text.TextFramePreparer {
        if (self.text_preparer == null) {
            var ft_hb = ftHbSource(context);
            self.text_preparer = try text.TextFramePreparer.initWithProvider(self.allocator, 2048, ft_hb.textProvider());
        }
        return &self.text_preparer.?;
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

    fn fontSession(context: *TextContext, faces: []text.FontSession.FontFaceRecord, active_resolve: ?*text_pipeline.ResolveObservability) text.FontSession.FontSession {
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

    fn providerRasterizeGlyphThunk(ctx: *anyopaque, allocator: std.mem.Allocator, req: text_pipeline.RasterizeRequest) anyerror!text_pipeline.RasterizeOutput {
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

    fn prepareMetrics(timings: text.PrepareTimings) surface.PrepareMetrics {
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

pub const SurfaceTextOwner = struct {
    allocator: std.mem.Allocator,
    session: SurfaceText,
    flow: queue.Flow,
    config: SurfaceTextConfig,
    prepared_publish_handle: abi.PreparedSurfaceHandle = null,
    prepared_submit_handle: abi.PreparedSurfaceHandle = null,
    font_path: ?[:0]u8 = null,
    fallback_font_paths: std.ArrayList([:0]u8) = .empty,
    retained_surface_pixels: []u8 = &.{},
    retained_surface_width: u16 = 0,
    retained_surface_height: u16 = 0,
    retained_surface_snapshot_seq: u64 = 0,

    pub const FontConfigError = error{ InvalidArgument, OutOfMemory };

    pub fn create(allocator: std.mem.Allocator, config: SurfaceTextConfig) ?*SurfaceTextOwner {
        std.debug.assert(config.font_size_px > 0);
        const owner = allocator.create(SurfaceTextOwner) catch return null;
        owner.* = .{ .allocator = allocator, .session = SurfaceText.init(allocator), .flow = queue.Flow.init(allocator), .config = config };
        return owner;
    }

    pub fn destroy(self: *SurfaceTextOwner) void {
        if (self.font_path) |path| self.allocator.free(path);
        self.font_path = null;
        freeOwnedFallbackFontPaths(self.allocator, &self.fallback_font_paths);
        self.flow.deinit();
        self.clearRetainedSurface();
        self.session.deinit();
        self.allocator.destroy(self);
    }

    pub fn setFontSizePx(self: *SurfaceTextOwner, font_size_px: u16) void {
        std.debug.assert(font_size_px > 0);
        self.config.font_size_px = font_size_px;
        self.invalidateTextState();
    }

    pub fn setFontPathBytes(self: *SurfaceTextOwner, bytes: ?[]const u8) FontConfigError!void {
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

    pub fn setFallbackFontPathPtrs(self: *SurfaceTextOwner, raw_paths: []const ?[*]const u8) FontConfigError!void {
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

    pub fn isValidFont(self: *SurfaceTextOwner) bool {
        return self.session.isValidFont(self.config);
    }

    pub fn prepareHandle(self: *SurfaceTextOwner, token: pipeline.SnapshotToken) !*prepared_surface_owner.Owner {
        const prepare = try self.flow.consumePrepare(token);
        var prepared = try self.session.prepareSurface(.{
            .config = self.config,
            .request = prepare.request,
            .layout = prepare.layout,
            .state = prepare.state,
        });
        errdefer prepared.deinit();
        return prepared_surface_owner.Owner.create(self, prepared);
    }

    pub fn invalidateTextState(self: *SurfaceTextOwner) void {
        text_support.resetLoadedFace(&self.session);
        self.session.text_state.face_text_cache.clear();
        self.session.text_state.shape_run_cache.clear();
        self.session.text_state.glyph_cell_cache.clear();
        if (self.session.text_preparer) |*preparer| preparer.clearAtlas();
        self.clearRetainedSurface();
    }

    pub fn setOwnedFontPath(self: *SurfaceTextOwner, owned: ?[:0]u8) void {
        if (owned) |path| std.debug.assert(path.len > 0);
        const old = self.font_path;
        self.font_path = owned;
        self.config.font_path = owned;
        self.invalidateTextState();
        if (old) |path| self.allocator.free(path);
    }

    pub fn adoptFallbackFontPaths(self: *SurfaceTextOwner, owned_paths: *std.ArrayList([:0]u8)) void {
        var old = self.fallback_font_paths;
        self.fallback_font_paths = owned_paths.*;
        owned_paths.* = .empty;
        self.syncFallbackFontPaths();
        self.invalidateTextState();
        freeOwnedFallbackFontPaths(self.allocator, &old);
    }

    pub fn requiredRetainedSurfaceBase(self: *const SurfaceTextOwner, prepared: *const surface.PreparedSurface) []const u8 {
        std.debug.assert(prepared.damageKind() == .partial);
        // Queue validation already proved that partial prepares must compose
        // against the last submitted full image from this render owner.
        std.debug.assert(self.retained_surface_snapshot_seq == prepared.pipelineFrame().required_base_seq);
        std.debug.assert(self.retained_surface_width == prepared.render_px.width);
        std.debug.assert(self.retained_surface_height == prepared.render_px.height);
        const pixels_len: u64 = @as(u64, prepared.render_px.width) * @as(u64, prepared.render_px.height) * 4;
        const retained_len: u64 = @intCast(self.retained_surface_pixels.len);
        std.debug.assert(retained_len == pixels_len);
        return self.retained_surface_pixels;
    }

    pub fn retainSurfaceImage(self: *SurfaceTextOwner, pixels: *[]u8, width: u16, height: u16, snapshot_seq: u64) void {
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

    pub fn clearRetainedSurface(self: *SurfaceTextOwner) void {
        if (self.retained_surface_pixels.len > 0) self.allocator.free(self.retained_surface_pixels);
        self.retained_surface_pixels = &.{};
        self.retained_surface_width = 0;
        self.retained_surface_height = 0;
        self.retained_surface_snapshot_seq = 0;
    }

    fn syncFallbackFontPaths(self: *SurfaceTextOwner) void {
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

test "retainSurfaceImage adopts full image for later partial prepares" {
    var owner = SurfaceTextOwner{
        .allocator = std.heap.c_allocator,
        .session = SurfaceText.init(std.heap.c_allocator),
        .flow = queue.Flow.init(std.heap.c_allocator),
        .config = .{ .surface_px = .{ .width = 2, .height = 3 } },
    };
    defer owner.clearRetainedSurface();
    defer owner.flow.deinit();
    defer owner.session.deinit();

    const pixels = try std.heap.c_allocator.alloc(u8, 2 * 3 * 4);
    for (pixels, 0..) |*pixel, i| pixel.* = @intCast(i);
    var owned_pixels = pixels;
    owner.retainSurfaceImage(&owned_pixels, 2, 3, 1);

    try std.testing.expect(owned_pixels.len == 0);
    try std.testing.expectEqual(@as(u16, 2), owner.retained_surface_width);
    try std.testing.expectEqual(@as(u16, 3), owner.retained_surface_height);
    try std.testing.expectEqual(@as(u64, 1), owner.retained_surface_snapshot_seq);

    const prepared = surface.PreparedSurface{
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

test "invalidateTextState clears retained image state" {
    var owner = SurfaceTextOwner{
        .allocator = std.heap.c_allocator,
        .session = SurfaceText.init(std.heap.c_allocator),
        .flow = queue.Flow.init(std.heap.c_allocator),
        .config = .{ .surface_px = .{ .width = 1, .height = 1 } },
    };
    defer owner.clearRetainedSurface();
    defer owner.flow.deinit();
    defer owner.session.deinit();

    const pixels = try std.heap.c_allocator.alloc(u8, 4);
    @memset(pixels, 9);
    var owned_pixels = pixels;
    owner.retainSurfaceImage(&owned_pixels, 1, 1, 1);

    owner.invalidateTextState();

    try std.testing.expect(owner.retained_surface_pixels.len == 0);
    try std.testing.expectEqual(@as(u16, 0), owner.retained_surface_width);
    try std.testing.expectEqual(@as(u16, 0), owner.retained_surface_height);
    try std.testing.expectEqual(@as(u64, 0), owner.retained_surface_snapshot_seq);
}

test "setOwnedFontPath keeps owner and config font paths aligned" {
    const owner = SurfaceTextOwner.create(std.heap.c_allocator, .{ .surface_px = .{ .width = 1, .height = 1 } }) orelse return error.OutOfMemory;
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
    const owner = SurfaceTextOwner.create(std.heap.c_allocator, .{ .surface_px = .{ .width = 1, .height = 1 } }) orelse return error.OutOfMemory;
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
    const owner = SurfaceTextOwner.create(std.heap.c_allocator, .{ .surface_px = .{ .width = 1, .height = 1 } }) orelse return error.OutOfMemory;
    defer owner.destroy();

    var overflow_paths: [text_support.max_fallback_fonts + 1]?[*]const u8 = [_]?[*]const u8{"font".ptr} ** (text_support.max_fallback_fonts + 1);
    try std.testing.expectError(error.InvalidArgument, owner.setFallbackFontPathPtrs(&overflow_paths));

    const bad_paths = [_]?[*]const u8{null};
    try std.testing.expectError(error.InvalidArgument, owner.setFallbackFontPathPtrs(&bad_paths));
}
