const std = @import("std");
const c = @import("ffi.zig").c;
const handle_owner = @import("handle.zig");
const surface_geometry = @import("surface_geometry.zig");
const text_session = @import("session/text.zig");
const text_support = @import("text/font/ft_hb/support.zig");

pub fn init(config: c.HowlRenderTextConfig) callconv(.c) c.HowlRenderTextSessionHandle {
    if (config.surface_px.width == 0 or config.surface_px.height == 0) return null;
    if (config.font_size_px == 0) return null;
    const owner = text_session.TextSessionOwner.create(std.heap.c_allocator, .{
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

pub fn setFontPath(
    value: c.HowlRenderTextSessionHandle,
    ptr: ?[*]const u8,
    len: usize,
) callconv(.c) c_int {
    const owner = handle_owner.textSessionOwner(value) orelse return c.HOWL_RENDER_CALL_MISSING_HANDLE;
    if (len > 0 and ptr == null) return c.HOWL_RENDER_CALL_INVALID_ARGUMENT;
    owner.setFontPathBytes(if (len == 0 or ptr == null) null else ptr.?[0..len]) catch {
        return c.HOWL_RENDER_CALL_FAILED;
    };
    return c.HOWL_RENDER_CALL_OK;
}

pub fn setFallbackFontPaths(
    value: c.HowlRenderTextSessionHandle,
    ptrs: ?[*]const ?[*]const u8,
    count: usize,
) callconv(.c) c_int {
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

pub fn setCursorBlinkVisible(value: c.HowlRenderTextSessionHandle, visible: u8) callconv(.c) c_int {
    const owner = handle_owner.textSessionOwner(value) orelse return c.HOWL_RENDER_CALL_MISSING_HANDLE;
    _ = owner.setCursorBlinkVisible(visible != 0);
    return c.HOWL_RENDER_CALL_OK;
}
