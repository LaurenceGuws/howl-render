const std = @import("std");
const builtin = @import("builtin");

const c = @import("../ffi.zig").c;
const contract = @import("../text/contract.zig");
const geometry_contract = @import("../render/geometry_contract.zig");
const prepared_surface = @import("../prepared/surface.zig");
const realize = @import("realize.zig");
const text = @import("../text/text.zig");
const text_session = @import("../session/text.zig");

const ResourceId = c.HowlRenderV0ResourceId;
const Rect = c.HowlRenderV0Rect;
const GlyphRef = c.HowlRenderV0GlyphRef;
pub const Frame = c.HowlRenderV0Frame;

pub const persistent_sprite_resources_max: u32 = 384;
pub const alpha_atlas_entries_max: u32 = 1024;
const persistent_sprite_resource_bytes_max: u32 = 64 * 1024;
const glyph_atlas_width_px: u16 = 1024;
const glyph_atlas_height_px: u16 = 1024;

comptime {
    std.debug.assert(persistent_sprite_resources_max < c.HOWL_RENDER_V0_RESOURCES_MAX);
    std.debug.assert(alpha_atlas_entries_max > persistent_sprite_resources_max);
    std.debug.assert(alpha_atlas_entries_max <=
        @as(u32, glyph_atlas_width_px) * @as(u32, glyph_atlas_height_px));
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
    damage_max: u32 = c.HOWL_RENDER_V0_DAMAGE_ITEMS_MAX,
    creates_max: u32 = c.HOWL_RENDER_V0_CREATES_MAX,
    uploads_max: u32 = c.HOWL_RENDER_V0_UPLOADS_MAX,
    commands_max: u32 = c.HOWL_RENDER_V0_COMMANDS_MAX,
    retires_max: u32 = c.HOWL_RENDER_V0_RETIRES_MAX,
    upload_bytes_max: u32 = c.HOWL_RENDER_V0_UPLOAD_BYTES_MAX,

    pub fn assertValid(comptime limits: Limits) void {
        std.debug.assert(limits.damage_max <= c.HOWL_RENDER_V0_DAMAGE_ITEMS_MAX);
        std.debug.assert(limits.creates_max <= c.HOWL_RENDER_V0_CREATES_MAX);
        std.debug.assert(limits.uploads_max <= c.HOWL_RENDER_V0_UPLOADS_MAX);
        std.debug.assert(limits.commands_max <= c.HOWL_RENDER_V0_COMMANDS_MAX);
        std.debug.assert(limits.retires_max <= c.HOWL_RENDER_V0_RETIRES_MAX);
        std.debug.assert(limits.upload_bytes_max <= c.HOWL_RENDER_V0_UPLOAD_BYTES_MAX);
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

const PreparedSprite = struct {
    key: contract.SpriteKey,
    pixels: []const u8,
    width_px: u16,
    height_px: u16,
    stride_bytes: u32,
    color_mode: contract.SpriteColorMode,
    visual_bounds: text.Rasterizer.SpriteBounds,
};

pub const SpriteResourceStore = struct {
    entries: [c.HOWL_RENDER_V0_RESOURCES_MAX]Entry = undefined,
    bytes: [persistent_sprite_resource_bytes_max]u8 = undefined,
    count: u32 = 0,
    bytes_count: u32 = 0,
    value_next: u64 = 1,
    atlas_resource: ResourceId = zeroResource(),
    atlas_entries: [alpha_atlas_entries_max]AtlasEntry = undefined,
    atlas_count: u32 = 0,
    atlas_next_x: u16 = 0,
    atlas_next_y: u16 = 0,
    atlas_row_height: u16 = 0,

    pub const Result = struct {
        resource: ResourceId,
        lifetime: Lifetime,

        pub const Lifetime = enum { reused, persistent, transient };
    };

    pub const AtlasResult = struct {
        resource: ResourceId,
        rect: Rect,
        created: bool,
        uploaded: bool,
    };

    const Entry = struct {
        key: contract.SpriteKey,
        bytes_hash: u64,
        bytes_offset: u32,
        bytes_count: u32,
        resource: ResourceId,
        width_px: u16,
        height_px: u16,
        format: u32,
    };

    const AtlasEntry = struct {
        key: contract.SpriteKey,
        bytes_hash: u64,
        width_px: u16,
        height_px: u16,
        rect: Rect,
    };

    pub fn init() SpriteResourceStore {
        return .{};
    }

    pub fn fillForTest(self: *SpriteResourceStore, count: u32) void {
        comptime std.debug.assert(builtin.is_test);
        std.debug.assert(count <= c.HOWL_RENDER_V0_RESOURCES_MAX);
        self.count = count;
        self.bytes_count = 0;
        self.value_next = @as(u64, count) + 1;
        var index: u32 = 0;
        while (index < count) : (index += 1) {
            const value = @as(u64, index) + 1;
            self.entries[@intCast(index)] = .{
                .key = .{ .value = value },
                .bytes_hash = value,
                .bytes_offset = 0,
                .bytes_count = 0,
                .resource = .{
                    .value = value,
                    .generation = 1,
                    .kind = c.HOWL_RENDER_V0_RESOURCE_SPRITE_ALPHA,
                },
                .width_px = 1,
                .height_px = 1,
                .format = c.HOWL_RENDER_V0_UPLOAD_ALPHA8,
            };
        }
    }

    fn resourceFor(
        self: *SpriteResourceStore,
        sprite: PreparedSprite,
        width_px: u16,
        height_px: u16,
        bytes: []const u8,
    ) Error!Result {
        const format = uploadFormatForPrepared(sprite.color_mode);
        const bytes_hash = hashSpriteBytes(sprite, width_px, height_px, bytes);
        for (self.entries[0..@intCast(self.count)]) |entry| {
            if (entry.key.value != sprite.key.value) continue;
            if (entry.bytes_hash != bytes_hash) continue;
            if (entry.width_px != width_px) continue;
            if (entry.height_px != height_px) continue;
            if (entry.format != format) continue;
            const bytes_end = std.math.add(u32, entry.bytes_offset, entry.bytes_count) catch {
                return error.ResourceBoundOverflow;
            };
            std.debug.assert(bytes_end <= self.bytes_count);
            if (!std.mem.eql(u8, self.bytes[entry.bytes_offset..bytes_end], bytes)) continue;
            return .{ .resource = entry.resource, .lifetime = .reused };
        }
        const bytes_count: u32 = std.math.cast(u32, bytes.len) orelse {
            return error.ResourceBoundOverflow;
        };
        const resource = try self.nextResource(sprite.color_mode);
        if (self.count >= persistent_sprite_resources_max) {
            return .{ .resource = resource, .lifetime = .transient };
        }
        const bytes_end = std.math.add(u32, self.bytes_count, bytes_count) catch {
            return error.ResourceBoundOverflow;
        };
        if (bytes_end > persistent_sprite_resource_bytes_max) {
            return .{ .resource = resource, .lifetime = .transient };
        }
        self.entries[@intCast(self.count)] = .{
            .key = sprite.key,
            .bytes_hash = bytes_hash,
            .bytes_offset = self.bytes_count,
            .bytes_count = bytes_count,
            .resource = resource,
            .width_px = width_px,
            .height_px = height_px,
            .format = format,
        };
        @memcpy(self.bytes[self.bytes_count..bytes_end], bytes);
        self.bytes_count = bytes_end;
        self.count += 1;
        return .{ .resource = resource, .lifetime = .persistent };
    }

    fn atlasRegionFor(
        self: *SpriteResourceStore,
        sprite: PreparedSprite,
        width_px: u16,
        height_px: u16,
        bytes: []const u8,
    ) Error!AtlasResult {
        std.debug.assert(sprite.color_mode == .alpha);
        const bytes_hash = hashSpriteBytes(sprite, width_px, height_px, bytes);
        for (self.atlas_entries[0..@intCast(self.atlas_count)]) |entry| {
            if (entry.key.value != sprite.key.value) continue;
            if (entry.bytes_hash != bytes_hash) continue;
            if (entry.width_px != width_px) continue;
            if (entry.height_px != height_px) continue;
            return .{ .resource = self.atlas_resource, .rect = entry.rect, .created = false, .uploaded = false };
        }
        if (self.atlas_count >= alpha_atlas_entries_max) return error.ResourceBoundOverflow;
        const had_resource = !resourceIsZero(self.atlas_resource);
        const resource = try self.ensureAtlasResource();
        const rect_value = try self.reserveAtlasRect(width_px, height_px);
        self.atlas_entries[@intCast(self.atlas_count)] = .{
            .key = sprite.key,
            .bytes_hash = bytes_hash,
            .width_px = width_px,
            .height_px = height_px,
            .rect = rect_value,
        };
        self.atlas_count += 1;
        return .{ .resource = resource, .rect = rect_value, .created = !had_resource, .uploaded = true };
    }

    fn ensureAtlasResource(self: *SpriteResourceStore) Error!ResourceId {
        if (!resourceIsZero(self.atlas_resource)) return self.atlas_resource;
        if (self.value_next == 0) return error.ResourceBoundOverflow;
        self.atlas_resource = .{
            .value = self.value_next,
            .generation = 1,
            .kind = c.HOWL_RENDER_V0_RESOURCE_GLYPH_ATLAS_ALPHA,
        };
        self.value_next = std.math.add(u64, self.value_next, 1) catch {
            return error.ResourceBoundOverflow;
        };
        return self.atlas_resource;
    }

    fn reserveAtlasRect(self: *SpriteResourceStore, width_px: u16, height_px: u16) Error!Rect {
        if (width_px == 0) return error.InvalidPreparedSprite;
        if (height_px == 0) return error.InvalidPreparedSprite;
        if (width_px > glyph_atlas_width_px) return error.ResourceBoundOverflow;
        if (height_px > glyph_atlas_height_px) return error.ResourceBoundOverflow;
        const next_x = std.math.add(u16, self.atlas_next_x, width_px) catch {
            return error.ResourceBoundOverflow;
        };
        if (next_x > glyph_atlas_width_px) {
            self.atlas_next_x = 0;
            self.atlas_next_y = std.math.add(u16, self.atlas_next_y, self.atlas_row_height) catch {
                return error.ResourceBoundOverflow;
            };
            self.atlas_row_height = 0;
        }
        const bottom = std.math.add(u16, self.atlas_next_y, height_px) catch {
            return error.ResourceBoundOverflow;
        };
        if (bottom > glyph_atlas_height_px) return error.ResourceBoundOverflow;
        const rect_value = Rect{
            .x_px = @intCast(self.atlas_next_x),
            .y_px = @intCast(self.atlas_next_y),
            .width_px = width_px,
            .height_px = height_px,
        };
        self.atlas_next_x = std.math.add(u16, self.atlas_next_x, width_px) catch {
            return error.ResourceBoundOverflow;
        };
        self.atlas_row_height = @max(self.atlas_row_height, height_px);
        return rect_value;
    }

    fn nextResource(
        self: *SpriteResourceStore,
        color_mode: contract.SpriteColorMode,
    ) Error!ResourceId {
        if (self.value_next == 0) return error.ResourceBoundOverflow;
        const resource = ResourceId{
            .value = self.value_next,
            .generation = 1,
            .kind = switch (color_mode) {
                .alpha => c.HOWL_RENDER_V0_RESOURCE_SPRITE_ALPHA,
                .color => c.HOWL_RENDER_V0_RESOURCE_SPRITE_COLOR,
            },
        };
        self.value_next = std.math.add(u64, self.value_next, 1) catch {
            return error.ResourceBoundOverflow;
        };
        return resource;
    }
};

pub const Fixture = struct {
    render_px: c.HowlRenderPixelSize,
    cell_px: c.HowlRenderCellSize = .{ .width = 1, .height = 1 },
    grid: c.HowlRenderGridSize = .{ .cols = 1, .rows = 1 },
    token: c.HowlRenderV0Token = .{
        .snapshot_seq = 0,
        .frame_seq = 0,
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
        damage: [limits.damage_max]c.HowlRenderV0DamageItem = undefined,
        creates: [limits.creates_max]c.HowlRenderV0Create = undefined,
        uploads: [limits.uploads_max]c.HowlRenderV0Upload = undefined,
        upload_byte_offsets: [limits.uploads_max]u32 = undefined,
        commands: [limits.commands_max]c.HowlRenderV0Command = undefined,
        glyphs: [limits.commands_max]GlyphRef = undefined,
        retires: [limits.retires_max]c.HowlRenderV0Retire = undefined,
        upload_bytes: [limits.upload_bytes_max]u8 = undefined,
        damage_count: u32 = 0,
        create_count: u32 = 0,
        upload_count: u32 = 0,
        command_count: u32 = 0,
        glyph_count: u32 = 0,
        retire_count: u32 = 0,
        upload_bytes_count: u32 = 0,
        frame_storage: Frame = emptyFrame(),

        const Self = @This();

        pub fn init() Self {
            return .{};
        }

        pub fn frame(self: *const Self) *const Frame {
            return &self.frame_storage;
        }

        pub fn emit(self: *Self, fixture: *const Fixture) Error!*const Frame {
            var next = self.*;
            next.reset(fixture);
            try next.appendFullDamage(fixture.render_px);
            try next.appendFillPass(fixture.clear_fills, c.HOWL_RENDER_V0_COMMAND_CLEAR_RECT);
            try next.appendFillPass(fixture.background_fills, c.HOWL_RENDER_V0_COMMAND_FILL_RECT);
            try next.appendFillPass(fixture.decoration_fills, c.HOWL_RENDER_V0_COMMAND_FILL_RECT);
            try next.appendSprites(fixture.sprites);
            try next.appendFillPass(fixture.cursor_fills, c.HOWL_RENDER_V0_COMMAND_FILL_RECT);
            self.* = next;
            self.publishFrame();
            return &self.frame_storage;
        }

        pub fn emitPrepared(
            self: *Self,
            resources: *SpriteResourceStore,
            session: *text_session.TextSession,
            prepared: *const prepared_surface.PreparedSurface,
        ) Error!*const Frame {
            var next = self.*;
            var next_resources = resources.*;
            next.resetPrepared(prepared);
            try next.appendFullDamage(pixelSizeOut(prepared.render_px));
            try next.appendPreparedClears(prepared.text_frame.scene.scene.clear_draws);
            try next.appendPreparedBackgrounds(prepared.text_frame.scene.scene.background_draws);
            try next.appendPreparedDecorations(prepared.text_frame.scene.scene.decoration_draws);
            try next.appendPreparedSprites(&next_resources, session, prepared);
            try next.appendPreparedCursors(prepared.text_frame.scene.scene.cursor_draws);
            self.* = next;
            resources.* = next_resources;
            self.publishFrame();
            return &self.frame_storage;
        }

        fn reset(self: *Self, fixture: *const Fixture) void {
            self.damage_count = 0;
            self.create_count = 0;
            self.upload_count = 0;
            self.command_count = 0;
            self.glyph_count = 0;
            self.retire_count = 0;
            self.upload_bytes_count = 0;
            self.frame_storage = emptyFrame();
            self.frame_storage.token = fixture.token;
            self.frame_storage.render_px = fixture.render_px;
            self.frame_storage.cell_px = fixture.cell_px;
            self.frame_storage.grid = fixture.grid;
        }

        fn resetPrepared(self: *Self, prepared: *const prepared_surface.PreparedSurface) void {
            self.damage_count = 0;
            self.create_count = 0;
            self.upload_count = 0;
            self.command_count = 0;
            self.glyph_count = 0;
            self.retire_count = 0;
            self.upload_bytes_count = 0;
            self.frame_storage = emptyFrame();
            self.frame_storage.token = .{
                .snapshot_seq = prepared.request.token.snapshot_seq,
                .frame_seq = prepared.request.token.dirty_epoch,
                .geometry_epoch = prepared.geometry_epoch,
                .resource_epoch = 0,
            };
            self.frame_storage.render_px = pixelSizeOut(prepared.render_px);
            self.frame_storage.cell_px = cellSizeOut(prepared.cell_px);
            self.frame_storage.grid = gridSizeOut(prepared.grid);
        }

        fn appendFullDamage(self: *Self, render_px: c.HowlRenderPixelSize) Error!void {
            if (self.damage_count >= limits.damage_max) return error.DamageBoundOverflow;
            self.damage[self.damage_count] = .{
                .kind = c.HOWL_RENDER_V0_DAMAGE_FULL,
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

        fn appendPreparedClears(
            self: *Self,
            draws: []const contract.TextClearDraw,
        ) Error!void {
            for (draws) |draw| try self.appendPreparedFillCommand(
                draw.x_px,
                draw.y_px,
                draw.width_px,
                draw.height_px,
                draw.color,
                c.HOWL_RENDER_V0_COMMAND_CLEAR_RECT,
            );
        }

        fn appendPreparedBackgrounds(
            self: *Self,
            draws: []const contract.TextBackgroundDraw,
        ) Error!void {
            for (draws) |draw| try self.appendPreparedFillCommand(
                draw.x_px,
                draw.y_px,
                draw.width_px,
                draw.height_px,
                draw.color,
                c.HOWL_RENDER_V0_COMMAND_FILL_RECT,
            );
        }

        fn appendPreparedDecorations(
            self: *Self,
            draws: []const contract.TextDecorationDraw,
        ) Error!void {
            for (draws) |draw| try self.appendPreparedFillCommand(
                draw.x_px,
                draw.y_px,
                draw.width_px,
                draw.height_px,
                draw.color,
                c.HOWL_RENDER_V0_COMMAND_FILL_RECT,
            );
        }

        fn appendPreparedCursors(
            self: *Self,
            draws: []const contract.TextCursorDraw,
        ) Error!void {
            for (draws) |draw| try self.appendPreparedFillCommand(
                draw.x_px,
                draw.y_px,
                draw.width_px,
                draw.height_px,
                draw.color,
                c.HOWL_RENDER_V0_COMMAND_FILL_RECT,
            );
        }

        fn appendPreparedFillCommand(
            self: *Self,
            x_px: i32,
            y_px: i32,
            width_px: u16,
            height_px: u16,
            color: contract.Rgba8,
            kind: u8,
        ) Error!void {
            const command = c.HowlRenderV0Command{
                .kind = kind,
                .reserved0 = 0,
                .reserved1 = 0,
                .rect = .{
                    .x_px = x_px,
                    .y_px = y_px,
                    .width_px = width_px,
                    .height_px = height_px,
                },
                .color_rgba = packRgba(color),
                .resource = zeroResource(),
                .glyphs = emptyGlyphs(),
            };
            if (self.tryMergePreparedFillCommand(command)) return;
            try self.appendCommand(command);
        }

        fn tryMergePreparedFillCommand(self: *Self, command: c.HowlRenderV0Command) bool {
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
                    .kind = c.HOWL_RENDER_V0_COMMAND_DRAW_SPRITE,
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

        fn appendPreparedSprites(
            self: *Self,
            resources: *SpriteResourceStore,
            session: *text_session.TextSession,
            prepared: *const prepared_surface.PreparedSurface,
        ) Error!void {
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
                        .x_px = std.math.add(i32, draw.x_px, @intCast(bounds.x_px)) catch {
                            return error.InvalidPreparedSprite;
                        },
                        .y_px = std.math.add(i32, draw.y_px, @intCast(bounds.y_px)) catch {
                            return error.InvalidPreparedSprite;
                        },
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
                    .kind = c.HOWL_RENDER_V0_COMMAND_DRAW_SPRITE,
                    .reserved0 = 0,
                    .reserved1 = 0,
                    .rect = .{
                        .x_px = std.math.add(i32, draw.x_px, @intCast(bounds.x_px)) catch {
                            return error.InvalidPreparedSprite;
                        },
                        .y_px = std.math.add(i32, draw.y_px, @intCast(bounds.y_px)) catch {
                            return error.InvalidPreparedSprite;
                        },
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

        fn appendPreparedCreate(
            self: *Self,
            resource: ResourceId,
            sprite: PreparedSprite,
            width_px: u16,
            height_px: u16,
        ) Error!void {
            if (self.create_count >= limits.creates_max) return error.CreateBoundOverflow;
            self.creates[self.create_count] = .{
                .resource = resource,
                .width_px = width_px,
                .height_px = height_px,
                .format = uploadFormatForPrepared(sprite.color_mode),
                .create_seq = 0,
            };
            self.create_count += 1;
        }

        fn appendGlyphAtlasCreate(self: *Self, resource: ResourceId) Error!void {
            if (self.create_count >= limits.creates_max) return error.CreateBoundOverflow;
            self.creates[self.create_count] = .{
                .resource = resource,
                .width_px = glyph_atlas_width_px,
                .height_px = glyph_atlas_height_px,
                .format = c.HOWL_RENDER_V0_UPLOAD_ALPHA8,
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

        fn appendPreparedUpload(
            self: *Self,
            resource: ResourceId,
            sprite: PreparedSprite,
            width_px: u16,
            height_px: u16,
            upload_range: ByteRange,
        ) Error!void {
            if (self.upload_count >= limits.uploads_max) return error.UploadBoundOverflow;
            const bytes_per_pixel = bytesPerPixelForPrepared(sprite.color_mode);
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
                .format = uploadFormatForPrepared(sprite.color_mode),
                .upload_seq = 0,
            };
            self.upload_byte_offsets[self.upload_count] = upload_range.start;
            self.upload_count += 1;
        }

        fn appendPreparedAtlasUpload(
            self: *Self,
            resource: ResourceId,
            atlas_rect: Rect,
            upload_range: ByteRange,
        ) Error!void {
            if (self.upload_count >= limits.uploads_max) return error.UploadBoundOverflow;
            const bytes_count = upload_range.end - upload_range.start;
            std.debug.assert(upload_range.end == self.upload_bytes_count);
            self.uploads[self.upload_count] = .{
                .resource = resource,
                .rect = atlas_rect,
                .bytes_ptr = &self.upload_bytes[upload_range.start],
                .bytes_count = bytes_count,
                .stride_bytes = atlas_rect.width_px,
                .format = c.HOWL_RENDER_V0_UPLOAD_ALPHA8,
                .upload_seq = 0,
            };
            self.upload_byte_offsets[self.upload_count] = upload_range.start;
            self.upload_count += 1;
        }

        fn stagePreparedUploadBytes(
            self: *Self,
            sprite: PreparedSprite,
            bounds: text.Rasterizer.SpriteBounds,
            width_px: u16,
            height_px: u16,
        ) Error!ByteRange {
            const bytes_per_pixel = bytesPerPixelForPrepared(sprite.color_mode);
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

        fn appendCommand(self: *Self, command: c.HowlRenderV0Command) Error!void {
            if (self.command_count >= limits.commands_max) return error.CommandBoundOverflow;
            self.commands[self.command_count] = command;
            self.command_count += 1;
        }

        fn appendGlyphRef(self: *Self, glyph: GlyphRef) Error!void {
            if (self.glyph_count >= limits.commands_max) return error.CommandBoundOverflow;
            const start = self.glyph_count;
            self.glyphs[@intCast(self.glyph_count)] = glyph;
            self.glyph_count += 1;
            try self.appendCommand(.{
                .kind = c.HOWL_RENDER_V0_COMMAND_DRAW_GLYPH_RUN,
                .reserved0 = 0,
                .reserved1 = 0,
                .rect = .{ .x_px = 0, .y_px = 0, .width_px = 0, .height_px = 0 },
                .color_rgba = 0,
                .resource = zeroResource(),
                .glyphs = .{
                    .ptr = &self.glyphs[@intCast(start)],
                    .count = 1,
                    .count_max = c.HOWL_RENDER_V0_GLYPHS_PER_RUN_MAX,
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

        fn publishFrame(self: *Self) void {
            var upload_index: u32 = 0;
            while (upload_index < self.upload_count) : (upload_index += 1) {
                const byte_offset = self.upload_byte_offsets[upload_index];
                std.debug.assert(byte_offset < self.upload_bytes_count);
                self.uploads[upload_index].bytes_ptr = &self.upload_bytes[byte_offset];
            }
            self.frame_storage.damage = .{
                .ptr = if (self.damage_count == 0) null else &self.damage[0],
                .count = self.damage_count,
                .count_max = c.HOWL_RENDER_V0_DAMAGE_ITEMS_MAX,
            };
            self.frame_storage.creates = .{
                .ptr = if (self.create_count == 0) null else &self.creates[0],
                .count = self.create_count,
                .count_max = c.HOWL_RENDER_V0_CREATES_MAX,
            };
            self.frame_storage.uploads = .{
                .ptr = if (self.upload_count == 0) null else &self.uploads[0],
                .count = self.upload_count,
                .count_max = c.HOWL_RENDER_V0_UPLOADS_MAX,
                .bytes_count_total = self.upload_bytes_count,
                .bytes_count_max = c.HOWL_RENDER_V0_UPLOAD_BYTES_MAX,
            };
            self.frame_storage.commands = .{
                .ptr = if (self.command_count == 0) null else &self.commands[0],
                .count = self.command_count,
                .count_max = c.HOWL_RENDER_V0_COMMANDS_MAX,
            };
            self.frame_storage.retires = .{
                .ptr = if (self.retire_count == 0) null else &self.retires[0],
                .count = self.retire_count,
                .count_max = c.HOWL_RENDER_V0_RETIRES_MAX,
            };
        }
    };
}

fn emptyFrame() Frame {
    return .{
        .protocol_version = c.HOWL_RENDER_PROTOCOL_V0_VERSION,
        .reserved0 = 0,
        .token = .{ .snapshot_seq = 0, .frame_seq = 0, .geometry_epoch = 0, .resource_epoch = 0 },
        .render_px = .{ .width = 1, .height = 1 },
        .cell_px = .{ .width = 1, .height = 1 },
        .grid = .{ .cols = 1, .rows = 1 },
        .damage = .{ .ptr = null, .count = 0, .count_max = c.HOWL_RENDER_V0_DAMAGE_ITEMS_MAX },
        .creates = .{ .ptr = null, .count = 0, .count_max = c.HOWL_RENDER_V0_CREATES_MAX },
        .uploads = .{
            .ptr = null,
            .count = 0,
            .count_max = c.HOWL_RENDER_V0_UPLOADS_MAX,
            .bytes_count_total = 0,
            .bytes_count_max = c.HOWL_RENDER_V0_UPLOAD_BYTES_MAX,
        },
        .commands = .{ .ptr = null, .count = 0, .count_max = c.HOWL_RENDER_V0_COMMANDS_MAX },
        .retires = .{ .ptr = null, .count = 0, .count_max = c.HOWL_RENDER_V0_RETIRES_MAX },
    };
}

fn emptyGlyphs() c.HowlRenderV0GlyphRunSpan {
    return .{ .ptr = null, .count = 0, .count_max = c.HOWL_RENDER_V0_GLYPHS_PER_RUN_MAX };
}

fn zeroResource() ResourceId {
    return .{ .value = 0, .generation = 0, .kind = 0 };
}

fn resourceIsZero(resource: ResourceId) bool {
    return resource.value == 0 and resource.generation == 0 and resource.kind == 0;
}

fn spriteResource(sprite: Sprite, value: u64) ResourceId {
    return .{
        .value = value,
        .generation = 1,
        .kind = switch (sprite.color_mode) {
            .alpha => c.HOWL_RENDER_V0_RESOURCE_SPRITE_ALPHA,
            .color => c.HOWL_RENDER_V0_RESOURCE_SPRITE_COLOR,
        },
    };
}

fn preparedSpriteResource(sprite: PreparedSprite, value: u64) ResourceId {
    return .{
        .value = value,
        .generation = 1,
        .kind = switch (sprite.color_mode) {
            .alpha => c.HOWL_RENDER_V0_RESOURCE_SPRITE_ALPHA,
            .color => c.HOWL_RENDER_V0_RESOURCE_SPRITE_COLOR,
        },
    };
}

const ByteRange = struct {
    start: u32,
    end: u32,
};

fn uploadFormat(color_mode: ColorMode) u32 {
    return switch (color_mode) {
        .alpha => c.HOWL_RENDER_V0_UPLOAD_ALPHA8,
        .color => c.HOWL_RENDER_V0_UPLOAD_RGBA8,
    };
}

fn uploadFormatForPrepared(color_mode: contract.SpriteColorMode) u32 {
    return switch (color_mode) {
        .alpha => c.HOWL_RENDER_V0_UPLOAD_ALPHA8,
        .color => c.HOWL_RENDER_V0_UPLOAD_RGBA8,
    };
}

fn bytesPerPixelForPrepared(color_mode: contract.SpriteColorMode) u32 {
    return switch (color_mode) {
        .alpha => 1,
        .color => 4,
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

fn lookupPreparedSprite(
    session: *text_session.TextSession,
    prepared: *const prepared_surface.PreparedSurface,
    sprite_key: contract.SpriteKey,
) error{MissingSprite}!PreparedSprite {
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

fn hashSpriteBytes(
    sprite: PreparedSprite,
    width_px: u16,
    height_px: u16,
    bytes: []const u8,
) u64 {
    var hasher = std.hash.Wyhash.init(0x5350524954455630);
    hasher.update(std.mem.asBytes(&sprite.key.value));
    hasher.update(std.mem.asBytes(&width_px));
    hasher.update(std.mem.asBytes(&height_px));
    const format = uploadFormatForPrepared(sprite.color_mode);
    hasher.update(std.mem.asBytes(&format));
    hasher.update(bytes);
    return hasher.final();
}

fn packedStrideForOutput(output: text.Rasterizer.RasterSpriteOutput) u32 {
    return @as(u32, output.width_px) * bytesPerPixelForPrepared(output.color_mode);
}

fn visualBoundsForDraw(
    bounds: text.Rasterizer.SpriteBounds,
    draw: contract.TextSpriteDraw,
) text.Rasterizer.SpriteBounds {
    if (bounds.width_px != 0) {
        if (bounds.height_px != 0) return bounds;
    }
    return .{ .x_px = 0, .y_px = 0, .width_px = draw.width_px, .height_px = draw.height_px };
}

fn copyPreparedSpriteBytes(
    target: []u8,
    target_stride: u32,
    sprite: PreparedSprite,
    bounds: text.Rasterizer.SpriteBounds,
    width_px: u16,
    height_px: u16,
) Error!void {
    const bytes_per_pixel = bytesPerPixelForPrepared(sprite.color_mode);
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

fn spriteFixture(
    sprite_rect: Rect,
    color_rgba: u32,
    bytes: []const u8,
    width_px: u16,
    height_px: u16,
    stride_bytes: u32,
    color_mode: ColorMode,
) Sprite {
    return .{
        .rect = sprite_rect,
        .color_rgba = color_rgba,
        .bytes = bytes,
        .width_px = width_px,
        .height_px = height_px,
        .stride_bytes = stride_bytes,
        .color_mode = color_mode,
    };
}

fn realizeFixture(comptime limits: Limits, fixture: Fixture, pixels: []u8) !void {
    var emitter = Emitter(limits).init();
    const frame = try emitter.emit(&fixture);
    try realize.realize(frame, pixels, null);
}

test "protocol v0 emitter realizes fill pass order equal to oracle" {
    const limits = Limits{ .commands_max = 5 };
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

test "protocol v0 emitter realizes alpha sprite equal to oracle" {
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

test "protocol v0 emitter realizes color sprite equal to oracle" {
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

test "protocol v0 emitter emits sprite retires after final use" {
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
    const frame = try emitter.emit(&.{
        .render_px = .{ .width = 1, .height = 1 },
        .sprites = &sprites,
    });
    try std.testing.expectEqual(@as(u32, 1), frame.retires.count);
    try std.testing.expectEqual(@as(u64, 1), frame.retires.ptr[0].retire_seq);
    var pixels: [4]u8 = undefined;
    try realize.realize(frame, &pixels, null);
    const oracle = [_]u8{ 255, 255, 255, 255 };
    try std.testing.expectEqualSlices(u8, &oracle, &pixels);
}

test "protocol v0 emitter rejects command bound overflow" {
    const limits = Limits{ .commands_max = 1 };
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

test "protocol v0 emitter rejects upload bound overflow" {
    const limits = Limits{
        .creates_max = 2,
        .uploads_max = 1,
        .commands_max = 2,
        .retires_max = 2,
        .upload_bytes_max = 2,
    };
    const one = [_]u8{255};
    const sprites = [_]Sprite{
        spriteFixture(rect(0, 0, 1, 1), 0xffffffff, &one, 1, 1, 1, .alpha),
        spriteFixture(rect(0, 0, 1, 1), 0xffffffff, &one, 1, 1, 1, .alpha),
    };
    var emitter = Emitter(limits).init();
    try std.testing.expectError(error.UploadBoundOverflow, emitter.emit(&.{
        .render_px = .{ .width = 1, .height = 1 },
        .sprites = &sprites,
    }));
}

test "protocol v0 emitter rejects retire bound overflow" {
    const limits = Limits{
        .creates_max = 2,
        .uploads_max = 2,
        .commands_max = 2,
        .retires_max = 1,
        .upload_bytes_max = 2,
    };
    const one = [_]u8{255};
    const sprites = [_]Sprite{
        spriteFixture(rect(0, 0, 1, 1), 0xffffffff, &one, 1, 1, 1, .alpha),
        spriteFixture(rect(0, 0, 1, 1), 0xffffffff, &one, 1, 1, 1, .alpha),
    };
    var emitter = Emitter(limits).init();
    try std.testing.expectError(error.RetireBoundOverflow, emitter.emit(&.{
        .render_px = .{ .width = 1, .height = 1 },
        .sprites = &sprites,
    }));
}

test "protocol v0 emitter rejects upload byte total overflow" {
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

test "protocol v0 emitter leaves oracle path independent after emission failure" {
    const limits = Limits{ .commands_max = 1 };
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
    try std.testing.expectEqual(@as(*const Frame, accepted), emitter.frame());
    var pixels: [4]u8 = undefined;
    try realize.realize(emitter.frame(), &pixels, null);
    const oracle = [_]u8{ 255, 0, 0, 255 };
    try std.testing.expectEqualSlices(u8, &oracle, &pixels);
}

test "protocol v0 alpha atlas reports explicit entry exhaustion" {
    var resources = SpriteResourceStore.init();
    var pixel = [_]u8{255};
    var index: u32 = 0;
    while (index < alpha_atlas_entries_max) : (index += 1) {
        const sprite = PreparedSprite{
            .key = .{ .value = @as(u64, index) + 1 },
            .pixels = &pixel,
            .width_px = 1,
            .height_px = 1,
            .stride_bytes = 1,
            .color_mode = .alpha,
            .visual_bounds = .{},
        };
        const atlas = try resources.atlasRegionFor(sprite, 1, 1, &pixel);
        try std.testing.expectEqual(index == 0, atlas.created);
        try std.testing.expect(atlas.uploaded);
        try std.testing.expect(atlas.resource.value != 0);
    }
    try std.testing.expectEqual(alpha_atlas_entries_max, resources.atlas_count);

    const overflow_sprite = PreparedSprite{
        .key = .{ .value = @as(u64, alpha_atlas_entries_max) + 1 },
        .pixels = &pixel,
        .width_px = 1,
        .height_px = 1,
        .stride_bytes = 1,
        .color_mode = .alpha,
        .visual_bounds = .{},
    };
    try std.testing.expectError(
        error.ResourceBoundOverflow,
        resources.atlasRegionFor(overflow_sprite, 1, 1, &pixel),
    );
    try std.testing.expectEqual(alpha_atlas_entries_max, resources.atlas_count);
}
