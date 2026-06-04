const std = @import("std");

const c = @import("../ffi.zig").c;
const contract = @import("../text/contract.zig");
const geometry_contract = @import("../render/geometry_contract.zig");
const prepared_buffer = @import("buffer.zig");
const prepared_surface = @import("surface.zig");
const realize = @import("../render/render_surface_realizer.zig");
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

const ColorMode = enum {
    alpha,
    color,
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

        fn emitTesting(self: *Self, fixture: *const testing.Fixture) Error!*const Surface {
            var next = self.*;
            next.resetTesting(fixture);
            try next.appendFullDamage(fixture.render_px);
            try next.appendTestingFillPass(fixture.clear_fills, c.HOWL_RENDER_SURFACE_COMMAND_CLEAR_RECT);
            try next.appendTestingFillPass(fixture.background_fills, c.HOWL_RENDER_SURFACE_COMMAND_FILL_RECT);
            try next.appendTestingFillPass(fixture.decoration_fills, c.HOWL_RENDER_SURFACE_COMMAND_FILL_RECT);
            try next.appendTestingSprites(fixture.sprites);
            try next.appendTestingFillPass(fixture.cursor_fills, c.HOWL_RENDER_SURFACE_COMMAND_FILL_RECT);
            self.* = next;
            self.publishSurface();
            return &self.surface_storage;
        }

        pub fn emitPrepared(self: *Self, resources: *SpriteResourceStore, session: *text_session.TextSession, prepared: *const prepared_surface.PreparedSurface) Error!*const Surface {
            var next = self.*;
            var next_resources = resources.*;
            next.resetPrepared(prepared);
            try next.appendFullDamage(pixelSizeOut(prepared.render_px));
            try next.appendPreparedFullRedrawClear(prepared);
            try next.appendPreparedClears(prepared.text_frame.scene.scene.clear_draws);
            try next.appendPreparedBackgrounds(prepared.text_frame.scene.scene.background_draws);
            try next.appendPreparedDecorations(prepared.text_frame.scene.scene.decoration_draws);
            try next.appendPreparedSprites(&next_resources, session, prepared);
            try next.appendPreparedCursors(prepared.text_frame.scene.scene.cursor_draws);
            self.* = next;
            resources.* = next_resources;
            self.publishSurface();
            return &self.surface_storage;
        }

        fn resetTesting(self: *Self, fixture: *const testing.Fixture) void {
            self.damage_count = 0;
            self.create_count = 0;
            self.upload_count = 0;
            self.command_count = 0;
            self.glyph_count = 0;
            self.retire_count = 0;
            self.upload_bytes_count = 0;
            self.surface_storage = emptySurface();
            self.surface_storage.token = fixture.token;
            self.surface_storage.render_px = fixture.render_px;
            self.surface_storage.cell_px = fixture.cell_px;
            self.surface_storage.grid = fixture.grid;
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

        fn appendTestingFillPass(self: *Self, fills: []const testing.Fill, kind: u8) Error!void {
            for (fills) |fill| try self.appendCommand(.{
                .kind = kind,
                .reserved0 = 0,
                .reserved1 = 0,
                .rect = fill.rect,
                .color_rgba = fill.color_rgba,
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

        fn appendTestingSprites(self: *Self, sprites: []const testing.Sprite) Error!void {
            for (sprites, 0..) |sprite, sprite_index| {
                const resource = spriteResource(sprite, @intCast(sprite_index + 1));
                try self.appendTestingCreate(resource, sprite);
                try self.appendTestingUpload(resource, sprite);
                try self.appendCommand(.{
                    .kind = c.HOWL_RENDER_SURFACE_COMMAND_DRAW_SPRITE,
                    .reserved0 = 0,
                    .reserved1 = 0,
                    .rect = sprite.rect,
                    .color_rgba = if (sprite.color_mode == .alpha) sprite.color_rgba else 0,
                    .resource = resource,
                    .glyphs = emptyGlyphs(),
                });
                try self.appendRetire(resource, self.command_count);
            }
        }

        fn appendPreparedSprites(self: *Self, resources: *SpriteResourceStore, session: *text_session.TextSession, prepared: *const prepared_surface.PreparedSurface) Error!void {
            for (prepared.text_frame.scene.scene.sprite_draws) |draw| {
                const sprite = lookupPreparedSprite(
                    session,
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

                const upload_range = try self.stagePreparedUploadBytes(
                    sprite,
                    bounds,
                    width_px,
                    height_px,
                );
                if (sprite.color_mode == .alpha) {
                    const atlas = try resources.atlasRegionFor(
                        sprite,
                        width_px,
                        height_px,
                        self.upload_bytes[upload_range.start..upload_range.end],
                    );
                    if (atlas.created) try self.appendGlyphAtlasCreate(atlas.resource);
                    if (atlas.uploaded) try self.appendPreparedAtlasUpload(
                        atlas.resource,
                        atlas.rect,
                        upload_range,
                    ) else self.upload_bytes_count = upload_range.start;
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
                const result = try resources.resourceFor(
                    sprite,
                    width_px,
                    height_px,
                    self.upload_bytes[upload_range.start..upload_range.end],
                );
                switch (result.lifetime) {
                    .persistent, .transient => {
                        try self.appendPreparedCreate(result.resource, sprite, width_px, height_px);
                        try self.appendPreparedUpload(
                            result.resource,
                            sprite,
                            width_px,
                            height_px,
                            upload_range,
                        );
                    },
                    .reused => {
                        self.upload_bytes_count = upload_range.start;
                    },
                }
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
                if (result.lifetime == .transient) {
                    try self.appendRetire(result.resource, self.command_count);
                }
            }
        }

        fn appendTestingCreate(self: *Self, resource: ResourceId, sprite: testing.Sprite) Error!void {
            if (self.create_count >= limits.creates_max) return error.CreateBoundOverflow;
            self.creates[self.create_count] = .{
                .resource = resource,
                .width_px = sprite.width_px,
                .height_px = sprite.height_px,
                .format = uploadFormat(sprite.color_mode),
                .create_seq = 0,
            };
            self.create_count += 1;
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

        fn appendTestingUpload(self: *Self, resource: ResourceId, sprite: testing.Sprite) Error!void {
            if (self.upload_count >= limits.uploads_max) return error.UploadBoundOverflow;
            const bytes_count: u32 = std.math.cast(u32, sprite.bytes.len) orelse {
                return error.UploadBytesOverflow;
            };
            const next_bytes_count = std.math.add(u32, self.upload_bytes_count, bytes_count) catch {
                return error.UploadBytesOverflow;
            };
            if (next_bytes_count > limits.upload_bytes_max) return error.UploadBytesOverflow;
            @memcpy(self.upload_bytes[self.upload_bytes_count..next_bytes_count], sprite.bytes);
            self.uploads[self.upload_count] = .{
                .resource = resource,
                .rect = .{
                    .x_px = 0,
                    .y_px = 0,
                    .width_px = sprite.width_px,
                    .height_px = sprite.height_px,
                },
                .bytes_ptr = &self.upload_bytes[self.upload_bytes_count],
                .bytes_count = bytes_count,
                .stride_bytes = sprite.stride_bytes,
                .format = uploadFormat(sprite.color_mode),
                .upload_seq = 0,
            };
            self.upload_byte_offsets[self.upload_count] = self.upload_bytes_count;
            self.upload_bytes_count = next_bytes_count;
            self.upload_count += 1;
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

        fn publishSurface(self: *Self) void {
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

            var upload_index: u32 = 0;
            while (upload_index < self.upload_count) : (upload_index += 1) {
                const byte_offset = self.upload_byte_offsets[upload_index];
                std.debug.assert(byte_offset < self.upload_bytes_count);
                self.uploads[upload_index].bytes_ptr = &self.upload_bytes[byte_offset];
            }
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

fn spriteResource(sprite: testing.Sprite, value: u64) ResourceId {
    return .{
        .value = value,
        .generation = 1,
        .kind = switch (sprite.color_mode) {
            .alpha => c.HOWL_RENDER_RESOURCE_SPRITE_ALPHA,
            .color => c.HOWL_RENDER_RESOURCE_SPRITE_COLOR,
        },
    };
}

const ByteRange = struct {
    start: u32,
    end: u32,
};

fn uploadFormat(color_mode: ColorMode) u32 {
    return switch (color_mode) {
        .alpha => c.HOWL_RENDER_UPLOAD_ALPHA8,
        .color => c.HOWL_RENDER_UPLOAD_RGBA8,
    };
}

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
    for (prepared.text_frame.raster_plan.outputs) |output| {
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
    pub const Fill = struct {
        rect: Rect,
        color_rgba: u32,
    };

    pub const Sprite = struct {
        rect: Rect,
        color_rgba: u32,
        bytes: []const u8,
        width_px: u16,
        height_px: u16,
        stride_bytes: u32,
        color_mode: ColorMode,
    };

    pub const Fixture = struct {
        render_px: c.HowlRenderPixelSize,
        cell_px: c.HowlRenderCellSize = .{ .width = 1, .height = 1 },
        grid: c.HowlRenderGridSize = .{ .cols = 1, .rows = 1 },
        token: c.HowlRenderSurfaceToken = .{
            .snapshot_seq = 0,
            .surface_seq = 0,
            .geometry_epoch = 0,
            .resource_epoch = 0,
        },
        clear_fills: []const Fill = &.{},
        background_fills: []const Fill = &.{},
        decoration_fills: []const Fill = &.{},
        sprites: []const Sprite = &.{},
        cursor_fills: []const Fill = &.{},
    };

    pub fn emit(comptime limits: Limits, emitter: *Emitter(limits), fixture: *const Fixture) Error!*const Surface {
        return emitter.emitTesting(fixture);
    }

    pub fn appendGlyphRef(comptime limits: Limits, emitter: *Emitter(limits), glyph: GlyphRef) Error!void {
        return emitter.appendGlyphRef(glyph);
    }

    pub fn publishSurface(comptime limits: Limits, emitter: *Emitter(limits)) void {
        return emitter.publishSurface();
    }
};
