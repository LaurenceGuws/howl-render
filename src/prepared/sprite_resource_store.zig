const std = @import("std");
const c = @import("../ffi.zig").c;
const contract = @import("../text/contract.zig");
const rasterizer = @import("../text/raster/rasterizer.zig");

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
    visual_bounds: rasterizer.SpriteBounds,
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
    last_resource_entry_index: ?u32 = null,
    last_atlas_entry_index: ?u32 = null,

    pub const ResourceAllocation = struct {
        resource: ResourceId,
        lifetime: Lifetime,

        pub const Lifetime = enum { reused, persistent, transient };
    };

    pub const AtlasPlacement = struct {
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

    pub fn resourceFor(self: *SpriteResourceStore, sprite: PreparedSprite, width_px: u16, height_px: u16, bytes: []const u8) Error!ResourceAllocation {
        const format = uploadFormatForPrepared(sprite.color_mode);
        const bytes_hash = try hashPreparedBytes(sprite, width_px, height_px, bytes);
        if (self.last_resource_entry_index) |index| {
            if (index < self.count) {
                const entry = self.entries[index];
                if (entry.key.value == sprite.key.value and
                    entry.bytes_hash == bytes_hash and
                    entry.width_px == width_px and
                    entry.height_px == height_px and
                    entry.format == format)
                {
                    const bytes_end = std.math.add(u32, entry.bytes_offset, entry.bytes_count) catch {
                        return error.ResourceBoundOverflow;
                    };
                    std.debug.assert(bytes_end <= self.bytes_count);
                    if (std.mem.eql(u8, self.bytes[entry.bytes_offset..bytes_end], bytes)) {
                        return .{ .resource = entry.resource, .lifetime = .reused };
                    }
                }
            }
        }
        for (self.entries[0..@intCast(self.count)], 0..) |entry, i| {
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
            self.last_resource_entry_index = @intCast(i);
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
        std.debug.assert(self.count <= persistent_sprite_resources_max);
        self.last_resource_entry_index = self.count - 1;
        return .{ .resource = resource, .lifetime = .persistent };
    }

    pub fn resourceAdmissionForPrepared(self: *SpriteResourceStore, sprite: PreparedSprite, bounds: rasterizer.SpriteBounds, width_px: u16, height_px: u16) Error!ResourceAllocation {
        const format = uploadFormatForPrepared(sprite.color_mode);
        const bytes_hash = try hashPreparedSpriteBytes(sprite, bounds, width_px, height_px);
        if (self.last_resource_entry_index) |index| {
            if (index < self.count) {
                const entry = self.entries[index];
                if (entry.key.value == sprite.key.value and
                    entry.bytes_hash == bytes_hash and
                    entry.width_px == width_px and
                    entry.height_px == height_px and
                    entry.format == format)
                {
                    const bytes_end = std.math.add(u32, entry.bytes_offset, entry.bytes_count) catch {
                        return error.ResourceBoundOverflow;
                    };
                    std.debug.assert(bytes_end <= self.bytes_count);
                    if (try preparedSpriteBytesEqualStored(self.bytes[entry.bytes_offset..bytes_end], sprite, bounds, width_px, height_px)) {
                        return .{ .resource = entry.resource, .lifetime = .reused };
                    }
                }
            }
        }
        for (self.entries[0..@intCast(self.count)], 0..) |entry, i| {
            if (entry.key.value != sprite.key.value) continue;
            if (entry.bytes_hash != bytes_hash) continue;
            if (entry.width_px != width_px) continue;
            if (entry.height_px != height_px) continue;
            if (entry.format != format) continue;
            const bytes_end = std.math.add(u32, entry.bytes_offset, entry.bytes_count) catch {
                return error.ResourceBoundOverflow;
            };
            std.debug.assert(bytes_end <= self.bytes_count);
            if (!(try preparedSpriteBytesEqualStored(self.bytes[entry.bytes_offset..bytes_end], sprite, bounds, width_px, height_px))) continue;
            self.last_resource_entry_index = @intCast(i);
            return .{ .resource = entry.resource, .lifetime = .reused };
        }
        const upload_stride = try preparedUploadStride(sprite.color_mode, width_px);
        const bytes_count = try preparedBytesCount(sprite.color_mode, width_px, height_px);
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
        try copyPreparedSpriteBytes(self.bytes[self.bytes_count..bytes_end], upload_stride, sprite, bounds, width_px, height_px);
        self.bytes_count = bytes_end;
        self.count += 1;
        std.debug.assert(self.count <= persistent_sprite_resources_max);
        self.last_resource_entry_index = self.count - 1;
        return .{ .resource = resource, .lifetime = .persistent };
    }

    pub fn atlasRegionFor(self: *SpriteResourceStore, sprite: PreparedSprite, width_px: u16, height_px: u16, bytes: []const u8) Error!AtlasPlacement {
        std.debug.assert(sprite.color_mode == .alpha);
        const bytes_hash = try hashPreparedBytes(sprite, width_px, height_px, bytes);
        if (self.last_atlas_entry_index) |index| {
            if (index < self.atlas_count) {
                const entry = self.atlas_entries[index];
                if (entry.key.value == sprite.key.value and
                    entry.bytes_hash == bytes_hash and
                    entry.width_px == width_px and
                    entry.height_px == height_px)
                {
                    return .{ .resource = self.atlas_resource, .rect = entry.rect, .created = false, .uploaded = false };
                }
            }
        }
        for (self.atlas_entries[0..@intCast(self.atlas_count)], 0..) |entry, i| {
            if (entry.key.value != sprite.key.value) continue;
            if (entry.bytes_hash != bytes_hash) continue;
            if (entry.width_px != width_px) continue;
            if (entry.height_px != height_px) continue;
            self.last_atlas_entry_index = @intCast(i);
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
        std.debug.assert(self.atlas_count <= alpha_atlas_entries_max);
        self.last_atlas_entry_index = self.atlas_count - 1;
        return .{ .resource = resource, .rect = rect_value, .created = !had_resource, .uploaded = true };
    }

    pub fn atlasAdmissionForPrepared(self: *SpriteResourceStore, sprite: PreparedSprite, bounds: rasterizer.SpriteBounds, width_px: u16, height_px: u16) Error!AtlasPlacement {
        std.debug.assert(sprite.color_mode == .alpha);
        const bytes_hash = try hashPreparedSpriteBytes(sprite, bounds, width_px, height_px);
        if (self.last_atlas_entry_index) |index| {
            if (index < self.atlas_count) {
                const entry = self.atlas_entries[index];
                if (entry.key.value == sprite.key.value and
                    entry.bytes_hash == bytes_hash and
                    entry.width_px == width_px and
                    entry.height_px == height_px)
                {
                    return .{ .resource = self.atlas_resource, .rect = entry.rect, .created = false, .uploaded = false };
                }
            }
        }
        for (self.atlas_entries[0..@intCast(self.atlas_count)], 0..) |entry, i| {
            if (entry.key.value != sprite.key.value) continue;
            if (entry.bytes_hash != bytes_hash) continue;
            if (entry.width_px != width_px) continue;
            if (entry.height_px != height_px) continue;
            self.last_atlas_entry_index = @intCast(i);
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
        std.debug.assert(self.atlas_count <= alpha_atlas_entries_max);
        self.last_atlas_entry_index = self.atlas_count - 1;
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

fn hashPreparedBytes(sprite: PreparedSprite, width_px: u16, height_px: u16, bytes: []const u8) Error!u64 {
    var hasher = std.hash.Wyhash.init(0x5350524954455630);
    hasher.update(std.mem.asBytes(&sprite.key.value));
    hasher.update(std.mem.asBytes(&width_px));
    hasher.update(std.mem.asBytes(&height_px));
    const format = uploadFormatForPrepared(sprite.color_mode);
    hasher.update(std.mem.asBytes(&format));
    const expected_count = try preparedBytesCount(sprite.color_mode, width_px, height_px);
    const bytes_count: u32 = std.math.cast(u32, bytes.len) orelse return error.InvalidPreparedSprite;
    if (bytes_count != expected_count) return error.InvalidPreparedSprite;
    hasher.update(bytes);
    return hasher.final();
}

fn hashPreparedSpriteBytes(sprite: PreparedSprite, bounds: rasterizer.SpriteBounds, width_px: u16, height_px: u16) Error!u64 {
    var hasher = std.hash.Wyhash.init(0x5350524954455630);
    hasher.update(std.mem.asBytes(&sprite.key.value));
    hasher.update(std.mem.asBytes(&width_px));
    hasher.update(std.mem.asBytes(&height_px));
    const format = uploadFormatForPrepared(sprite.color_mode);
    hasher.update(std.mem.asBytes(&format));
    const source = try preparedSpriteSource(sprite, bounds, width_px, height_px);
    if (source.source_stride == source.row_bytes) {
        const contiguous_end = source.source_offset + (source.row_bytes * height_px);
        hasher.update(sprite.pixels[source.source_offset..contiguous_end]);
        return hasher.final();
    }
    var yy: u16 = 0;
    while (yy < height_px) : (yy += 1) {
        const source_start = source.source_offset + (@as(u32, yy) * source.source_stride);
        const source_end = source_start + source.row_bytes;
        hasher.update(sprite.pixels[source_start..source_end]);
    }
    return hasher.final();
}

fn preparedUploadStride(color_mode: contract.SpriteColorMode, width_px: u16) Error!u32 {
    const bytes_per_pixel = bytesPerPixelForPrepared(color_mode);
    return std.math.mul(u32, width_px, bytes_per_pixel) catch error.ResourceBoundOverflow;
}

fn preparedBytesCount(color_mode: contract.SpriteColorMode, width_px: u16, height_px: u16) Error!u32 {
    const upload_stride = try preparedUploadStride(color_mode, width_px);
    return std.math.mul(u32, upload_stride, height_px) catch error.ResourceBoundOverflow;
}

fn preparedSpriteBytesEqualStored(stored: []const u8, sprite: PreparedSprite, bounds: rasterizer.SpriteBounds, width_px: u16, height_px: u16) Error!bool {
    const source = try preparedSpriteSource(sprite, bounds, width_px, height_px);
    const bytes_count = std.math.mul(u32, source.row_bytes, height_px) catch {
        return error.InvalidPreparedSprite;
    };
    const stored_count: u32 = std.math.cast(u32, stored.len) orelse return error.InvalidPreparedSprite;
    if (stored_count != bytes_count) return false;
    if (source.source_stride == source.row_bytes) {
        const contiguous_end = source.source_offset + bytes_count;
        return std.mem.eql(u8, stored, sprite.pixels[source.source_offset..contiguous_end]);
    }
    var yy: u16 = 0;
    while (yy < height_px) : (yy += 1) {
        const row_offset = @as(u32, yy) * source.row_bytes;
        const source_start = source.source_offset + (@as(u32, yy) * source.source_stride);
        const source_end = source_start + source.row_bytes;
        if (!std.mem.eql(u8, stored[row_offset .. row_offset + source.row_bytes], sprite.pixels[source_start..source_end])) return false;
    }
    return true;
}

fn copyPreparedSpriteBytes(target: []u8, target_stride: u32, sprite: PreparedSprite, bounds: rasterizer.SpriteBounds, width_px: u16, height_px: u16) Error!void {
    const source = try preparedSpriteSource(sprite, bounds, width_px, height_px);
    const target_count: u32 = std.math.cast(u32, target.len) orelse return error.InvalidPreparedSprite;
    const required_bytes = std.math.mul(u32, target_stride, height_px) catch {
        return error.InvalidPreparedSprite;
    };
    if (target_count < required_bytes) return error.InvalidPreparedSprite;
    if (target_stride == source.row_bytes and source.source_stride == source.row_bytes) {
        const contiguous_end = source.source_offset + required_bytes;
        @memcpy(target[0..required_bytes], sprite.pixels[source.source_offset..contiguous_end]);
        return;
    }
    var yy: u16 = 0;
    while (yy < height_px) : (yy += 1) {
        const source_start = source.source_offset + (@as(u32, yy) * source.source_stride);
        const source_end = source_start + source.row_bytes;
        const target_start = @as(u32, yy) * target_stride;
        const target_end = target_start + source.row_bytes;
        @memcpy(target[target_start..target_end], sprite.pixels[source_start..source_end]);
    }
}

const PreparedSpriteSource = struct {
    source_offset: u32,
    source_stride: u32,
    row_bytes: u32,
};

fn preparedSpriteSource(sprite: PreparedSprite, bounds: rasterizer.SpriteBounds, width_px: u16, height_px: u16) Error!PreparedSpriteSource {
    const bytes_per_pixel = bytesPerPixelForPrepared(sprite.color_mode);
    if (width_px == 0) return error.InvalidPreparedSprite;
    if (height_px == 0) return error.InvalidPreparedSprite;
    const source_right = std.math.add(u32, bounds.x_px, width_px) catch {
        return error.InvalidPreparedSprite;
    };
    const source_bottom = std.math.add(u32, bounds.y_px, height_px) catch {
        return error.InvalidPreparedSprite;
    };
    if (source_right > sprite.width_px) return error.InvalidPreparedSprite;
    if (source_bottom > sprite.height_px) return error.InvalidPreparedSprite;
    const row_bytes = std.math.mul(u32, width_px, bytes_per_pixel) catch {
        return error.InvalidPreparedSprite;
    };
    const source_x_bytes = std.math.mul(u32, bounds.x_px, bytes_per_pixel) catch {
        return error.InvalidPreparedSprite;
    };
    const source_y_row = std.math.mul(u32, bounds.y_px, sprite.stride_bytes) catch {
        return error.InvalidPreparedSprite;
    };
    const source_offset = std.math.add(u32, source_y_row, source_x_bytes) catch {
        return error.InvalidPreparedSprite;
    };
    const last_row_start = std.math.mul(u32, height_px - 1, sprite.stride_bytes) catch {
        return error.InvalidPreparedSprite;
    };
    const last_row_offset = std.math.add(u32, source_offset, last_row_start) catch {
        return error.InvalidPreparedSprite;
    };
    const source_end = std.math.add(u32, last_row_offset, row_bytes) catch {
        return error.InvalidPreparedSprite;
    };
    if (source_end > sprite.pixels.len) return error.InvalidPreparedSprite;
    return .{
        .source_offset = source_offset,
        .source_stride = sprite.stride_bytes,
        .row_bytes = row_bytes,
    };
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
        const atlas = try resources.atlasAdmissionForPrepared(sprite, .{}, 1, 1);
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
        resources.atlasAdmissionForPrepared(overflow_sprite, .{}, 1, 1),
    );
    try std.testing.expectEqual(alpha_atlas_entries_max, resources.atlas_count);
}

test "render-surface sprite resource store reuses last atlas and resource lookups" {
    var resources = SpriteResourceStore.init();
    const alpha_pixel = [_]u8{255};
    const color_bytes = [_]u8{ 1, 2, 3, 4 };
    const atlas_sprite = PreparedSprite{
        .key = .{ .value = 1 },
        .pixels = &alpha_pixel,
        .width_px = 1,
        .height_px = 1,
        .stride_bytes = 1,
        .color_mode = .alpha,
        .visual_bounds = .{},
    };
    const color_sprite = PreparedSprite{
        .key = .{ .value = 2 },
        .pixels = &color_bytes,
        .width_px = 1,
        .height_px = 1,
        .stride_bytes = 4,
        .color_mode = .color,
        .visual_bounds = .{},
    };

    const first_atlas = try resources.atlasAdmissionForPrepared(atlas_sprite, .{}, 1, 1);
    try std.testing.expect(first_atlas.created);
    try std.testing.expect(first_atlas.uploaded);
    const second_atlas = try resources.atlasAdmissionForPrepared(atlas_sprite, .{}, 1, 1);
    try std.testing.expect(!second_atlas.created);
    try std.testing.expect(!second_atlas.uploaded);
    try std.testing.expectEqual(first_atlas.rect, second_atlas.rect);
    try std.testing.expectEqual(@as(u32, 1), resources.atlas_count);

    const first_resource = try resources.resourceAdmissionForPrepared(color_sprite, .{}, 1, 1);
    try std.testing.expectEqual(SpriteResourceStore.ResourceAllocation.Lifetime.persistent, first_resource.lifetime);
    const second_resource = try resources.resourceAdmissionForPrepared(color_sprite, .{}, 1, 1);
    try std.testing.expectEqual(SpriteResourceStore.ResourceAllocation.Lifetime.reused, second_resource.lifetime);
    try std.testing.expectEqual(first_resource.resource, second_resource.resource);
    try std.testing.expectEqual(@as(u32, 1), resources.count);
}

test "render-surface sprite resource store admits atlas and color reuse before emitter staging" {
    var resources = SpriteResourceStore.init();
    const alpha_bytes = [_]u8{ 11, 22, 33, 44 };
    const color_bytes = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8 };
    const alpha_sprite = PreparedSprite{
        .key = .{ .value = 11 },
        .pixels = &alpha_bytes,
        .width_px = 2,
        .height_px = 2,
        .stride_bytes = 2,
        .color_mode = .alpha,
        .visual_bounds = .{},
    };
    const color_sprite = PreparedSprite{
        .key = .{ .value = 12 },
        .pixels = &color_bytes,
        .width_px = 2,
        .height_px = 1,
        .stride_bytes = 8,
        .color_mode = .color,
        .visual_bounds = .{},
    };

    const atlas_first = try resources.atlasAdmissionForPrepared(alpha_sprite, .{}, 2, 2);
    try std.testing.expect(atlas_first.uploaded);
    try std.testing.expectEqual(@as(u32, 1), resources.atlas_count);
    const atlas_second = try resources.atlasAdmissionForPrepared(alpha_sprite, .{}, 2, 2);
    try std.testing.expect(!atlas_second.uploaded);
    try std.testing.expectEqual(atlas_first.rect, atlas_second.rect);
    try std.testing.expectEqual(@as(u32, 1), resources.atlas_count);

    const color_first = try resources.resourceAdmissionForPrepared(color_sprite, .{}, 2, 1);
    try std.testing.expectEqual(SpriteResourceStore.ResourceAllocation.Lifetime.persistent, color_first.lifetime);
    try std.testing.expectEqual(@as(u32, color_bytes.len), resources.bytes_count);
    const color_second = try resources.resourceAdmissionForPrepared(color_sprite, .{}, 2, 1);
    try std.testing.expectEqual(SpriteResourceStore.ResourceAllocation.Lifetime.reused, color_second.lifetime);
    try std.testing.expectEqual(color_first.resource, color_second.resource);
    try std.testing.expectEqual(@as(u32, color_bytes.len), resources.bytes_count);
}
