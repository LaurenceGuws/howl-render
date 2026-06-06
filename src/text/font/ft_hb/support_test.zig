const std = @import("std");

const test_font_options = @import("test_font_options");
const contract = @import("../../contract.zig");
const text_session = @import("../../../session/text.zig");
const support = @import("support.zig");

const InjectedTestFontPaths = struct {
    primary_path: []const u8,
    symbol_path: []const u8,
};

fn injectedTestFontPaths() !InjectedTestFontPaths {
    if (test_font_options.primary_path.len == 0) return error.SkipZigTest;
    if (test_font_options.symbol_path.len == 0) return error.SkipZigTest;
    return .{
        .primary_path = test_font_options.primary_path,
        .symbol_path = test_font_options.symbol_path,
    };
}

test "provider loads fallback face for symbol glyph with primary present" {
    const font_paths = try injectedTestFontPaths();
    const io = std.Io.Threaded.global_single_threaded.io();
    const primary_path = try std.Io.Dir.cwd().realPathFileAlloc(io, font_paths.primary_path, std.testing.allocator);
    defer std.testing.allocator.free(primary_path);
    const symbol_path = try std.Io.Dir.cwd().realPathFileAlloc(io, font_paths.symbol_path, std.testing.allocator);
    defer std.testing.allocator.free(symbol_path);

    const owner = text_session.TextSessionOwner.create(std.heap.c_allocator, .{ .surface_px = .{ .width = 1, .height = 1 } }) orelse return error.OutOfMemory;
    defer owner.destroy();

    owner.setOwnedFontPath(try std.heap.c_allocator.dupeZ(u8, primary_path));
    var fallbacks = std.ArrayList([:0]u8).empty;
    fallbacks.append(std.heap.c_allocator, try std.heap.c_allocator.dupeZ(u8, symbol_path)) catch return error.OutOfMemory;
    owner.adoptFallbackFontPaths(&fallbacks);

    const Context = struct {
        session: *text_session.TextSession,
        session_config: text_session.TextSessionConfig,
    };
    var context = Context{ .session = &owner.session, .session_config = owner.config };

    try std.testing.expect(!support.providerHasCodepoint(Context, &context, .{ .value = support.primary_face_id }, 0xebfc));
    try std.testing.expect(support.providerHasCodepoint(Context, &context, .{ .value = 2 }, 0xebfc));
    try std.testing.expect(support.providerGlyphId(&context, .{ .value = 2 }, 0xebfc) != 0);
    try std.testing.expect(!support.providerHasCodepoint(Context, &context, .{ .value = support.primary_face_id }, 0xf117));
    try std.testing.expect(support.providerHasCodepoint(Context, &context, .{ .value = 2 }, 0xf117));
    try std.testing.expect(support.providerGlyphId(&context, .{ .value = 2 }, 0xf117) != 0);
}

test "ft hb state configures explicit retained cache and input capacities" {
    var state = support.State.init(std.testing.allocator);
    defer state.deinit();

    try state.configureFtHbCapacity(.{
        .face_text_cache_entries = 4,
        .shape_run_cache_entries = 2,
        .glyph_cell_cache_entries = 3,
        .max_shape_input_codepoints = 6,
        .max_glyphs_per_run = 5,
    });
    try std.testing.expectEqual(@as(u32, 4), state.face_text_cache.capacity);
    try std.testing.expectEqual(@as(u32, 2), state.shape_run_cache.capacity);
    try std.testing.expectEqual(@as(u32, 5), state.shape_run_cache.max_glyphs_per_run);
    try std.testing.expectEqual(@as(u32, 3), state.glyph_cell_cache.capacity);
    try std.testing.expectEqual(@as(u32, 6), state.max_shape_input_codepoints);
    try std.testing.expectEqual(@as(usize, 6), state.shape_input_codepoints.len);
    try std.testing.expectEqual(@as(usize, 6), state.shape_input_cluster_map.len);
}

test "shape run input assembly reuses retained bounded buffers" {
    var state = support.State.init(std.testing.allocator);
    defer state.deinit();
    try state.configureFtHbCapacity(.{
        .face_text_cache_entries = 2,
        .shape_run_cache_entries = 2,
        .glyph_cell_cache_entries = 2,
        .max_shape_input_codepoints = 2,
        .max_glyphs_per_run = 2,
    });

    const text_cache_view = contract.LineTextCache{ .texts = &.{
        .{ .id = .{ .value = 0 }, .first_cp = 'a', .codepoints = &.{'a'} },
        .{ .id = .{ .value = 1 }, .first_cp = 'b', .codepoints = &.{'b'} },
    } };
    const clusters = [_]contract.CellCluster{
        .{ .text_id = .{ .value = 0 }, .first_cell = 0, .cell_span = 1, .first_cp = 'a', .style = .regular, .presentation = .any },
        .{ .text_id = .{ .value = 1 }, .first_cell = 1, .cell_span = 1, .first_cp = 'b', .style = .regular, .presentation = .any },
    };

    const first = try support.testing.gatherShapeRunInput(&state, text_cache_view, &clusters, 0, 2);
    try std.testing.expectEqual(state.shape_input_codepoints.ptr, first.codepoints.ptr);
    try std.testing.expectEqual(state.shape_input_cluster_map.ptr, first.cluster_map.ptr);

    const second = try support.testing.gatherShapeRunInput(&state, text_cache_view, &clusters, 0, 2);
    try std.testing.expectEqual(first.codepoints.ptr, second.codepoints.ptr);
    try std.testing.expectEqual(first.cluster_map.ptr, second.cluster_map.ptr);

    const overflow_text_cache = contract.LineTextCache{ .texts = &.{.{ .id = .{ .value = 0 }, .first_cp = 'x', .codepoints = &.{ 'x', 0x0332, 0x0308 } }} };
    const overflow_clusters = [_]contract.CellCluster{.{ .text_id = .{ .value = 0 }, .first_cell = 0, .cell_span = 1, .first_cp = 'x', .style = .regular, .presentation = .any }};
    try std.testing.expectError(error.ShapeRunInputOverflow, support.testing.gatherShapeRunInput(&state, overflow_text_cache, &overflow_clusters, 0, 1));
}
