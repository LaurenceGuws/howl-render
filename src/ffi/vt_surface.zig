const std = @import("std");
const c = @import("../ffi.zig").c;
const handle_owner = @import("handle.zig");
const source_cell = @import("../source/cell.zig");
const source_slot = @import("../source/slot.zig");
const source_vt = @import("../source/vt.zig");
const tokens = @import("../render/tokens.zig");

comptime {
    assertVtCellLayout();
}

pub fn reserveVtSurfaceSlot(value: c.HowlRenderTextSessionHandle, cols: u16, rows: u16, out: ?*c.HowlRenderVtSurfaceSlot) callconv(.c) c_int {
    const slot_out = out orelse return c.HOWL_RENDER_CALL_INVALID_ARGUMENT;
    slot_out.* = std.mem.zeroes(c.HowlRenderVtSurfaceSlot);
    const owner = handle_owner.textSessionOwner(value) orelse return c.HOWL_RENDER_CALL_MISSING_HANDLE;
    if (cols == 0 or rows == 0) return c.HOWL_RENDER_CALL_INVALID_ARGUMENT;
    const slot = owner.reserveVtSurfaceSlot(cols, rows) catch return c.HOWL_RENDER_CALL_FAILED;
    slot_out.* = vtSurfaceSlotOut(slot);
    return c.HOWL_RENDER_CALL_OK;
}

pub fn commitVtSurface(value: c.HowlRenderTextSessionHandle, commit: c.HowlRenderVtSurfaceCommit) callconv(.c) c.HowlRenderVtSurfacePublishResult {
    const owner = handle_owner.textSessionOwner(value) orelse return vtSurfacePublishFailure(c.HOWL_RENDER_CALL_MISSING_HANDLE);
    const cursor = cursorIn(commit.cursor) orelse {
        owner.cancelVtSurface();
        return vtSurfacePublishFailure(c.HOWL_RENDER_CALL_INVALID_ARGUMENT);
    };
    const result = owner.commitVtSurface(.{
        .history_count = commit.history_count,
        .scroll_row = commit.scroll_row,
        .snapshot_seq = commit.snapshot_seq,
        .is_alternate_screen = commit.is_alternate_screen != 0,
        .cursor = cursor,
        .colors = colorStateIn(commit.colors),
        .selection = selectionIn(commit.selection),
    }) catch {
        owner.cancelVtSurface();
        return vtSurfacePublishFailure(c.HOWL_RENDER_CALL_INVALID_ARGUMENT);
    };
    return vtSurfacePublishResultOut(result);
}

pub fn rejectVtSurface(value: c.HowlRenderTextSessionHandle, snapshot_seq: u64) callconv(.c) c.HowlRenderVtSurfacePublishResult {
    const owner = handle_owner.textSessionOwner(value) orelse return vtSurfacePublishFailure(c.HOWL_RENDER_CALL_MISSING_HANDLE);
    if (snapshot_seq == 0) return vtSurfacePublishFailure(c.HOWL_RENDER_CALL_INVALID_ARGUMENT);
    return vtSurfacePublishResultWithStatus(owner.rejectVtSurface(snapshot_seq), c.HOWL_RENDER_CALL_FAILED);
}

fn vtSurfacePublishFailure(status: c_int) c.HowlRenderVtSurfacePublishResult {
    return .{
        .status = status,
        .published = 0,
        .queued = 0,
        .damage_kind = @intFromEnum(tokens.DamageKind.none),
        .snapshot_seq = 0,
        .geometry_epoch = 0,
    };
}

pub fn cancelVtSurface(value: c.HowlRenderTextSessionHandle) callconv(.c) void {
    const owner = handle_owner.textSessionOwner(value) orelse return;
    owner.cancelVtSurface();
}

pub fn vtSurfaceSlotOut(value: source_slot.VtSurfaceSlot) c.HowlRenderVtSurfaceSlot {
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

pub fn vtSurfacePublishResultOut(value: source_vt.VtSurfacePublishResult) c.HowlRenderVtSurfacePublishResult {
    return vtSurfacePublishResultWithStatus(value, c.HOWL_RENDER_CALL_OK);
}

pub fn vtSurfacePublishResultWithStatus(value: source_vt.VtSurfacePublishResult, status: c_int) c.HowlRenderVtSurfacePublishResult {
    return .{
        .status = status,
        .published = @intFromBool(value.published),
        .queued = @intFromBool(value.queued),
        .damage_kind = @intFromEnum(value.damage_kind),
        .snapshot_seq = value.snapshot_seq,
        .geometry_epoch = value.geometry_epoch,
    };
}

pub fn colorStateIn(value: c.HowlRenderSourceColors) source_vt.SourceColors {
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

pub fn selectionIn(value: c.HowlRenderSourceSelection) source_vt.SourceSelection {
    return .{
        .active = value.active,
        .selecting = value.selecting,
        .start = .{ .row = value.start.row, .col = value.start.col },
        .end = .{ .row = value.end.row, .col = value.end.col },
    };
}

pub fn cursorIn(value: c.HowlRenderSourceCursor) ?source_cell.CursorInfo {
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
        assertLayout(source_vt.SourceRgb, c.HowlRenderSourceRgb);
        assertOffset(source_vt.SourceRgb, c.HowlRenderSourceRgb, "r");
        assertOffset(source_vt.SourceRgb, c.HowlRenderSourceRgb, "g");
        assertOffset(source_vt.SourceRgb, c.HowlRenderSourceRgb, "b");

        assertLayout(source_vt.SourceColor, c.HowlRenderSourceColor);
        assertOffset(source_vt.SourceColor, c.HowlRenderSourceColor, "kind");
        assertOffset(source_vt.SourceColor, c.HowlRenderSourceColor, "value");

        assertLayout(source_vt.SourceCellFlags, c.HowlRenderSourceCellFlags);
        assertOffset(source_vt.SourceCellFlags, c.HowlRenderSourceCellFlags, "continuation");

        assertLayout(source_vt.SourceCellAttrs, c.HowlRenderSourceCellAttrs);
        assertOffset(source_vt.SourceCellAttrs, c.HowlRenderSourceCellAttrs, "bold");
        assertOffset(source_vt.SourceCellAttrs, c.HowlRenderSourceCellAttrs, "dim");
        assertOffset(source_vt.SourceCellAttrs, c.HowlRenderSourceCellAttrs, "italic");
        assertOffset(source_vt.SourceCellAttrs, c.HowlRenderSourceCellAttrs, "underline");
        assertOffset(source_vt.SourceCellAttrs, c.HowlRenderSourceCellAttrs, "underline_color_set");
        assertOffset(source_vt.SourceCellAttrs, c.HowlRenderSourceCellAttrs, "blink");
        assertOffset(source_vt.SourceCellAttrs, c.HowlRenderSourceCellAttrs, "inverse");
        assertOffset(source_vt.SourceCellAttrs, c.HowlRenderSourceCellAttrs, "invisible");
        assertOffset(source_vt.SourceCellAttrs, c.HowlRenderSourceCellAttrs, "strikethrough");
        assertOffset(source_vt.SourceCellAttrs, c.HowlRenderSourceCellAttrs, "selected");

        assertLayout(source_vt.SourceCell, c.HowlRenderSourceCell);
        assertOffset(source_vt.SourceCell, c.HowlRenderSourceCell, "codepoint");
        assertOffset(source_vt.SourceCell, c.HowlRenderSourceCell, "combining_len");
        assertOffset(source_vt.SourceCell, c.HowlRenderSourceCell, "combining");
        assertOffset(source_vt.SourceCell, c.HowlRenderSourceCell, "flags");
        assertOffset(source_vt.SourceCell, c.HowlRenderSourceCell, "fg_color");
        assertOffset(source_vt.SourceCell, c.HowlRenderSourceCell, "bg_color");
        assertOffset(source_vt.SourceCell, c.HowlRenderSourceCell, "underline_color");
        assertOffset(source_vt.SourceCell, c.HowlRenderSourceCell, "underline_style");
        assertOffset(source_vt.SourceCell, c.HowlRenderSourceCell, "attrs");
        assertOffset(source_vt.SourceCell, c.HowlRenderSourceCell, "link_id");

        assertLayout(source_vt.SourceColors, c.HowlRenderSourceColors);
        assertOffset(source_vt.SourceColors, c.HowlRenderSourceColors, "foreground");
        assertOffset(source_vt.SourceColors, c.HowlRenderSourceColors, "background");
        assertOffset(source_vt.SourceColors, c.HowlRenderSourceColors, "cursor");
        assertOffset(source_vt.SourceColors, c.HowlRenderSourceColors, "palette");

        assertLayout(source_vt.SourceSelectionPoint, c.HowlRenderSourceSelectionPos);
        assertOffset(source_vt.SourceSelectionPoint, c.HowlRenderSourceSelectionPos, "row");
        assertOffset(source_vt.SourceSelectionPoint, c.HowlRenderSourceSelectionPos, "col");

        assertLayout(source_vt.SourceSelection, c.HowlRenderSourceSelection);
        assertOffset(source_vt.SourceSelection, c.HowlRenderSourceSelection, "active");
        assertOffset(source_vt.SourceSelection, c.HowlRenderSourceSelection, "selecting");
        assertOffset(source_vt.SourceSelection, c.HowlRenderSourceSelection, "start");
        assertOffset(source_vt.SourceSelection, c.HowlRenderSourceSelection, "end");

        assertLayout(source_vt.SourceCursor, c.HowlRenderSourceCursor);
        assertOffset(source_vt.SourceCursor, c.HowlRenderSourceCursor, "row");
        assertOffset(source_vt.SourceCursor, c.HowlRenderSourceCursor, "col");
        assertOffset(source_vt.SourceCursor, c.HowlRenderSourceCursor, "visible");
        assertOffset(source_vt.SourceCursor, c.HowlRenderSourceCursor, "shape");
        assertOffset(source_vt.SourceCursor, c.HowlRenderSourceCursor, "blink");
    }
}

pub fn assertLayout(comptime Source: type, comptime Abi: type) void {
    std.debug.assert(@sizeOf(Source) == @sizeOf(Abi));
    std.debug.assert(@alignOf(Source) == @alignOf(Abi));
}

pub fn assertOffset(comptime Source: type, comptime Abi: type, comptime field: []const u8) void {
    std.debug.assert(@offsetOf(Source, field) == @offsetOf(Abi, field));
}
