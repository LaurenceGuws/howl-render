const std = @import("std");
const builtin = @import("builtin");

const c = @import("../ffi.zig").c;
const contract = @import("../text/contract.zig");
const text = @import("../text/text.zig");

const ResourceId = c.HowlRenderResourceId;
const Rect = c.HowlRenderSurfaceRect;

pub const persistent_sprite_resources_max: u32 = 384;
pub const alpha_atlas_entries_max: u32 = c.HOWL_RENDER_SURFACE_COMMANDS_MAX;
const persistent_sprite_resource_bytes_max: u32 = 64 * 1024;
pub const glyph_atlas_width_px: u16 = 1024;
pub const glyph_atlas_height_px: u16 = 1024;

comptime {
    std.debug.assert(persistent_sprite_resources_max < c.HOWL_RENDER_SURFACE_RESOURCES_MAX);
    std.debug.assert(alpha_atlas_entries_max > persistent_sprite_resources_max);
    std.debug.assert(alpha_atlas_entries_max <=
        @as(u32, glyph_atlas_width_px) * @as(u32, glyph_atlas_height_px));
}

pub const Error = error{
    ResourceBoundOverflow,
    InvalidPreparedSprite,
};

pub const PreparedSprite = struct {
    key: contract.SpriteKey,
    pixels: []const u8,
    width_px: u16,
    height_px: u16,
    stride_bytes: u32,
    color_mode: contract.SpriteColorMode,
    visual_bounds: text.Rasterizer.SpriteBounds,
};

pub const SpriteResourceStore = struct {
    entries: [c.HOWL_RENDER_SURFACE_RESOURCES_MAX]Entry = undefined,
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

    pub fn clear(self: *SpriteResourceStore) void {
        const next_value = self.value_next;
        self.* = .{};
        self.value_next = next_value;
    }

    pub fn fillForTest(self: *SpriteResourceStore, count: u32) void {
        comptime std.debug.assert(builtin.is_test);
        std.debug.assert(count <= c.HOWL_RENDER_SURFACE_RESOURCES_MAX);
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
                    .kind = c.HOWL_RENDER_RESOURCE_SPRITE_ALPHA,
                },
                .width_px = 1,
                .height_px = 1,
                .format = c.HOWL_RENDER_UPLOAD_ALPHA8,
            };
        }
    }

    pub fn resourceFor(self: *SpriteResourceStore, sprite: PreparedSprite, width_px: u16, height_px: u16, bytes: []const u8) Error!Result {
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

    pub fn atlasRegionFor(self: *SpriteResourceStore, sprite: PreparedSprite, width_px: u16, height_px: u16, bytes: []const u8) Error!AtlasResult {
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
            .kind = c.HOWL_RENDER_RESOURCE_GLYPH_ATLAS_ALPHA,
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

    fn nextResource(self: *SpriteResourceStore, color_mode: contract.SpriteColorMode) Error!ResourceId {
        if (self.value_next == 0) return error.ResourceBoundOverflow;
        const resource = ResourceId{
            .value = self.value_next,
            .generation = 1,
            .kind = switch (color_mode) {
                .alpha => c.HOWL_RENDER_RESOURCE_SPRITE_ALPHA,
                .color => c.HOWL_RENDER_RESOURCE_SPRITE_COLOR,
            },
        };
        self.value_next = std.math.add(u64, self.value_next, 1) catch {
            return error.ResourceBoundOverflow;
        };
        return resource;
    }
};

pub fn uploadFormatForPrepared(color_mode: contract.SpriteColorMode) u32 {
    return switch (color_mode) {
        .alpha => c.HOWL_RENDER_UPLOAD_ALPHA8,
        .color => c.HOWL_RENDER_UPLOAD_RGBA8,
    };
}

pub fn bytesPerPixelForPrepared(color_mode: contract.SpriteColorMode) u32 {
    return switch (color_mode) {
        .alpha => 1,
        .color => 4,
    };
}

fn zeroResource() ResourceId {
    return .{ .value = 0, .generation = 0, .kind = 0 };
}

fn resourceIsZero(resource: ResourceId) bool {
    return resource.value == 0 and resource.generation == 0 and resource.kind == 0;
}

fn hashSpriteBytes(sprite: PreparedSprite, width_px: u16, height_px: u16, bytes: []const u8) u64 {
    var hasher = std.hash.Wyhash.init(0x5350524954455630);
    hasher.update(std.mem.asBytes(&sprite.key.value));
    hasher.update(std.mem.asBytes(&width_px));
    hasher.update(std.mem.asBytes(&height_px));
    const format = uploadFormatForPrepared(sprite.color_mode);
    hasher.update(std.mem.asBytes(&format));
    hasher.update(bytes);
    return hasher.final();
}

test "render-surface sprite resource store alpha atlas reports explicit entry exhaustion" {
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
