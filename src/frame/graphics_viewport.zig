const std = @import("std");
const abi = @import("../ffi_types.zig");
const clip_rect = @import("clip_rect.zig");
const surface = @import("surface.zig");

pub const ViewportState = struct {
    rows: u16,
    history_count: u64,
    scroll_row: u64,
    is_alternate_screen: bool,
};

pub const PlacementViewport = struct {
    viewport_col: i32,
    viewport_row: i32,
    x_px: i32,
    y_px: i32,
    width_px: u32,
    height_px: u32,
    clip_top_origin: ?clip_rect.ClipRect,
};

pub fn prepareGraphics(
    allocator: std.mem.Allocator,
    layout: surface.PrepareLayout,
    viewport: ViewportState,
    publication_seq: u64,
    images: []const abi.FfiVtGraphicsDecodedImage,
    placements: []const abi.FfiVtGraphicsPlacement,
) !surface.PreparedGraphics {
    var prepared_images = std.ArrayList(surface.PreparedGraphicsImageRef).empty;
    defer prepared_images.deinit(allocator);
    var prepared_placements = std.ArrayList(surface.PreparedGraphicsPlacement).empty;
    defer prepared_placements.deinit(allocator);

    var below_bg_count: u32 = 0;
    var below_text_count: u32 = 0;
    var above_text_count: u32 = 0;

    for (placements) |placement| {
        const viewport_rect = resolvePlacementViewport(viewport, layout.grid_px, layout.cell_px, placement) orelse continue;
        const clipped = viewport_rect.clip_top_origin orelse continue;
        const image = findImage(images, placement.image_id) orelse continue;
        const source = resolveSourceRect(image, placement) orelse continue;
        const dest = destRect(clipped);
        const adjusted_source = adjustSourceRect(source, viewport_rect, dest) orelse continue;
        const image_index = try appendImageRef(allocator, &prepared_images, image);
        const layer = classifyLayer(placement.z_index);
        switch (layer) {
            .below_bg => below_bg_count +%= 1,
            .below_text => below_text_count +%= 1,
            .above_text => above_text_count +%= 1,
        }
        try prepared_placements.append(allocator, .{
            .image_index = image_index,
            .render_order_key = placement.render_order_key,
            .z_index = placement.z_index,
            .layer = layer,
            .dest_x_px = dest.x,
            .dest_y_px = dest.y,
            .dest_width_px = dest.width,
            .dest_height_px = dest.height,
            .src_x_px = adjusted_source.x,
            .src_y_px = adjusted_source.y,
            .src_width_px = adjusted_source.width,
            .src_height_px = adjusted_source.height,
        });
    }

    sortPreparedPlacements(prepared_images.items, prepared_placements.items);

    return .{
        .publication_seq = publication_seq,
        .images = try prepared_images.toOwnedSlice(allocator),
        .placements = try prepared_placements.toOwnedSlice(allocator),
        .below_bg_count = below_bg_count,
        .below_text_count = below_text_count,
        .above_text_count = above_text_count,
    };
}

pub fn resolvePlacementViewport(
    viewport: ViewportState,
    grid_px: surface.PixelSize,
    cell_px: surface.CellSize,
    placement: abi.FfiVtGraphicsPlacement,
) ?PlacementViewport {
    if (cell_px.width == 0) return null;
    if (cell_px.height == 0) return null;
    if (placement.dest_right_cell_px <= placement.dest_left_cell_px) return null;
    if (placement.dest_bottom_cell_px <= placement.dest_top_cell_px) return null;

    const viewport_row = anchorViewportRow(viewport, placement.anchor) orelse return null;
    const viewport_col: i64 = placement.anchor_col;
    const x_px = viewport_col * cell_px.width + placement.dest_left_cell_px;
    const y_px = viewport_row * cell_px.height + placement.dest_top_cell_px;
    const right_px = viewport_col * cell_px.width + placement.dest_right_cell_px;
    const bottom_px = viewport_row * cell_px.height + placement.dest_bottom_cell_px;
    const width_px = right_px - x_px;
    const height_px = bottom_px - y_px;
    if (width_px <= 0) return null;
    if (height_px <= 0) return null;

    return .{
        .viewport_col = std.math.cast(i32, viewport_col) orelse return null,
        .viewport_row = std.math.cast(i32, viewport_row) orelse return null,
        .x_px = std.math.cast(i32, x_px) orelse return null,
        .y_px = std.math.cast(i32, y_px) orelse return null,
        .width_px = std.math.cast(u32, width_px) orelse return null,
        .height_px = std.math.cast(u32, height_px) orelse return null,
        .clip_top_origin = clipPlacementTopOrigin(grid_px, x_px, y_px, right_px, bottom_px),
    };
}

fn anchorViewportRow(viewport: ViewportState, anchor: abi.FfiVtGraphicsRowAnchor) ?i64 {
    _ = viewport.is_alternate_screen;
    const source_row = switch (anchor.kind) {
        1 => std.math.add(u64, viewport.history_count, anchor.value) catch return null,
        2 => blk: {
            if (anchor.value > viewport.history_count) return null;
            break :blk viewport.history_count - anchor.value;
        },
        3 => blk: {
            const below_screen = std.math.add(u64, viewport.history_count, viewport.rows) catch return null;
            break :blk std.math.add(u64, below_screen, anchor.value) catch return null;
        },
        else => return null,
    };
    const source_row_i128: i128 = source_row;
    const scroll_row_i128: i128 = viewport.scroll_row;
    return std.math.cast(i64, source_row_i128 - scroll_row_i128);
}

fn clipPlacementTopOrigin(
    grid_px: surface.PixelSize,
    left_px: i64,
    top_px: i64,
    right_px: i64,
    bottom_px: i64,
) ?clip_rect.ClipRect {
    const width_px: i64 = grid_px.width;
    const height_px: i64 = grid_px.height;
    const clip_left = std.math.clamp(left_px, 0, width_px);
    const clip_top = std.math.clamp(top_px, 0, height_px);
    const clip_right = std.math.clamp(right_px, 0, width_px);
    const clip_bottom = std.math.clamp(bottom_px, 0, height_px);
    if (clip_right <= clip_left) return null;
    if (clip_bottom <= clip_top) return null;
    return .{
        .x = std.math.cast(c_int, clip_left) orelse return null,
        .y = std.math.cast(c_int, clip_top) orelse return null,
        .w = std.math.cast(c_int, clip_right - clip_left) orelse return null,
        .h = std.math.cast(c_int, clip_bottom - clip_top) orelse return null,
    };
}

const SourceRect = struct {
    x: u32,
    y: u32,
    width: u32,
    height: u32,
};

const DestRect = struct {
    x: i32,
    y: i32,
    width: u32,
    height: u32,
};

fn classifyLayer(z_index: i32) surface.PreparedGraphicsLayer {
    if (z_index < std.math.minInt(i32) / 2) return .below_bg;
    if (z_index < 0) return .below_text;
    return .above_text;
}

fn findImage(images: []const abi.FfiVtGraphicsDecodedImage, image_id: u32) ?abi.FfiVtGraphicsDecodedImage {
    for (images) |image| {
        if (image.image_id == image_id) return image;
    }
    return null;
}

fn appendImageRef(
    allocator: std.mem.Allocator,
    prepared_images: *std.ArrayList(surface.PreparedGraphicsImageRef),
    image: abi.FfiVtGraphicsDecodedImage,
) !u32 {
    std.debug.assert(image.image_ref_id != 0);
    for (prepared_images.items, 0..) |prepared, image_index| {
        if (prepared.image_ref_id == image.image_ref_id) {
            return std.math.cast(u32, image_index) orelse return error.OutOfMemory;
        }
    }
    try prepared_images.append(allocator, .{
        .image_id = image.image_id,
        .image_ref_id = image.image_ref_id,
        .width = image.width,
        .height = image.height,
        .format = image.format,
        .raster_index = std.math.maxInt(u32),
    });
    return std.math.cast(u32, prepared_images.items.len - 1) orelse return error.OutOfMemory;
}

fn resolveSourceRect(image: abi.FfiVtGraphicsDecodedImage, placement: abi.FfiVtGraphicsPlacement) ?SourceRect {
    if (placement.source_x >= image.width) return null;
    if (placement.source_y >= image.height) return null;

    const max_width = image.width - placement.source_x;
    const max_height = image.height - placement.source_y;
    const width = if (placement.source_width == 0) max_width else @min(placement.source_width, max_width);
    const height = if (placement.source_height == 0) max_height else @min(placement.source_height, max_height);
    if (width == 0) return null;
    if (height == 0) return null;

    return .{
        .x = placement.source_x,
        .y = placement.source_y,
        .width = width,
        .height = height,
    };
}

fn destRect(clipped: clip_rect.ClipRect) DestRect {
    std.debug.assert(clipped.w > 0);
    std.debug.assert(clipped.h > 0);
    return .{
        .x = clipped.x,
        .y = clipped.y,
        .width = @intCast(clipped.w),
        .height = @intCast(clipped.h),
    };
}

fn adjustSourceRect(source: SourceRect, viewport_rect: PlacementViewport, dest: DestRect) ?SourceRect {
    if (viewport_rect.width_px == 0) return null;
    if (viewport_rect.height_px == 0) return null;

    const dest_left = viewport_rect.x_px;
    const dest_top = viewport_rect.y_px;
    const dest_right = dest_left + (std.math.cast(i32, viewport_rect.width_px) orelse return null);
    const dest_bottom = dest_top + (std.math.cast(i32, viewport_rect.height_px) orelse return null);
    const clipped_right = dest.x + (std.math.cast(i32, dest.width) orelse return null);
    const clipped_bottom = dest.y + (std.math.cast(i32, dest.height) orelse return null);

    const offset_left = std.math.cast(u32, dest.x - dest_left) orelse return null;
    const offset_top = std.math.cast(u32, dest.y - dest_top) orelse return null;
    const offset_right = std.math.cast(u32, clipped_right - dest_left) orelse return null;
    const offset_bottom = std.math.cast(u32, clipped_bottom - dest_top) orelse return null;
    std.debug.assert(clipped_right <= dest_right);
    std.debug.assert(clipped_bottom <= dest_bottom);

    const src_left = source.x + mulDivFloor(offset_left, source.width, viewport_rect.width_px);
    const src_top = source.y + mulDivFloor(offset_top, source.height, viewport_rect.height_px);
    const src_right = source.x + mulDivCeil(offset_right, source.width, viewport_rect.width_px);
    const src_bottom = source.y + mulDivCeil(offset_bottom, source.height, viewport_rect.height_px);
    if (src_right <= src_left) return null;
    if (src_bottom <= src_top) return null;

    return .{
        .x = src_left,
        .y = src_top,
        .width = src_right - src_left,
        .height = src_bottom - src_top,
    };
}

fn mulDivFloor(value: u32, numerator: u32, denominator: u32) u32 {
    std.debug.assert(denominator > 0);
    const product = @as(u64, value) * @as(u64, numerator);
    return @intCast(product / denominator);
}

fn mulDivCeil(value: u32, numerator: u32, denominator: u32) u32 {
    std.debug.assert(denominator > 0);
    const product = @as(u64, value) * @as(u64, numerator);
    return @intCast(@divFloor(product + denominator - 1, denominator));
}

fn sortPreparedPlacements(
    prepared_images: []const surface.PreparedGraphicsImageRef,
    prepared_placements: []surface.PreparedGraphicsPlacement,
) void {
    var i: usize = 1;
    while (i < prepared_placements.len) : (i += 1) {
        const item = prepared_placements[i];
        var j = i;
        while (j > 0) {
            const prior = prepared_placements[j - 1];
            if (!placementLess(prepared_images, item, prior)) break;
            prepared_placements[j] = prior;
            j -= 1;
        }
        prepared_placements[j] = item;
    }
}

fn placementLess(
    prepared_images: []const surface.PreparedGraphicsImageRef,
    a: surface.PreparedGraphicsPlacement,
    b: surface.PreparedGraphicsPlacement,
) bool {
    if (a.z_index != b.z_index) return a.z_index < b.z_index;

    const a_image = prepared_images[@intCast(a.image_index)].image_id;
    const b_image = prepared_images[@intCast(b.image_index)].image_id;
    if (a_image != b_image) return a_image < b_image;

    if (a.render_order_key != b.render_order_key) return a.render_order_key < b.render_order_key;
    return false;
}

fn testPlacement() abi.FfiVtGraphicsPlacement {
    return std.mem.zeroes(abi.FfiVtGraphicsPlacement);
}

test "graphics viewport resolves visible scrollback placement from retained viewport state" {
    var placement = std.mem.zeroes(abi.FfiVtGraphicsPlacement);
    placement.anchor = .{ .kind = 2, .value = 2 };
    placement.anchor_col = 3;
    placement.dest_left_cell_px = 2;
    placement.dest_top_cell_px = 5;
    placement.dest_right_cell_px = 22;
    placement.dest_bottom_cell_px = 25;
    const resolved = resolvePlacementViewport(
        .{ .rows = 4, .history_count = 10, .scroll_row = 8, .is_alternate_screen = false },
        .{ .width = 100, .height = 80 },
        .{ .width = 10, .height = 20 },
        placement,
    ).?;

    try std.testing.expectEqual(@as(i32, 3), resolved.viewport_col);
    try std.testing.expectEqual(@as(i32, 0), resolved.viewport_row);
    try std.testing.expectEqual(@as(i32, 32), resolved.x_px);
    try std.testing.expectEqual(@as(i32, 5), resolved.y_px);
    try std.testing.expectEqual(@as(c_int, 32), resolved.clip_top_origin.?.x);
    try std.testing.expectEqual(@as(c_int, 5), resolved.clip_top_origin.?.y);
    try std.testing.expectEqual(@as(c_int, 20), resolved.clip_top_origin.?.w);
    try std.testing.expectEqual(@as(c_int, 20), resolved.clip_top_origin.?.h);
}

test "graphics viewport clips placement that starts above the viewport" {
    var placement = std.mem.zeroes(abi.FfiVtGraphicsPlacement);
    placement.anchor = .{ .kind = 2, .value = 3 };
    placement.dest_top_cell_px = 5;
    placement.dest_right_cell_px = 20;
    placement.dest_bottom_cell_px = 37;
    const resolved = resolvePlacementViewport(
        .{ .rows = 4, .history_count = 10, .scroll_row = 8, .is_alternate_screen = false },
        .{ .width = 100, .height = 80 },
        .{ .width = 10, .height = 20 },
        placement,
    ).?;

    try std.testing.expectEqual(@as(i32, -1), resolved.viewport_row);
    try std.testing.expectEqual(@as(i32, -15), resolved.y_px);
    try std.testing.expectEqual(@as(c_int, 0), resolved.clip_top_origin.?.y);
    try std.testing.expectEqual(@as(c_int, 17), resolved.clip_top_origin.?.h);
}

test "graphics viewport reports fully off-screen below placement as invisible" {
    var placement = std.mem.zeroes(abi.FfiVtGraphicsPlacement);
    placement.anchor = .{ .kind = 3, .value = 0 };
    placement.dest_right_cell_px = 20;
    placement.dest_bottom_cell_px = 20;
    const resolved = resolvePlacementViewport(
        .{ .rows = 4, .history_count = 10, .scroll_row = 8, .is_alternate_screen = false },
        .{ .width = 100, .height = 80 },
        .{ .width = 10, .height = 20 },
        placement,
    ).?;

    try std.testing.expectEqual(@as(i32, 6), resolved.viewport_row);
    try std.testing.expect(resolved.clip_top_origin == null);
}

test "graphics viewport prepares visible placement" {
    const images = [_]abi.FfiVtGraphicsDecodedImage{.{
        .image_id = 7,
        .image_ref_id = 77,
        .format = 24,
        .width = 64,
        .height = 32,
        .payload_len = 0,
        .image_number = 0,
    }};
    var placement = testPlacement();
    placement.image_id = 7;
    placement.anchor = .{ .kind = 1, .value = 1 };
    placement.anchor_col = 2;
    placement.source_width = 64;
    placement.source_height = 32;
    placement.dest_left_cell_px = 3;
    placement.dest_top_cell_px = 4;
    placement.dest_right_cell_px = 35;
    placement.dest_bottom_cell_px = 36;
    const placements = [_]abi.FfiVtGraphicsPlacement{placement};

    var prepared = try prepareGraphics(
        std.testing.allocator,
        .{
            .render_px = .{ .width = 64, .height = 64 },
            .grid_px = .{ .width = 64, .height = 64 },
            .cell_px = .{ .width = 16, .height = 16 },
        },
        .{ .rows = 4, .history_count = 0, .scroll_row = 0, .is_alternate_screen = false },
        3,
        images[0..],
        placements[0..],
    );
    defer prepared.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u64, 3), prepared.publication_seq);
    try std.testing.expectEqual(@as(usize, 1), prepared.images.len);
    try std.testing.expectEqual(@as(u32, 77), prepared.images[0].image_ref_id);
    try std.testing.expectEqual(@as(usize, 1), prepared.placements.len);
    try std.testing.expectEqual(surface.PreparedGraphicsLayer.above_text, prepared.placements[0].layer);
    try std.testing.expectEqual(@as(i32, 35), prepared.placements[0].dest_x_px);
    try std.testing.expectEqual(@as(i32, 20), prepared.placements[0].dest_y_px);
    try std.testing.expectEqual(@as(u32, 29), prepared.placements[0].dest_width_px);
    try std.testing.expectEqual(@as(u32, 32), prepared.placements[0].dest_height_px);
    try std.testing.expectEqual(@as(u32, 0), prepared.placements[0].src_x_px);
    try std.testing.expectEqual(@as(u32, 0), prepared.placements[0].src_y_px);
    try std.testing.expectEqual(@as(u32, 58), prepared.placements[0].src_width_px);
    try std.testing.expectEqual(@as(u32, 32), prepared.placements[0].src_height_px);
}

test "graphics viewport adjusts source rect after clipping" {
    const images = [_]abi.FfiVtGraphicsDecodedImage{.{
        .image_id = 9,
        .image_ref_id = 99,
        .format = 24,
        .width = 100,
        .height = 50,
        .payload_len = 0,
        .image_number = 0,
    }};
    var placement = testPlacement();
    placement.image_id = 9;
    placement.anchor = .{ .kind = 2, .value = 1 };
    placement.source_x = 10;
    placement.source_y = 5;
    placement.source_width = 80;
    placement.source_height = 40;
    placement.dest_top_cell_px = 10;
    placement.dest_right_cell_px = 40;
    placement.dest_bottom_cell_px = 50;
    const placements = [_]abi.FfiVtGraphicsPlacement{placement};

    var prepared = try prepareGraphics(
        std.testing.allocator,
        .{
            .render_px = .{ .width = 40, .height = 40 },
            .grid_px = .{ .width = 40, .height = 40 },
            .cell_px = .{ .width = 20, .height = 20 },
        },
        .{ .rows = 2, .history_count = 2, .scroll_row = 2, .is_alternate_screen = false },
        1,
        images[0..],
        placements[0..],
    );
    defer prepared.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), prepared.placements.len);
    try std.testing.expectEqual(@as(i32, 0), prepared.placements[0].dest_x_px);
    try std.testing.expectEqual(@as(i32, 0), prepared.placements[0].dest_y_px);
    try std.testing.expectEqual(@as(u32, 40), prepared.placements[0].dest_width_px);
    try std.testing.expectEqual(@as(u32, 30), prepared.placements[0].dest_height_px);
    try std.testing.expectEqual(@as(u32, 10), prepared.placements[0].src_x_px);
    try std.testing.expectEqual(@as(u32, 15), prepared.placements[0].src_y_px);
    try std.testing.expectEqual(@as(u32, 80), prepared.placements[0].src_width_px);
    try std.testing.expectEqual(@as(u32, 30), prepared.placements[0].src_height_px);
}

test "graphics viewport rejects fully off-screen placement" {
    const images = [_]abi.FfiVtGraphicsDecodedImage{.{
        .image_id = 3,
        .image_ref_id = 33,
        .format = 24,
        .width = 16,
        .height = 16,
        .payload_len = 0,
        .image_number = 0,
    }};
    var placement = testPlacement();
    placement.image_id = 3;
    placement.anchor = .{ .kind = 3, .value = 0 };
    placement.source_width = 16;
    placement.source_height = 16;
    placement.dest_right_cell_px = 16;
    placement.dest_bottom_cell_px = 16;
    const placements = [_]abi.FfiVtGraphicsPlacement{placement};

    var prepared = try prepareGraphics(
        std.testing.allocator,
        .{
            .render_px = .{ .width = 40, .height = 40 },
            .grid_px = .{ .width = 40, .height = 40 },
            .cell_px = .{ .width = 20, .height = 20 },
        },
        .{ .rows = 2, .history_count = 1, .scroll_row = 0, .is_alternate_screen = false },
        1,
        images[0..],
        placements[0..],
    );
    defer prepared.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 0), prepared.images.len);
    try std.testing.expectEqual(@as(usize, 0), prepared.placements.len);
}

test "graphics viewport classifies kitty z bands and stable ordering" {
    const images = [_]abi.FfiVtGraphicsDecodedImage{
        .{ .image_id = 9, .image_ref_id = 90, .format = 24, .width = 16, .height = 16, .payload_len = 0, .image_number = 0 },
        .{ .image_id = 4, .image_ref_id = 40, .format = 24, .width = 16, .height = 16, .payload_len = 0, .image_number = 0 },
    };
    var placement0 = testPlacement();
    placement0.image_id = 9;
    placement0.z_index = 1;
    placement0.anchor = .{ .kind = 1, .value = 0 };
    placement0.source_width = 16;
    placement0.source_height = 16;
    placement0.dest_right_cell_px = 16;
    placement0.dest_bottom_cell_px = 16;
    var placement1 = placement0;
    placement1.z_index = std.math.minInt(i32) / 2 - 1;
    var placement2 = placement0;
    placement2.image_id = 4;
    placement2.z_index = -1;
    const placement3 = placement2;
    const placements = [_]abi.FfiVtGraphicsPlacement{ placement0, placement1, placement2, placement3 };

    var prepared = try prepareGraphics(
        std.testing.allocator,
        .{
            .render_px = .{ .width = 32, .height = 32 },
            .grid_px = .{ .width = 32, .height = 32 },
            .cell_px = .{ .width = 16, .height = 16 },
        },
        .{ .rows = 2, .history_count = 0, .scroll_row = 0, .is_alternate_screen = false },
        1,
        images[0..],
        placements[0..],
    );
    defer prepared.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u32, 1), prepared.below_bg_count);
    try std.testing.expectEqual(@as(u32, 2), prepared.below_text_count);
    try std.testing.expectEqual(@as(u32, 1), prepared.above_text_count);
    try std.testing.expectEqual(surface.PreparedGraphicsLayer.below_bg, prepared.placements[0].layer);
    try std.testing.expectEqual(surface.PreparedGraphicsLayer.below_text, prepared.placements[1].layer);
    try std.testing.expectEqual(surface.PreparedGraphicsLayer.below_text, prepared.placements[2].layer);
    try std.testing.expectEqual(surface.PreparedGraphicsLayer.above_text, prepared.placements[3].layer);
}

test "graphics viewport sorts same z and image by render order key" {
    const images = [_]abi.FfiVtGraphicsDecodedImage{.{
        .image_id = 7,
        .image_ref_id = 70,
        .format = 24,
        .width = 16,
        .height = 16,
        .payload_len = 0,
        .image_number = 0,
    }};
    var later = testPlacement();
    later.image_id = 7;
    later.render_order_key = 30;
    later.anchor = .{ .kind = 1, .value = 0 };
    later.source_width = 16;
    later.source_height = 16;
    later.dest_right_cell_px = 16;
    later.dest_bottom_cell_px = 16;
    var earlier = later;
    earlier.render_order_key = 20;
    const placements = [_]abi.FfiVtGraphicsPlacement{ later, earlier };

    var prepared = try prepareGraphics(
        std.testing.allocator,
        .{
            .render_px = .{ .width = 32, .height = 32 },
            .grid_px = .{ .width = 32, .height = 32 },
            .cell_px = .{ .width = 16, .height = 16 },
        },
        .{ .rows = 2, .history_count = 0, .scroll_row = 0, .is_alternate_screen = false },
        1,
        images[0..],
        placements[0..],
    );
    defer prepared.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u32, 0), prepared.below_bg_count);
    try std.testing.expectEqual(@as(u32, 0), prepared.below_text_count);
    try std.testing.expectEqual(@as(u32, 2), prepared.above_text_count);
}
