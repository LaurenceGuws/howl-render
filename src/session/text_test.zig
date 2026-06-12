const std = @import("std");
const text_session = @import("text.zig");
const source_vt = @import("../tv_surface/vt.zig");
const prepared_handle = @import("../prepared/handle.zig");
const sprite_resource_store = @import("../prepared/sprite_resource_store.zig");
const support = @import("../ffi/test_support.zig");
const tokens = @import("../geometry/tokens.zig");

test "ft hb retained capacities separate cache slots from run scratch" {
    var session = text_session.TextSession.init(std.testing.allocator);
    defer session.deinit();

    const capacity = text_session.testing.ftHbCapacity(&session, .{
        .surface_px = .{ .width = 80, .height = 32 },
        .font_size_px = 16,
    });
    try std.testing.expectEqual(@as(u32, 20), capacity.face_text_cache_entries);
    try std.testing.expectEqual(@as(u32, 20), capacity.glyph_cell_cache_entries);
    try std.testing.expectEqual(@as(u32, 20), capacity.shape_run_cache_entries);
    try std.testing.expectEqual(@as(u32, 160), capacity.max_shape_input_codepoints);
    try std.testing.expectEqual(@as(u32, 512), capacity.max_glyphs_per_run);
}

test "surface text owner keeps source and submitted owners separate" {
    const owner = text_session.TextSessionOwner.create(
        std.testing.allocator,
        .{ .surface_px = .{ .width = 8, .height = 16 } },
    ) orelse return error.OutOfMemory;
    defer owner.destroy();

    try std.testing.expect(owner.source_slot.reserved == null);
    try std.testing.expect(owner.prepare_requests.pending == null);
    try std.testing.expect(owner.submitted.submitted_token == null);
}

test "surface text owner invalidation clears sprite resource store" {
    const owner = text_session.TextSessionOwner.create(
        std.testing.allocator,
        .{ .surface_px = .{ .width = 8, .height = 16 } },
    ) orelse return error.OutOfMemory;
    defer owner.destroy();

    const sprite = sprite_resource_store.PreparedSprite{
        .key = .{ .value = 1 },
        .pixels = &[_]u8{255},
        .width_px = 1,
        .height_px = 1,
        .stride_bytes = 1,
        .color_mode = .alpha,
        .visual_bounds = .{},
    };
    _ = try owner.render_surface_sprite_resources.atlasRegionFor(sprite, 1, 1, &[_]u8{255});
    try std.testing.expectEqual(@as(u32, 1), owner.render_surface_sprite_resources.atlas_count);
    const next_value = owner.render_surface_sprite_resources.value_next;

    owner.invalidateTextState();
    try std.testing.expectEqual(@as(u32, 0), owner.render_surface_sprite_resources.atlas_count);
    try std.testing.expectEqual(@as(u32, 0), owner.render_surface_sprite_resources.count);
    try std.testing.expectEqual(next_value, owner.render_surface_sprite_resources.value_next);
}

test "surface text owner rejects prepared work after resize publication" {
    const owner = text_session.TextSessionOwner.create(
        std.testing.allocator,
        .{ .surface_px = .{ .width = 8, .height = 16 } },
    ) orelse return error.OutOfMemory;
    defer owner.destroy();

    const initial_geometry = try owner.syncGeometry(.{
        .render_px = .{ .width = 8, .height = 16 },
        .grid_px = .{ .width = 8, .height = 16 },
        .cell_px = .{ .width = 8, .height = 16 },
    });
    try std.testing.expect(initial_geometry.changed);
    try std.testing.expectEqual(@as(u64, 1), initial_geometry.geometry_epoch);

    var first_cells = [_]source_vt.SourceCell{testCell('A')};
    var first_dirty_rows = [_]u8{1};
    var first_dirty_cols_start = [_]u16{0};
    var first_dirty_cols_end = [_]u16{0};
    const first_publish = try owner.publishVtSurface(support.validVtSurfaceResult(1, 1, 1, &first_cells, &first_dirty_rows, &first_dirty_cols_start, &first_dirty_cols_end));
    try std.testing.expect(first_publish.published);
    try std.testing.expect(first_publish.queued);
    try std.testing.expectEqual(@as(u64, 1), first_publish.geometry_epoch);

    const old_request = owner.prepare() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u64, 1), old_request.token.snapshot_seq);
    try std.testing.expectEqual(@as(u64, 1), old_request.token.geometry_epoch);
    const old_rdr_sfc_handle = try owner.prepareHandle(old_request.token);
    defer old_rdr_sfc_handle.release();
    try std.testing.expect(owner.workState().submit_pending);

    const resized_geometry = try owner.syncGeometry(.{
        .render_px = .{ .width = 16, .height = 16 },
        .grid_px = .{ .width = 8, .height = 16 },
        .cell_px = .{ .width = 8, .height = 16 },
    });
    try std.testing.expect(resized_geometry.changed);
    try std.testing.expect(resized_geometry.geometry_epoch > old_request.token.geometry_epoch);

    var resized_cells = [_]source_vt.SourceCell{testCell('A')};
    var resized_dirty_rows = [_]u8{1};
    var resized_dirty_cols_start = [_]u16{0};
    var resized_dirty_cols_end = [_]u16{0};
    const resized_publish = try owner.publishVtSurface(support.validVtSurfaceResult(2, 1, 1, &resized_cells, &resized_dirty_rows, &resized_dirty_cols_start, &resized_dirty_cols_end));
    try std.testing.expect(resized_publish.published);
    try std.testing.expect(resized_publish.queued);
    try std.testing.expectEqual(tokens.DamageKind.full, resized_publish.damage_kind);
    try std.testing.expectEqual(resized_geometry.geometry_epoch, resized_publish.geometry_epoch);

    const decision = owner.takeSubmitHandle();
    switch (decision) {
        .stale => {},
        else => return error.TestUnexpectedResult,
    }
    try std.testing.expect(!owner.workState().submit_pending);

    const resized_request = owner.prepare() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u64, 2), resized_request.token.snapshot_seq);
    try std.testing.expectEqual(resized_geometry.geometry_epoch, resized_request.token.geometry_epoch);
    try std.testing.expectEqual(tokens.DamageKind.full, resized_request.token.damage_kind);
    try std.testing.expectEqual(@as(u64, 0), resized_request.token.damage_base_seq);
    try std.testing.expect(!resized_request.allow_retained_reuse);
}

fn testCell(codepoint: u21) source_vt.SourceCell {
    var cell = std.mem.zeroes(source_vt.SourceCell);
    cell.codepoint = codepoint;
    return cell;
}

test "surface text owner rejects partial rdr_sfc handle with wrong submitted base" {
    const owner = text_session.TextSessionOwner.create(
        std.testing.allocator,
        .{ .surface_px = .{ .width = 8, .height = 16 } },
    ) orelse return error.OutOfMemory;
    defer owner.destroy();

    owner.submitted.acceptSubmitted(.{
        .token = .{ .snapshot_seq = 9, .dirty_epoch = 9, .geometry_epoch = 1, .damage_base_seq = 0, .damage_kind = .full },
    });
    var prepared_value = support.preparedSurface(.{ .width_px = 8, .height_px = 16, .full_redraw = false });
    prepared_value.request.token = .{ .snapshot_seq = 10, .dirty_epoch = 10, .geometry_epoch = 1, .damage_base_seq = 1, .damage_kind = .partial };
    const rdr_sfc_handle = try prepared_handle.PreparedHandle.create(owner, &prepared_value);
    defer rdr_sfc_handle.release();
    owner.rdr_sfc_handle = @ptrCast(rdr_sfc_handle);

    switch (owner.takeSubmitHandle()) {
        .needs_full_prepare => {},
        else => return error.TestUnexpectedResult,
    }
    try std.testing.expect(owner.rdr_sfc_handle == null);
}

test "ft hb retained capacities cap shape run cache slots" {
    var session = text_session.TextSession.init(std.testing.allocator);
    defer session.deinit();

    const capacity = text_session.testing.ftHbCapacity(&session, .{
        .surface_px = .{ .width = 4096, .height = 4096 },
        .font_size_px = 16,
    });
    try std.testing.expectEqual(@as(u32, 64), capacity.shape_run_cache_entries);
    try std.testing.expectEqual(@as(u32, 4096), capacity.face_text_cache_entries);
    try std.testing.expectEqual(@as(u32, 4096), capacity.glyph_cell_cache_entries);
}

test "surface text retains translated cell scratch across prepares" {
    var session = text_session.TextSession.init(std.testing.allocator);
    defer session.deinit();

    try text_session.testing.ensureCellInputScratchCapacity(&session, 4);
    const first_ptr = @intFromPtr(session.cell_input_scratch.ptr);
    try text_session.testing.ensureCellInputScratchCapacity(&session, 4);
    try std.testing.expectEqual(first_ptr, @intFromPtr(session.cell_input_scratch.ptr));
    try std.testing.expectEqual(@as(usize, 4), session.cell_input_scratch.len);

    try text_session.testing.ensureCellInputScratchCapacity(&session, 8);
    try std.testing.expectEqual(@as(usize, 8), session.cell_input_scratch.len);
}
