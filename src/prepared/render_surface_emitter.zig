const std = @import("std");

const c = @import("../ffi.zig").c;
const contract = @import("../text/contract.zig");
const geometry_contract = @import("../render/geometry_contract.zig");
const prepared_buffer = @import("buffer.zig");
const prepared_surface = @import("surface.zig");
const realize = @import("../render/render_surface_realizer.zig");
const sprite_resource_store = @import("sprite_resource_store.zig");
const text = @import("../text/text.zig");
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

pub const ColorMode = enum {
    alpha,
    color,
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

        pub fn emit(self: *Self, fixture: *const Fixture) Error!*const Surface {
            var next = self.*;
            next.reset(fixture);
            try next.appendFullDamage(fixture.render_px);
            try next.appendFillPass(fixture.clear_fills, c.HOWL_RENDER_SURFACE_COMMAND_CLEAR_RECT);
            try next.appendFillPass(fixture.background_fills, c.HOWL_RENDER_SURFACE_COMMAND_FILL_RECT);
            try next.appendFillPass(fixture.decoration_fills, c.HOWL_RENDER_SURFACE_COMMAND_FILL_RECT);
            try next.appendSprites(fixture.sprites);
            try next.appendFillPass(fixture.cursor_fills, c.HOWL_RENDER_SURFACE_COMMAND_FILL_RECT);
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

        fn reset(self: *Self, fixture: *const Fixture) void {
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

        fn appendFillPass(self: *Self, fills: []const Fill, kind: u8) Error!void {
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

        fn appendPreparedClears(self: *Self, draws: []const contract.TextClearDraw) Error!void {
            for (draws) |draw| try self.appendPreparedFillCommand(
                draw.x_px,
                draw.y_px,
                draw.width_px,
                draw.height_px,
                draw.color,
                c.HOWL_RENDER_SURFACE_COMMAND_CLEAR_RECT,
            );
        }

        fn appendPreparedBackgrounds(self: *Self, draws: []const contract.TextBackgroundDraw) Error!void {
            for (draws) |draw| try self.appendPreparedFillCommand(
                draw.x_px,
                draw.y_px,
                draw.width_px,
                draw.height_px,
                draw.color,
                c.HOWL_RENDER_SURFACE_COMMAND_FILL_RECT,
            );
        }

        fn appendPreparedDecorations(self: *Self, draws: []const contract.TextDecorationDraw) Error!void {
            for (draws) |draw| try self.appendPreparedFillCommand(
                draw.x_px,
                draw.y_px,
                draw.width_px,
                draw.height_px,
                draw.color,
                c.HOWL_RENDER_SURFACE_COMMAND_FILL_RECT,
            );
        }

        fn appendPreparedCursors(self: *Self, draws: []const contract.TextCursorDraw) Error!void {
            for (draws) |draw| try self.appendPreparedFillCommand(
                draw.x_px,
                draw.y_px,
                draw.width_px,
                draw.height_px,
                draw.color,
                c.HOWL_RENDER_SURFACE_COMMAND_FILL_RECT,
            );
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

        fn appendSprites(self: *Self, sprites: []const Sprite) Error!void {
            for (sprites, 0..) |sprite, sprite_index| {
                const resource = spriteResource(sprite, @intCast(sprite_index + 1));
                try self.appendCreate(resource, sprite);
                try self.appendUpload(resource, sprite);
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

        fn appendCreate(self: *Self, resource: ResourceId, sprite: Sprite) Error!void {
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

        fn appendUpload(self: *Self, resource: ResourceId, sprite: Sprite) Error!void {
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

        fn stagePreparedUploadBytes(self: *Self, sprite: PreparedSprite, bounds: text.Rasterizer.SpriteBounds, width_px: u16, height_px: u16) Error!ByteRange {
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

fn spriteResource(sprite: Sprite, value: u64) ResourceId {
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

fn packedStrideForOutput(output: text.Rasterizer.RasterSpriteOutput) u32 {
    return @as(u32, output.width_px) * sprite_resource_store.bytesPerPixelForPrepared(output.color_mode);
}

fn visualBoundsForDraw(bounds: text.Rasterizer.SpriteBounds, draw: contract.TextSpriteDraw) text.Rasterizer.SpriteBounds {
    if (bounds.width_px != 0) {
        if (bounds.height_px != 0) return bounds;
    }
    return .{ .x_px = 0, .y_px = 0, .width_px = draw.width_px, .height_px = draw.height_px };
}

fn copyPreparedSpriteBytes(target: []u8, target_stride: u32, sprite: PreparedSprite, bounds: text.Rasterizer.SpriteBounds, width_px: u16, height_px: u16) Error!void {
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

fn rect(x_px: i32, y_px: i32, width_px: u16, height_px: u16) Rect {
    return .{ .x_px = x_px, .y_px = y_px, .width_px = width_px, .height_px = height_px };
}

fn glyphRefForTest(glyph_id: u32) GlyphRef {
    return .{
        .atlas_resource = .{
            .value = 1,
            .generation = 1,
            .kind = c.HOWL_RENDER_RESOURCE_GLYPH_ATLAS_ALPHA,
        },
        .atlas_rect = rect(0, 0, 1, 1),
        .x_px = @intCast(glyph_id),
        .y_px = 0,
        .glyph_id = glyph_id,
        .color_rgba = 0xffffffff,
    };
}

fn fillResourcesForTest(resources: *sprite_resource_store.SpriteResourceStore, count: u32) void {
    std.debug.assert(count <= c.HOWL_RENDER_SURFACE_RESOURCES_MAX);
    resources.count = count;
    resources.bytes_count = 0;
    resources.value_next = @as(u64, count) + 1;
    var index: u32 = 0;
    while (index < count) : (index += 1) {
        const value = @as(u64, index) + 1;
        resources.entries[@intCast(index)] = .{
            .key = .{ .value = value },
            .bytes_hash = value,
            .bytes_offset = 0,
            .bytes_count = 0,
            .resource = .{
                .value = value,
                .generation = 1,
                .kind = c.HOWL_RENDER_RESOURCE_SPRITE_ALPHA,
            },
            .width_px = 1,
            .height_px = 1,
            .format = c.HOWL_RENDER_UPLOAD_ALPHA8,
        };
    }
}

fn realizeFixture(comptime limits: Limits, fixture: Fixture, pixels: []u8) !void {
    var emitter = Emitter(limits).init();
    const surface = try emitter.emit(&fixture);
    try realize.realize(surface, pixels, null);
}

test "render surface surface emitter realizes fill pass order equal to oracle" {
    const limits = Limits{ .commands_max = 5, .glyph_refs_max = 5 };
    const clear = [_]Fill{.{ .rect = rect(0, 0, 2, 1), .color_rgba = 0x000000ff }};
    const background = [_]Fill{.{ .rect = rect(0, 0, 1, 1), .color_rgba = 0xff0000ff }};
    const decoration = [_]Fill{.{ .rect = rect(1, 0, 1, 1), .color_rgba = 0x00ff00ff }};
    const cursor = [_]Fill{.{ .rect = rect(0, 0, 2, 1), .color_rgba = 0x0000ff80 }};
    var pixels: [8]u8 = undefined;
    try realizeFixture(limits, .{
        .render_px = .{ .width = 2, .height = 1 },
        .clear_fills = &clear,
        .background_fills = &background,
        .decoration_fills = &decoration,
        .cursor_fills = &cursor,
    }, &pixels);
    const oracle = [_]u8{ 127, 0, 128, 255, 0, 127, 128, 255 };
    try std.testing.expectEqualSlices(u8, &oracle, &pixels);
}

test "render surface surface emitter realizes alpha sprite equal to oracle" {
    const limits = Limits{
        .creates_max = 1,
        .uploads_max = 1,
        .commands_max = 1,
        .retires_max = 1,
        .upload_bytes_max = 2,
    };
    const sprite_bytes = [_]u8{ 255, 128 };
    const sprites = [_]Sprite{.{
        .rect = rect(0, 0, 2, 1),
        .color_rgba = 0xff000080,
        .bytes = &sprite_bytes,
        .width_px = 2,
        .height_px = 1,
        .stride_bytes = 2,
        .color_mode = .alpha,
    }};
    var pixels: [8]u8 = undefined;
    try realizeFixture(limits, .{
        .render_px = .{ .width = 2, .height = 1 },
        .sprites = &sprites,
    }, &pixels);
    const oracle = [_]u8{ 128, 0, 0, 255, 64, 0, 0, 255 };
    try std.testing.expectEqualSlices(u8, &oracle, &pixels);
}

test "render surface surface emitter realizes color sprite equal to oracle" {
    const limits = Limits{
        .creates_max = 1,
        .uploads_max = 1,
        .commands_max = 1,
        .retires_max = 1,
        .upload_bytes_max = 4,
    };
    const sprite_bytes = [_]u8{ 0, 255, 0, 128 };
    const sprites = [_]Sprite{.{
        .rect = rect(0, 0, 1, 1),
        .color_rgba = 0,
        .bytes = &sprite_bytes,
        .width_px = 1,
        .height_px = 1,
        .stride_bytes = 4,
        .color_mode = .color,
    }};
    var pixels: [4]u8 = undefined;
    try realizeFixture(limits, .{
        .render_px = .{ .width = 1, .height = 1 },
        .sprites = &sprites,
    }, &pixels);
    const oracle = [_]u8{ 0, 128, 0, 255 };
    try std.testing.expectEqualSlices(u8, &oracle, &pixels);
}

test "render surface surface emitter batches two glyph refs into one run command" {
    var emitter = Emitter(.{ .commands_max = 1, .glyph_refs_max = 2 }).init();
    try emitter.appendGlyphRef(glyphRefForTest(1));
    try emitter.appendGlyphRef(glyphRefForTest(2));
    emitter.publishSurface();

    const surface_value = emitter.surface();
    try std.testing.expectEqual(@as(u32, 1), surface_value.commands.count);
    try std.testing.expectEqual(
        c.HOWL_RENDER_SURFACE_COMMAND_DRAW_GLYPH_RUN,
        surface_value.commands.ptr[0].kind,
    );
    try std.testing.expectEqual(@as(u32, 2), surface_value.commands.ptr[0].glyphs.count);
    try std.testing.expectEqual(@as(u32, 1), surface_value.commands.ptr[0].glyphs.ptr[0].glyph_id);
    try std.testing.expectEqual(@as(u32, 2), surface_value.commands.ptr[0].glyphs.ptr[1].glyph_id);
}

test "render surface surface emitter starts a second glyph run after run capacity" {
    const glyphs_max: u32 = c.HOWL_RENDER_SURFACE_GLYPHS_PER_RUN_MAX + 1;
    var emitter = Emitter(.{ .commands_max = 2, .glyph_refs_max = glyphs_max }).init();
    var glyph_index: u32 = 0;
    while (glyph_index < glyphs_max) : (glyph_index += 1) {
        try emitter.appendGlyphRef(glyphRefForTest(glyph_index + 1));
    }
    emitter.publishSurface();

    const surface_value = emitter.surface();
    try std.testing.expectEqual(@as(u32, 2), surface_value.commands.count);
    try std.testing.expectEqual(
        @as(u32, c.HOWL_RENDER_SURFACE_GLYPHS_PER_RUN_MAX),
        surface_value.commands.ptr[0].glyphs.count,
    );
    try std.testing.expectEqual(@as(u32, 1), surface_value.commands.ptr[1].glyphs.count);
    try std.testing.expectEqual(
        @as(u32, c.HOWL_RENDER_SURFACE_GLYPHS_PER_RUN_MAX),
        surface_value.commands.ptr[0].glyphs.ptr[c.HOWL_RENDER_SURFACE_GLYPHS_PER_RUN_MAX - 1].glyph_id,
    );
    try std.testing.expectEqual(glyphs_max, surface_value.commands.ptr[1].glyphs.ptr[0].glyph_id);
}

test "render surface surface emitter emits sprite retires after final use" {
    const limits = Limits{
        .creates_max = 1,
        .uploads_max = 1,
        .commands_max = 1,
        .retires_max = 1,
        .upload_bytes_max = 1,
    };
    const sprite_bytes = [_]u8{255};
    const sprites = [_]Sprite{.{
        .rect = rect(0, 0, 1, 1),
        .color_rgba = 0xffffffff,
        .bytes = &sprite_bytes,
        .width_px = 1,
        .height_px = 1,
        .stride_bytes = 1,
        .color_mode = .alpha,
    }};
    var emitter = Emitter(limits).init();
    const surface = try emitter.emit(&.{
        .render_px = .{ .width = 1, .height = 1 },
        .sprites = &sprites,
    });
    try std.testing.expectEqual(@as(u32, 1), surface.retires.count);
    try std.testing.expectEqual(@as(u64, 1), surface.retires.ptr[0].retire_seq);
    var pixels: [4]u8 = undefined;
    try realize.realize(surface, &pixels, null);
    const oracle = [_]u8{ 255, 255, 255, 255 };
    try std.testing.expectEqualSlices(u8, &oracle, &pixels);
}

test "render surface surface emitter rejects command bound overflow" {
    const limits = Limits{ .commands_max = 1, .glyph_refs_max = 1 };
    const fills = [_]Fill{
        .{ .rect = rect(0, 0, 1, 1), .color_rgba = 0xffffffff },
        .{ .rect = rect(0, 0, 1, 1), .color_rgba = 0xffffffff },
    };
    var emitter = Emitter(limits).init();
    try std.testing.expectError(error.CommandBoundOverflow, emitter.emit(&.{
        .render_px = .{ .width = 1, .height = 1 },
        .background_fills = &fills,
    }));
}

test "render surface surface emitter rejects upload bound overflow" {
    const limits = Limits{
        .creates_max = 2,
        .uploads_max = 1,
        .commands_max = 2,
        .retires_max = 2,
        .upload_bytes_max = 2,
    };
    const one = [_]u8{255};
    const sprites = [_]Sprite{
        .{ .rect = rect(0, 0, 1, 1), .color_rgba = 0xffffffff, .bytes = &one, .width_px = 1, .height_px = 1, .stride_bytes = 1, .color_mode = .alpha },
        .{ .rect = rect(0, 0, 1, 1), .color_rgba = 0xffffffff, .bytes = &one, .width_px = 1, .height_px = 1, .stride_bytes = 1, .color_mode = .alpha },
    };
    var emitter = Emitter(limits).init();
    try std.testing.expectError(error.UploadBoundOverflow, emitter.emit(&.{
        .render_px = .{ .width = 1, .height = 1 },
        .sprites = &sprites,
    }));
}

test "render surface surface emitter rejects retire bound overflow" {
    const limits = Limits{
        .creates_max = 2,
        .uploads_max = 2,
        .commands_max = 2,
        .retires_max = 1,
        .upload_bytes_max = 2,
    };
    const one = [_]u8{255};
    const sprites = [_]Sprite{
        .{ .rect = rect(0, 0, 1, 1), .color_rgba = 0xffffffff, .bytes = &one, .width_px = 1, .height_px = 1, .stride_bytes = 1, .color_mode = .alpha },
        .{ .rect = rect(0, 0, 1, 1), .color_rgba = 0xffffffff, .bytes = &one, .width_px = 1, .height_px = 1, .stride_bytes = 1, .color_mode = .alpha },
    };
    var emitter = Emitter(limits).init();
    try std.testing.expectError(error.RetireBoundOverflow, emitter.emit(&.{
        .render_px = .{ .width = 1, .height = 1 },
        .sprites = &sprites,
    }));
}

test "render surface surface emitter rejects upload byte total overflow" {
    const limits = Limits{
        .creates_max = 1,
        .uploads_max = 1,
        .commands_max = 1,
        .retires_max = 1,
        .upload_bytes_max = 1,
    };
    const two = [_]u8{ 255, 255 };
    const sprites = [_]Sprite{.{
        .rect = rect(0, 0, 2, 1),
        .color_rgba = 0xffffffff,
        .bytes = &two,
        .width_px = 2,
        .height_px = 1,
        .stride_bytes = 2,
        .color_mode = .alpha,
    }};
    var emitter = Emitter(limits).init();
    try std.testing.expectError(error.UploadBytesOverflow, emitter.emit(&.{
        .render_px = .{ .width = 2, .height = 1 },
        .sprites = &sprites,
    }));
}

test "render surface surface emitter leaves oracle path independent after emission failure" {
    const limits = Limits{ .commands_max = 1, .glyph_refs_max = 1 };
    const fill = [_]Fill{.{ .rect = rect(0, 0, 1, 1), .color_rgba = 0xff0000ff }};
    const too_many = [_]Fill{
        .{ .rect = rect(0, 0, 1, 1), .color_rgba = 0x00ff00ff },
        .{ .rect = rect(0, 0, 1, 1), .color_rgba = 0x0000ffff },
    };
    var emitter = Emitter(limits).init();
    const accepted = try emitter.emit(&.{
        .render_px = .{ .width = 1, .height = 1 },
        .background_fills = &fill,
    });
    try std.testing.expectError(error.CommandBoundOverflow, emitter.emit(&.{
        .render_px = .{ .width = 1, .height = 1 },
        .background_fills = &too_many,
    }));
    try std.testing.expectEqual(@as(*const Surface, accepted), emitter.surface());
    var pixels: [4]u8 = undefined;
    try realize.realize(emitter.surface(), &pixels, null);
    const oracle = [_]u8{ 255, 0, 0, 255 };
    try std.testing.expectEqualSlices(u8, &oracle, &pixels);
}

test "render surface surface emitter realizes prepared fill surface equal to full rgba oracle" {
    const allocator = std.testing.allocator;
    var session = text_session.TextSession.init(allocator);
    defer session.deinit();

    const clear = [_]contract.TextClearDraw{clearDraw(0, 0, 2, 1, rgba(0, 0, 0, 255))};
    const background = [_]contract.TextBackgroundDraw{
        backgroundDraw(0, 0, 1, 1, rgba(255, 0, 0, 255)),
    };
    const decoration = [_]contract.TextDecorationDraw{
        decorationDraw(1, 0, 1, 1, rgba(0, 255, 0, 255)),
    };
    const cursor = [_]contract.TextCursorDraw{
        cursorDraw(0, 0, 2, 1, rgba(0, 0, 255, 128)),
    };
    const prepared = preparedSurface(.{
        .clear_draws = &clear,
        .background_draws = &background,
        .decoration_draws = &decoration,
        .cursor_draws = &cursor,
        .width_px = 2,
        .height_px = 1,
    });
    try expectPreparedEmissionEqualsCompose(allocator, &session, &prepared, null);
}

test "render surface surface emitter emits full prepared surface clear before fills" {
    const allocator = std.testing.allocator;
    var session = text_session.TextSession.init(allocator);
    defer session.deinit();

    const background = [_]contract.TextBackgroundDraw{
        backgroundDraw(0, 0, 1, 1, rgba(255, 0, 0, 255)),
    };
    const prepared = preparedSurface(.{
        .background_draws = &background,
        .width_px = 2,
        .height_px = 1,
    });
    const PreparedEmitter = Emitter(.{});
    const emitter = try allocator.create(PreparedEmitter);
    defer allocator.destroy(emitter);
    emitter.* = .{};
    var resources = sprite_resource_store.SpriteResourceStore.init();
    const surface = try emitter.emitPrepared(&resources, &session, &prepared);

    try std.testing.expectEqual(@as(u32, 2), surface.commands.count);
    try std.testing.expectEqual(c.HOWL_RENDER_SURFACE_COMMAND_CLEAR_RECT, surface.commands.ptr[0].kind);
    try std.testing.expectEqual(@as(i32, 0), surface.commands.ptr[0].rect.x_px);
    try std.testing.expectEqual(@as(i32, 0), surface.commands.ptr[0].rect.y_px);
    try std.testing.expectEqual(@as(u16, 2), surface.commands.ptr[0].rect.width_px);
    try std.testing.expectEqual(@as(u16, 1), surface.commands.ptr[0].rect.height_px);
    try std.testing.expectEqual(c.HOWL_RENDER_SURFACE_COMMAND_FILL_RECT, surface.commands.ptr[1].kind);
    try expectPreparedEmissionEqualsCompose(allocator, &session, &prepared, null);
}

test "render surface surface emitter keeps partial prepared surface patch shaped" {
    const allocator = std.testing.allocator;
    var session = text_session.TextSession.init(allocator);
    defer session.deinit();

    const background = [_]contract.TextBackgroundDraw{
        backgroundDraw(0, 0, 1, 1, rgba(255, 0, 0, 255)),
    };
    const prepared = preparedSurface(.{
        .background_draws = &background,
        .width_px = 2,
        .height_px = 1,
        .full_redraw = false,
    });
    const PreparedEmitter = Emitter(.{});
    const emitter = try allocator.create(PreparedEmitter);
    defer allocator.destroy(emitter);
    emitter.* = .{};
    var resources = sprite_resource_store.SpriteResourceStore.init();
    const surface = try emitter.emitPrepared(&resources, &session, &prepared);

    try std.testing.expectEqual(@as(u32, 1), surface.commands.count);
    try std.testing.expectEqual(c.HOWL_RENDER_SURFACE_COMMAND_FILL_RECT, surface.commands.ptr[0].kind);
}

test "render surface surface emitter skips zero area prepared fills" {
    const allocator = std.testing.allocator;
    var session = text_session.TextSession.init(allocator);
    defer session.deinit();

    const background = [_]contract.TextBackgroundDraw{
        backgroundDraw(0, 0, 0, 1, rgba(255, 0, 0, 255)),
        backgroundDraw(0, 0, 1, 0, rgba(0, 255, 0, 255)),
        backgroundDraw(0, 0, 1, 1, rgba(0, 0, 255, 255)),
    };
    const prepared = preparedSurface(.{
        .background_draws = &background,
        .width_px = 1,
        .height_px = 1,
    });
    const PreparedEmitter = Emitter(.{});
    const emitter = try allocator.create(PreparedEmitter);
    defer allocator.destroy(emitter);
    emitter.* = .{};
    var resources = sprite_resource_store.SpriteResourceStore.init();
    const surface = try emitter.emitPrepared(&resources, &session, &prepared);

    try std.testing.expectEqual(@as(u32, 2), surface.commands.count);
    try std.testing.expectEqual(c.HOWL_RENDER_SURFACE_COMMAND_CLEAR_RECT, surface.commands.ptr[0].kind);
    try std.testing.expectEqual(c.HOWL_RENDER_SURFACE_COMMAND_FILL_RECT, surface.commands.ptr[1].kind);
    try std.testing.expectEqual(@as(u16, 1), surface.commands.ptr[1].rect.width_px);
    try std.testing.expectEqual(@as(u16, 1), surface.commands.ptr[1].rect.height_px);
}

test "render surface surface emitter clips prepared fills to surface" {
    const allocator = std.testing.allocator;
    var session = text_session.TextSession.init(allocator);
    defer session.deinit();

    const background = [_]contract.TextBackgroundDraw{
        backgroundDraw(-1, 0, 2, 1, rgba(255, 0, 0, 255)),
        backgroundDraw(1, 0, 2, 1, rgba(0, 255, 0, 255)),
    };
    const prepared = preparedSurface(.{
        .background_draws = &background,
        .width_px = 2,
        .height_px = 1,
    });
    const PreparedEmitter = Emitter(.{});
    const emitter = try allocator.create(PreparedEmitter);
    defer allocator.destroy(emitter);
    emitter.* = .{};
    var resources = sprite_resource_store.SpriteResourceStore.init();
    const surface = try emitter.emitPrepared(&resources, &session, &prepared);

    try std.testing.expectEqual(@as(u32, 3), surface.commands.count);
    try std.testing.expectEqual(c.HOWL_RENDER_SURFACE_COMMAND_FILL_RECT, surface.commands.ptr[1].kind);
    try std.testing.expectEqual(@as(i32, 0), surface.commands.ptr[1].rect.x_px);
    try std.testing.expectEqual(@as(u16, 1), surface.commands.ptr[1].rect.width_px);
    try std.testing.expectEqual(c.HOWL_RENDER_SURFACE_COMMAND_FILL_RECT, surface.commands.ptr[2].kind);
    try std.testing.expectEqual(@as(i32, 1), surface.commands.ptr[2].rect.x_px);
    try std.testing.expectEqual(@as(u16, 1), surface.commands.ptr[2].rect.width_px);
    try expectPreparedEmissionEqualsCompose(allocator, &session, &prepared, null);
}

test "render surface surface emitter coalesces adjacent prepared fill commands" {
    const allocator = std.testing.allocator;
    var session = text_session.TextSession.init(allocator);
    defer session.deinit();

    const color = rgba(10, 20, 30, 255);
    const background = [_]contract.TextBackgroundDraw{
        backgroundDraw(0, 0, 1, 1, color),
        backgroundDraw(1, 0, 2, 1, color),
        backgroundDraw(3, 0, 1, 1, color),
    };
    const prepared = preparedSurface(.{
        .background_draws = &background,
        .width_px = 4,
        .height_px = 1,
    });

    const PreparedEmitter = Emitter(.{});
    const emitter = try allocator.create(PreparedEmitter);
    defer allocator.destroy(emitter);
    emitter.* = .{};
    var resources = sprite_resource_store.SpriteResourceStore.init();
    const surface = try emitter.emitPrepared(&resources, &session, &prepared);

    try std.testing.expectEqual(@as(u32, 2), surface.commands.count);
    try std.testing.expectEqual(c.HOWL_RENDER_SURFACE_COMMAND_FILL_RECT, surface.commands.ptr[1].kind);
    try std.testing.expectEqual(@as(i32, 0), surface.commands.ptr[1].rect.x_px);
    try std.testing.expectEqual(@as(i32, 0), surface.commands.ptr[1].rect.y_px);
    try std.testing.expectEqual(@as(u16, 4), surface.commands.ptr[1].rect.width_px);
    try std.testing.expectEqual(@as(u16, 1), surface.commands.ptr[1].rect.height_px);
    try expectPreparedEmissionEqualsCompose(allocator, &session, &prepared, null);
}

test "render surface surface emitter does not coalesce distinct prepared fills" {
    const allocator = std.testing.allocator;
    var session = text_session.TextSession.init(allocator);
    defer session.deinit();

    const background = [_]contract.TextBackgroundDraw{
        backgroundDraw(0, 0, 1, 1, rgba(1, 2, 3, 255)),
        backgroundDraw(1, 0, 1, 1, rgba(4, 5, 6, 255)),
        backgroundDraw(3, 0, 1, 1, rgba(4, 5, 6, 255)),
        backgroundDraw(4, 1, 1, 1, rgba(4, 5, 6, 255)),
    };
    const decoration = [_]contract.TextDecorationDraw{
        decorationDraw(0, 0, 1, 1, rgba(4, 5, 6, 255)),
    };
    const prepared = preparedSurface(.{
        .background_draws = &background,
        .decoration_draws = &decoration,
        .width_px = 5,
        .height_px = 2,
    });

    const PreparedEmitter = Emitter(.{});
    const emitter = try allocator.create(PreparedEmitter);
    defer allocator.destroy(emitter);
    emitter.* = .{};
    var resources = sprite_resource_store.SpriteResourceStore.init();
    const surface = try emitter.emitPrepared(&resources, &session, &prepared);

    try std.testing.expectEqual(@as(u32, 6), surface.commands.count);
    try expectPreparedEmissionEqualsCompose(allocator, &session, &prepared, null);
}

test "render surface surface emitter realizes prepared alpha sprite surface equal to full rgba oracle" {
    const allocator = std.testing.allocator;
    var session = text_session.TextSession.init(allocator);
    defer session.deinit();

    var sprite_bytes = [_]u8{ 255, 128 };
    var sprite_draws = [_]contract.TextSpriteDraw{
        spriteDraw(11, 0, 0, 2, 1, rgba(255, 0, 0, 128)),
    };
    var raster_outputs = [_]text.Rasterizer.RasterSpriteOutput{rasterOutput(
        allocator,
        11,
        2,
        1,
        .alpha,
        &sprite_bytes,
        .{},
    )};
    const prepared = preparedSurface(.{
        .sprite_draws = &sprite_draws,
        .raster_outputs = &raster_outputs,
        .width_px = 2,
        .height_px = 1,
    });
    try expectPreparedEmissionEqualsCompose(allocator, &session, &prepared, null);
}

test "render surface surface emitter batches prepared alpha sprite glyph commands" {
    const allocator = std.testing.allocator;
    var session = text_session.TextSession.init(allocator);
    defer session.deinit();

    var sprite_bytes = [_]u8{255};
    var sprite_draws = [_]contract.TextSpriteDraw{
        spriteDraw(111, 0, 0, 1, 1, rgba(255, 255, 255, 255)),
        spriteDraw(111, 1, 0, 1, 1, rgba(255, 255, 255, 255)),
    };
    var raster_outputs = [_]text.Rasterizer.RasterSpriteOutput{rasterOutput(
        allocator,
        111,
        1,
        1,
        .alpha,
        &sprite_bytes,
        .{},
    )};
    const prepared = preparedSurface(.{
        .sprite_draws = &sprite_draws,
        .raster_outputs = &raster_outputs,
        .width_px = 2,
        .height_px = 1,
    });

    const PreparedEmitter = Emitter(.{ .commands_max = 2, .glyph_refs_max = 2 });
    const emitter = try allocator.create(PreparedEmitter);
    defer allocator.destroy(emitter);
    emitter.* = .{};
    var resources = sprite_resource_store.SpriteResourceStore.init();
    const surface = try emitter.emitPrepared(&resources, &session, &prepared);

    try std.testing.expectEqual(@as(u32, 2), surface.commands.count);
    try std.testing.expectEqual(c.HOWL_RENDER_SURFACE_COMMAND_DRAW_GLYPH_RUN, surface.commands.ptr[1].kind);
    try std.testing.expectEqual(@as(u32, 2), surface.commands.ptr[1].glyphs.count);
    try expectPreparedEmissionEqualsCompose(allocator, &session, &prepared, null);
}

test "render surface surface emitter skips fully offscreen prepared alpha sprites" {
    const allocator = std.testing.allocator;
    var session = text_session.TextSession.init(allocator);
    defer session.deinit();

    var sprite_bytes = [_]u8{255};
    var sprite_draws = [_]contract.TextSpriteDraw{
        spriteDraw(114, 2, 0, 1, 1, rgba(255, 255, 255, 255)),
    };
    var raster_outputs = [_]text.Rasterizer.RasterSpriteOutput{rasterOutput(
        allocator,
        114,
        1,
        1,
        .alpha,
        &sprite_bytes,
        .{},
    )};
    const prepared = preparedSurface(.{
        .sprite_draws = &sprite_draws,
        .raster_outputs = &raster_outputs,
        .width_px = 1,
        .height_px = 1,
    });

    const PreparedEmitter = Emitter(.{ .commands_max = 2, .glyph_refs_max = 2 });
    const emitter = try allocator.create(PreparedEmitter);
    defer allocator.destroy(emitter);
    emitter.* = .{};
    var resources = sprite_resource_store.SpriteResourceStore.init();
    const surface = try emitter.emitPrepared(&resources, &session, &prepared);

    try std.testing.expectEqual(@as(u32, 0), surface.creates.count);
    try std.testing.expectEqual(@as(u32, 0), surface.uploads.count);
    try std.testing.expectEqual(@as(u32, 1), surface.commands.count);
    try std.testing.expectEqual(c.HOWL_RENDER_SURFACE_COMMAND_CLEAR_RECT, surface.commands.ptr[0].kind);
    try std.testing.expectEqual(@as(u32, 0), resources.atlas_count);
    try expectPreparedEmissionEqualsCompose(allocator, &session, &prepared, null);
}

test "render surface surface emitter emits over command bound alpha draws with batched glyph runs" {
    const allocator = std.testing.allocator;
    var session = text_session.TextSession.init(allocator);
    defer session.deinit();

    const draws_len: usize = c.HOWL_RENDER_SURFACE_COMMANDS_MAX + 1;
    const sprite_draws = try allocator.alloc(contract.TextSpriteDraw, draws_len);
    defer allocator.free(sprite_draws);
    for (sprite_draws, 0..) |*draw, index| {
        draw.* = spriteDraw(112, @intCast(index), 0, 1, 1, rgba(255, 255, 255, 255));
    }
    var sprite_bytes = [_]u8{255};
    var raster_outputs = [_]text.Rasterizer.RasterSpriteOutput{rasterOutput(
        allocator,
        112,
        1,
        1,
        .alpha,
        &sprite_bytes,
        .{},
    )};
    const prepared = preparedSurface(.{
        .sprite_draws = sprite_draws,
        .raster_outputs = &raster_outputs,
        .width_px = @intCast(draws_len),
        .height_px = 1,
    });

    const glyphs_max: u32 = c.HOWL_RENDER_SURFACE_COMMANDS_MAX + 1;
    const PreparedEmitter = Emitter(.{});
    const emitter = try allocator.create(PreparedEmitter);
    defer allocator.destroy(emitter);
    emitter.* = .{};
    var resources = sprite_resource_store.SpriteResourceStore.init();
    const surface = try emitter.emitPrepared(&resources, &session, &prepared);

    const commands_expected = std.math.divCeil(
        u32,
        glyphs_max,
        c.HOWL_RENDER_SURFACE_GLYPHS_PER_RUN_MAX,
    ) catch unreachable;
    try std.testing.expectEqual(commands_expected + 1, surface.commands.count);
    try std.testing.expect(surface.commands.count < c.HOWL_RENDER_SURFACE_COMMANDS_MAX + 1);
    try std.testing.expectEqual(c.HOWL_RENDER_SURFACE_COMMAND_DRAW_GLYPH_RUN, surface.commands.ptr[1].kind);
    try std.testing.expectEqual(
        @as(u32, c.HOWL_RENDER_SURFACE_GLYPHS_PER_RUN_MAX),
        surface.commands.ptr[1].glyphs.count,
    );
    try std.testing.expectEqual(@as(u32, 1), surface.uploads.count);
}

test "render surface surface emitter preserves command overflow after batched glyph runs" {
    const allocator = std.testing.allocator;
    var session = text_session.TextSession.init(allocator);
    defer session.deinit();

    const draws_len: usize = c.HOWL_RENDER_SURFACE_GLYPHS_PER_RUN_MAX + 1;
    const sprite_draws = try allocator.alloc(contract.TextSpriteDraw, draws_len);
    defer allocator.free(sprite_draws);
    for (sprite_draws, 0..) |*draw, index| {
        draw.* = spriteDraw(113, @intCast(index), 0, 1, 1, rgba(255, 255, 255, 255));
    }
    var sprite_bytes = [_]u8{255};
    var raster_outputs = [_]text.Rasterizer.RasterSpriteOutput{rasterOutput(
        allocator,
        113,
        1,
        1,
        .alpha,
        &sprite_bytes,
        .{},
    )};
    const prepared = preparedSurface(.{
        .sprite_draws = sprite_draws,
        .raster_outputs = &raster_outputs,
        .width_px = @intCast(draws_len),
        .height_px = 1,
    });

    const PreparedEmitter = Emitter(.{ .commands_max = 1, .glyph_refs_max = draws_len });
    const emitter = try allocator.create(PreparedEmitter);
    defer allocator.destroy(emitter);
    emitter.* = .{};
    var resources = sprite_resource_store.SpriteResourceStore.init();
    try std.testing.expectError(
        error.CommandBoundOverflow,
        emitter.emitPrepared(&resources, &session, &prepared),
    );
    try std.testing.expectEqual(@as(u32, 0), emitter.surface().commands.count);
    try std.testing.expectEqual(@as(u32, 0), resources.atlas_count);
}

test "render surface surface emitter emits more than old alpha atlas entry cap" {
    const allocator = std.testing.allocator;
    var session = text_session.TextSession.init(allocator);
    defer session.deinit();

    const PreparedEmitter = Emitter(.{});
    const emitter = try allocator.create(PreparedEmitter);
    defer allocator.destroy(emitter);
    emitter.* = .{};
    var resources = sprite_resource_store.SpriteResourceStore.init();
    var index: u32 = 0;
    while (index <= sprite_resource_store.persistent_sprite_resources_max) : (index += 1) {
        var sprite_bytes = [_]u8{@intCast((index % 251) + 1)};
        var sprite_draws = [_]contract.TextSpriteDraw{
            spriteDraw(10_000 + index, 0, 0, 1, 1, rgba(255, 255, 255, 255)),
        };
        var raster_outputs = [_]text.Rasterizer.RasterSpriteOutput{rasterOutput(
            allocator,
            10_000 + index,
            1,
            1,
            .alpha,
            &sprite_bytes,
            .{},
        )};
        const prepared = preparedSurface(.{
            .sprite_draws = &sprite_draws,
            .raster_outputs = &raster_outputs,
            .width_px = 1,
            .height_px = 1,
        });

        const surface = try emitter.emitPrepared(&resources, &session, &prepared);
        try std.testing.expectEqual(@as(u32, 1), surface.uploads.count);
        try std.testing.expectEqual(@as(u32, 2), surface.commands.count);
        try std.testing.expectEqual(c.HOWL_RENDER_SURFACE_COMMAND_DRAW_GLYPH_RUN, surface.commands.ptr[1].kind);
    }
    try std.testing.expectEqual(sprite_resource_store.persistent_sprite_resources_max + 1, resources.atlas_count);
}

test "render surface surface emitter emits more than old alpha atlas hard cap" {
    const allocator = std.testing.allocator;
    var session = text_session.TextSession.init(allocator);
    defer session.deinit();

    const old_alpha_atlas_entry_limit: u32 = 1024;
    const PreparedEmitter = Emitter(.{});
    const emitter = try allocator.create(PreparedEmitter);
    defer allocator.destroy(emitter);
    emitter.* = .{};
    var resources = sprite_resource_store.SpriteResourceStore.init();
    var index: u32 = 0;
    while (index <= old_alpha_atlas_entry_limit) : (index += 1) {
        var sprite_bytes = [_]u8{@intCast((index % 251) + 1)};
        var sprite_draws = [_]contract.TextSpriteDraw{
            spriteDraw(20_000 + index, 0, 0, 1, 1, rgba(255, 255, 255, 255)),
        };
        var raster_outputs = [_]text.Rasterizer.RasterSpriteOutput{rasterOutput(
            allocator,
            20_000 + index,
            1,
            1,
            .alpha,
            &sprite_bytes,
            .{},
        )};
        const prepared = preparedSurface(.{
            .sprite_draws = &sprite_draws,
            .raster_outputs = &raster_outputs,
            .width_px = 1,
            .height_px = 1,
        });

        const surface = try emitter.emitPrepared(&resources, &session, &prepared);
        try std.testing.expectEqual(c.HOWL_RENDER_SURFACE_COMMAND_DRAW_GLYPH_RUN, surface.commands.ptr[1].kind);
    }
    try std.testing.expectEqual(old_alpha_atlas_entry_limit + 1, resources.atlas_count);
}

test "render surface surface emitter realizes prepared color sprite surface equal to full rgba oracle" {
    const allocator = std.testing.allocator;
    var session = text_session.TextSession.init(allocator);
    defer session.deinit();

    var sprite_bytes = [_]u8{ 0, 255, 0, 128 };
    var sprite_draws = [_]contract.TextSpriteDraw{
        spriteDraw(12, 0, 0, 1, 1, rgba(255, 0, 0, 255)),
    };
    var raster_outputs = [_]text.Rasterizer.RasterSpriteOutput{rasterOutput(
        allocator,
        12,
        1,
        1,
        .color,
        &sprite_bytes,
        .{},
    )};
    const prepared = preparedSurface(.{
        .sprite_draws = &sprite_draws,
        .raster_outputs = &raster_outputs,
        .width_px = 1,
        .height_px = 1,
    });
    try expectPreparedEmissionEqualsCompose(allocator, &session, &prepared, null);
}

test "render surface surface emitter realizes sprite visual bounds like oracle" {
    const allocator = std.testing.allocator;
    var session = text_session.TextSession.init(allocator);
    defer session.deinit();

    var sprite_bytes = [_]u8{
        0, 200, 0,
        0, 100, 0,
    };
    var sprite_draws = [_]contract.TextSpriteDraw{
        spriteDraw(13, 0, 0, 3, 2, rgba(0, 0, 255, 255)),
    };
    var raster_outputs = [_]text.Rasterizer.RasterSpriteOutput{rasterOutput(
        allocator,
        13,
        3,
        2,
        .alpha,
        &sprite_bytes,
        .{ .x_px = 1, .y_px = 0, .width_px = 1, .height_px = 2 },
    )};
    const prepared = preparedSurface(.{
        .sprite_draws = &sprite_draws,
        .raster_outputs = &raster_outputs,
        .width_px = 3,
        .height_px = 2,
    });
    try expectPreparedEmissionEqualsCompose(allocator, &session, &prepared, null);
}

test "render surface surface emitter persists prepared sprite resource across surfaces" {
    const allocator = std.testing.allocator;
    var session = text_session.TextSession.init(allocator);
    defer session.deinit();

    var sprite_bytes = [_]u8{ 255, 128 };
    var sprite_draws = [_]contract.TextSpriteDraw{
        spriteDraw(31, 0, 0, 2, 1, rgba(255, 0, 0, 128)),
    };
    var raster_outputs = [_]text.Rasterizer.RasterSpriteOutput{rasterOutput(
        allocator,
        31,
        2,
        1,
        .alpha,
        &sprite_bytes,
        .{},
    )};
    const prepared = preparedSurface(.{
        .sprite_draws = &sprite_draws,
        .raster_outputs = &raster_outputs,
        .width_px = 2,
        .height_px = 1,
    });

    const PreparedEmitter = Emitter(.{});
    const emitter = try allocator.create(PreparedEmitter);
    defer allocator.destroy(emitter);
    emitter.* = .{};
    var resources = sprite_resource_store.SpriteResourceStore.init();
    const surface1 = try emitter.emitPrepared(&resources, &session, &prepared);
    try std.testing.expectEqual(@as(u32, 1), surface1.creates.count);
    try std.testing.expectEqual(@as(u32, 1), surface1.uploads.count);
    try std.testing.expectEqual(@as(u32, 2), surface1.commands.count);
    try std.testing.expectEqual(@as(u32, 0), surface1.retires.count);
    const resource = surface1.commands.ptr[1].glyphs.ptr[0].atlas_resource;
    try std.testing.expect(resource.value != 0);
    try std.testing.expectEqual(@as(u32, 1), resource.generation);

    const retained = try allocator.create(realize.ResourceStore);
    defer allocator.destroy(retained);
    retained.count = 0;
    retained.bytes_count = 0;
    const oracle = try prepared_buffer.compose(allocator, null, &session, &prepared);
    defer allocator.free(oracle);
    const realized1 = try allocator.alloc(u8, oracle.len);
    defer allocator.free(realized1);
    try realize.realizeRetained(surface1, realized1, null, retained);
    try std.testing.expectEqualSlices(u8, oracle, realized1);

    const surface2 = try emitter.emitPrepared(&resources, &session, &prepared);
    try std.testing.expectEqual(@as(u32, 0), surface2.creates.count);
    try std.testing.expectEqual(@as(u32, 0), surface2.uploads.count);
    try std.testing.expectEqual(@as(u32, 2), surface2.commands.count);
    try std.testing.expectEqual(@as(u32, 0), surface2.retires.count);
    try std.testing.expectEqual(resource.value, surface2.commands.ptr[1].glyphs.ptr[0].atlas_resource.value);
    try std.testing.expectEqual(resource.generation, surface2.commands.ptr[1].glyphs.ptr[0].atlas_resource.generation);
    const realized2 = try allocator.alloc(u8, oracle.len);
    defer allocator.free(realized2);
    try realize.realizeRetained(surface2, realized2, null, retained);
    try std.testing.expectEqualSlices(u8, oracle, realized2);
}

test "render surface surface emitter allocates distinct monotonic sprite resources" {
    const allocator = std.testing.allocator;
    var session = text_session.TextSession.init(allocator);
    defer session.deinit();

    var first_bytes = [_]u8{255};
    var first_draws = [_]contract.TextSpriteDraw{
        spriteDraw(41, 0, 0, 1, 1, rgba(255, 255, 255, 255)),
    };
    var first_outputs = [_]text.Rasterizer.RasterSpriteOutput{rasterOutput(
        allocator,
        41,
        1,
        1,
        .alpha,
        &first_bytes,
        .{},
    )};
    var second_bytes = [_]u8{128};
    var second_draws = [_]contract.TextSpriteDraw{
        spriteDraw(42, 0, 0, 1, 1, rgba(255, 255, 255, 255)),
    };
    var second_outputs = [_]text.Rasterizer.RasterSpriteOutput{rasterOutput(
        allocator,
        42,
        1,
        1,
        .alpha,
        &second_bytes,
        .{},
    )};
    const first = preparedSurface(.{
        .sprite_draws = &first_draws,
        .raster_outputs = &first_outputs,
        .width_px = 1,
        .height_px = 1,
    });
    const second = preparedSurface(.{
        .sprite_draws = &second_draws,
        .raster_outputs = &second_outputs,
        .width_px = 1,
        .height_px = 1,
    });

    const PreparedEmitter = Emitter(.{});
    const emitter = try allocator.create(PreparedEmitter);
    defer allocator.destroy(emitter);
    emitter.* = .{};
    var resources = sprite_resource_store.SpriteResourceStore.init();
    const surface1 = try emitter.emitPrepared(&resources, &session, &first);
    const first_resource = surface1.commands.ptr[1].glyphs.ptr[0].atlas_resource;
    const surface2 = try emitter.emitPrepared(&resources, &session, &second);
    const second_resource = surface2.commands.ptr[1].glyphs.ptr[0].atlas_resource;
    try std.testing.expectEqual(@as(u64, 1), first_resource.value);
    try std.testing.expectEqual(first_resource.value, second_resource.value);
    try std.testing.expectEqual(@as(u32, 1), second_resource.generation);
}

test "render surface surface emitter allocates distinct resource for changed sprite bytes" {
    const allocator = std.testing.allocator;
    var session = text_session.TextSession.init(allocator);
    defer session.deinit();

    var first_bytes = [_]u8{255};
    var first_draws = [_]contract.TextSpriteDraw{
        spriteDraw(43, 0, 0, 1, 1, rgba(255, 255, 255, 255)),
    };
    var first_outputs = [_]text.Rasterizer.RasterSpriteOutput{rasterOutput(
        allocator,
        43,
        1,
        1,
        .alpha,
        &first_bytes,
        .{},
    )};
    var second_bytes = [_]u8{128};
    var second_draws = [_]contract.TextSpriteDraw{
        spriteDraw(43, 0, 0, 1, 1, rgba(255, 255, 255, 255)),
    };
    var second_outputs = [_]text.Rasterizer.RasterSpriteOutput{rasterOutput(
        allocator,
        43,
        1,
        1,
        .alpha,
        &second_bytes,
        .{},
    )};
    const first = preparedSurface(.{
        .sprite_draws = &first_draws,
        .raster_outputs = &first_outputs,
        .width_px = 1,
        .height_px = 1,
    });
    const second = preparedSurface(.{
        .sprite_draws = &second_draws,
        .raster_outputs = &second_outputs,
        .width_px = 1,
        .height_px = 1,
    });

    const PreparedEmitter = Emitter(.{});
    const emitter = try allocator.create(PreparedEmitter);
    defer allocator.destroy(emitter);
    emitter.* = .{};
    var resources = sprite_resource_store.SpriteResourceStore.init();
    const surface1 = try emitter.emitPrepared(&resources, &session, &first);
    const first_resource = surface1.commands.ptr[1].glyphs.ptr[0].atlas_resource;
    const surface2 = try emitter.emitPrepared(&resources, &session, &second);
    const second_resource = surface2.commands.ptr[1].glyphs.ptr[0].atlas_resource;
    try std.testing.expectEqual(@as(u64, 1), first_resource.value);
    try std.testing.expectEqual(first_resource.value, second_resource.value);
    try std.testing.expectEqual(@as(u32, 1), first_resource.generation);
    try std.testing.expectEqual(@as(u32, 1), second_resource.generation);
    try std.testing.expectEqual(@as(u32, 0), surface1.retires.count);
    try std.testing.expectEqual(@as(u32, 0), surface2.retires.count);
}

test "render surface surface emitter allocates distinct resource for changed sprite dimensions" {
    const allocator = std.testing.allocator;
    var session = text_session.TextSession.init(allocator);
    defer session.deinit();

    var first_bytes = [_]u8{255};
    var first_draws = [_]contract.TextSpriteDraw{
        spriteDraw(44, 0, 0, 1, 1, rgba(255, 255, 255, 255)),
    };
    var first_outputs = [_]text.Rasterizer.RasterSpriteOutput{rasterOutput(
        allocator,
        44,
        1,
        1,
        .alpha,
        &first_bytes,
        .{},
    )};
    var second_bytes = [_]u8{ 255, 128 };
    var second_draws = [_]contract.TextSpriteDraw{
        spriteDraw(44, 0, 0, 2, 1, rgba(255, 255, 255, 255)),
    };
    var second_outputs = [_]text.Rasterizer.RasterSpriteOutput{rasterOutput(
        allocator,
        44,
        2,
        1,
        .alpha,
        &second_bytes,
        .{},
    )};
    const first = preparedSurface(.{
        .sprite_draws = &first_draws,
        .raster_outputs = &first_outputs,
        .width_px = 2,
        .height_px = 1,
    });
    const second = preparedSurface(.{
        .sprite_draws = &second_draws,
        .raster_outputs = &second_outputs,
        .width_px = 2,
        .height_px = 1,
    });

    const PreparedEmitter = Emitter(.{});
    const emitter = try allocator.create(PreparedEmitter);
    defer allocator.destroy(emitter);
    emitter.* = .{};
    var resources = sprite_resource_store.SpriteResourceStore.init();
    const surface1 = try emitter.emitPrepared(&resources, &session, &first);
    const first_resource = surface1.commands.ptr[1].glyphs.ptr[0].atlas_resource;
    const surface2 = try emitter.emitPrepared(&resources, &session, &second);
    const second_resource = surface2.commands.ptr[1].glyphs.ptr[0].atlas_resource;
    try std.testing.expectEqual(@as(u64, 1), first_resource.value);
    try std.testing.expectEqual(first_resource.value, second_resource.value);
    try std.testing.expectEqual(@as(u32, 1), first_resource.generation);
    try std.testing.expectEqual(@as(u32, 1), second_resource.generation);
    try std.testing.expectEqual(@as(u32, 0), surface1.retires.count);
    try std.testing.expectEqual(@as(u32, 0), surface2.retires.count);
}

test "render surface surface emitter failure preserves accepted persistent resource state" {
    const allocator = std.testing.allocator;
    var session = text_session.TextSession.init(allocator);
    defer session.deinit();

    var bytes = [_]u8{ 255, 255 };
    var draws = [_]contract.TextSpriteDraw{
        spriteDraw(51, 0, 0, 2, 1, rgba(255, 255, 255, 255)),
    };
    var outputs = [_]text.Rasterizer.RasterSpriteOutput{rasterOutput(
        allocator,
        51,
        2,
        1,
        .alpha,
        &bytes,
        .{},
    )};
    const prepared = preparedSurface(.{
        .sprite_draws = &draws,
        .raster_outputs = &outputs,
        .width_px = 2,
        .height_px = 1,
    });

    var emitter = Emitter(.{
        .commands_max = 1,
        .glyph_refs_max = 1,
        .upload_bytes_max = 1,
    }).init();
    var resources = sprite_resource_store.SpriteResourceStore.init();
    try std.testing.expectError(
        error.UploadBytesOverflow,
        emitter.emitPrepared(&resources, &session, &prepared),
    );
    try std.testing.expectEqual(@as(u32, 0), resources.count);
    try std.testing.expectEqual(@as(u32, 0), emitter.surface().creates.count);
    try std.testing.expectEqual(@as(u32, 0), emitter.surface().commands.count);
}

test "render surface surface emitter resource id exhaustion preserves accepted state" {
    const allocator = std.testing.allocator;
    var session = text_session.TextSession.init(allocator);
    defer session.deinit();

    var bytes = [_]u8{ 255, 255, 255, 255 };
    var draws = [_]contract.TextSpriteDraw{
        spriteDraw(61, 0, 0, 1, 1, rgba(255, 255, 255, 255)),
    };
    var outputs = [_]text.Rasterizer.RasterSpriteOutput{rasterOutput(
        allocator,
        61,
        1,
        1,
        .color,
        &bytes,
        .{},
    )};
    const prepared = preparedSurface(.{
        .sprite_draws = &draws,
        .raster_outputs = &outputs,
        .width_px = 1,
        .height_px = 1,
    });

    const PreparedEmitter = Emitter(.{});
    const emitter = try allocator.create(PreparedEmitter);
    defer allocator.destroy(emitter);
    emitter.* = .{};
    var resources = sprite_resource_store.SpriteResourceStore.init();
    resources.value_next = 0;
    try std.testing.expectError(
        error.ResourceBoundOverflow,
        emitter.emitPrepared(&resources, &session, &prepared),
    );
    try std.testing.expectEqual(@as(u32, 0), resources.count);
    try std.testing.expectEqual(@as(u32, 0), emitter.surface().creates.count);
    try std.testing.expectEqual(@as(u32, 0), emitter.surface().commands.count);
}

test "render surface surface emitter emits transient sprite beyond persistent budget" {
    const allocator = std.testing.allocator;
    var session = text_session.TextSession.init(allocator);
    defer session.deinit();

    var bytes = [_]u8{ 255, 255, 255, 255 };
    var draws = [_]contract.TextSpriteDraw{
        spriteDraw(62, 0, 0, 1, 1, rgba(255, 255, 255, 255)),
    };
    var outputs = [_]text.Rasterizer.RasterSpriteOutput{rasterOutput(
        allocator,
        62,
        1,
        1,
        .color,
        &bytes,
        .{},
    )};
    const prepared = preparedSurface(.{
        .sprite_draws = &draws,
        .raster_outputs = &outputs,
        .width_px = 1,
        .height_px = 1,
    });

    const PreparedEmitter = Emitter(.{});
    const emitter = try allocator.create(PreparedEmitter);
    defer allocator.destroy(emitter);
    emitter.* = .{};
    var resources = sprite_resource_store.SpriteResourceStore.init();
    fillResourcesForTest(&resources, sprite_resource_store.persistent_sprite_resources_max);
    const surface = try emitter.emitPrepared(&resources, &session, &prepared);
    try std.testing.expectEqual(sprite_resource_store.persistent_sprite_resources_max, resources.count);
    try std.testing.expectEqual(@as(u32, 1), surface.creates.count);
    try std.testing.expectEqual(@as(u32, 1), surface.uploads.count);
    try std.testing.expectEqual(@as(u32, 2), surface.commands.count);
    try std.testing.expectEqual(@as(u32, 1), surface.retires.count);
    try std.testing.expectEqual(surface.commands.ptr[1].resource.value, surface.retires.ptr[0].resource.value);
    try std.testing.expectEqual(@as(u64, 2), surface.retires.ptr[0].retire_seq);
}

test "render surface surface emitter reports exact transient retire bound" {
    const allocator = std.testing.allocator;
    var session = text_session.TextSession.init(allocator);
    defer session.deinit();

    var first_bytes = [_]u8{ 255, 255, 255, 255 };
    var second_bytes = [_]u8{ 128, 128, 128, 255 };
    var draws = [_]contract.TextSpriteDraw{
        spriteDraw(63, 0, 0, 1, 1, rgba(255, 255, 255, 255)),
        spriteDraw(64, 0, 0, 1, 1, rgba(255, 255, 255, 255)),
    };
    var outputs = [_]text.Rasterizer.RasterSpriteOutput{
        rasterOutput(allocator, 63, 1, 1, .color, &first_bytes, .{}),
        rasterOutput(allocator, 64, 1, 1, .color, &second_bytes, .{}),
    };
    const prepared = preparedSurface(.{
        .sprite_draws = &draws,
        .raster_outputs = &outputs,
        .width_px = 1,
        .height_px = 1,
    });

    var emitter = Emitter(.{
        .commands_max = 3,
        .glyph_refs_max = 3,
        .retires_max = 1,
    }).init();
    var resources = sprite_resource_store.SpriteResourceStore.init();
    fillResourcesForTest(&resources, sprite_resource_store.persistent_sprite_resources_max);
    try std.testing.expectError(
        error.RetireBoundOverflow,
        emitter.emitPrepared(&resources, &session, &prepared),
    );
    try std.testing.expectEqual(sprite_resource_store.persistent_sprite_resources_max, resources.count);
    try std.testing.expectEqual(@as(u32, 0), emitter.surface().commands.count);
}

test "render surface surface emitter rejects missing prepared sprite without mutating accepted surface" {
    const allocator = std.testing.allocator;
    var session = text_session.TextSession.init(allocator);
    defer session.deinit();

    const background = [_]contract.TextBackgroundDraw{
        backgroundDraw(0, 0, 1, 1, rgba(255, 0, 0, 255)),
    };
    var accepted_prepared = preparedSurface(.{
        .background_draws = &background,
        .width_px = 1,
        .height_px = 1,
    });
    var missing_sprite_draws = [_]contract.TextSpriteDraw{
        spriteDraw(99, 0, 0, 1, 1, rgba(255, 255, 255, 255)),
    };
    var missing_prepared = preparedSurface(.{
        .sprite_draws = &missing_sprite_draws,
        .width_px = 1,
        .height_px = 1,
    });

    const PreparedEmitter = Emitter(.{});
    const emitter = try allocator.create(PreparedEmitter);
    defer allocator.destroy(emitter);
    emitter.* = .{};
    var resources = sprite_resource_store.SpriteResourceStore.init();
    const accepted_surface = try emitter.emitPrepared(&resources, &session, &accepted_prepared);
    try std.testing.expectError(
        error.MissingPreparedSprite,
        emitter.emitPrepared(&resources, &session, &missing_prepared),
    );
    try std.testing.expectEqual(accepted_surface, emitter.surface());

    const oracle = try prepared_buffer.compose(allocator, null, &session, &accepted_prepared);
    defer allocator.free(oracle);
    const realized = try allocator.alloc(u8, oracle.len);
    defer allocator.free(realized);
    try realize.realize(emitter.surface(), realized, null);
    try std.testing.expectEqualSlices(u8, oracle, realized);
}

test "render surface surface emitter realizes partial prepared surface equal to full rgba oracle" {
    const allocator = std.testing.allocator;
    var session = text_session.TextSession.init(allocator);
    defer session.deinit();

    var base = [_]u8{
        1, 2, 3, 255,
        4, 5, 6, 255,
    };
    const background = [_]contract.TextBackgroundDraw{
        backgroundDraw(0, 0, 1, 1, rgba(9, 8, 7, 255)),
    };
    const prepared = preparedSurface(.{
        .background_draws = &background,
        .width_px = 2,
        .height_px = 1,
        .full_redraw = false,
    });
    try expectPreparedEmissionEqualsCompose(allocator, &session, &prepared, &base);
}
fn expectPreparedEmissionEqualsCompose(allocator: std.mem.Allocator, session: *text_session.TextSession, prepared: *const prepared_surface.PreparedSurface, base_pixels: ?[]const u8) !void {
    const oracle = try prepared_buffer.compose(allocator, base_pixels, session, prepared);
    defer allocator.free(oracle);
    const realized = try allocator.alloc(u8, oracle.len);
    defer allocator.free(realized);
    const PreparedEmitter = Emitter(.{});
    const emitter = try allocator.create(PreparedEmitter);
    defer allocator.destroy(emitter);
    emitter.* = .{};
    var resources = sprite_resource_store.SpriteResourceStore.init();
    const surface = try emitter.emitPrepared(&resources, session, prepared);
    try realize.realize(surface, realized, base_pixels);
    try std.testing.expectEqualSlices(u8, oracle, realized);
}
const PreparedOptions = struct {
    clear_draws: []const contract.TextClearDraw = &.{},
    background_draws: []const contract.TextBackgroundDraw = &.{},
    sprite_draws: []const contract.TextSpriteDraw = &.{},
    decoration_draws: []const contract.TextDecorationDraw = &.{},
    cursor_draws: []const contract.TextCursorDraw = &.{},
    raster_outputs: []text.Rasterizer.RasterSpriteOutput = &.{},
    width_px: u16,
    height_px: u16,
    full_redraw: bool = true,
};

fn preparedSurface(options: PreparedOptions) prepared_surface.PreparedSurface {
    return .{
        .allocator = std.testing.allocator,
        .request = .{
            .token = .{
                .snapshot_seq = 1,
                .dirty_epoch = 1,
                .geometry_epoch = 1,
                .damage_base_seq = if (options.full_redraw) 0 else 1,
                .damage_kind = if (options.full_redraw) .full else .partial,
            },
        },
        .geometry_epoch = 1,
        .render_px = .{ .width = options.width_px, .height = options.height_px },
        .cell_px = .{ .width = 1, .height = 1 },
        .grid = .{ .cols = options.width_px, .rows = options.height_px },
        .text_frame = .{
            .scene = .{
                .allocator = std.testing.allocator,
                .owned = false,
                .scene = .{
                    .clear_draws = options.clear_draws,
                    .background_draws = options.background_draws,
                    .sprite_draws = options.sprite_draws,
                    .decoration_draws = options.decoration_draws,
                    .cursor_draws = options.cursor_draws,
                    .raster_requests = &.{},
                    .missing = &.{},
                    .full_redraw = options.full_redraw,
                },
            },
            .raster_plan = .{
                .allocator = std.testing.allocator,
                .outputs = options.raster_outputs,
                .owned = false,
            },
        },
    };
}

fn rasterOutput(
    allocator: std.mem.Allocator,
    key: u64,
    width_px: u16,
    height_px: u16,
    color_mode: contract.SpriteColorMode,
    pixels: []u8,
    visual_bounds: text.Rasterizer.SpriteBounds,
) text.Rasterizer.RasterSpriteOutput {
    return .{
        .allocator = allocator,
        .key = .{ .value = key },
        .width_px = width_px,
        .height_px = height_px,
        .color_mode = color_mode,
        .visual_bounds = visual_bounds,
        .pixels = pixels,
    };
}

fn clearDraw(x: i32, y: i32, width: u16, height: u16, color: contract.Rgba8) contract.TextClearDraw {
    return .{
        .x_px = x,
        .y_px = y,
        .width_px = width,
        .height_px = height,
        .color = color,
        .first_cell = 0,
        .cell_span = 1,
    };
}

fn backgroundDraw(x: i32, y: i32, width: u16, height: u16, color: contract.Rgba8) contract.TextBackgroundDraw {
    return .{
        .x_px = x,
        .y_px = y,
        .width_px = width,
        .height_px = height,
        .color = color,
        .first_cell = 0,
        .cell_span = 1,
    };
}

fn decorationDraw(x: i32, y: i32, width: u16, height: u16, color: contract.Rgba8) contract.TextDecorationDraw {
    return .{
        .kind = .underline,
        .x_px = x,
        .y_px = y,
        .width_px = width,
        .height_px = height,
        .color = color,
        .first_cell = 0,
        .cell_span = 1,
    };
}

fn cursorDraw(x: i32, y: i32, width: u16, height: u16, color: contract.Rgba8) contract.TextCursorDraw {
    return .{ .x_px = x, .y_px = y, .width_px = width, .height_px = height, .color = color };
}

fn spriteDraw(key: u64, x: i32, y: i32, width: u16, height: u16, color: contract.Rgba8) contract.TextSpriteDraw {
    return .{
        .sprite = .{ .slot = 0, .key = .{ .value = key } },
        .x_px = x,
        .y_px = y,
        .width_px = width,
        .height_px = height,
        .color = color,
        .first_cell = 0,
        .cell_span = 1,
    };
}

fn rgba(r: u8, g: u8, b: u8, a: u8) contract.Rgba8 {
    return .{ .r = r, .g = g, .b = b, .a = a };
}
