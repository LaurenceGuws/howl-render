const std = @import("std");

const c = @import("../ffi.zig").c;
const contract = @import("../text/contract.zig");
const geometry_contract = @import("../geometry/geometry_contract.zig");
const prepared_buffer = @import("buffer.zig");
const prepared_surface = @import("surface.zig");
const realize = @import("../geometry/render_surface_realizer.zig");
const sprite_resource_store = @import("sprite_resource_store.zig");
const rasterizer = @import("../text/raster/rasterizer.zig");
const text_session = @import("../session/text.zig");

const ResourceId = c.HowlRenderResourceId;
const Rect = c.HowlRenderSurfaceRect;
const GlyphRef = c.HowlRenderGlyphRef;
pub const Surface = c.HowlRenderSurface;
const SpriteResourceStore = sprite_resource_store.SpriteResourceStore;

// Glyph refs are data-plane payload; commands are control-plane payload.
const glyph_refs_max: u32 = 32 * 1024;
const PreparedSprite = sprite_resource_store.PreparedSprite;

fn monotonicNs() u64 {
    var ts: std.posix.timespec = undefined;
    if (std.posix.errno(std.posix.system.clock_gettime(.MONOTONIC, &ts)) != .SUCCESS) return 0;
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

const DebugEmitPreparedTiming = struct {
    enabled_known: bool = false,
    enabled: bool = false,
    count: u64 = 0,
    copy_in_ns_total: u64 = 0,
    fills_ns_total: u64 = 0,
    full_redraw_clear_ns_total: u64 = 0,
    clear_pass_ns_total: u64 = 0,
    background_pass_ns_total: u64 = 0,
    decoration_pass_ns_total: u64 = 0,
    cursor_pass_ns_total: u64 = 0,
    sprites_ns_total: u64 = 0,
    publish_ns_total: u64 = 0,
    publish_glyph_fixup_ns_total: u64 = 0,
    publish_upload_fixup_ns_total: u64 = 0,
    publish_surface_spans_ns_total: u64 = 0,
    copy_out_ns_total: u64 = 0,
    stage_upload_ns_total: u64 = 0,
    atlas_resource_ns_total: u64 = 0,
    direct_resource_ns_total: u64 = 0,
    sprite_lookup_ns_total: u64 = 0,
    alpha_glyph_append_ns_total: u64 = 0,
    direct_command_append_ns_total: u64 = 0,
    transient_retire_ns_total: u64 = 0,
    sprite_count_total: u64 = 0,
    alpha_sprite_count_total: u64 = 0,
    copy_in_ns_max: u64 = 0,
    fills_ns_max: u64 = 0,
    full_redraw_clear_ns_max: u64 = 0,
    clear_pass_ns_max: u64 = 0,
    background_pass_ns_max: u64 = 0,
    decoration_pass_ns_max: u64 = 0,
    cursor_pass_ns_max: u64 = 0,
    sprites_ns_max: u64 = 0,
    publish_ns_max: u64 = 0,
    publish_glyph_fixup_ns_max: u64 = 0,
    publish_upload_fixup_ns_max: u64 = 0,
    publish_surface_spans_ns_max: u64 = 0,
    copy_out_ns_max: u64 = 0,
    stage_upload_ns_max: u64 = 0,
    atlas_resource_ns_max: u64 = 0,
    direct_resource_ns_max: u64 = 0,
    sprite_lookup_ns_max: u64 = 0,
    alpha_glyph_append_ns_max: u64 = 0,
    direct_command_append_ns_max: u64 = 0,
    transient_retire_ns_max: u64 = 0,

    const SpriteTotals = struct {
        stage_upload_ns: u64 = 0,
        atlas_resource_ns: u64 = 0,
        direct_resource_ns: u64 = 0,
        lookup_ns: u64 = 0,
        alpha_glyph_append_ns: u64 = 0,
        direct_command_append_ns: u64 = 0,
        transient_retire_ns: u64 = 0,
        sprite_count: u32 = 0,
        alpha_sprite_count: u32 = 0,
    };

    const FillTotals = struct {
        full_redraw_clear_ns: u64 = 0,
        clear_pass_ns: u64 = 0,
        background_pass_ns: u64 = 0,
        decoration_pass_ns: u64 = 0,
        cursor_pass_ns: u64 = 0,
    };

    const PublishTotals = struct {
        glyph_fixup_ns: u64 = 0,
        upload_fixup_ns: u64 = 0,
        surface_spans_ns: u64 = 0,
    };

    fn active(self: *DebugEmitPreparedTiming) bool {
        if (!self.enabled_known) {
            self.enabled = std.c.getenv("HOWL_RENDER_DEBUG_TIMING") != null;
            self.enabled_known = true;
        }
        return self.enabled;
    }

    fn record(self: *DebugEmitPreparedTiming, copy_in_ns: u64, fills_ns: u64, sprites_ns: u64, publish_ns: u64, copy_out_ns: u64, fill_totals: FillTotals, sprite_totals: SpriteTotals, publish_totals: PublishTotals) void {
        if (!self.active()) return;
        self.count += 1;
        self.copy_in_ns_total += copy_in_ns;
        self.fills_ns_total += fills_ns;
        self.full_redraw_clear_ns_total += fill_totals.full_redraw_clear_ns;
        self.clear_pass_ns_total += fill_totals.clear_pass_ns;
        self.background_pass_ns_total += fill_totals.background_pass_ns;
        self.decoration_pass_ns_total += fill_totals.decoration_pass_ns;
        self.cursor_pass_ns_total += fill_totals.cursor_pass_ns;
        self.sprites_ns_total += sprites_ns;
        self.publish_ns_total += publish_ns;
        self.publish_glyph_fixup_ns_total += publish_totals.glyph_fixup_ns;
        self.publish_upload_fixup_ns_total += publish_totals.upload_fixup_ns;
        self.publish_surface_spans_ns_total += publish_totals.surface_spans_ns;
        self.copy_out_ns_total += copy_out_ns;
        self.stage_upload_ns_total += sprite_totals.stage_upload_ns;
        self.atlas_resource_ns_total += sprite_totals.atlas_resource_ns;
        self.direct_resource_ns_total += sprite_totals.direct_resource_ns;
        self.sprite_lookup_ns_total += sprite_totals.lookup_ns;
        self.alpha_glyph_append_ns_total += sprite_totals.alpha_glyph_append_ns;
        self.direct_command_append_ns_total += sprite_totals.direct_command_append_ns;
        self.transient_retire_ns_total += sprite_totals.transient_retire_ns;
        self.sprite_count_total += sprite_totals.sprite_count;
        self.alpha_sprite_count_total += sprite_totals.alpha_sprite_count;
        self.copy_in_ns_max = @max(self.copy_in_ns_max, copy_in_ns);
        self.fills_ns_max = @max(self.fills_ns_max, fills_ns);
        self.full_redraw_clear_ns_max = @max(self.full_redraw_clear_ns_max, fill_totals.full_redraw_clear_ns);
        self.clear_pass_ns_max = @max(self.clear_pass_ns_max, fill_totals.clear_pass_ns);
        self.background_pass_ns_max = @max(self.background_pass_ns_max, fill_totals.background_pass_ns);
        self.decoration_pass_ns_max = @max(self.decoration_pass_ns_max, fill_totals.decoration_pass_ns);
        self.cursor_pass_ns_max = @max(self.cursor_pass_ns_max, fill_totals.cursor_pass_ns);
        self.sprites_ns_max = @max(self.sprites_ns_max, sprites_ns);
        self.publish_ns_max = @max(self.publish_ns_max, publish_ns);
        self.publish_glyph_fixup_ns_max = @max(self.publish_glyph_fixup_ns_max, publish_totals.glyph_fixup_ns);
        self.publish_upload_fixup_ns_max = @max(self.publish_upload_fixup_ns_max, publish_totals.upload_fixup_ns);
        self.publish_surface_spans_ns_max = @max(self.publish_surface_spans_ns_max, publish_totals.surface_spans_ns);
        self.copy_out_ns_max = @max(self.copy_out_ns_max, copy_out_ns);
        self.stage_upload_ns_max = @max(self.stage_upload_ns_max, sprite_totals.stage_upload_ns);
        self.atlas_resource_ns_max = @max(self.atlas_resource_ns_max, sprite_totals.atlas_resource_ns);
        self.direct_resource_ns_max = @max(self.direct_resource_ns_max, sprite_totals.direct_resource_ns);
        self.sprite_lookup_ns_max = @max(self.sprite_lookup_ns_max, sprite_totals.lookup_ns);
        self.alpha_glyph_append_ns_max = @max(self.alpha_glyph_append_ns_max, sprite_totals.alpha_glyph_append_ns);
        self.direct_command_append_ns_max = @max(self.direct_command_append_ns_max, sprite_totals.direct_command_append_ns);
        self.transient_retire_ns_max = @max(self.transient_retire_ns_max, sprite_totals.transient_retire_ns);
        if (self.count % 128 != 0) return;
        std.debug.print(
            "howl-render-debug emit_prepared count={} copy_in_avg_us={} fills_avg_us={} full_redraw_clear_avg_us={} clear_pass_avg_us={} background_pass_avg_us={} decoration_pass_avg_us={} cursor_pass_avg_us={} sprites_avg_us={} sprite_lookup_avg_us={} stage_upload_avg_us={} atlas_resource_avg_us={} direct_resource_avg_us={} alpha_glyph_append_avg_us={} direct_command_append_avg_us={} transient_retire_avg_us={} publish_avg_us={} publish_glyph_fixup_avg_us={} publish_upload_fixup_avg_us={} publish_surface_spans_avg_us={} copy_out_avg_us={} sprites_avg={} alpha_sprites_avg={}\n",
            .{
                self.count,
                self.copy_in_ns_total / self.count / std.time.ns_per_us,
                self.fills_ns_total / self.count / std.time.ns_per_us,
                self.full_redraw_clear_ns_total / self.count / std.time.ns_per_us,
                self.clear_pass_ns_total / self.count / std.time.ns_per_us,
                self.background_pass_ns_total / self.count / std.time.ns_per_us,
                self.decoration_pass_ns_total / self.count / std.time.ns_per_us,
                self.cursor_pass_ns_total / self.count / std.time.ns_per_us,
                self.sprites_ns_total / self.count / std.time.ns_per_us,
                self.sprite_lookup_ns_total / self.count / std.time.ns_per_us,
                self.stage_upload_ns_total / self.count / std.time.ns_per_us,
                self.atlas_resource_ns_total / self.count / std.time.ns_per_us,
                self.direct_resource_ns_total / self.count / std.time.ns_per_us,
                self.alpha_glyph_append_ns_total / self.count / std.time.ns_per_us,
                self.direct_command_append_ns_total / self.count / std.time.ns_per_us,
                self.transient_retire_ns_total / self.count / std.time.ns_per_us,
                self.publish_ns_total / self.count / std.time.ns_per_us,
                self.publish_glyph_fixup_ns_total / self.count / std.time.ns_per_us,
                self.publish_upload_fixup_ns_total / self.count / std.time.ns_per_us,
                self.publish_surface_spans_ns_total / self.count / std.time.ns_per_us,
                self.copy_out_ns_total / self.count / std.time.ns_per_us,
                self.sprite_count_total / self.count,
                self.alpha_sprite_count_total / self.count,
            },
        );
    }
};

var debug_emit_prepared_timing: DebugEmitPreparedTiming = .{};

comptime {
    std.debug.assert(glyph_refs_max > c.HOWL_RENDER_SURFACE_COMMANDS_MAX);
    std.debug.assert(glyph_refs_max <=
        c.HOWL_RENDER_SURFACE_COMMANDS_MAX * c.HOWL_RENDER_SURFACE_GLYPHS_PER_RUN_MAX);
}

pub const Error = error{
    CommandBoundOverflow,
    CreateBoundOverflow,
    DamageBoundOverflow,
    RetireBoundOverflow,
    ResourceBoundOverflow,
    UploadBoundOverflow,
    UploadBytesOverflow,
    InvalidPreparedSprite,
    MissingPreparedSprite,
};

pub const RenderSurfaceEmissionFailure = enum {
    none,
    allocation_failed,
    command_bound_overflow,
    create_bound_overflow,
    damage_bound_overflow,
    retire_bound_overflow,
    resource_bound_overflow,
    upload_bound_overflow,
    upload_bytes_overflow,
    invalid_prepared_sprite,
    missing_prepared_sprite,
};

pub fn emissionFailureFromError(err: Error) RenderSurfaceEmissionFailure {
    return switch (err) {
        error.CommandBoundOverflow => .command_bound_overflow,
        error.CreateBoundOverflow => .create_bound_overflow,
        error.DamageBoundOverflow => .damage_bound_overflow,
        error.RetireBoundOverflow => .retire_bound_overflow,
        error.ResourceBoundOverflow => .resource_bound_overflow,
        error.UploadBoundOverflow => .upload_bound_overflow,
        error.UploadBytesOverflow => .upload_bytes_overflow,
        error.InvalidPreparedSprite => .invalid_prepared_sprite,
        error.MissingPreparedSprite => .missing_prepared_sprite,
    };
}

pub const Limits = struct {
    damage_max: u32 = c.HOWL_RENDER_SURFACE_DAMAGE_ITEMS_MAX,
    creates_max: u32 = c.HOWL_RENDER_SURFACE_CREATES_MAX,
    uploads_max: u32 = c.HOWL_RENDER_SURFACE_UPLOADS_MAX,
    commands_max: u32 = c.HOWL_RENDER_SURFACE_COMMANDS_MAX,
    glyph_refs_max: u32 = glyph_refs_max,
    retires_max: u32 = c.HOWL_RENDER_SURFACE_RETIRES_MAX,
    upload_bytes_max: u32 = c.HOWL_RENDER_SURFACE_UPLOAD_BYTES_MAX,

    pub fn assertValid(comptime limits: Limits) void {
        std.debug.assert(limits.damage_max <= c.HOWL_RENDER_SURFACE_DAMAGE_ITEMS_MAX);
        std.debug.assert(limits.creates_max <= c.HOWL_RENDER_SURFACE_CREATES_MAX);
        std.debug.assert(limits.uploads_max <= c.HOWL_RENDER_SURFACE_UPLOADS_MAX);
        std.debug.assert(limits.commands_max <= c.HOWL_RENDER_SURFACE_COMMANDS_MAX);
        std.debug.assert(limits.glyph_refs_max <=
            c.HOWL_RENDER_SURFACE_COMMANDS_MAX * c.HOWL_RENDER_SURFACE_GLYPHS_PER_RUN_MAX);
        std.debug.assert(limits.glyph_refs_max >= limits.commands_max);
        std.debug.assert(limits.retires_max <= c.HOWL_RENDER_SURFACE_RETIRES_MAX);
        std.debug.assert(limits.upload_bytes_max <= c.HOWL_RENDER_SURFACE_UPLOAD_BYTES_MAX);
    }
};

pub fn Emitter(comptime limits: Limits) type {
    comptime limits.assertValid();

    return struct {
        damage: [limits.damage_max]c.HowlRenderSurfaceDamageItem = undefined,
        creates: [limits.creates_max]c.HowlRenderResourceCreate = undefined,
        uploads: [limits.uploads_max]c.HowlRenderResourceUpload = undefined,
        upload_byte_offsets: [limits.uploads_max]u32 = undefined,
        commands: [limits.commands_max]c.HowlRenderSurfaceCommand = undefined,
        glyphs: [limits.glyph_refs_max]GlyphRef = undefined,
        retires: [limits.retires_max]c.HowlRenderResourceRetire = undefined,
        upload_bytes: [limits.upload_bytes_max]u8 = undefined,
        damage_count: u32 = 0,
        create_count: u32 = 0,
        upload_count: u32 = 0,
        command_count: u32 = 0,
        glyph_count: u32 = 0,
        retire_count: u32 = 0,
        upload_bytes_count: u32 = 0,
        surface_storage: Surface = emptySurface(),

        const Self = @This();

        pub fn init() Self {
            return .{};
        }

        pub fn surface(self: *const Self) *const Surface {
            return &self.surface_storage;
        }

        pub fn emitPrepared(self: *Self, resources: *SpriteResourceStore, session: *text_session.TextSession, prepared: *const prepared_surface.PreparedSurface) Error!*const Surface {
            const copy_in_start_ns = monotonicNs();
            var next = self.*;
            var next_resources = resources.*;
            const copy_in_ns = monotonicNs() -| copy_in_start_ns;
            next.resetPrepared(prepared);
            var fill_totals: DebugEmitPreparedTiming.FillTotals = .{};
            var fill_step_start_ns = monotonicNs();
            try next.appendFullDamage(pixelSizeOut(prepared.render_px));
            fill_totals.full_redraw_clear_ns += monotonicNs() -| fill_step_start_ns;
            fill_step_start_ns = monotonicNs();
            try next.appendPreparedFullRedrawClear(prepared);
            fill_totals.full_redraw_clear_ns += monotonicNs() -| fill_step_start_ns;
            fill_step_start_ns = monotonicNs();
            try next.appendPreparedClears(prepared.text_surface.scene.scene.clear_draws);
            fill_totals.clear_pass_ns = monotonicNs() -| fill_step_start_ns;
            fill_step_start_ns = monotonicNs();
            try next.appendPreparedBackgrounds(prepared.text_surface.scene.scene.background_draws);
            fill_totals.background_pass_ns = monotonicNs() -| fill_step_start_ns;
            fill_step_start_ns = monotonicNs();
            try next.appendPreparedDecorations(prepared.text_surface.scene.scene.decoration_draws);
            fill_totals.decoration_pass_ns = monotonicNs() -| fill_step_start_ns;
            var sprite_totals: DebugEmitPreparedTiming.SpriteTotals = .{};
            const sprites_start_ns = monotonicNs();
            try next.appendPreparedSprites(&next_resources, session, prepared, &sprite_totals);
            const sprites_ns = monotonicNs() -| sprites_start_ns;
            fill_step_start_ns = monotonicNs();
            try next.appendPreparedCursors(prepared.text_surface.scene.scene.cursor_draws);
            fill_totals.cursor_pass_ns = monotonicNs() -| fill_step_start_ns;
            const fills_ns = fill_totals.full_redraw_clear_ns + fill_totals.clear_pass_ns + fill_totals.background_pass_ns + fill_totals.decoration_pass_ns + fill_totals.cursor_pass_ns;
            const copy_out_start_ns = monotonicNs();
            self.* = next;
            resources.* = next_resources;
            const copy_out_ns = monotonicNs() -| copy_out_start_ns;
            const publish_start_ns = monotonicNs();
            const publish_totals = self.publishSurface();
            debug_emit_prepared_timing.record(copy_in_ns, fills_ns, sprites_ns, monotonicNs() -| publish_start_ns, copy_out_ns, fill_totals, sprite_totals, publish_totals);
            return &self.surface_storage;
        }

        pub fn emitPreparedFresh(self: *Self, resources: *SpriteResourceStore, session: *text_session.TextSession, prepared: *const prepared_surface.PreparedSurface) Error!*const Surface {
            const resource_rollback = resources.admissionRollback();
            errdefer resources.restoreAdmission(resource_rollback);
            const copy_in_ns: u64 = 0;
            self.resetPrepared(prepared);
            var fill_totals: DebugEmitPreparedTiming.FillTotals = .{};
            var fill_step_start_ns = monotonicNs();
            try self.appendFullDamage(pixelSizeOut(prepared.render_px));
            fill_totals.full_redraw_clear_ns += monotonicNs() -| fill_step_start_ns;
            fill_step_start_ns = monotonicNs();
            try self.appendPreparedFullRedrawClear(prepared);
            fill_totals.full_redraw_clear_ns += monotonicNs() -| fill_step_start_ns;
            fill_step_start_ns = monotonicNs();
            try self.appendPreparedClears(prepared.text_surface.scene.scene.clear_draws);
            fill_totals.clear_pass_ns = monotonicNs() -| fill_step_start_ns;
            fill_step_start_ns = monotonicNs();
            try self.appendPreparedBackgrounds(prepared.text_surface.scene.scene.background_draws);
            fill_totals.background_pass_ns = monotonicNs() -| fill_step_start_ns;
            fill_step_start_ns = monotonicNs();
            try self.appendPreparedDecorations(prepared.text_surface.scene.scene.decoration_draws);
            fill_totals.decoration_pass_ns = monotonicNs() -| fill_step_start_ns;
            var sprite_totals: DebugEmitPreparedTiming.SpriteTotals = .{};
            const sprites_start_ns = monotonicNs();
            try self.appendPreparedSprites(resources, session, prepared, &sprite_totals);
            const sprites_ns = monotonicNs() -| sprites_start_ns;
            fill_step_start_ns = monotonicNs();
            try self.appendPreparedCursors(prepared.text_surface.scene.scene.cursor_draws);
            fill_totals.cursor_pass_ns = monotonicNs() -| fill_step_start_ns;
            const fills_ns = fill_totals.full_redraw_clear_ns + fill_totals.clear_pass_ns + fill_totals.background_pass_ns + fill_totals.decoration_pass_ns + fill_totals.cursor_pass_ns;
            const copy_out_ns: u64 = 0;
            const publish_start_ns = monotonicNs();
            const publish_totals = self.publishSurface();
            debug_emit_prepared_timing.record(copy_in_ns, fills_ns, sprites_ns, monotonicNs() -| publish_start_ns, copy_out_ns, fill_totals, sprite_totals, publish_totals);
            return &self.surface_storage;
        }

        fn resetPrepared(self: *Self, prepared: *const prepared_surface.PreparedSurface) void {
            self.damage_count = 0;
            self.create_count = 0;
            self.upload_count = 0;
            self.command_count = 0;
            self.glyph_count = 0;
            self.retire_count = 0;
            self.upload_bytes_count = 0;
            self.surface_storage = emptySurface();
            self.surface_storage.token = .{
                .snapshot_seq = prepared.request.token.snapshot_seq,
                .surface_seq = prepared.request.token.dirty_epoch,
                .geometry_epoch = prepared.geometry_epoch,
                .resource_epoch = 0,
            };
            self.surface_storage.render_px = pixelSizeOut(prepared.render_px);
            self.surface_storage.cell_px = cellSizeOut(prepared.cell_px);
            self.surface_storage.grid = gridSizeOut(prepared.grid);
            std.debug.assert(self.damage_count == 0);
            std.debug.assert(self.create_count == 0);
            std.debug.assert(self.upload_count == 0);
            std.debug.assert(self.command_count == 0);
            std.debug.assert(self.glyph_count == 0);
            std.debug.assert(self.retire_count == 0);
            std.debug.assert(self.upload_bytes_count == 0);
            std.debug.assert(self.surface_storage.surface_version == c.HOWL_RENDER_SURFACE_VERSION);
            std.debug.assert(self.surface_storage.damage.ptr == null);
            std.debug.assert(self.surface_storage.creates.ptr == null);
            std.debug.assert(self.surface_storage.uploads.ptr == null);
            std.debug.assert(self.surface_storage.commands.ptr == null);
            std.debug.assert(self.surface_storage.retires.ptr == null);
        }

        fn appendFullDamage(self: *Self, render_px: c.HowlRenderPixelSize) Error!void {
            if (self.damage_count >= limits.damage_max) return error.DamageBoundOverflow;
            self.damage[self.damage_count] = .{
                .kind = c.HOWL_RENDER_SURFACE_DAMAGE_FULL,
                .reserved0 = 0,
                .reserved1 = 0,
                .rect = .{
                    .x_px = 0,
                    .y_px = 0,
                    .width_px = render_px.width,
                    .height_px = render_px.height,
                },
            };
            self.damage_count += 1;
        }

        fn appendPreparedFullRedrawClear(self: *Self, prepared: *const prepared_surface.PreparedSurface) Error!void {
            if (prepared.damageKind() != .full) return;
            try self.appendCommand(.{
                .kind = c.HOWL_RENDER_SURFACE_COMMAND_CLEAR_RECT,
                .reserved0 = 0,
                .reserved1 = 0,
                .rect = .{
                    .x_px = 0,
                    .y_px = 0,
                    .width_px = prepared.render_px.width,
                    .height_px = prepared.render_px.height,
                },
                .color_rgba = packRgba(.{ .r = 0, .g = 0, .b = 0, .a = 255 }),
                .resource = zeroResource(),
                .glyphs = emptyGlyphs(),
            });
        }

        fn appendPreparedFillPass(self: *Self, draws: anytype, kind: u8) Error!void {
            for (draws) |draw| try self.appendPreparedFillCommand(
                draw.x_px,
                draw.y_px,
                draw.width_px,
                draw.height_px,
                draw.color,
                kind,
            );
        }

        fn appendPreparedClears(self: *Self, draws: []const contract.TextClearDraw) Error!void {
            try self.appendPreparedFillPass(draws, c.HOWL_RENDER_SURFACE_COMMAND_CLEAR_RECT);
        }

        fn appendPreparedBackgrounds(self: *Self, draws: []const contract.TextBackgroundDraw) Error!void {
            try self.appendPreparedFillPass(draws, c.HOWL_RENDER_SURFACE_COMMAND_FILL_RECT);
        }

        fn appendPreparedDecorations(self: *Self, draws: []const contract.TextDecorationDraw) Error!void {
            try self.appendPreparedFillPass(draws, c.HOWL_RENDER_SURFACE_COMMAND_FILL_RECT);
        }

        fn appendPreparedCursors(self: *Self, draws: []const contract.TextCursorDraw) Error!void {
            try self.appendPreparedFillPass(draws, c.HOWL_RENDER_SURFACE_COMMAND_FILL_RECT);
        }

        fn appendPreparedFillCommand(self: *Self, x_px: i32, y_px: i32, width_px: u16, height_px: u16, color: contract.Rgba8, kind: u8) Error!void {
            if (width_px == 0) return;
            if (height_px == 0) return;
            const clipped = clippedFillRect(self.surface_storage.render_px, x_px, y_px, width_px, height_px) orelse return;
            const command = c.HowlRenderSurfaceCommand{
                .kind = kind,
                .reserved0 = 0,
                .reserved1 = 0,
                .rect = clipped,
                .color_rgba = packRgba(color),
                .resource = zeroResource(),
                .glyphs = emptyGlyphs(),
            };
            if (self.tryMergePreparedFillCommand(command)) return;
            try self.appendCommand(command);
        }

        fn clippedFillRect(render_px: c.HowlRenderPixelSize, x_px: i32, y_px: i32, width_px: u16, height_px: u16) ?Rect {
            const x0 = @max(x_px, 0);
            const y0 = @max(y_px, 0);
            const x1 = @min(std.math.add(i32, x_px, width_px) catch return null, @as(i32, render_px.width));
            const y1 = @min(std.math.add(i32, y_px, height_px) catch return null, @as(i32, render_px.height));
            if (x1 <= x0) return null;
            if (y1 <= y0) return null;
            return .{
                .x_px = x0,
                .y_px = y0,
                .width_px = @intCast(x1 - x0),
                .height_px = @intCast(y1 - y0),
            };
        }

        fn destinationOverlaps(render_px: c.HowlRenderPixelSize, x_px: i32, y_px: i32, width_px: u16, height_px: u16) bool {
            const right = std.math.add(i32, x_px, width_px) catch return false;
            const bottom = std.math.add(i32, y_px, height_px) catch return false;
            if (right <= 0) return false;
            if (bottom <= 0) return false;
            if (x_px >= render_px.width) return false;
            if (y_px >= render_px.height) return false;
            return true;
        }

        fn tryMergePreparedFillCommand(self: *Self, command: c.HowlRenderSurfaceCommand) bool {
            if (self.command_count == 0) return false;
            const prior = &self.commands[self.command_count - 1];
            if (prior.kind != command.kind) return false;
            if (prior.color_rgba != command.color_rgba) return false;
            if (prior.rect.y_px != command.rect.y_px) return false;
            if (prior.rect.height_px != command.rect.height_px) return false;
            if (prior.resource.value != 0 or command.resource.value != 0) return false;
            if (prior.glyphs.count != 0 or command.glyphs.count != 0) return false;
            const prior_end = std.math.add(i32, prior.rect.x_px, prior.rect.width_px) catch {
                return false;
            };
            if (prior_end != command.rect.x_px) return false;
            const merged_width = std.math.add(u32, prior.rect.width_px, command.rect.width_px) catch {
                return false;
            };
            if (merged_width > std.math.maxInt(u16)) return false;
            prior.rect.width_px = @intCast(merged_width);
            return true;
        }

        fn appendPreparedSprites(self: *Self, resources: *SpriteResourceStore, session: *text_session.TextSession, prepared: *const prepared_surface.PreparedSurface, sprite_totals: *DebugEmitPreparedTiming.SpriteTotals) Error!void {
            for (prepared.text_surface.scene.scene.sprite_draws) |draw| {
                sprite_totals.sprite_count += 1;
                const lookup_start_ns = monotonicNs();
                const sprite = lookupPreparedSprite(
                    session,
                    prepared,
                    draw.sprite.key,
                ) catch |err| {
                    return switch (err) {
                        error.MissingSprite => error.MissingPreparedSprite,
                    };
                };
                sprite_totals.lookup_ns += monotonicNs() -| lookup_start_ns;
                const bounds = visualBoundsForDraw(sprite.visual_bounds, draw);
                const width_px = @min(draw.width_px, bounds.width_px);
                const height_px = @min(draw.height_px, bounds.height_px);
                if (width_px == 0) return error.InvalidPreparedSprite;
                if (height_px == 0) return error.InvalidPreparedSprite;
                const dest_x = std.math.add(i32, draw.x_px, @intCast(bounds.x_px)) catch {
                    return error.InvalidPreparedSprite;
                };
                const dest_y = std.math.add(i32, draw.y_px, @intCast(bounds.y_px)) catch {
                    return error.InvalidPreparedSprite;
                };
                if (!destinationOverlaps(self.surface_storage.render_px, dest_x, dest_y, width_px, height_px)) continue;

                const upload_start = self.upload_bytes_count;
                if (sprite.color_mode == .alpha) {
                    sprite_totals.alpha_sprite_count += 1;
                    const atlas_start_ns = monotonicNs();
                    const atlas = try resources.atlasAdmissionForPrepared(
                        sprite,
                        bounds,
                        width_px,
                        height_px,
                    );
                    sprite_totals.atlas_resource_ns += monotonicNs() -| atlas_start_ns;
                    if (atlas.created) try self.appendGlyphAtlasCreate(atlas.resource);
                    if (atlas.uploaded) {
                        const upload_count_start = self.upload_count;
                        const upload_start_ns = monotonicNs();
                        const upload_range = try self.stagePreparedUploadBytes(
                            sprite,
                            bounds,
                            width_px,
                            height_px,
                        );
                        sprite_totals.stage_upload_ns += monotonicNs() -| upload_start_ns;
                        try self.appendPreparedAtlasUpload(
                            atlas.resource,
                            atlas.rect,
                            upload_range,
                        );
                        std.debug.assert(upload_range.start == upload_start);
                        std.debug.assert(self.upload_count == upload_count_start + 1);
                        std.debug.assert(self.upload_bytes_count == upload_range.end);
                    } else {
                        self.rollbackUploadBytes(upload_start);
                    }
                    std.debug.assert(atlas.resource.value != 0);
                    const alpha_append_start_ns = monotonicNs();
                    try self.appendGlyphRef(.{
                        .atlas_resource = atlas.resource,
                        .atlas_rect = atlas.rect,
                        .x_px = dest_x,
                        .y_px = dest_y,
                        .glyph_id = @intCast(draw.sprite.key.value & 0xffffffff),
                        .color_rgba = packRgba(draw.color),
                    });
                    sprite_totals.alpha_glyph_append_ns += monotonicNs() -| alpha_append_start_ns;
                    continue;
                }
                const resource_start_ns = monotonicNs();
                const result = try resources.resourceAdmissionForPrepared(
                    sprite,
                    bounds,
                    width_px,
                    height_px,
                );
                sprite_totals.direct_resource_ns += monotonicNs() -| resource_start_ns;
                switch (result.lifetime) {
                    .persistent, .transient => {
                        const upload_count_start = self.upload_count;
                        const upload_start_ns = monotonicNs();
                        const upload_range = try self.stagePreparedUploadBytes(
                            sprite,
                            bounds,
                            width_px,
                            height_px,
                        );
                        sprite_totals.stage_upload_ns += monotonicNs() -| upload_start_ns;
                        try self.appendPreparedCreate(result.resource, sprite, width_px, height_px);
                        try self.appendPreparedUpload(
                            result.resource,
                            sprite,
                            width_px,
                            height_px,
                            upload_range,
                        );
                        std.debug.assert(upload_range.start == upload_start);
                        std.debug.assert(self.upload_count == upload_count_start + 1);
                        std.debug.assert(self.upload_bytes_count == upload_range.end);
                    },
                    .reused => {
                        self.rollbackUploadBytes(upload_start);
                    },
                }
                std.debug.assert(result.resource.value != 0);
                const direct_command_start_ns = monotonicNs();
                try self.appendCommand(.{
                    .kind = c.HOWL_RENDER_SURFACE_COMMAND_DRAW_SPRITE,
                    .reserved0 = 0,
                    .reserved1 = 0,
                    .rect = .{
                        .x_px = dest_x,
                        .y_px = dest_y,
                        .width_px = width_px,
                        .height_px = height_px,
                    },
                    .color_rgba = if (sprite.color_mode == .alpha) packRgba(draw.color) else 0,
                    .resource = result.resource,
                    .glyphs = emptyGlyphs(),
                });
                sprite_totals.direct_command_append_ns += monotonicNs() -| direct_command_start_ns;
                if (result.lifetime == .transient) {
                    const retire_start_ns = monotonicNs();
                    try self.appendRetire(result.resource, self.command_count);
                    sprite_totals.transient_retire_ns += monotonicNs() -| retire_start_ns;
                }
            }
        }

        fn appendPreparedCreate(self: *Self, resource: ResourceId, sprite: PreparedSprite, width_px: u16, height_px: u16) Error!void {
            if (self.create_count >= limits.creates_max) return error.CreateBoundOverflow;
            self.creates[self.create_count] = .{
                .resource = resource,
                .width_px = width_px,
                .height_px = height_px,
                .format = sprite_resource_store.uploadFormatForPrepared(sprite.color_mode),
                .create_seq = 0,
            };
            self.create_count += 1;
        }

        fn appendGlyphAtlasCreate(self: *Self, resource: ResourceId) Error!void {
            if (self.create_count >= limits.creates_max) return error.CreateBoundOverflow;
            self.creates[self.create_count] = .{
                .resource = resource,
                .width_px = sprite_resource_store.glyph_atlas_width_px,
                .height_px = sprite_resource_store.glyph_atlas_height_px,
                .format = c.HOWL_RENDER_UPLOAD_ALPHA8,
                .create_seq = 0,
            };
            self.create_count += 1;
        }

        fn appendPreparedUpload(self: *Self, resource: ResourceId, sprite: PreparedSprite, width_px: u16, height_px: u16, upload_range: ByteRange) Error!void {
            if (self.upload_count >= limits.uploads_max) return error.UploadBoundOverflow;
            const bytes_per_pixel = sprite_resource_store.bytesPerPixelForPrepared(sprite.color_mode);
            const upload_stride = std.math.mul(u32, width_px, bytes_per_pixel) catch {
                return error.UploadBytesOverflow;
            };
            const bytes_count = std.math.mul(u32, upload_stride, height_px) catch {
                return error.UploadBytesOverflow;
            };
            std.debug.assert(upload_range.end == self.upload_bytes_count);
            std.debug.assert(upload_range.end - upload_range.start == bytes_count);
            self.uploads[self.upload_count] = .{
                .resource = resource,
                .rect = .{ .x_px = 0, .y_px = 0, .width_px = width_px, .height_px = height_px },
                .bytes_ptr = &self.upload_bytes[upload_range.start],
                .bytes_count = bytes_count,
                .stride_bytes = upload_stride,
                .format = sprite_resource_store.uploadFormatForPrepared(sprite.color_mode),
                .upload_seq = 0,
            };
            self.upload_byte_offsets[self.upload_count] = upload_range.start;
            self.upload_count += 1;
        }

        fn appendPreparedAtlasUpload(self: *Self, resource: ResourceId, atlas_rect: Rect, upload_range: ByteRange) Error!void {
            if (self.upload_count >= limits.uploads_max) return error.UploadBoundOverflow;
            const bytes_count = upload_range.end - upload_range.start;
            std.debug.assert(upload_range.end == self.upload_bytes_count);
            self.uploads[self.upload_count] = .{
                .resource = resource,
                .rect = atlas_rect,
                .bytes_ptr = &self.upload_bytes[upload_range.start],
                .bytes_count = bytes_count,
                .stride_bytes = atlas_rect.width_px,
                .format = c.HOWL_RENDER_UPLOAD_ALPHA8,
                .upload_seq = 0,
            };
            self.upload_byte_offsets[self.upload_count] = upload_range.start;
            self.upload_count += 1;
        }

        fn stagePreparedUploadBytes(self: *Self, sprite: PreparedSprite, bounds: rasterizer.SpriteBounds, width_px: u16, height_px: u16) Error!ByteRange {
            const bytes_per_pixel = sprite_resource_store.bytesPerPixelForPrepared(sprite.color_mode);
            const upload_stride = std.math.mul(u32, width_px, bytes_per_pixel) catch {
                return error.UploadBytesOverflow;
            };
            const bytes_count = std.math.mul(u32, upload_stride, height_px) catch {
                return error.UploadBytesOverflow;
            };
            const next_bytes_count = std.math.add(u32, self.upload_bytes_count, bytes_count) catch {
                return error.UploadBytesOverflow;
            };
            if (next_bytes_count > limits.upload_bytes_max) return error.UploadBytesOverflow;
            try copyPreparedSpriteBytes(
                self.upload_bytes[self.upload_bytes_count..next_bytes_count],
                upload_stride,
                sprite,
                bounds,
                width_px,
                height_px,
            );
            const range = ByteRange{ .start = self.upload_bytes_count, .end = next_bytes_count };
            self.upload_bytes_count = next_bytes_count;
            return range;
        }

        fn rollbackUploadBytes(self: *Self, upload_start: u32) void {
            std.debug.assert(upload_start <= self.upload_bytes_count);
            self.upload_bytes_count = upload_start;
            std.debug.assert(self.upload_bytes_count == upload_start);
        }

        fn appendCommand(self: *Self, command: c.HowlRenderSurfaceCommand) Error!void {
            if (self.command_count >= limits.commands_max) return error.CommandBoundOverflow;
            self.commands[self.command_count] = command;
            self.command_count += 1;
        }

        fn appendGlyphRef(self: *Self, glyph: GlyphRef) Error!void {
            if (self.glyph_count >= limits.glyph_refs_max) return error.CommandBoundOverflow;

            if (self.command_count > 0) {
                const prior = &self.commands[self.command_count - 1];
                if (prior.kind == c.HOWL_RENDER_SURFACE_COMMAND_DRAW_GLYPH_RUN) {
                    std.debug.assert(prior.glyphs.count > 0);
                    std.debug.assert(prior.glyphs.count <= c.HOWL_RENDER_SURFACE_GLYPHS_PER_RUN_MAX);
                    if (prior.glyphs.count < c.HOWL_RENDER_SURFACE_GLYPHS_PER_RUN_MAX) {
                        self.glyphs[@intCast(self.glyph_count)] = glyph;
                        self.glyph_count += 1;
                        prior.glyphs.count += 1;
                        return;
                    }
                }
            }

            if (self.command_count >= limits.commands_max) return error.CommandBoundOverflow;

            const start = self.glyph_count;
            self.glyphs[@intCast(self.glyph_count)] = glyph;
            self.glyph_count += 1;
            try self.appendCommand(.{
                .kind = c.HOWL_RENDER_SURFACE_COMMAND_DRAW_GLYPH_RUN,
                .reserved0 = 0,
                .reserved1 = 0,
                .rect = .{ .x_px = 0, .y_px = 0, .width_px = 0, .height_px = 0 },
                .color_rgba = 0,
                .resource = zeroResource(),
                .glyphs = .{
                    .ptr = &self.glyphs[@intCast(start)],
                    .count = 1,
                    .count_max = c.HOWL_RENDER_SURFACE_GLYPHS_PER_RUN_MAX,
                },
            });
        }

        fn appendRetire(self: *Self, resource: ResourceId, retire_seq: u32) Error!void {
            if (self.retire_count >= limits.retires_max) return error.RetireBoundOverflow;
            self.retires[self.retire_count] = .{
                .resource = resource,
                .retire_seq = retire_seq,
            };
            self.retire_count += 1;
        }

        fn publishSurface(self: *Self) DebugEmitPreparedTiming.PublishTotals {
            var totals: DebugEmitPreparedTiming.PublishTotals = .{};
            var publish_step_start_ns = monotonicNs();
            var glyph_offset: u32 = 0;
            var command_index: u32 = 0;
            while (command_index < self.command_count) : (command_index += 1) {
                const command = &self.commands[command_index];
                if (command.kind != c.HOWL_RENDER_SURFACE_COMMAND_DRAW_GLYPH_RUN) continue;
                std.debug.assert(command.glyphs.count > 0);
                std.debug.assert(command.glyphs.count <= c.HOWL_RENDER_SURFACE_GLYPHS_PER_RUN_MAX);
                std.debug.assert(glyph_offset < self.glyph_count);
                command.glyphs.ptr = &self.glyphs[@intCast(glyph_offset)];
                glyph_offset += command.glyphs.count;
                std.debug.assert(glyph_offset <= self.glyph_count);
            }
            std.debug.assert(glyph_offset == self.glyph_count);
            totals.glyph_fixup_ns = monotonicNs() -| publish_step_start_ns;
            publish_step_start_ns = monotonicNs();
            var upload_index: u32 = 0;
            while (upload_index < self.upload_count) : (upload_index += 1) {
                const byte_offset = self.upload_byte_offsets[upload_index];
                std.debug.assert(byte_offset < self.upload_bytes_count);
                self.uploads[upload_index].bytes_ptr = &self.upload_bytes[byte_offset];
            }
            totals.upload_fixup_ns = monotonicNs() -| publish_step_start_ns;
            publish_step_start_ns = monotonicNs();
            self.surface_storage.damage = .{
                .ptr = if (self.damage_count == 0) null else &self.damage[0],
                .count = self.damage_count,
                .count_max = c.HOWL_RENDER_SURFACE_DAMAGE_ITEMS_MAX,
            };
            self.surface_storage.creates = .{
                .ptr = if (self.create_count == 0) null else &self.creates[0],
                .count = self.create_count,
                .count_max = c.HOWL_RENDER_SURFACE_CREATES_MAX,
            };
            self.surface_storage.uploads = .{
                .ptr = if (self.upload_count == 0) null else &self.uploads[0],
                .count = self.upload_count,
                .count_max = c.HOWL_RENDER_SURFACE_UPLOADS_MAX,
                .bytes_count_total = self.upload_bytes_count,
                .bytes_count_max = c.HOWL_RENDER_SURFACE_UPLOAD_BYTES_MAX,
            };
            self.surface_storage.commands = .{
                .ptr = if (self.command_count == 0) null else &self.commands[0],
                .count = self.command_count,
                .count_max = c.HOWL_RENDER_SURFACE_COMMANDS_MAX,
            };
            self.surface_storage.retires = .{
                .ptr = if (self.retire_count == 0) null else &self.retires[0],
                .count = self.retire_count,
                .count_max = c.HOWL_RENDER_SURFACE_RETIRES_MAX,
            };
            std.debug.assert(self.surface_storage.surface_version == c.HOWL_RENDER_SURFACE_VERSION);
            std.debug.assert(self.surface_storage.damage.count_max == c.HOWL_RENDER_SURFACE_DAMAGE_ITEMS_MAX);
            std.debug.assert(self.surface_storage.creates.count_max == c.HOWL_RENDER_SURFACE_CREATES_MAX);
            std.debug.assert(self.surface_storage.uploads.count_max == c.HOWL_RENDER_SURFACE_UPLOADS_MAX);
            std.debug.assert(self.surface_storage.uploads.bytes_count_max == c.HOWL_RENDER_SURFACE_UPLOAD_BYTES_MAX);
            std.debug.assert(self.surface_storage.commands.count_max == c.HOWL_RENDER_SURFACE_COMMANDS_MAX);
            std.debug.assert(self.surface_storage.retires.count_max == c.HOWL_RENDER_SURFACE_RETIRES_MAX);
            if (self.surface_storage.damage.count == 0) std.debug.assert(self.surface_storage.damage.ptr == null);
            if (self.surface_storage.damage.count > 0) std.debug.assert(self.surface_storage.damage.ptr != null);
            if (self.surface_storage.creates.count == 0) std.debug.assert(self.surface_storage.creates.ptr == null);
            if (self.surface_storage.creates.count > 0) std.debug.assert(self.surface_storage.creates.ptr != null);
            if (self.surface_storage.uploads.count == 0) std.debug.assert(self.surface_storage.uploads.ptr == null);
            if (self.surface_storage.uploads.count > 0) std.debug.assert(self.surface_storage.uploads.ptr != null);
            if (self.surface_storage.commands.count == 0) std.debug.assert(self.surface_storage.commands.ptr == null);
            if (self.surface_storage.commands.count > 0) std.debug.assert(self.surface_storage.commands.ptr != null);
            if (self.surface_storage.retires.count == 0) std.debug.assert(self.surface_storage.retires.ptr == null);
            if (self.surface_storage.retires.count > 0) std.debug.assert(self.surface_storage.retires.ptr != null);
            totals.surface_spans_ns = monotonicNs() -| publish_step_start_ns;
            return totals;
        }
    };
}

fn emptySurface() Surface {
    return .{
        .surface_version = c.HOWL_RENDER_SURFACE_VERSION,
        .reserved0 = 0,
        .token = .{ .snapshot_seq = 0, .surface_seq = 0, .geometry_epoch = 0, .resource_epoch = 0 },
        .render_px = .{ .width = 1, .height = 1 },
        .cell_px = .{ .width = 1, .height = 1 },
        .grid = .{ .cols = 1, .rows = 1 },
        .damage = .{ .ptr = null, .count = 0, .count_max = c.HOWL_RENDER_SURFACE_DAMAGE_ITEMS_MAX },
        .creates = .{ .ptr = null, .count = 0, .count_max = c.HOWL_RENDER_SURFACE_CREATES_MAX },
        .uploads = .{
            .ptr = null,
            .count = 0,
            .count_max = c.HOWL_RENDER_SURFACE_UPLOADS_MAX,
            .bytes_count_total = 0,
            .bytes_count_max = c.HOWL_RENDER_SURFACE_UPLOAD_BYTES_MAX,
        },
        .commands = .{ .ptr = null, .count = 0, .count_max = c.HOWL_RENDER_SURFACE_COMMANDS_MAX },
        .retires = .{ .ptr = null, .count = 0, .count_max = c.HOWL_RENDER_SURFACE_RETIRES_MAX },
    };
}

fn emptyGlyphs() c.HowlRenderGlyphRunSpan {
    return .{ .ptr = null, .count = 0, .count_max = c.HOWL_RENDER_SURFACE_GLYPHS_PER_RUN_MAX };
}

fn zeroResource() ResourceId {
    return .{ .value = 0, .generation = 0, .kind = 0 };
}

const ByteRange = struct {
    start: u32,
    end: u32,
};

fn packRgba(color: contract.Rgba8) u32 {
    return (@as(u32, color.r) << 24) |
        (@as(u32, color.g) << 16) |
        (@as(u32, color.b) << 8) |
        @as(u32, color.a);
}

fn pixelSizeOut(size: geometry_contract.PixelSize) c.HowlRenderPixelSize {
    return .{ .width = size.width, .height = size.height };
}

fn cellSizeOut(size: geometry_contract.CellSize) c.HowlRenderCellSize {
    return .{ .width = size.width, .height = size.height };
}

fn gridSizeOut(size: geometry_contract.GridSize) c.HowlRenderGridSize {
    return .{ .cols = size.cols, .rows = size.rows };
}

fn lookupPreparedSprite(session: *text_session.TextSession, prepared: *const prepared_surface.PreparedSurface, sprite_key: contract.SpriteKey) error{MissingSprite}!PreparedSprite {
    for (prepared.text_surface.raster_plan.outputs) |output| {
        if (output.key.value != sprite_key.value) continue;
        return .{
            .key = output.key,
            .pixels = output.pixels,
            .width_px = output.width_px,
            .height_px = output.height_px,
            .stride_bytes = packedStrideForOutput(output),
            .color_mode = output.color_mode,
            .visual_bounds = output.visualBounds(),
        };
    }
    const cached = session.atlasRaster(sprite_key) orelse return error.MissingSprite;
    return .{
        .key = sprite_key,
        .pixels = cached.pixels,
        .width_px = cached.width_px,
        .height_px = cached.height_px,
        .stride_bytes = switch (cached.color_mode) {
            .alpha => cached.width_px,
            .color => @as(u32, cached.width_px) * 4,
        },
        .color_mode = cached.color_mode,
        .visual_bounds = cached.visual_bounds,
    };
}

fn packedStrideForOutput(output: rasterizer.RasterSpriteOutput) u32 {
    return @as(u32, output.width_px) * sprite_resource_store.bytesPerPixelForPrepared(output.color_mode);
}

fn visualBoundsForDraw(bounds: rasterizer.SpriteBounds, draw: contract.TextSpriteDraw) rasterizer.SpriteBounds {
    if (bounds.width_px != 0) {
        if (bounds.height_px != 0) return bounds;
    }
    return .{ .x_px = 0, .y_px = 0, .width_px = draw.width_px, .height_px = draw.height_px };
}

fn copyPreparedSpriteBytes(target: []u8, target_stride: u32, sprite: PreparedSprite, bounds: rasterizer.SpriteBounds, width_px: u16, height_px: u16) Error!void {
    const bytes_per_pixel = sprite_resource_store.bytesPerPixelForPrepared(sprite.color_mode);
    const source_right = std.math.add(u32, bounds.x_px, width_px) catch {
        return error.InvalidPreparedSprite;
    };
    const source_bottom = std.math.add(u32, bounds.y_px, height_px) catch {
        return error.InvalidPreparedSprite;
    };
    if (source_right > sprite.width_px) return error.InvalidPreparedSprite;
    if (source_bottom > sprite.height_px) return error.InvalidPreparedSprite;
    const row_bytes = std.math.mul(u32, width_px, bytes_per_pixel) catch {
        return error.UploadBytesOverflow;
    };
    std.debug.assert(row_bytes <= target_stride);
    var yy: u16 = 0;
    while (yy < height_px) : (yy += 1) {
        const source_y = std.math.add(u32, bounds.y_px, yy) catch {
            return error.InvalidPreparedSprite;
        };
        if (source_y >= sprite.height_px) return error.InvalidPreparedSprite;
        const source_x_bytes = std.math.mul(u32, bounds.x_px, bytes_per_pixel) catch {
            return error.InvalidPreparedSprite;
        };
        const source_row = std.math.mul(u32, source_y, sprite.stride_bytes) catch {
            return error.InvalidPreparedSprite;
        };
        const source_start = std.math.add(u32, source_row, source_x_bytes) catch {
            return error.InvalidPreparedSprite;
        };
        const source_end = std.math.add(u32, source_start, row_bytes) catch {
            return error.InvalidPreparedSprite;
        };
        if (source_end > sprite.pixels.len) return error.InvalidPreparedSprite;
        const target_start = std.math.mul(u32, yy, target_stride) catch {
            return error.UploadBytesOverflow;
        };
        const target_end = std.math.add(u32, target_start, row_bytes) catch {
            return error.UploadBytesOverflow;
        };
        if (target_end > target.len) return error.UploadBytesOverflow;
        @memcpy(target[target_start..target_end], sprite.pixels[source_start..source_end]);
    }
}

pub const testing = struct {
    pub fn appendGlyphRef(comptime limits: Limits, emitter: *Emitter(limits), glyph: GlyphRef) Error!void {
        return emitter.appendGlyphRef(glyph);
    }

    pub fn publishSurface(comptime limits: Limits, emitter: *Emitter(limits)) void {
        _ = emitter.publishSurface();
    }
};
