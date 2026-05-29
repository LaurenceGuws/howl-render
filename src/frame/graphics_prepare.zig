const std = @import("std");
const abi = @import("../ffi_types.zig");
const surface = @import("surface.zig");

pub const invalid_graphics_raster_index = std.math.maxInt(u32);

pub const DecodedGraphicsRaster = struct {
    width: u32,
    height: u32,
    stride: u32,
    pixels_rgba: []u8,
};

pub const GraphicsRasterView = struct {
    width: u32,
    height: u32,
    stride: u32,
    pixels_rgba: []const u8,
};

pub const SourceGraphicsPayload = struct {
    image: abi.FfiVtGraphicsDecodedImage,
    payload: []const u8,
};

pub const GraphicsPreparer = struct {
    allocator: std.mem.Allocator,
    decoded_graphics_rasters: []DecodedGraphicsRaster = &.{},

    pub fn init(allocator: std.mem.Allocator) GraphicsPreparer {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *GraphicsPreparer) void {
        self.clearDecodedGraphicsRasters();
    }

    pub fn clearDecodedGraphicsRasters(self: *GraphicsPreparer) void {
        for (self.decoded_graphics_rasters) |decoded_raster| {
            self.allocator.free(decoded_raster.pixels_rgba);
        }
        if (self.decoded_graphics_rasters.len > 0) self.allocator.free(self.decoded_graphics_rasters);
        self.decoded_graphics_rasters = &.{};
    }

    pub fn prepare(
        self: *GraphicsPreparer,
        prepared: *surface.PreparedGraphics,
        source_images: []const abi.FfiVtGraphicsDecodedImage,
        payload_bytes: []const u8,
    ) !void {
        const source_payloads = try self.sourceGraphicsPayloads(source_images, payload_bytes);
        defer self.allocator.free(source_payloads);

        self.clearDecodedGraphicsRasters();
        errdefer self.clearDecodedGraphicsRasters();

        self.decoded_graphics_rasters = try self.decodeGraphicsRasters(source_payloads);
        try self.bindPreparedGraphicsRasters(prepared, source_payloads);
    }

    pub fn raster(self: *const GraphicsPreparer, raster_index: u32) ?GraphicsRasterView {
        if (raster_index >= self.decoded_graphics_rasters.len) return null;
        const raster_ = self.decoded_graphics_rasters[raster_index];
        return .{
            .width = raster_.width,
            .height = raster_.height,
            .stride = raster_.stride,
            .pixels_rgba = raster_.pixels_rgba,
        };
    }

    fn sourceGraphicsPayloads(
        self: *GraphicsPreparer,
        source_images: []const abi.FfiVtGraphicsDecodedImage,
        payload_bytes: []const u8,
    ) ![]SourceGraphicsPayload {
        var payloads = try self.allocator.alloc(SourceGraphicsPayload, source_images.len);
        errdefer self.allocator.free(payloads);
        var offset: usize = 0;
        for (source_images, 0..) |image, i| {
            const payload_len = std.math.cast(usize, image.payload_len) orelse return error.InvalidGraphicsPayload;
            const next_offset = std.math.add(usize, offset, payload_len) catch return error.InvalidGraphicsPayload;
            if (next_offset > payload_bytes.len) return error.InvalidGraphicsPayload;
            payloads[i] = .{
                .image = image,
                .payload = payload_bytes[offset..next_offset],
            };
            offset = next_offset;
        }
        if (offset != payload_bytes.len) return error.InvalidGraphicsPayload;
        return payloads;
    }

    fn decodeGraphicsRasters(
        self: *GraphicsPreparer,
        source_payloads: []const SourceGraphicsPayload,
    ) ![]DecodedGraphicsRaster {
        var decoded = try self.allocator.alloc(DecodedGraphicsRaster, source_payloads.len);
        errdefer self.allocator.free(decoded);

        var decoded_count: usize = 0;
        errdefer {
            for (decoded[0..decoded_count]) |decoded_raster| {
                self.allocator.free(decoded_raster.pixels_rgba);
            }
        }

        for (source_payloads) |source_payload| {
            decoded[decoded_count] = try decodeGraphicsRaster(self.allocator, source_payload);
            decoded_count += 1;
        }

        return decoded;
    }

    fn bindPreparedGraphicsRasters(
        self: *GraphicsPreparer,
        prepared: *surface.PreparedGraphics,
        source_payloads: []const SourceGraphicsPayload,
    ) !void {
        const old_images = prepared.images;
        const old_placements = prepared.placements;
        const image_remap = try self.allocator.alloc(u32, old_images.len);
        defer self.allocator.free(image_remap);
        @memset(image_remap, invalid_graphics_raster_index);

        var images = std.ArrayList(surface.PreparedGraphicsImageRef).empty;
        defer images.deinit(self.allocator);
        for (old_images, 0..) |image, old_index| {
            const raster_index = publicationRasterIndex(source_payloads, image.image_ref_id) orelse continue;
            image_remap[old_index] = std.math.cast(u32, images.items.len) orelse return error.OutOfMemory;
            try images.append(self.allocator, .{
                .image_id = image.image_id,
                .image_ref_id = image.image_ref_id,
                .width = image.width,
                .height = image.height,
                .format = image.format,
                .raster_index = raster_index,
            });
        }

        var placements = std.ArrayList(surface.PreparedGraphicsPlacement).empty;
        defer placements.deinit(self.allocator);
        var below_bg_count: u32 = 0;
        var below_text_count: u32 = 0;
        var above_text_count: u32 = 0;
        for (old_placements) |placement| {
            const next_image_index = image_remap[placement.image_index];
            if (next_image_index == invalid_graphics_raster_index) continue;
            var next = placement;
            next.image_index = next_image_index;
            try placements.append(self.allocator, next);
            switch (placement.layer) {
                .below_bg => below_bg_count +%= 1,
                .below_text => below_text_count +%= 1,
                .above_text => above_text_count +%= 1,
            }
        }

        if (old_images.len > 0) self.allocator.free(old_images);
        if (old_placements.len > 0) self.allocator.free(old_placements);
        prepared.images = try images.toOwnedSlice(self.allocator);
        prepared.placements = try placements.toOwnedSlice(self.allocator);
        prepared.below_bg_count = below_bg_count;
        prepared.below_text_count = below_text_count;
        prepared.above_text_count = above_text_count;
    }
};

fn publicationRasterIndex(source_payloads: []const SourceGraphicsPayload, image_ref_id: u32) ?u32 {
    for (source_payloads, 0..) |source_payload, i| {
        if (source_payload.image.image_ref_id == image_ref_id) {
            return std.math.cast(u32, i) orelse unreachable;
        }
    }
    return null;
}

fn decodeGraphicsRaster(
    allocator: std.mem.Allocator,
    source_payload: SourceGraphicsPayload,
) !DecodedGraphicsRaster {
    return switch (source_payload.image.format) {
        24 => try decodeDecodedRawGraphicsRaster(allocator, source_payload, 3),
        32 => try decodeDecodedRawGraphicsRaster(allocator, source_payload, 4),
        else => error.InvalidGraphicsPayload,
    };
}

fn decodeDecodedRawGraphicsRaster(
    allocator: std.mem.Allocator,
    source_payload: SourceGraphicsPayload,
    channels: u32,
) !DecodedGraphicsRaster {
    const pixel_count = try graphicsPixelCount(source_payload.image.width, source_payload.image.height);
    const expected_len = try graphicsBytesLen(pixel_count, channels);
    if (source_payload.payload.len != expected_len) return error.InvalidGraphicsPayload;
    const stride = try graphicsBytesLen(source_payload.image.width, 4);
    const pixels_rgba = try allocator.alloc(u8, try graphicsBytesLen(pixel_count, 4));
    errdefer allocator.free(pixels_rgba);

    if (channels == 4) {
        @memcpy(pixels_rgba, source_payload.payload);
    } else {
        var source_index: usize = 0;
        var target_index: usize = 0;
        while (source_index < source_payload.payload.len) : (source_index += 3) {
            pixels_rgba[target_index] = source_payload.payload[source_index];
            pixels_rgba[target_index + 1] = source_payload.payload[source_index + 1];
            pixels_rgba[target_index + 2] = source_payload.payload[source_index + 2];
            pixels_rgba[target_index + 3] = 255;
            target_index += 4;
        }
    }

    return .{
        .width = source_payload.image.width,
        .height = source_payload.image.height,
        .stride = std.math.cast(u32, stride) orelse return error.InvalidGraphicsPayload,
        .pixels_rgba = pixels_rgba,
    };
}

fn graphicsPixelCount(width: u32, height: u32) !u32 {
    return std.math.mul(u32, width, height) catch return error.InvalidGraphicsPayload;
}

fn graphicsBytesLen(left: u32, right: u32) !usize {
    const total = std.math.mul(u64, left, right) catch return error.InvalidGraphicsPayload;
    return std.math.cast(usize, total) orelse return error.InvalidGraphicsPayload;
}

test "sourceGraphicsPayloads binds exact payload slices across multiple images" {
    var preparer = GraphicsPreparer.init(std.testing.allocator);
    defer preparer.deinit();

    const images = [_]abi.FfiVtGraphicsDecodedImage{
        .{ .image_id = 1, .image_ref_id = 10, .image_number = 0, .format = 24, .width = 1, .height = 1, .payload_len = 2 },
        .{ .image_id = 2, .image_ref_id = 20, .image_number = 0, .format = 24, .width = 1, .height = 1, .payload_len = 3 },
        .{ .image_id = 3, .image_ref_id = 30, .image_number = 0, .format = 24, .width = 1, .height = 1, .payload_len = 1 },
    };

    const payloads = try preparer.sourceGraphicsPayloads(images[0..], "ABCDEF");
    defer std.testing.allocator.free(payloads);

    try std.testing.expectEqual(@as(usize, 3), payloads.len);
    try std.testing.expectEqual(@as(u32, 1), payloads[0].image.image_id);
    try std.testing.expectEqual(@as(u32, 2), payloads[1].image.image_id);
    try std.testing.expectEqual(@as(u32, 3), payloads[2].image.image_id);
    try std.testing.expectEqualStrings("AB", payloads[0].payload);
    try std.testing.expectEqualStrings("CDE", payloads[1].payload);
    try std.testing.expectEqualStrings("F", payloads[2].payload);
}

test "sourceGraphicsPayloads rejects trailing or truncated multi-image payload bytes" {
    var preparer = GraphicsPreparer.init(std.testing.allocator);
    defer preparer.deinit();

    const images = [_]abi.FfiVtGraphicsDecodedImage{
        .{ .image_id = 1, .image_ref_id = 10, .image_number = 0, .format = 24, .width = 1, .height = 1, .payload_len = 2 },
        .{ .image_id = 2, .image_ref_id = 20, .image_number = 0, .format = 24, .width = 1, .height = 1, .payload_len = 2 },
    };

    try std.testing.expectError(error.InvalidGraphicsPayload, preparer.sourceGraphicsPayloads(images[0..], "ABCDE"));
    try std.testing.expectError(error.InvalidGraphicsPayload, preparer.sourceGraphicsPayloads(images[0..], "ABC"));
}

test "decoded graphics prepares raw rgb and rgba payloads" {
    var preparer = GraphicsPreparer.init(std.testing.allocator);
    defer preparer.deinit();

    var rgb_graphics = surface.PreparedGraphics{
        .publication_seq = 1,
        .images = try std.testing.allocator.dupe(surface.PreparedGraphicsImageRef, &.{.{ .image_id = 1, .image_ref_id = 10, .width = 1, .height = 1, .format = 24, .raster_index = invalid_graphics_raster_index }}),
        .placements = &.{},
    };
    defer rgb_graphics.deinit(std.testing.allocator);
    const rgb_images = [_]abi.FfiVtGraphicsDecodedImage{.{ .image_id = 1, .image_ref_id = 10, .image_number = 0, .format = 24, .width = 1, .height = 1, .payload_len = 3 }};
    try preparer.prepare(&rgb_graphics, rgb_images[0..], &.{ 1, 2, 3 });
    try std.testing.expectEqual(@as(usize, 1), rgb_graphics.images.len);
    try std.testing.expectEqual(@as(u32, 10), rgb_graphics.images[0].image_ref_id);
    try std.testing.expectEqual(@as(u32, 0), rgb_graphics.images[0].raster_index);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 255 }, preparer.raster(0).?.pixels_rgba);

    var rgba_graphics = surface.PreparedGraphics{
        .publication_seq = 2,
        .images = try std.testing.allocator.dupe(surface.PreparedGraphicsImageRef, &.{.{ .image_id = 2, .image_ref_id = 20, .width = 1, .height = 1, .format = 32, .raster_index = invalid_graphics_raster_index }}),
        .placements = &.{},
    };
    defer rgba_graphics.deinit(std.testing.allocator);
    const rgba_images = [_]abi.FfiVtGraphicsDecodedImage{.{ .image_id = 2, .image_ref_id = 20, .image_number = 0, .format = 32, .width = 1, .height = 1, .payload_len = 4 }};
    try preparer.prepare(&rgba_graphics, rgba_images[0..], &.{ 4, 5, 6, 7 });
    try std.testing.expectEqual(@as(u32, 0), rgba_graphics.images[0].raster_index);
    try std.testing.expectEqualSlices(u8, &.{ 4, 5, 6, 7 }, preparer.raster(0).?.pixels_rgba);
}

test "decoded graphics rejects exact byte and format violations" {
    var preparer = GraphicsPreparer.init(std.testing.allocator);
    defer preparer.deinit();

    const images = [_]abi.FfiVtGraphicsDecodedImage{.{ .image_id = 1, .image_ref_id = 10, .image_number = 0, .format = 24, .width = 1, .height = 1, .payload_len = 3 }};
    try std.testing.expectError(error.InvalidGraphicsPayload, preparer.sourceGraphicsPayloads(images[0..], &.{ 1, 2 }));
    try std.testing.expectError(error.InvalidGraphicsPayload, preparer.sourceGraphicsPayloads(images[0..], &.{ 1, 2, 3, 4 }));

    var graphics = surface.PreparedGraphics{
        .publication_seq = 1,
        .images = try std.testing.allocator.dupe(surface.PreparedGraphicsImageRef, &.{.{ .image_id = 2, .image_ref_id = 20, .width = 1, .height = 1, .format = 100, .raster_index = invalid_graphics_raster_index }}),
        .placements = &.{},
    };
    defer graphics.deinit(std.testing.allocator);
    const unsupported = [_]abi.FfiVtGraphicsDecodedImage{.{ .image_id = 2, .image_ref_id = 20, .image_number = 0, .format = 100, .width = 1, .height = 1, .payload_len = 4 }};
    try std.testing.expectError(error.InvalidGraphicsPayload, preparer.prepare(&graphics, unsupported[0..], &.{ 1, 2, 3, 4 }));
}
