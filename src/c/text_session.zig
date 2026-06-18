const std = @import("std");
const c = @import("howl_render_c");
const handle_owner = @import("text_session_handle.zig");
const surface_geometry = @import("surface_geometry.zig");
const render_session = @import("../render_session.zig");
const text_support = @import("../text/ft_hb/support.zig");

pub fn init(config: c.HowlRenderTextConfig) callconv(.c) c.HowlRenderTextSessionHandle {
    if (config.surface_px.width == 0 or config.surface_px.height == 0) return null;
    if (config.font_size_px == 0) return null;
    const owner = render_session.TextSessionOwner.create(std.heap.c_allocator, .{
        .surface_px = surface_geometry.pixelIn(config.surface_px),
        .font_size_px = config.font_size_px,
    }) orelse return null;
    return @ptrCast(owner);
}

pub fn deinit(value: c.HowlRenderTextSessionHandle) callconv(.c) void {
    const owner = handle_owner.textSessionOwner(value) orelse return;
    owner.destroy();
}

pub fn isValidFont(value: c.HowlRenderTextSessionHandle) callconv(.c) c_int {
    const owner = handle_owner.textSessionOwner(value) orelse return c.HOWL_RENDER_CALL_MISSING_HANDLE;
    return if (owner.isValidFont()) c.HOWL_RENDER_CALL_OK else c.HOWL_RENDER_CALL_FAILED;
}

pub fn setFontSize(value: c.HowlRenderTextSessionHandle, font_size_px: u16) callconv(.c) c_int {
    const owner = handle_owner.textSessionOwner(value) orelse return c.HOWL_RENDER_CALL_MISSING_HANDLE;
    if (font_size_px == 0) return c.HOWL_RENDER_CALL_INVALID_ARGUMENT;
    owner.setFontSizePx(font_size_px);
    return c.HOWL_RENDER_CALL_OK;
}

pub fn setFontPath(value: c.HowlRenderTextSessionHandle, ptr: ?[*]const u8, len: usize) callconv(.c) c_int {
    const owner = handle_owner.textSessionOwner(value) orelse return c.HOWL_RENDER_CALL_MISSING_HANDLE;
    if (len > 0 and ptr == null) return c.HOWL_RENDER_CALL_INVALID_ARGUMENT;
    owner.setFontPathBytes(if (len == 0 or ptr == null) null else ptr.?[0..len]) catch {
        return c.HOWL_RENDER_CALL_FAILED;
    };
    return c.HOWL_RENDER_CALL_OK;
}

pub fn setFallbackFontPaths(value: c.HowlRenderTextSessionHandle, ptrs: ?[*]const ?[*]const u8, count: usize) callconv(.c) c_int {
    const owner = handle_owner.textSessionOwner(value) orelse return c.HOWL_RENDER_CALL_MISSING_HANDLE;
    if (count > text_support.max_fallback_fonts) return c.HOWL_RENDER_CALL_INVALID_ARGUMENT;
    const path_count = text_support.fallbackFontCount(@intCast(count)) orelse unreachable;
    if (path_count > 0 and ptrs == null) return c.HOWL_RENDER_CALL_INVALID_ARGUMENT;
    const raw_paths = if (path_count == 0)
        &.{}
    else
        ptrs.?[0..@intCast(text_support.fallbackFontLen(path_count))];
    owner.setFallbackFontPathPtrs(raw_paths) catch |err| {
        return switch (err) {
            error.InvalidArgument => c.HOWL_RENDER_CALL_INVALID_ARGUMENT,
            error.OutOfMemory => c.HOWL_RENDER_CALL_FAILED,
        };
    };
    return c.HOWL_RENDER_CALL_OK;
}

pub fn setCursorCadence(value: c.HowlRenderTextSessionHandle, cadence: ?*const c.HowlRenderHostCursorCadence) callconv(.c) c_int {
    const owner = handle_owner.textSessionOwner(value) orelse return c.HOWL_RENDER_CALL_MISSING_HANDLE;
    const host_cadence = cadence orelse return c.HOWL_RENDER_CALL_INVALID_ARGUMENT;
    if (host_cadence.effective_shape > 4) return c.HOWL_RENDER_CALL_INVALID_ARGUMENT;
    if (!colorValid(host_cadence.cursor_color)) return c.HOWL_RENDER_CALL_INVALID_ARGUMENT;
    if (!colorValid(host_cadence.cursor_text_color)) return c.HOWL_RENDER_CALL_INVALID_ARGUMENT;
    if (!colorValid(host_cadence.cursor_trail_color)) return c.HOWL_RENDER_CALL_INVALID_ARGUMENT;
    if (!(host_cadence.cursor_beam_thickness > 0) or !(host_cadence.cursor_underline_thickness > 0)) return c.HOWL_RENDER_CALL_INVALID_ARGUMENT;
    if (!(host_cadence.cursor_trail_decay_fast_s > 0) or !(host_cadence.cursor_trail_decay_slow_s > 0)) return c.HOWL_RENDER_CALL_INVALID_ARGUMENT;
    if (host_cadence.cursor_trail_count > c.HOWL_RENDER_CURSOR_TRAIL_RECTS_MAX) return c.HOWL_RENDER_CALL_INVALID_ARGUMENT;
    var trail_rects = [_]render_session.TextSessionOwner.HostCursorCadenceRect{std.mem.zeroes(render_session.TextSessionOwner.HostCursorCadenceRect)} ** c.HOWL_RENDER_CURSOR_TRAIL_RECTS_MAX;
    for (0..host_cadence.cursor_trail_count) |index| {
        trail_rects[index] = .{
            .row = host_cadence.cursor_trail_rects[index].row,
            .col = host_cadence.cursor_trail_rects[index].col,
            .rows = host_cadence.cursor_trail_rects[index].rows,
            .cols = host_cadence.cursor_trail_rects[index].cols,
            .opacity = host_cadence.cursor_trail_rects[index].opacity,
            .reserved0 = host_cadence.cursor_trail_rects[index].reserved0,
            .reserved1 = host_cadence.cursor_trail_rects[index].reserved1,
            .color = host_cadence.cursor_trail_rects[index].color,
        };
    }
    owner.setHostCursorCadence(.{
        .focused = host_cadence.focused != 0,
        .cursor_opacity = host_cadence.cursor_opacity,
        .text_blink_opacity = host_cadence.text_blink_opacity,
        .effective_shape = host_cadence.effective_shape,
        .cursor_color = host_cadence.cursor_color,
        .cursor_text_color = host_cadence.cursor_text_color,
        .cursor_trail_color = host_cadence.cursor_trail_color,
        .cursor_beam_thickness = host_cadence.cursor_beam_thickness,
        .cursor_underline_thickness = host_cadence.cursor_underline_thickness,
        .cursor_trail_decay_fast_s = host_cadence.cursor_trail_decay_fast_s,
        .cursor_trail_decay_slow_s = host_cadence.cursor_trail_decay_slow_s,
        .cursor_trail_count = host_cadence.cursor_trail_count,
        .cursor_trail_rects = trail_rects,
        .now_ns = host_cadence.now_ns,
    });
    return c.HOWL_RENDER_CALL_OK;
}

fn colorValid(color: c.HowlVtColor) bool {
    return switch (color.kind) {
        0 => true,
        1 => color.value <= std.math.maxInt(u8),
        2 => color.value <= std.math.maxInt(u24),
        else => false,
    };
}

test "text session cadence accepts hollow host shape and rejects out-of-range shape" {
    const handle = init(.{ .surface_px = .{ .width = 64, .height = 32 }, .font_size_px = 12 });
    defer deinit(handle);
    try std.testing.expect(handle != null);

    var cadence = std.mem.zeroes(c.HowlRenderHostCursorCadence);
    cadence.focused = 1;
    cadence.cursor_opacity = 255;
    cadence.text_blink_opacity = 255;
    cadence.effective_shape = 4;
    cadence.cursor_beam_thickness = 1.5;
    cadence.cursor_underline_thickness = 2.0;
    cadence.cursor_trail_decay_fast_s = 0.1;
    cadence.cursor_trail_decay_slow_s = 0.4;

    try std.testing.expectEqual(c.HOWL_RENDER_CALL_OK, setCursorCadence(handle, &cadence));

    cadence.effective_shape = 5;
    try std.testing.expectEqual(c.HOWL_RENDER_CALL_INVALID_ARGUMENT, setCursorCadence(handle, &cadence));
}
