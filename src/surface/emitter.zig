const std = @import("std");

const c = @import("howl_render_c");
const render = @import("../text/draw_primitives.zig");
const text_damage = @import("../text/damage.zig");
const layout = @import("../layout.zig");
const cursor_presentation = @import("../cursor/presentation.zig");
const prepared_surface = @import("prepared_surface.zig");
const sprite_resource_store = @import("resource_store.zig");
const rasterizer = @import("../text/raster/rasterizer.zig");

const ResourceId = c.HowlRenderResourceId;
const Rect = c.HowlRenderTermSurfaceRect;
const GlyphRef = c.HowlRenderGlyphRef;
pub const Surface = c.HowlRenderTermSurfacePrepared;
const SpriteResourceStore = sprite_resource_store.SpriteResourceStore;
const CursorTrailDrawRect = cursor_presentation.CursorTrailDrawRect;

// Glyph refs are data-plane payload; commands are control-plane payload.
const glyph_refs_max: u32 = 32 * 1024;
const PreparedSprite = sprite_resource_store.PreparedSprite;

comptime {
    std.debug.assert(glyph_refs_max > c.HOWL_RENDER_TERM_SURFACE_PREPARED_COMMANDS_MAX);
    std.debug.assert(glyph_refs_max <=
        c.HOWL_RENDER_TERM_SURFACE_PREPARED_COMMANDS_MAX * c.HOWL_RENDER_TERM_SURFACE_PREPARED_GLYPHS_PER_RUN_MAX);
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
    damage_max: u32 = c.HOWL_RENDER_TERM_SURFACE_DAMAGE_ITEMS_MAX,
    creates_max: u32 = c.HOWL_RENDER_TERM_SURFACE_PREPARED_CREATES_MAX,
    uploads_max: u32 = c.HOWL_RENDER_TERM_SURFACE_PREPARED_UPLOADS_MAX,
    commands_max: u32 = c.HOWL_RENDER_TERM_SURFACE_PREPARED_COMMANDS_MAX,
    glyph_refs_max: u32 = glyph_refs_max,
    retires_max: u32 = c.HOWL_RENDER_TERM_SURFACE_PREPARED_RETIRES_MAX,
    upload_bytes_max: u32 = c.HOWL_RENDER_TERM_SURFACE_PREPARED_UPLOAD_BYTES_MAX,

    pub fn assertValid(comptime limits: Limits) void {
        std.debug.assert(limits.damage_max <= c.HOWL_RENDER_TERM_SURFACE_DAMAGE_ITEMS_MAX);
        std.debug.assert(limits.creates_max <= c.HOWL_RENDER_TERM_SURFACE_PREPARED_CREATES_MAX);
        std.debug.assert(limits.uploads_max <= c.HOWL_RENDER_TERM_SURFACE_PREPARED_UPLOADS_MAX);
        std.debug.assert(limits.commands_max <= c.HOWL_RENDER_TERM_SURFACE_PREPARED_COMMANDS_MAX);
        std.debug.assert(limits.glyph_refs_max <=
            c.HOWL_RENDER_TERM_SURFACE_PREPARED_COMMANDS_MAX * c.HOWL_RENDER_TERM_SURFACE_PREPARED_GLYPHS_PER_RUN_MAX);
        std.debug.assert(limits.glyph_refs_max >= limits.commands_max);
        std.debug.assert(limits.retires_max <= c.HOWL_RENDER_TERM_SURFACE_PREPARED_RETIRES_MAX);
        std.debug.assert(limits.upload_bytes_max <= c.HOWL_RENDER_TERM_SURFACE_PREPARED_UPLOAD_BYTES_MAX);
    }
};

pub fn Emitter(comptime limits: Limits) type {
    comptime limits.assertValid();

    return struct {
        damage: [limits.damage_max]c.HowlRenderTermSurfaceDamageItem = undefined,
        creates: [limits.creates_max]c.HowlRenderResourceCreate = undefined,
        uploads: [limits.uploads_max]c.HowlRenderResourceUpload = undefined,
        upload_byte_offsets: [limits.uploads_max]u32 = undefined,
        commands: [limits.commands_max]c.HowlRenderTermSurfaceCommand = undefined,
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

        pub fn emitPrepared(self: *Self, resources: *SpriteResourceStore, prepared: *const prepared_surface.PreparedSurface) Error!*const Surface {
            var next = self.*;
            var next_resources = resources.*;
            try next.appendPreparedPass(&next_resources, prepared);
            next.assertReadyToPublish();
            self.* = next;
            resources.* = next_resources;
            self.assertReadyToPublish();
            self.publishSurface();
            self.assertPublishedSurface();
            return &self.surface_storage;
        }

        pub fn emitPreparedFresh(self: *Self, resources: *SpriteResourceStore, prepared: *const prepared_surface.PreparedSurface) Error!*const Surface {
            const resource_rollback = resources.admissionRollback();
            errdefer resources.restoreAdmission(resource_rollback);
            try self.appendPreparedPass(resources, prepared);
            self.assertReadyToPublish();
            self.publishSurface();
            self.assertPublishedSurface();
            return &self.surface_storage;
        }

        fn appendPreparedPass(self: *Self, resources: *SpriteResourceStore, prepared: *const prepared_surface.PreparedSurface) Error!void {
            self.resetPrepared(prepared);
            try self.appendPreparedFullRedrawClear(prepared);
            try self.appendPreparedClears(prepared.text_surface.draw_list.draw_list.clear_draws);
            try self.appendPreparedBackgrounds(prepared.text_surface.draw_list.draw_list.background_draws);
            try self.appendPreparedDecorations(prepared.text_surface.draw_list.draw_list.decoration_draws);
            try self.appendPreparedSprites(resources, prepared);
            try self.appendPreparedCursorTrails(prepared.text_surface.draw_list.cursor_trail_rects);
            try self.appendPreparedCursors(prepared.text_surface.draw_list.draw_list.cursor_draws);
            try self.appendPreparedDamage(prepared);
        }

        fn assertReadyToPublish(self: *const Self) void {
            std.debug.assert(self.damage_count <= limits.damage_max);
            std.debug.assert(self.create_count <= limits.creates_max);
            std.debug.assert(self.upload_count <= limits.uploads_max);
            std.debug.assert(self.command_count <= limits.commands_max);
            std.debug.assert(self.glyph_count <= limits.glyph_refs_max);
            std.debug.assert(self.retire_count <= limits.retires_max);
            std.debug.assert(self.upload_bytes_count <= limits.upload_bytes_max);
            std.debug.assert(self.surface_storage.damage.ptr == null);
            std.debug.assert(self.surface_storage.creates.ptr == null);
            std.debug.assert(self.surface_storage.uploads.ptr == null);
            std.debug.assert(self.surface_storage.commands.ptr == null);
            std.debug.assert(self.surface_storage.retires.ptr == null);
        }

        fn assertPublishedSurface(self: *const Self) void {
            std.debug.assert(self.surface_storage.damage.count == self.damage_count);
            std.debug.assert(self.surface_storage.creates.count == self.create_count);
            std.debug.assert(self.surface_storage.uploads.count == self.upload_count);
            std.debug.assert(self.surface_storage.commands.count == self.command_count);
            std.debug.assert(self.surface_storage.retires.count == self.retire_count);
            std.debug.assert(self.surface_storage.uploads.bytes_count_total == self.upload_bytes_count);
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
                .prepare_seq = prepared.request.token.dirty_epoch,
                .layout_epoch = prepared.layout_epoch,
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
            std.debug.assert(self.surface_storage.prepared_version == c.HOWL_RENDER_TERM_SURFACE_PREPARED_VERSION);
            std.debug.assert(self.surface_storage.damage.ptr == null);
            std.debug.assert(self.surface_storage.creates.ptr == null);
            std.debug.assert(self.surface_storage.uploads.ptr == null);
            std.debug.assert(self.surface_storage.commands.ptr == null);
            std.debug.assert(self.surface_storage.retires.ptr == null);
        }

        fn appendFullDamage(self: *Self, render_px: c.HowlRenderPixelSize) Error!void {
            if (self.damage_count >= limits.damage_max) return error.DamageBoundOverflow;
            self.damage[self.damage_count] = .{
                .kind = c.HOWL_RENDER_TERM_SURFACE_DAMAGE_FULL,
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

        fn appendPreparedDamage(self: *Self, prepared: *const prepared_surface.PreparedSurface) Error!void {
            if (prepared.damageKind() == .full) return self.appendFullDamage(pixelSizeOut(prepared.render_px));
            if (self.command_count != 0) return self.appendFullDamage(pixelSizeOut(prepared.render_px));
            const damage = text_damage.NormalizedDamage{
                .full = false,
                .dirty_rows = prepared.dirty_rows,
                .dirty_cols_start = prepared.dirty_cols_start,
                .dirty_cols_end = prepared.dirty_cols_end,
            };
            const cell_grid = render.CellGrid{ .cols = prepared.grid.cols, .rows = prepared.grid.rows };
            var row: u16 = 0;
            while (row < prepared.grid.rows) : (row += 1) {
                const dirty = text_damage.dirtyRowSpan(damage, cell_grid, row) orelse continue;
                const rect = damageRectForDirtySpan(prepared, dirty) orelse continue;
                self.appendDamageRect(rect) catch |err| switch (err) {
                    error.DamageBoundOverflow => return self.replaceDamageWithFull(pixelSizeOut(prepared.render_px)),
                    else => return err,
                };
            }
            if (self.damage_count == 0) try self.appendFullDamage(pixelSizeOut(prepared.render_px));
        }

        fn replaceDamageWithFull(self: *Self, render_px: c.HowlRenderPixelSize) Error!void {
            self.damage_count = 0;
            try self.appendFullDamage(render_px);
        }

        fn damageRectForDirtySpan(prepared: *const prepared_surface.PreparedSurface, dirty: text_damage.DirtyRowSpan) ?Rect {
            const start_col = if (dirty.start_col == 0) 0 else dirty.start_col - 1;
            const end_col = @min(@as(u32, dirty.end_col) + 1, @as(u32, prepared.grid.cols) - 1);
            const x_px_u32 = @as(u32, start_col) * @as(u32, prepared.cell_px.width);
            const y_px_u32 = @as(u32, dirty.row) * @as(u32, prepared.cell_px.height);
            const right_px_u32 = (@as(u32, @intCast(end_col)) + 1) * @as(u32, prepared.cell_px.width);
            const bottom_px_u32 = (@as(u32, dirty.row) + 1) * @as(u32, prepared.cell_px.height);
            const x_px = @min(x_px_u32, prepared.render_px.width);
            const y_px = @min(y_px_u32, prepared.render_px.height);
            const right_px = @min(right_px_u32, prepared.render_px.width);
            const bottom_px = @min(bottom_px_u32, prepared.render_px.height);
            if (right_px <= x_px or bottom_px <= y_px) return null;
            return .{
                .x_px = @intCast(x_px),
                .y_px = @intCast(y_px),
                .width_px = @intCast(right_px - x_px),
                .height_px = @intCast(bottom_px - y_px),
            };
        }

        fn appendDamageRect(self: *Self, rect: Rect) Error!void {
            std.debug.assert(rect.width_px != 0);
            std.debug.assert(rect.height_px != 0);
            if (self.tryMergeDamageRect(rect)) return;
            if (self.damage_count >= limits.damage_max) return error.DamageBoundOverflow;
            self.damage[self.damage_count] = .{
                .kind = c.HOWL_RENDER_TERM_SURFACE_DAMAGE_RECT,
                .reserved0 = 0,
                .reserved1 = 0,
                .rect = rect,
            };
            self.damage_count += 1;
        }

        fn tryMergeDamageRect(self: *Self, rect: Rect) bool {
            if (self.damage_count == 0) return false;
            const prior = &self.damage[self.damage_count - 1];
            if (prior.kind != c.HOWL_RENDER_TERM_SURFACE_DAMAGE_RECT) return false;
            if (prior.rect.x_px != rect.x_px) return false;
            if (prior.rect.width_px != rect.width_px) return false;
            const prior_bottom = std.math.add(i32, prior.rect.y_px, prior.rect.height_px) catch return false;
            if (prior_bottom < rect.y_px) return false;
            const rect_bottom = std.math.add(i32, rect.y_px, rect.height_px) catch return false;
            if (rect_bottom <= prior_bottom) return true;
            const height = rect_bottom - prior.rect.y_px;
            if (height > std.math.maxInt(u16)) return false;
            prior.rect.height_px = @intCast(height);
            return true;
        }

        fn appendPreparedFullRedrawClear(self: *Self, prepared: *const prepared_surface.PreparedSurface) Error!void {
            if (prepared.damageKind() != .full) return;
            try self.appendCommand(.{
                .kind = c.HOWL_RENDER_TERM_SURFACE_COMMAND_CLEAR_RECT,
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

        fn appendPreparedClears(self: *Self, draws: []const render.TextClearDraw) Error!void {
            for (draws) |draw| try self.appendPreparedFillCommand(
                draw.x_px,
                draw.y_px,
                draw.width_px,
                draw.height_px,
                draw.color,
                c.HOWL_RENDER_TERM_SURFACE_COMMAND_CLEAR_RECT,
            );
        }

        fn appendPreparedBackgrounds(self: *Self, draws: []const render.TextBackgroundDraw) Error!void {
            for (draws) |draw| try self.appendPreparedFillCommand(
                draw.x_px,
                draw.y_px,
                draw.width_px,
                draw.height_px,
                draw.color,
                c.HOWL_RENDER_TERM_SURFACE_COMMAND_FILL_RECT,
            );
        }

        fn appendPreparedDecorations(self: *Self, draws: []const render.TextDecorationDraw) Error!void {
            for (draws) |draw| try self.appendPreparedFillCommand(
                draw.x_px,
                draw.y_px,
                draw.width_px,
                draw.height_px,
                draw.color,
                c.HOWL_RENDER_TERM_SURFACE_COMMAND_FILL_RECT,
            );
        }

        fn appendPreparedCursors(self: *Self, draws: []const render.TextCursorDraw) Error!void {
            for (draws) |draw| try self.appendPreparedFillCommand(
                draw.x_px,
                draw.y_px,
                draw.width_px,
                draw.height_px,
                draw.color,
                c.HOWL_RENDER_TERM_SURFACE_COMMAND_FILL_RECT,
            );
        }

        fn appendPreparedCursorTrails(self: *Self, draws: []const CursorTrailDrawRect) Error!void {
            for (draws) |draw| try self.appendPreparedFillCommand(
                draw.x_px,
                draw.y_px,
                draw.width_px,
                draw.height_px,
                draw.color,
                c.HOWL_RENDER_TERM_SURFACE_COMMAND_FILL_RECT,
            );
        }

        fn appendPreparedFillCommand(self: *Self, x_px: i32, y_px: i32, width_px: u16, height_px: u16, color: render.Rgba8, kind: u8) Error!void {
            if (width_px == 0) return;
            if (height_px == 0) return;
            const clipped = clippedFillRect(self.surface_storage.render_px, x_px, y_px, width_px, height_px) orelse return;
            const command = c.HowlRenderTermSurfaceCommand{
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

        fn tryMergePreparedFillCommand(self: *Self, command: c.HowlRenderTermSurfaceCommand) bool {
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

        fn appendPreparedSprites(self: *Self, resources: *SpriteResourceStore, prepared: *const prepared_surface.PreparedSurface) Error!void {
            for (prepared.text_surface.draw_list.draw_list.sprite_draws) |draw| {
                const sprite = lookupPreparedSprite(
                    prepared,
                    draw.sprite.key,
                ) catch |err| {
                    return switch (err) {
                        error.MissingSprite => error.MissingPreparedSprite,
                    };
                };
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
                    const atlas = try resources.atlasAdmissionForPrepared(
                        sprite,
                        bounds,
                        width_px,
                        height_px,
                    );
                    if (atlas.created) try self.appendGlyphAtlasCreate(atlas.resource);
                    if (atlas.uploaded) {
                        const upload_count_start = self.upload_count;
                        const upload_range = try self.stagePreparedUploadBytes(
                            sprite,
                            bounds,
                            width_px,
                            height_px,
                        );
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
                    try self.appendGlyphRef(.{
                        .atlas_resource = atlas.resource,
                        .atlas_rect = atlas.rect,
                        .x_px = dest_x,
                        .y_px = dest_y,
                        .glyph_id = @intCast(draw.sprite.key.value & 0xffffffff),
                        .color_rgba = packRgba(draw.color),
                    });
                    continue;
                }
                const result = try resources.resourceAdmissionForPrepared(
                    sprite,
                    bounds,
                    width_px,
                    height_px,
                );
                switch (result.lifetime) {
                    .persistent, .transient => {
                        const upload_count_start = self.upload_count;
                        const upload_range = try self.stagePreparedUploadBytes(
                            sprite,
                            bounds,
                            width_px,
                            height_px,
                        );
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
                try self.appendCommand(.{
                    .kind = c.HOWL_RENDER_TERM_SURFACE_COMMAND_DRAW_SPRITE,
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
                if (result.lifetime == .transient) {
                    try self.appendRetire(result.resource, self.command_count);
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
            try sprite_resource_store.copyPreparedSpriteBytes(
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

        fn appendCommand(self: *Self, command: c.HowlRenderTermSurfaceCommand) Error!void {
            if (self.command_count >= limits.commands_max) return error.CommandBoundOverflow;
            self.commands[self.command_count] = command;
            self.command_count += 1;
        }

        fn appendGlyphRef(self: *Self, glyph: GlyphRef) Error!void {
            if (self.glyph_count >= limits.glyph_refs_max) return error.CommandBoundOverflow;

            if (self.command_count > 0) {
                const prior = &self.commands[self.command_count - 1];
                if (prior.kind == c.HOWL_RENDER_TERM_SURFACE_COMMAND_DRAW_GLYPH_RUN) {
                    std.debug.assert(prior.glyphs.count > 0);
                    std.debug.assert(prior.glyphs.count <= c.HOWL_RENDER_TERM_SURFACE_PREPARED_GLYPHS_PER_RUN_MAX);
                    if (prior.glyphs.count < c.HOWL_RENDER_TERM_SURFACE_PREPARED_GLYPHS_PER_RUN_MAX) {
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
                .kind = c.HOWL_RENDER_TERM_SURFACE_COMMAND_DRAW_GLYPH_RUN,
                .reserved0 = 0,
                .reserved1 = 0,
                .rect = .{ .x_px = 0, .y_px = 0, .width_px = 0, .height_px = 0 },
                .color_rgba = 0,
                .resource = zeroResource(),
                .glyphs = .{
                    .ptr = &self.glyphs[@intCast(start)],
                    .count = 1,
                    .count_max = c.HOWL_RENDER_TERM_SURFACE_PREPARED_GLYPHS_PER_RUN_MAX,
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

        fn publishSurface(self: *Self) void {
            var glyph_offset: u32 = 0;
            var command_index: u32 = 0;
            while (command_index < self.command_count) : (command_index += 1) {
                const command = &self.commands[command_index];
                if (command.kind != c.HOWL_RENDER_TERM_SURFACE_COMMAND_DRAW_GLYPH_RUN) continue;
                std.debug.assert(command.glyphs.count > 0);
                std.debug.assert(command.glyphs.count <= c.HOWL_RENDER_TERM_SURFACE_PREPARED_GLYPHS_PER_RUN_MAX);
                std.debug.assert(glyph_offset < self.glyph_count);
                command.glyphs.ptr = &self.glyphs[@intCast(glyph_offset)];
                glyph_offset += command.glyphs.count;
                std.debug.assert(glyph_offset <= self.glyph_count);
            }
            std.debug.assert(glyph_offset == self.glyph_count);
            var upload_index: u32 = 0;
            while (upload_index < self.upload_count) : (upload_index += 1) {
                const byte_offset = self.upload_byte_offsets[upload_index];
                std.debug.assert(byte_offset < self.upload_bytes_count);
                self.uploads[upload_index].bytes_ptr = &self.upload_bytes[byte_offset];
            }
            self.surface_storage.damage = .{
                .ptr = if (self.damage_count == 0) null else &self.damage[0],
                .count = self.damage_count,
                .count_max = c.HOWL_RENDER_TERM_SURFACE_DAMAGE_ITEMS_MAX,
            };
            self.surface_storage.creates = .{
                .ptr = if (self.create_count == 0) null else &self.creates[0],
                .count = self.create_count,
                .count_max = c.HOWL_RENDER_TERM_SURFACE_PREPARED_CREATES_MAX,
            };
            self.surface_storage.uploads = .{
                .ptr = if (self.upload_count == 0) null else &self.uploads[0],
                .count = self.upload_count,
                .count_max = c.HOWL_RENDER_TERM_SURFACE_PREPARED_UPLOADS_MAX,
                .bytes_count_total = self.upload_bytes_count,
                .bytes_count_max = c.HOWL_RENDER_TERM_SURFACE_PREPARED_UPLOAD_BYTES_MAX,
            };
            self.surface_storage.commands = .{
                .ptr = if (self.command_count == 0) null else &self.commands[0],
                .count = self.command_count,
                .count_max = c.HOWL_RENDER_TERM_SURFACE_PREPARED_COMMANDS_MAX,
            };
            self.surface_storage.retires = .{
                .ptr = if (self.retire_count == 0) null else &self.retires[0],
                .count = self.retire_count,
                .count_max = c.HOWL_RENDER_TERM_SURFACE_PREPARED_RETIRES_MAX,
            };
            std.debug.assert(self.surface_storage.prepared_version == c.HOWL_RENDER_TERM_SURFACE_PREPARED_VERSION);
            std.debug.assert(self.surface_storage.damage.count_max == c.HOWL_RENDER_TERM_SURFACE_DAMAGE_ITEMS_MAX);
            std.debug.assert(self.surface_storage.creates.count_max == c.HOWL_RENDER_TERM_SURFACE_PREPARED_CREATES_MAX);
            std.debug.assert(self.surface_storage.uploads.count_max == c.HOWL_RENDER_TERM_SURFACE_PREPARED_UPLOADS_MAX);
            std.debug.assert(self.surface_storage.uploads.bytes_count_max == c.HOWL_RENDER_TERM_SURFACE_PREPARED_UPLOAD_BYTES_MAX);
            std.debug.assert(self.surface_storage.commands.count_max == c.HOWL_RENDER_TERM_SURFACE_PREPARED_COMMANDS_MAX);
            std.debug.assert(self.surface_storage.retires.count_max == c.HOWL_RENDER_TERM_SURFACE_PREPARED_RETIRES_MAX);
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
        }
    };
}

fn emptySurface() Surface {
    return .{
        .prepared_version = c.HOWL_RENDER_TERM_SURFACE_PREPARED_VERSION,
        .reserved0 = 0,
        .token = .{ .snapshot_seq = 0, .prepare_seq = 0, .layout_epoch = 0, .resource_epoch = 0 },
        .render_px = .{ .width = 1, .height = 1 },
        .cell_px = .{ .width = 1, .height = 1 },
        .grid = .{ .cols = 1, .rows = 1 },
        .damage = .{ .ptr = null, .count = 0, .count_max = c.HOWL_RENDER_TERM_SURFACE_DAMAGE_ITEMS_MAX },
        .creates = .{ .ptr = null, .count = 0, .count_max = c.HOWL_RENDER_TERM_SURFACE_PREPARED_CREATES_MAX },
        .uploads = .{
            .ptr = null,
            .count = 0,
            .count_max = c.HOWL_RENDER_TERM_SURFACE_PREPARED_UPLOADS_MAX,
            .bytes_count_total = 0,
            .bytes_count_max = c.HOWL_RENDER_TERM_SURFACE_PREPARED_UPLOAD_BYTES_MAX,
        },
        .commands = .{ .ptr = null, .count = 0, .count_max = c.HOWL_RENDER_TERM_SURFACE_PREPARED_COMMANDS_MAX },
        .retires = .{ .ptr = null, .count = 0, .count_max = c.HOWL_RENDER_TERM_SURFACE_PREPARED_RETIRES_MAX },
    };
}

fn emptyGlyphs() c.HowlRenderGlyphRunSpan {
    return .{ .ptr = null, .count = 0, .count_max = c.HOWL_RENDER_TERM_SURFACE_PREPARED_GLYPHS_PER_RUN_MAX };
}

fn zeroResource() ResourceId {
    return .{ .value = 0, .generation = 0, .kind = 0 };
}

const ByteRange = struct {
    start: u32,
    end: u32,
};

fn packRgba(color: render.Rgba8) u32 {
    return (@as(u32, color.r) << 24) |
        (@as(u32, color.g) << 16) |
        (@as(u32, color.b) << 8) |
        @as(u32, color.a);
}

fn pixelSizeOut(size: layout.PixelSize) c.HowlRenderPixelSize {
    return .{ .width = size.width, .height = size.height };
}

fn cellSizeOut(size: layout.CellSize) c.HowlRenderCellSize {
    return .{ .width = size.width, .height = size.height };
}

fn gridSizeOut(size: layout.GridSize) c.HowlRenderCellGrid {
    return .{ .cols = size.cols, .rows = size.rows };
}

fn lookupPreparedSprite(prepared: *const prepared_surface.PreparedSurface, sprite_key: render.SpriteKey) error{MissingSprite}!PreparedSprite {
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
    return error.MissingSprite;
}

fn packedStrideForOutput(output: rasterizer.RasterSpriteOutput) u32 {
    return @as(u32, output.width_px) * sprite_resource_store.bytesPerPixelForPrepared(output.color_mode);
}

fn visualBoundsForDraw(bounds: rasterizer.SpriteBounds, draw: render.TextSpriteDraw) rasterizer.SpriteBounds {
    if (bounds.width_px != 0) {
        if (bounds.height_px != 0) return bounds;
    }
    return .{ .x_px = 0, .y_px = 0, .width_px = draw.width_px, .height_px = draw.height_px };
}

pub const testing = struct {
    pub fn appendGlyphRef(comptime limits: Limits, emitter: *Emitter(limits), glyph: GlyphRef) Error!void {
        return emitter.appendGlyphRef(glyph);
    }

    pub fn publishSurface(comptime limits: Limits, emitter: *Emitter(limits)) void {
        emitter.publishSurface();
    }
};
