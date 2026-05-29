const std = @import("std");
const c = @import("ffi.zig").c;
const handle_owner = @import("handle.zig");
const source_cell = @import("source/cell.zig");
const source_slot = @import("source/slot.zig");
const source_vt = @import("source/vt.zig");
const tokens = @import("surface/tokens.zig");

comptime {
    assertVtCellLayout();
}

pub fn reservePublishSlot(
    value: c.HowlRenderSurfaceTextHandle,
    cols: u16,
    rows: u16,
    out: ?*c.HowlRenderPublishSlot,
) callconv(.c) c_int {
    const slot_out = out orelse return c.HOWL_RENDER_CALL_INVALID_ARGUMENT;
    slot_out.* = std.mem.zeroes(c.HowlRenderPublishSlot);
    const owner = handle_owner.surfaceTextOwner(value) orelse return c.HOWL_RENDER_CALL_MISSING_HANDLE;
    if (cols == 0 or rows == 0) return c.HOWL_RENDER_CALL_INVALID_ARGUMENT;
    const slot = owner.reservePublishSlot(cols, rows) catch return c.HOWL_RENDER_CALL_FAILED;
    slot_out.* = publishSlotOut(slot);
    return c.HOWL_RENDER_CALL_OK;
}

pub fn commitPublishSlot(
    value: c.HowlRenderSurfaceTextHandle,
    commit: c.HowlRenderPublishSlotCommit,
) callconv(.c) c.HowlRenderVtPublishResult {
    const owner = handle_owner.surfaceTextOwner(value) orelse return .{ .status = c.HOWL_RENDER_CALL_MISSING_HANDLE, .published = 0, .queued = 0, .damage_kind = @intFromEnum(tokens.DamageKind.none), .snapshot_seq = 0, .geometry_epoch = 0 };
    const cursor = cursorIn(commit.cursor) orelse {
        owner.cancelPublishSlot();
        return .{ .status = c.HOWL_RENDER_CALL_INVALID_ARGUMENT, .published = 0, .queued = 0, .damage_kind = @intFromEnum(tokens.DamageKind.none), .snapshot_seq = 0, .geometry_epoch = 0 };
    };
    const result = owner.commitPublishSlot(.{
        .history_count = commit.history_count,
        .scroll_row = commit.scroll_row,
        .snapshot_seq = commit.snapshot_seq,
        .is_alternate_screen = commit.is_alternate_screen != 0,
        .cursor = cursor,
        .colors = colorStateIn(commit.colors),
        .selection = selectionIn(commit.selection),
    }) catch {
        owner.cancelPublishSlot();
        return .{ .status = c.HOWL_RENDER_CALL_INVALID_ARGUMENT, .published = 0, .queued = 0, .damage_kind = @intFromEnum(tokens.DamageKind.none), .snapshot_seq = 0, .geometry_epoch = 0 };
    };
    return vtPublishResultOut(result);
}

pub fn rejectPublishSlot(
    value: c.HowlRenderSurfaceTextHandle,
    snapshot_seq: u64,
) callconv(.c) c.HowlRenderVtPublishResult {
    const owner = handle_owner.surfaceTextOwner(value) orelse return .{ .status = c.HOWL_RENDER_CALL_MISSING_HANDLE, .published = 0, .queued = 0, .damage_kind = @intFromEnum(tokens.DamageKind.none), .snapshot_seq = 0, .geometry_epoch = 0 };
    if (snapshot_seq == 0) return .{ .status = c.HOWL_RENDER_CALL_INVALID_ARGUMENT, .published = 0, .queued = 0, .damage_kind = @intFromEnum(tokens.DamageKind.none), .snapshot_seq = 0, .geometry_epoch = 0 };
    return vtPublishResultWithStatus(owner.rejectPublishSlot(snapshot_seq), c.HOWL_RENDER_CALL_FAILED);
}

pub fn cancelPublishSlot(value: c.HowlRenderSurfaceTextHandle) callconv(.c) void {
    const owner = handle_owner.surfaceTextOwner(value) orelse return;
    owner.cancelPublishSlot();
}

pub fn publishSlotOut(value: source_slot.PublicationSlot) c.HowlRenderPublishSlot {
    return .{
        .cells = sourceCellsOut(value.cells),
        .dirty_rows = .{ .ptr = if (value.dirty_rows.len == 0) null else value.dirty_rows.ptr, .len = value.dirty_rows.len },
        .dirty_cols_start = .{ .ptr = if (value.dirty_cols_start.len == 0) null else value.dirty_cols_start.ptr, .len = value.dirty_cols_start.len },
        .dirty_cols_end = .{ .ptr = if (value.dirty_cols_end.len == 0) null else value.dirty_cols_end.ptr, .len = value.dirty_cols_end.len },
    };
}

pub fn sourceCellsOut(cells: []source_vt.SourceCell) c.HowlRenderVtCellWriteSpan {
    return .{ .ptr = if (cells.len == 0) null else @ptrCast(cells.ptr), .len = cells.len };
}

pub fn vtPublishResultOut(value: source_vt.VtPublishResult) c.HowlRenderVtPublishResult {
    return vtPublishResultWithStatus(value, c.HOWL_RENDER_CALL_OK);
}

pub fn vtPublishResultWithStatus(
    value: source_vt.VtPublishResult,
    status: c_int,
) c.HowlRenderVtPublishResult {
    return .{
        .status = status,
        .published = @intFromBool(value.published),
        .queued = @intFromBool(value.queued),
        .damage_kind = @intFromEnum(value.damage_kind),
        .snapshot_seq = value.snapshot_seq,
        .geometry_epoch = value.geometry_epoch,
    };
}

pub fn colorStateIn(value: c.HowlVtRenderColorState) source_vt.SourceColors {
    var palette: [256]source_vt.SourceRgb = undefined;
    for (value.palette, 0..) |color, index| {
        palette[index] = .{ .r = color.r, .g = color.g, .b = color.b };
    }
    return .{
        .foreground = .{ .r = value.foreground.r, .g = value.foreground.g, .b = value.foreground.b },
        .background = .{ .r = value.background.r, .g = value.background.g, .b = value.background.b },
        .cursor = .{ .r = value.cursor.r, .g = value.cursor.g, .b = value.cursor.b },
        .palette = palette,
    };
}

pub fn selectionIn(value: c.HowlVtSelection) source_vt.SourceSelection {
    return .{
        .active = value.active,
        .selecting = value.selecting,
        .start = .{ .row = value.start.row, .col = value.start.col },
        .end = .{ .row = value.end.row, .col = value.end.col },
    };
}

pub fn cursorIn(value: c.HowlVtCursor) ?source_cell.CursorInfo {
    const shape = switch (value.shape) {
        0 => source_cell.CursorShape.block,
        1 => .underline,
        2 => .beam,
        3 => .hollow_block,
        else => return null,
    };
    return .{
        .row = value.row,
        .col = value.col,
        .visible = value.visible != 0,
        .shape = shape,
        .blink = value.blink != 0,
    };
}

pub fn assertVtCellLayout() void {
    comptime {
        std.debug.assert(@sizeOf(source_vt.SourceCell) == @sizeOf(c.HowlVtSurfaceCell));
        std.debug.assert(@alignOf(source_vt.SourceCell) == @alignOf(c.HowlVtSurfaceCell));
        assertOffset(source_vt.SourceCell, c.HowlVtSurfaceCell, "codepoint");
        assertOffset(source_vt.SourceCell, c.HowlVtSurfaceCell, "combining_len");
        assertOffset(source_vt.SourceCell, c.HowlVtSurfaceCell, "combining");
        assertOffset(source_vt.SourceCell, c.HowlVtSurfaceCell, "flags");
        assertOffset(source_vt.SourceCell, c.HowlVtSurfaceCell, "fg_color");
        assertOffset(source_vt.SourceCell, c.HowlVtSurfaceCell, "bg_color");
        assertOffset(source_vt.SourceCell, c.HowlVtSurfaceCell, "underline_color");
        assertOffset(source_vt.SourceCell, c.HowlVtSurfaceCell, "underline_style");
        assertOffset(source_vt.SourceCell, c.HowlVtSurfaceCell, "attrs");
        assertOffset(source_vt.SourceCell, c.HowlVtSurfaceCell, "link_id");

        std.debug.assert(@sizeOf(source_vt.SourceColor) == @sizeOf(c.HowlVtColor));
        std.debug.assert(@alignOf(source_vt.SourceColor) == @alignOf(c.HowlVtColor));
        assertOffset(source_vt.SourceColor, c.HowlVtColor, "kind");
        assertOffset(source_vt.SourceColor, c.HowlVtColor, "value");

        std.debug.assert(@sizeOf(source_vt.SourceCellFlags) == @sizeOf(c.HowlVtSurfaceCellFlags));
        std.debug.assert(@alignOf(source_vt.SourceCellFlags) == @alignOf(c.HowlVtSurfaceCellFlags));
        assertOffset(source_vt.SourceCellFlags, c.HowlVtSurfaceCellFlags, "continuation");

        std.debug.assert(@sizeOf(source_vt.SourceCellAttrs) == @sizeOf(c.HowlVtSurfaceCellAttrs));
        std.debug.assert(@alignOf(source_vt.SourceCellAttrs) == @alignOf(c.HowlVtSurfaceCellAttrs));
        assertOffset(source_vt.SourceCellAttrs, c.HowlVtSurfaceCellAttrs, "bold");
        assertOffset(source_vt.SourceCellAttrs, c.HowlVtSurfaceCellAttrs, "dim");
        assertOffset(source_vt.SourceCellAttrs, c.HowlVtSurfaceCellAttrs, "italic");
        assertOffset(source_vt.SourceCellAttrs, c.HowlVtSurfaceCellAttrs, "underline");
        assertOffset(source_vt.SourceCellAttrs, c.HowlVtSurfaceCellAttrs, "underline_color_set");
        assertOffset(source_vt.SourceCellAttrs, c.HowlVtSurfaceCellAttrs, "blink");
        assertOffset(source_vt.SourceCellAttrs, c.HowlVtSurfaceCellAttrs, "inverse");
        assertOffset(source_vt.SourceCellAttrs, c.HowlVtSurfaceCellAttrs, "invisible");
        assertOffset(source_vt.SourceCellAttrs, c.HowlVtSurfaceCellAttrs, "strikethrough");
        assertOffset(source_vt.SourceCellAttrs, c.HowlVtSurfaceCellAttrs, "selected");
    }
}

pub fn assertOffset(comptime Source: type, comptime Abi: type, comptime field: []const u8) void {
    std.debug.assert(@offsetOf(Source, field) == @offsetOf(Abi, field));
}
