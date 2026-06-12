const std = @import("std");

const c = @import("howl_render_c");
const render_surface_realizer = @import("render_surface_realizer.zig");

const DamageItem = c.HowlRenderSurfaceDamageItem;
const ResourceId = c.HowlRenderResourceId;
const Upload = c.HowlRenderResourceUpload;
const Create = c.HowlRenderResourceCreate;
const GlyphRef = c.HowlRenderGlyphRef;
const Command = c.HowlRenderSurfaceCommand;
const Retire = c.HowlRenderResourceRetire;
const Surface = c.HowlRenderSurface;

const ResourceStore = render_surface_realizer.ResourceStore;
const Error = render_surface_realizer.Error;
const realize = render_surface_realizer.realize;
const realizeRetained = render_surface_realizer.realizeRetained;

const glyph_atlas_width_px = 1024;
const glyph_atlas_height_px = 1024;

const Rgba = struct { r: u8, g: u8, b: u8, a: u8 };

test "render surface constants match documented kind values" {
    try std.testing.expectEqual(@as(u8, 1), c.HOWL_RENDER_SURFACE_DAMAGE_RECT);
    try std.testing.expectEqual(@as(u8, 2), c.HOWL_RENDER_SURFACE_DAMAGE_FULL);
    try std.testing.expectEqual(@as(u32, 1), c.HOWL_RENDER_RESOURCE_GLYPH_ATLAS_ALPHA);
    try std.testing.expectEqual(@as(u32, 2), c.HOWL_RENDER_RESOURCE_GLYPH_ATLAS_COLOR);
    try std.testing.expectEqual(@as(u32, 3), c.HOWL_RENDER_RESOURCE_SPRITE_ALPHA);
    try std.testing.expectEqual(@as(u32, 4), c.HOWL_RENDER_RESOURCE_SPRITE_COLOR);
    try std.testing.expectEqual(@as(u32, 1), c.HOWL_RENDER_UPLOAD_ALPHA8);
    try std.testing.expectEqual(@as(u32, 2), c.HOWL_RENDER_UPLOAD_RGBA8);
    try std.testing.expectEqual(@as(u8, 1), c.HOWL_RENDER_SURFACE_COMMAND_CLEAR_RECT);
    try std.testing.expectEqual(@as(u8, 2), c.HOWL_RENDER_SURFACE_COMMAND_FILL_RECT);
    try std.testing.expectEqual(@as(u8, 3), c.HOWL_RENDER_SURFACE_COMMAND_DRAW_GLYPH_RUN);
    try std.testing.expectEqual(@as(u8, 4), c.HOWL_RENDER_SURFACE_COMMAND_DRAW_SPRITE);
}

test "render-surface surface realizer clears and fills in command order" {
    var commands = [_]Command{
        fillCommand(c.HOWL_RENDER_SURFACE_COMMAND_FILL_RECT, makeRect(0, 0, 2, 1), 0xff0000ff),
        fillCommand(c.HOWL_RENDER_SURFACE_COMMAND_FILL_RECT, makeRect(1, 0, 1, 1), 0x0000ffff),
    };
    var pixels: [8]u8 = undefined;
    var surface = testSurface(2, 1);
    surface.commands = commandSpan(&commands);
    try realize(&surface, &pixels, null);
    try expectPixel(&pixels, 0, .{ .r = 255, .g = 0, .b = 0, .a = 255 });
    try expectPixel(&pixels, 1, .{ .r = 0, .g = 0, .b = 255, .a = 255 });
}

test "render-surface surface realizer preserves retained base outside commands" {
    var commands = [_]Command{
        fillCommand(c.HOWL_RENDER_SURFACE_COMMAND_FILL_RECT, makeRect(0, 0, 1, 1), 0x010203ff),
    };
    var base = [_]u8{ 9, 8, 7, 6, 5, 4, 3, 2 };
    var pixels: [8]u8 = undefined;
    var surface = testSurface(2, 1);
    surface.commands = commandSpan(&commands);
    try realize(&surface, &pixels, &base);
    try expectPixel(&pixels, 0, .{ .r = 1, .g = 2, .b = 3, .a = 255 });
    try expectPixel(&pixels, 1, .{ .r = 5, .g = 4, .b = 3, .a = 2 });
}

test "render-surface surface realizer draws alpha sprite bytes" {
    const resource = spriteAlphaResource(1, 1);
    var creates = [_]Create{createResource(resource, 2, 1, c.HOWL_RENDER_UPLOAD_ALPHA8)};
    var bytes = [_]u8{ 255, 128 };
    var uploads = [_]Upload{uploadResource(resource, makeRect(0, 0, 2, 1), &bytes, 2)};
    var commands = [_]Command{spriteCommand(resource, makeRect(0, 0, 2, 1), 0xff000080)};
    var pixels: [8]u8 = undefined;
    var surface = testSurface(2, 1);
    surface.creates = createSpan(&creates);
    surface.uploads = uploadSpan(&uploads, bytes.len);
    surface.commands = commandSpan(&commands);
    try realize(&surface, &pixels, null);
    try expectPixel(&pixels, 0, .{ .r = 128, .g = 0, .b = 0, .a = 255 });
    try expectPixel(&pixels, 1, .{ .r = 64, .g = 0, .b = 0, .a = 255 });
}

test "render-surface surface realizer draws color sprite bytes" {
    const resource = spriteColorResource(2, 1);
    var creates = [_]Create{createResource(resource, 1, 1, c.HOWL_RENDER_UPLOAD_RGBA8)};
    var bytes = [_]u8{ 0, 255, 0, 128 };
    var uploads = [_]Upload{uploadResource(resource, makeRect(0, 0, 1, 1), &bytes, 4)};
    var commands = [_]Command{spriteCommand(resource, makeRect(0, 0, 1, 1), 0)};
    var pixels: [4]u8 = undefined;
    var surface = testSurface(1, 1);
    surface.creates = createSpan(&creates);
    surface.uploads = uploadSpan(&uploads, bytes.len);
    surface.commands = commandSpan(&commands);
    try realize(&surface, &pixels, null);
    try expectPixel(&pixels, 0, .{ .r = 0, .g = 128, .b = 0, .a = 255 });
}

test "render-surface surface realizer draws alpha glyph atlas run" {
    const resource = glyphAtlasAlphaResource(1, 1);
    var creates = [_]Create{createGlyphAtlasAlpha(resource)};
    var bytes = [_]u8{ 255, 128, 64, 0 };
    var uploads = [_]Upload{uploadResource(resource, makeRect(2, 3, 2, 2), &bytes, 2)};
    var glyphs = [_]GlyphRef{glyphRef(resource, makeRect(2, 3, 2, 2), 0, 0, 0xff000080)};
    var commands = [_]Command{glyphCommand(&glyphs)};
    var pixels: [16]u8 = undefined;
    var surface = testSurface(2, 2);
    surface.creates = createSpan(&creates);
    surface.uploads = uploadSpan(&uploads, bytes.len);
    surface.commands = commandSpan(&commands);
    try realize(&surface, &pixels, null);
    try expectPixel(&pixels, 0, .{ .r = 128, .g = 0, .b = 0, .a = 255 });
    try expectPixel(&pixels, 1, .{ .r = 64, .g = 0, .b = 0, .a = 255 });
    try expectPixel(&pixels, 2, .{ .r = 32, .g = 0, .b = 0, .a = 255 });
    try expectPixel(&pixels, 3, .{ .r = 0, .g = 0, .b = 0, .a = 255 });
}

test "render-surface surface realizer clips alpha glyph atlas run" {
    const resource = glyphAtlasAlphaResource(2, 1);
    var creates = [_]Create{createGlyphAtlasAlpha(resource)};
    var bytes = [_]u8{ 10, 255, 20, 128 };
    var uploads = [_]Upload{uploadResource(resource, makeRect(0, 0, 2, 2), &bytes, 2)};
    var glyphs = [_]GlyphRef{glyphRef(resource, makeRect(0, 0, 2, 2), -1, 0, 0x00ff00ff)};
    var commands = [_]Command{glyphCommand(&glyphs)};
    var pixels: [8]u8 = undefined;
    var surface = testSurface(1, 2);
    surface.creates = createSpan(&creates);
    surface.uploads = uploadSpan(&uploads, bytes.len);
    surface.commands = commandSpan(&commands);
    try realize(&surface, &pixels, null);
    try expectPixel(&pixels, 0, .{ .r = 0, .g = 255, .b = 0, .a = 255 });
    try expectPixel(&pixels, 1, .{ .r = 0, .g = 128, .b = 0, .a = 255 });
}

test "render-surface surface realizer draws split alpha glyph runs in source order" {
    const resource = glyphAtlasAlphaResource(3, 1);
    var creates = [_]Create{createGlyphAtlasAlpha(resource)};
    var bytes = [_]u8{255};
    var uploads = [_]Upload{uploadResource(resource, makeRect(0, 0, 1, 1), &bytes, 1)};
    var red_glyphs = [_]GlyphRef{glyphRef(resource, makeRect(0, 0, 1, 1), 0, 0, 0xff000080)};
    var blue_glyphs = [_]GlyphRef{glyphRef(resource, makeRect(0, 0, 1, 1), 0, 0, 0x0000ff80)};
    var commands = [_]Command{ glyphCommand(&red_glyphs), glyphCommand(&blue_glyphs) };
    var pixels: [4]u8 = undefined;
    var surface = testSurface(1, 1);
    surface.creates = createSpan(&creates);
    surface.uploads = uploadSpan(&uploads, bytes.len);
    surface.commands = commandSpan(&commands);
    try realize(&surface, &pixels, null);
    try expectPixel(&pixels, 0, .{ .r = 63, .g = 0, .b = 128, .a = 255 });
}

test "render-surface surface rejects unknown command kind" {
    var commands = [_]Command{fillCommand(255, makeRect(0, 0, 0, 0), 0)};
    try expectRejectWithCommands(&commands, error.UnknownCommandKind);
}

test "render-surface surface rejects unknown damage kind" {
    var damage = [_]DamageItem{.{ .kind = 255, .rect = makeRect(0, 0, 1, 1) }};
    var surface = testSurface(1, 1);
    surface.damage = damageSpan(&damage, c.HOWL_RENDER_SURFACE_DAMAGE_ITEMS_MAX);
    try expectReject(&surface, error.UnknownDamageKind);
}

test "render-surface surface rejects unknown resource kind" {
    const resource = ResourceId{ .value = 1, .generation = 1, .kind = 255 };
    var creates = [_]Create{createResource(resource, 1, 1, c.HOWL_RENDER_UPLOAD_RGBA8)};
    try expectRejectWithCreates(&creates, error.UnknownResourceKind);
}

test "render-surface surface rejects unknown upload format" {
    const resource = spriteAlphaResource(1, 1);
    var bytes = [_]u8{255};
    var creates = [_]Create{createResource(resource, 1, 1, c.HOWL_RENDER_UPLOAD_ALPHA8)};
    var uploads = [_]Upload{
        uploadResourceWithFormat(resource, makeRect(0, 0, 1, 1), &bytes, 1, 255),
    };
    try expectRejectWithCreatesUploads(&creates, &uploads, bytes.len, error.UnknownUploadFormat);
}

test "render-surface surface rejects zero command width" {
    var commands = [_]Command{
        fillCommand(c.HOWL_RENDER_SURFACE_COMMAND_CLEAR_RECT, makeRect(0, 0, 0, 1), 0),
    };
    try expectRejectWithCommands(&commands, error.InvalidDamage);
}

test "render-surface surface rejects zero command height" {
    var commands = [_]Command{
        fillCommand(c.HOWL_RENDER_SURFACE_COMMAND_FILL_RECT, makeRect(0, 0, 1, 0), 0),
    };
    try expectRejectWithCommands(&commands, error.InvalidDamage);
}

test "render-surface surface rejects damage span overflow" {
    var surface = testSurface(1, 1);
    surface.damage.count = c.HOWL_RENDER_SURFACE_DAMAGE_ITEMS_MAX + 1;
    try expectReject(&surface, error.InvalidSpan);
}

test "render-surface surface rejects upload span overflow" {
    var surface = testSurface(1, 1);
    surface.uploads.count = c.HOWL_RENDER_SURFACE_UPLOADS_MAX + 1;
    try expectReject(&surface, error.InvalidSpan);
}

test "render-surface surface rejects command span overflow" {
    var surface = testSurface(1, 1);
    surface.commands.count = c.HOWL_RENDER_SURFACE_COMMANDS_MAX + 1;
    try expectReject(&surface, error.InvalidSpan);
}

test "render-surface surface rejects glyph span overflow" {
    var commands = [_]Command{
        fillCommand(c.HOWL_RENDER_SURFACE_COMMAND_FILL_RECT, makeRect(0, 0, 1, 1), 0),
    };
    commands[0].glyphs.count = c.HOWL_RENDER_SURFACE_GLYPHS_PER_RUN_MAX + 1;
    try expectRejectWithCommands(&commands, error.InvalidSpan);
}

test "render-surface surface rejects alpha upload to color sprite" {
    const resource = spriteColorResource(1, 1);
    var bytes = [_]u8{255};
    var creates = [_]Create{createResource(resource, 1, 1, c.HOWL_RENDER_UPLOAD_RGBA8)};
    var uploads = [_]Upload{
        uploadResourceWithFormat(
            resource,
            makeRect(0, 0, 1, 1),
            &bytes,
            1,
            c.HOWL_RENDER_UPLOAD_ALPHA8,
        ),
    };
    try expectRejectWithCreatesUploads(&creates, &uploads, bytes.len, error.InvalidUpload);
}

test "render-surface surface rejects rgba upload to alpha sprite" {
    const resource = spriteAlphaResource(1, 1);
    var bytes = [_]u8{ 1, 2, 3, 4 };
    var creates = [_]Create{createResource(resource, 1, 1, c.HOWL_RENDER_UPLOAD_ALPHA8)};
    var uploads = [_]Upload{
        uploadResourceWithFormat(
            resource,
            makeRect(0, 0, 1, 1),
            &bytes,
            4,
            c.HOWL_RENDER_UPLOAD_RGBA8,
        ),
    };
    try expectRejectWithCreatesUploads(&creates, &uploads, bytes.len, error.InvalidUpload);
}

test "render-surface surface rejects upload before create" {
    const resource = spriteAlphaResource(77, 1);
    var bytes = [_]u8{255};
    var uploads = [_]Upload{uploadResource(resource, makeRect(0, 0, 1, 1), &bytes, 1)};
    var surface = testSurface(1, 1);
    surface.uploads = uploadSpan(&uploads, bytes.len);
    try expectReject(&surface, error.MissingResource);
}

test "render-surface surface rejects missing sprite command resource" {
    const resource = spriteAlphaResource(78, 1);
    var commands = [_]Command{spriteCommand(resource, makeRect(0, 0, 1, 1), 0xffffffff)};
    try expectRejectWithCommands(&commands, error.MissingResource);
}

test "render-surface surface rejects wrong generation sprite use" {
    const created = spriteAlphaResource(79, 1);
    const used = spriteAlphaResource(79, 2);
    var creates = [_]Create{createResource(created, 1, 1, c.HOWL_RENDER_UPLOAD_ALPHA8)};
    var commands = [_]Command{spriteCommand(used, makeRect(0, 0, 1, 1), 0xffffffff)};
    try expectRejectWithCreatesCommands(&creates, &commands, error.WrongResourceGeneration);
}

test "render-surface surface rejects retired sprite use" {
    const resource = spriteAlphaResource(80, 1);
    var creates = [_]Create{createResource(resource, 1, 1, c.HOWL_RENDER_UPLOAD_ALPHA8)};
    var retires = [_]Retire{.{ .resource = resource }};
    var commands = [_]Command{spriteCommand(resource, makeRect(0, 0, 1, 1), 0xffffffff)};
    var surface = testSurface(1, 1);
    surface.creates = createSpan(&creates);
    surface.retires = retireSpan(&retires);
    surface.commands = commandSpan(&commands);
    try expectReject(&surface, error.RetiredResource);
}

test "render-surface surface rejects color sprite command color" {
    const resource = spriteColorResource(1, 1);
    var creates = [_]Create{createResource(resource, 1, 1, c.HOWL_RENDER_UPLOAD_RGBA8)};
    var commands = [_]Command{spriteCommand(resource, makeRect(0, 0, 1, 1), 0x01020304)};
    try expectRejectWithCreatesCommands(&creates, &commands, error.InvalidResource);
}

test "render-surface surface rejects sprite command glyph span" {
    const resource = spriteAlphaResource(1, 1);
    var glyphs = [_]GlyphRef{.{}};
    var commands = [_]Command{spriteCommand(resource, makeRect(0, 0, 1, 1), 0xffffffff)};
    commands[0].glyphs = .{
        .ptr = &glyphs,
        .count = 1,
        .count_max = c.HOWL_RENDER_SURFACE_GLYPHS_PER_RUN_MAX,
    };
    try expectRejectWithCommands(&commands, error.InvalidDamage);
}

test "render-surface surface rejects fill command resource" {
    var commands = [_]Command{
        fillCommand(c.HOWL_RENDER_SURFACE_COMMAND_FILL_RECT, makeRect(0, 0, 1, 1), 0),
    };
    commands[0].resource.value = 1;
    try expectRejectWithCommands(&commands, error.InvalidResource);
}

test "render-surface surface realizer rejects alpha atlas wrong size" {
    const resource = glyphAtlasAlphaResource(1, 1);
    var creates = [_]Create{createResource(resource, 1023, 1024, c.HOWL_RENDER_UPLOAD_ALPHA8)};
    try expectRejectWithCreates(&creates, error.InvalidResource);
}

test "render-surface surface realizer rejects color atlas create" {
    const resource = glyphAtlasColorResource(1, 1);
    var creates = [_]Create{createResource(resource, 1024, 1024, c.HOWL_RENDER_UPLOAD_RGBA8)};
    try expectRejectWithCreates(&creates, error.UnsupportedGlyphAtlas);
}

test "render-surface surface realizer rejects color atlas upload" {
    const resource = glyphAtlasColorResource(1, 1);
    var bytes = [_]u8{ 1, 2, 3, 4 };
    var uploads = [_]Upload{
        uploadResourceWithFormat(
            resource,
            makeRect(0, 0, 1, 1),
            &bytes,
            4,
            c.HOWL_RENDER_UPLOAD_RGBA8,
        ),
    };
    var surface = testSurface(1, 1);
    surface.uploads = uploadSpan(&uploads, bytes.len);
    try expectReject(&surface, error.UnsupportedGlyphAtlas);
}

test "render-surface surface realizer rejects rgba upload to alpha atlas" {
    const resource = glyphAtlasAlphaResource(2, 1);
    var bytes = [_]u8{ 1, 2, 3, 4 };
    var creates = [_]Create{createGlyphAtlasAlpha(resource)};
    var uploads = [_]Upload{
        uploadResourceWithFormat(
            resource,
            makeRect(0, 0, 1, 1),
            &bytes,
            4,
            c.HOWL_RENDER_UPLOAD_RGBA8,
        ),
    };
    try expectRejectWithCreatesUploads(&creates, &uploads, bytes.len, error.InvalidUpload);
}

test "render-surface surface realizer rejects alpha upload stride too small" {
    const resource = glyphAtlasAlphaResource(3, 1);
    var bytes = [_]u8{ 1, 2, 3, 4 };
    var creates = [_]Create{createGlyphAtlasAlpha(resource)};
    var uploads = [_]Upload{uploadResource(resource, makeRect(0, 0, 2, 1), &bytes, 1)};
    try expectRejectWithCreatesUploads(&creates, &uploads, bytes.len, error.InvalidUpload);
}

test "render-surface surface realizer rejects alpha upload byte count too small" {
    const resource = glyphAtlasAlphaResource(4, 1);
    var bytes = [_]u8{1};
    var creates = [_]Create{createGlyphAtlasAlpha(resource)};
    var uploads = [_]Upload{uploadResource(resource, makeRect(0, 0, 2, 1), &bytes, 2)};
    try expectRejectWithCreatesUploads(&creates, &uploads, bytes.len, error.InvalidUpload);
}

test "render-surface surface realizer rejects alpha atlas upload outside page" {
    const resource = glyphAtlasAlphaResource(5, 1);
    var bytes = [_]u8{ 1, 2 };
    var creates = [_]Create{createGlyphAtlasAlpha(resource)};
    var uploads = [_]Upload{uploadResource(resource, makeRect(1023, 0, 2, 1), &bytes, 2)};
    try expectRejectWithCreatesUploads(&creates, &uploads, bytes.len, error.InvalidUpload);
}

test "render-surface surface realizer rejects missing glyph atlas resource" {
    const resource = glyphAtlasAlphaResource(81, 1);
    var glyphs = [_]GlyphRef{glyphRef(resource, makeRect(0, 0, 1, 1), 0, 0, 0xffffffff)};
    var commands = [_]Command{glyphCommand(&glyphs)};
    try expectRejectWithCommands(&commands, error.MissingResource);
}

test "render-surface surface realizer rejects wrong generation glyph atlas use" {
    const created = glyphAtlasAlphaResource(82, 1);
    const used = glyphAtlasAlphaResource(82, 2);
    var creates = [_]Create{createGlyphAtlasAlpha(created)};
    var glyphs = [_]GlyphRef{glyphRef(used, makeRect(0, 0, 1, 1), 0, 0, 0xffffffff)};
    var commands = [_]Command{glyphCommand(&glyphs)};
    try expectRejectWithCreatesCommands(&creates, &commands, error.WrongResourceGeneration);
}

test "render-surface surface realizer rejects retired glyph atlas use" {
    const resource = glyphAtlasAlphaResource(83, 1);
    var creates = [_]Create{createGlyphAtlasAlpha(resource)};
    var retires = [_]Retire{.{ .resource = resource }};
    var glyphs = [_]GlyphRef{glyphRef(resource, makeRect(0, 0, 1, 1), 0, 0, 0xffffffff)};
    var commands = [_]Command{glyphCommand(&glyphs)};
    var surface = testSurface(1, 1);
    surface.creates = createSpan(&creates);
    surface.retires = retireSpan(&retires);
    surface.commands = commandSpan(&commands);
    try expectReject(&surface, error.RetiredResource);
}

test "render-surface surface realizer rejects empty glyph run" {
    var commands = [_]Command{glyphCommand(&.{})};
    try expectRejectWithCommands(&commands, error.UnsupportedGlyphRun);
}

test "render-surface surface realizer rejects zero alpha glyph ref" {
    const resource = glyphAtlasAlphaResource(84, 1);
    var creates = [_]Create{createGlyphAtlasAlpha(resource)};
    var bytes = [_]u8{255};
    var uploads = [_]Upload{uploadResource(resource, makeRect(0, 0, 1, 1), &bytes, 1)};
    var glyphs = [_]GlyphRef{glyphRef(resource, makeRect(0, 0, 1, 1), 0, 0, 0xffffff00)};
    var commands = [_]Command{glyphCommand(&glyphs)};
    var surface = testSurface(1, 1);
    surface.creates = createSpan(&creates);
    surface.uploads = uploadSpan(&uploads, bytes.len);
    surface.commands = commandSpan(&commands);
    try expectReject(&surface, error.InvalidDamage);
}

test "render-surface surface realizer rejects glyph rect outside page" {
    const resource = glyphAtlasAlphaResource(85, 1);
    var creates = [_]Create{createGlyphAtlasAlpha(resource)};
    var glyphs = [_]GlyphRef{glyphRef(resource, makeRect(1023, 0, 2, 1), 0, 0, 0xffffffff)};
    var commands = [_]Command{glyphCommand(&glyphs)};
    try expectRejectWithCreatesCommands(&creates, &commands, error.InvalidDamage);
}

test "render-surface surface realizer rejects color glyph run" {
    const resource = glyphAtlasColorResource(86, 1);
    var glyphs = [_]GlyphRef{glyphRef(resource, makeRect(0, 0, 1, 1), 0, 0, 0xffffffff)};
    var commands = [_]Command{glyphCommand(&glyphs)};
    try expectRejectWithCommands(&commands, error.UnsupportedGlyphAtlas);
}

test "render-surface surface realizer rejects glyph destination outside render" {
    const resource = glyphAtlasAlphaResource(87, 1);
    var creates = [_]Create{createGlyphAtlasAlpha(resource)};
    var bytes = [_]u8{255};
    var uploads = [_]Upload{uploadResource(resource, makeRect(0, 0, 1, 1), &bytes, 1)};
    var glyphs = [_]GlyphRef{glyphRef(resource, makeRect(0, 0, 1, 1), 1, 0, 0xffffffff)};
    var commands = [_]Command{glyphCommand(&glyphs)};
    var surface = testSurface(1, 1);
    surface.creates = createSpan(&creates);
    surface.uploads = uploadSpan(&uploads, bytes.len);
    surface.commands = commandSpan(&commands);
    try expectReject(&surface, error.InvalidDamage);
}

test "render-surface surface realizer rejects glyph without upload coverage" {
    const resource = glyphAtlasAlphaResource(88, 1);
    var creates = [_]Create{createGlyphAtlasAlpha(resource)};
    var bytes = [_]u8{255};
    var uploads = [_]Upload{uploadResource(resource, makeRect(0, 0, 1, 1), &bytes, 1)};
    var glyphs = [_]GlyphRef{glyphRef(resource, makeRect(1, 0, 1, 1), 0, 0, 0xffffffff)};
    var commands = [_]Command{glyphCommand(&glyphs)};
    var surface = testSurface(1, 1);
    surface.creates = createSpan(&creates);
    surface.uploads = uploadSpan(&uploads, bytes.len);
    surface.commands = commandSpan(&commands);
    try expectReject(&surface, error.MissingResource);
}

test "render-surface surface realizer rejects glyph run command rect" {
    var commands = [_]Command{glyphCommand(&.{})};
    commands[0].rect.width_px = 1;
    try expectRejectWithCommands(&commands, error.InvalidDamage);
}

test "render-surface surface realizer rejects glyph run command resource" {
    var commands = [_]Command{glyphCommand(&.{})};
    commands[0].resource.value = 1;
    try expectRejectWithCommands(&commands, error.InvalidResource);
}

test "render-surface surface realizer rejects glyph run command color" {
    var commands = [_]Command{glyphCommand(&.{})};
    commands[0].color_rgba = 0xffffffff;
    try expectRejectWithCommands(&commands, error.InvalidDamage);
}

test "render-surface surface rejects duplicate creates" {
    const resource = spriteAlphaResource(81, 1);
    var creates = [_]Create{
        createResource(resource, 1, 1, c.HOWL_RENDER_UPLOAD_ALPHA8),
        createResource(resource, 1, 1, c.HOWL_RENDER_UPLOAD_ALPHA8),
    };
    try expectRejectWithCreates(&creates, error.InvalidResource);
}

test "render-surface surface rejects duplicate retires" {
    const resource = spriteAlphaResource(82, 1);
    var creates = [_]Create{createResource(resource, 1, 1, c.HOWL_RENDER_UPLOAD_ALPHA8)};
    var retires = [_]Retire{ .{ .resource = resource }, .{ .resource = resource } };
    var surface = testSurface(1, 1);
    surface.creates = createSpan(&creates);
    surface.retires = retireSpan(&retires);
    try expectReject(&surface, error.InvalidResource);
}

test "render-surface surface rejects upload to retired resource" {
    const resource = spriteAlphaResource(83, 1);
    var bytes = [_]u8{255};
    var creates = [_]Create{createResource(resource, 1, 1, c.HOWL_RENDER_UPLOAD_ALPHA8)};
    var retires = [_]Retire{.{ .resource = resource }};
    var uploads = [_]Upload{uploadResource(resource, makeRect(0, 0, 1, 1), &bytes, 1)};
    var surface = testSurface(1, 1);
    surface.creates = createSpan(&creates);
    surface.retires = retireSpan(&retires);
    surface.uploads = uploadSpan(&uploads, bytes.len);
    try expectReject(&surface, error.RetiredResource);
}

test "render-surface surface rejects wrong generation uploads" {
    const created = spriteAlphaResource(84, 1);
    const uploaded = spriteAlphaResource(84, 2);
    var bytes = [_]u8{255};
    var creates = [_]Create{createResource(created, 1, 1, c.HOWL_RENDER_UPLOAD_ALPHA8)};
    var uploads = [_]Upload{uploadResource(uploaded, makeRect(0, 0, 1, 1), &bytes, 1)};
    try expectRejectWithCreatesUploads(&creates, &uploads, bytes.len, error.WrongResourceGeneration);
}

test "render-surface surface realizer accepts sprite use before same surface retire" {
    const resource = spriteAlphaResource(89, 1);
    var creates = [_]Create{createResource(resource, 1, 1, c.HOWL_RENDER_UPLOAD_ALPHA8)};
    var bytes = [_]u8{255};
    var uploads = [_]Upload{uploadResource(resource, makeRect(0, 0, 1, 1), &bytes, 1)};
    var commands = [_]Command{spriteCommand(resource, makeRect(0, 0, 1, 1), 0xffffffff)};
    var retires = [_]Retire{.{ .resource = resource, .retire_seq = 1 }};
    var pixels: [4]u8 = undefined;
    var surface = testSurface(1, 1);
    surface.creates = createSpan(&creates);
    surface.uploads = uploadSpan(&uploads, bytes.len);
    surface.commands = commandSpan(&commands);
    surface.retires = retireSpan(&retires);
    try realize(&surface, &pixels, null);
    try expectPixel(&pixels, 0, .{ .r = 255, .g = 255, .b = 255, .a = 255 });
}

test "render-surface surface realizer accepts late sprite create upload use retire" {
    const resource = spriteAlphaResource(90, 1);
    var creates = [_]Create{createResource(resource, 1, 1, c.HOWL_RENDER_UPLOAD_ALPHA8)};
    creates[0].create_seq = 1;
    var bytes = [_]u8{255};
    var uploads = [_]Upload{uploadResource(resource, makeRect(0, 0, 1, 1), &bytes, 1)};
    uploads[0].upload_seq = 1;
    var commands = [_]Command{
        fillCommand(c.HOWL_RENDER_SURFACE_COMMAND_FILL_RECT, makeRect(0, 0, 1, 1), 0x00000000),
        spriteCommand(resource, makeRect(0, 0, 1, 1), 0xffffffff),
    };
    var retires = [_]Retire{.{ .resource = resource, .retire_seq = 2 }};
    var pixels: [4]u8 = undefined;
    var surface = testSurface(1, 1);
    surface.creates = createSpan(&creates);
    surface.uploads = uploadSpan(&uploads, bytes.len);
    surface.commands = commandSpan(&commands);
    surface.retires = retireSpan(&retires);
    try realize(&surface, &pixels, null);
    try expectPixel(&pixels, 0, .{ .r = 255, .g = 255, .b = 255, .a = 255 });
}

test "render-surface surface realizer rejects upload after same surface retire" {
    const resource = spriteAlphaResource(91, 1);
    var creates = [_]Create{createResource(resource, 1, 1, c.HOWL_RENDER_UPLOAD_ALPHA8)};
    var bytes = [_]u8{255};
    var uploads = [_]Upload{uploadResource(resource, makeRect(0, 0, 1, 1), &bytes, 1)};
    uploads[0].upload_seq = 1;
    var commands = [_]Command{fillCommand(c.HOWL_RENDER_SURFACE_COMMAND_FILL_RECT, makeRect(0, 0, 1, 1), 0)};
    var retires = [_]Retire{.{ .resource = resource, .retire_seq = 1 }};
    var surface = testSurface(1, 1);
    surface.creates = createSpan(&creates);
    surface.uploads = uploadSpan(&uploads, bytes.len);
    surface.commands = commandSpan(&commands);
    surface.retires = retireSpan(&retires);
    try expectReject(&surface, error.RetiredResource);
}

test "render-surface surface realizer rejects upload before same surface create" {
    const resource = spriteAlphaResource(92, 1);
    var creates = [_]Create{createResource(resource, 1, 1, c.HOWL_RENDER_UPLOAD_ALPHA8)};
    creates[0].create_seq = 1;
    var bytes = [_]u8{255};
    var uploads = [_]Upload{uploadResource(resource, makeRect(0, 0, 1, 1), &bytes, 1)};
    var commands = [_]Command{fillCommand(c.HOWL_RENDER_SURFACE_COMMAND_FILL_RECT, makeRect(0, 0, 1, 1), 0)};
    var surface = testSurface(1, 1);
    surface.creates = createSpan(&creates);
    surface.uploads = uploadSpan(&uploads, bytes.len);
    surface.commands = commandSpan(&commands);
    try expectReject(&surface, error.InvalidUpload);
}

test "render-surface surface realizer rejects sprite use before same surface create" {
    const resource = spriteAlphaResource(93, 1);
    var creates = [_]Create{createResource(resource, 1, 1, c.HOWL_RENDER_UPLOAD_ALPHA8)};
    creates[0].create_seq = 1;
    var bytes = [_]u8{255};
    var uploads = [_]Upload{uploadResource(resource, makeRect(0, 0, 1, 1), &bytes, 1)};
    uploads[0].upload_seq = 1;
    var commands = [_]Command{spriteCommand(resource, makeRect(0, 0, 1, 1), 0xffffffff)};
    var surface = testSurface(1, 1);
    surface.creates = createSpan(&creates);
    surface.uploads = uploadSpan(&uploads, bytes.len);
    surface.commands = commandSpan(&commands);
    try expectReject(&surface, error.MissingResource);
}

test "render-surface surface realizer rejects sprite use before same surface upload" {
    const resource = spriteAlphaResource(94, 1);
    var creates = [_]Create{createResource(resource, 1, 1, c.HOWL_RENDER_UPLOAD_ALPHA8)};
    var bytes = [_]u8{255};
    var uploads = [_]Upload{uploadResource(resource, makeRect(0, 0, 1, 1), &bytes, 1)};
    uploads[0].upload_seq = 1;
    var commands = [_]Command{spriteCommand(resource, makeRect(0, 0, 1, 1), 0xffffffff)};
    var surface = testSurface(1, 1);
    surface.creates = createSpan(&creates);
    surface.uploads = uploadSpan(&uploads, bytes.len);
    surface.commands = commandSpan(&commands);
    try expectReject(&surface, error.MissingResource);
}

test "render-surface surface realizer rejects sprite command outside visible upload before mutation" {
    const resource = spriteAlphaResource(94, 2);
    var creates = [_]Create{createResource(resource, 2, 1, c.HOWL_RENDER_UPLOAD_ALPHA8)};
    var bytes = [_]u8{255};
    var uploads = [_]Upload{uploadResource(resource, makeRect(0, 0, 1, 1), &bytes, 1)};
    var commands = [_]Command{spriteCommand(resource, makeRect(0, 0, 2, 1), 0xffffffff)};
    var base = [_]u8{ 9, 8, 7, 6, 5, 4, 3, 2 };
    var pixels = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8 };
    const pixels_before = pixels;
    var surface = testSurface(2, 1);
    surface.creates = createSpan(&creates);
    surface.uploads = uploadSpan(&uploads, bytes.len);
    surface.commands = commandSpan(&commands);
    try std.testing.expectError(error.InvalidUpload, realize(&surface, &pixels, &base));
    try std.testing.expectEqualSlices(u8, &pixels_before, &pixels);
}

test "retained render-surface surface realizer rejects invalid surface without store mutation" {
    const accepted = spriteAlphaResource(200, 1);
    var accepted_creates = [_]Create{createResource(accepted, 1, 1, c.HOWL_RENDER_UPLOAD_ALPHA8)};
    var accepted_bytes = [_]u8{255};
    var accepted_uploads = [_]Upload{uploadResource(accepted, makeRect(0, 0, 1, 1), &accepted_bytes, 1)};
    var accepted_commands = [_]Command{spriteCommand(accepted, makeRect(0, 0, 1, 1), 0xffffffff)};
    var accepted_surface = testSurface(1, 1);
    accepted_surface.creates = createSpan(&accepted_creates);
    accepted_surface.uploads = uploadSpan(&accepted_uploads, accepted_bytes.len);
    accepted_surface.commands = commandSpan(&accepted_commands);

    var store = ResourceStore.init();
    var pixels: [4]u8 = undefined;
    try realizeRetained(&accepted_surface, &pixels, null, &store);
    try std.testing.expectEqual(@as(u32, 1), store.count);

    const rejected = spriteAlphaResource(201, 1);
    var rejected_creates = [_]Create{createResource(rejected, 2, 1, c.HOWL_RENDER_UPLOAD_ALPHA8)};
    var rejected_bytes = [_]u8{255};
    var rejected_uploads = [_]Upload{uploadResource(rejected, makeRect(0, 0, 1, 1), &rejected_bytes, 1)};
    var rejected_commands = [_]Command{spriteCommand(rejected, makeRect(0, 0, 2, 1), 0xffffffff)};
    var rejected_surface = testSurface(2, 1);
    rejected_surface.creates = createSpan(&rejected_creates);
    rejected_surface.uploads = uploadSpan(&rejected_uploads, rejected_bytes.len);
    rejected_surface.commands = commandSpan(&rejected_commands);

    var rejected_pixels: [8]u8 = undefined;
    try std.testing.expectError(
        error.InvalidUpload,
        realizeRetained(&rejected_surface, &rejected_pixels, null, &store),
    );
    try std.testing.expectEqual(@as(u32, 1), store.count);

    var later_commands = [_]Command{spriteCommand(rejected, makeRect(0, 0, 1, 1), 0xffffffff)};
    var later_surface = testSurface(1, 1);
    later_surface.commands = commandSpan(&later_commands);
    try std.testing.expectError(
        error.MissingResource,
        realizeRetained(&later_surface, &pixels, null, &store),
    );
}

test "render-surface surface realizer rejects sprite use after same surface retire" {
    const resource = spriteAlphaResource(95, 1);
    var creates = [_]Create{createResource(resource, 1, 1, c.HOWL_RENDER_UPLOAD_ALPHA8)};
    var bytes = [_]u8{255};
    var uploads = [_]Upload{uploadResource(resource, makeRect(0, 0, 1, 1), &bytes, 1)};
    var commands = [_]Command{spriteCommand(resource, makeRect(0, 0, 1, 1), 0xffffffff)};
    var retires = [_]Retire{.{ .resource = resource, .retire_seq = 0 }};
    var surface = testSurface(1, 1);
    surface.creates = createSpan(&creates);
    surface.uploads = uploadSpan(&uploads, bytes.len);
    surface.commands = commandSpan(&commands);
    surface.retires = retireSpan(&retires);
    try expectReject(&surface, error.RetiredResource);
}

test "retained render-surface surface realizer accepts existing sprite use before same surface retire" {
    const resource = spriteAlphaResource(97, 1);
    var creates = [_]Create{createResource(resource, 1, 1, c.HOWL_RENDER_UPLOAD_ALPHA8)};
    var bytes = [_]u8{255};
    var uploads = [_]Upload{uploadResource(resource, makeRect(0, 0, 1, 1), &bytes, 1)};
    var init_surface = testSurface(1, 1);
    init_surface.creates = createSpan(&creates);
    init_surface.uploads = uploadSpan(&uploads, bytes.len);

    var store = ResourceStore.init();
    var pixels: [4]u8 = undefined;
    try realizeRetained(&init_surface, &pixels, null, &store);

    var commands = [_]Command{spriteCommand(resource, makeRect(0, 0, 1, 1), 0xffffffff)};
    var retires = [_]Retire{.{ .resource = resource, .retire_seq = 1 }};
    var retire_surface = testSurface(1, 1);
    retire_surface.commands = commandSpan(&commands);
    retire_surface.retires = retireSpan(&retires);
    try realizeRetained(&retire_surface, &pixels, null, &store);
    try expectPixel(&pixels, 0, .{ .r = 255, .g = 255, .b = 255, .a = 255 });

    var later_surface = testSurface(1, 1);
    later_surface.commands = commandSpan(&commands);
    try std.testing.expectError(
        error.RetiredResource,
        realizeRetained(&later_surface, &pixels, null, &store),
    );
}

test "retained render-surface surface realizer uses old upload before future upload" {
    const resource = spriteAlphaResource(99, 1);
    var creates = [_]Create{createResource(resource, 1, 1, c.HOWL_RENDER_UPLOAD_ALPHA8)};
    var old_bytes = [_]u8{64};
    var init_uploads = [_]Upload{uploadResource(resource, makeRect(0, 0, 1, 1), &old_bytes, 1)};
    var init_surface = testSurface(1, 1);
    init_surface.creates = createSpan(&creates);
    init_surface.uploads = uploadSpan(&init_uploads, old_bytes.len);

    var store = ResourceStore.init();
    var pixels: [4]u8 = undefined;
    try realizeRetained(&init_surface, &pixels, null, &store);

    var new_bytes = [_]u8{255};
    var future_uploads = [_]Upload{uploadResource(resource, makeRect(0, 0, 1, 1), &new_bytes, 1)};
    future_uploads[0].upload_seq = 1;
    var commands = [_]Command{spriteCommand(resource, makeRect(0, 0, 1, 1), 0xffffffff)};
    var surface = testSurface(1, 1);
    surface.uploads = uploadSpan(&future_uploads, new_bytes.len);
    surface.commands = commandSpan(&commands);
    try realizeRetained(&surface, &pixels, null, &store);
    try expectPixel(&pixels, 0, .{ .r = 64, .g = 64, .b = 64, .a = 255 });
}

test "render-surface surface realizer uses latest visible same surface upload" {
    const resource = spriteAlphaResource(100, 1);
    var creates = [_]Create{createResource(resource, 1, 1, c.HOWL_RENDER_UPLOAD_ALPHA8)};
    var old_bytes = [_]u8{64};
    var new_bytes = [_]u8{255};
    var uploads = [_]Upload{
        uploadResource(resource, makeRect(0, 0, 1, 1), &old_bytes, 1),
        uploadResource(resource, makeRect(0, 0, 1, 1), &new_bytes, 1),
    };
    uploads[0].upload_seq = 0;
    uploads[1].upload_seq = 1;
    var commands = [_]Command{
        fillCommand(c.HOWL_RENDER_SURFACE_COMMAND_FILL_RECT, makeRect(0, 0, 1, 1), 0),
        spriteCommand(resource, makeRect(0, 0, 1, 1), 0xffffffff),
    };
    var surface = testSurface(1, 1);
    surface.creates = createSpan(&creates);
    surface.uploads = uploadSpan(&uploads, old_bytes.len + new_bytes.len);
    surface.commands = commandSpan(&commands);
    var pixels: [4]u8 = undefined;

    try realize(&surface, &pixels, null);
    try expectPixel(&pixels, 0, .{ .r = 255, .g = 255, .b = 255, .a = 255 });
}

test "render-surface surface rejects out of order upload sequence" {
    const resource = spriteAlphaResource(101, 1);
    var creates = [_]Create{createResource(resource, 1, 1, c.HOWL_RENDER_UPLOAD_ALPHA8)};
    var first_bytes = [_]u8{64};
    var second_bytes = [_]u8{255};
    var uploads = [_]Upload{
        uploadResource(resource, makeRect(0, 0, 1, 1), &first_bytes, 1),
        uploadResource(resource, makeRect(0, 0, 1, 1), &second_bytes, 1),
    };
    uploads[0].upload_seq = 1;
    uploads[1].upload_seq = 0;
    var surface = testSurface(1, 1);
    surface.creates = createSpan(&creates);
    surface.uploads = uploadSpan(&uploads, first_bytes.len + second_bytes.len);

    try expectReject(&surface, error.InvalidUpload);
}

test "render-surface surface realizer rejects retire before final sprite use" {
    const resource = spriteAlphaResource(96, 1);
    var creates = [_]Create{createResource(resource, 1, 1, c.HOWL_RENDER_UPLOAD_ALPHA8)};
    var bytes = [_]u8{255};
    var uploads = [_]Upload{uploadResource(resource, makeRect(0, 0, 1, 1), &bytes, 1)};
    var commands = [_]Command{
        spriteCommand(resource, makeRect(0, 0, 1, 1), 0xffffffff),
        spriteCommand(resource, makeRect(0, 0, 1, 1), 0xffffffff),
    };
    var retires = [_]Retire{.{ .resource = resource, .retire_seq = 1 }};
    var surface = testSurface(1, 1);
    surface.creates = createSpan(&creates);
    surface.uploads = uploadSpan(&uploads, bytes.len);
    surface.commands = commandSpan(&commands);
    surface.retires = retireSpan(&retires);
    try expectReject(&surface, error.RetiredResource);
}

test "render-surface surface realizer rejects create sequence outside surface" {
    const resource = spriteAlphaResource(98, 1);
    var creates = [_]Create{createResource(resource, 1, 1, c.HOWL_RENDER_UPLOAD_ALPHA8)};
    creates[0].create_seq = 2;
    var commands = [_]Command{fillCommand(c.HOWL_RENDER_SURFACE_COMMAND_FILL_RECT, makeRect(0, 0, 1, 1), 0)};
    var surface = testSurface(1, 1);
    surface.creates = createSpan(&creates);
    surface.commands = commandSpan(&commands);
    try expectReject(&surface, error.InvalidResource);
}

test "render-surface surface realizer rejects upload sequence outside surface" {
    const resource = spriteAlphaResource(99, 1);
    var creates = [_]Create{createResource(resource, 1, 1, c.HOWL_RENDER_UPLOAD_ALPHA8)};
    var bytes = [_]u8{255};
    var uploads = [_]Upload{uploadResource(resource, makeRect(0, 0, 1, 1), &bytes, 1)};
    uploads[0].upload_seq = 2;
    var commands = [_]Command{fillCommand(c.HOWL_RENDER_SURFACE_COMMAND_FILL_RECT, makeRect(0, 0, 1, 1), 0)};
    var surface = testSurface(1, 1);
    surface.creates = createSpan(&creates);
    surface.uploads = uploadSpan(&uploads, bytes.len);
    surface.commands = commandSpan(&commands);
    try expectReject(&surface, error.InvalidUpload);
}

test "render-surface surface realizer rejects retire sequence outside surface" {
    const resource = spriteAlphaResource(100, 1);
    var creates = [_]Create{createResource(resource, 1, 1, c.HOWL_RENDER_UPLOAD_ALPHA8)};
    var commands = [_]Command{fillCommand(c.HOWL_RENDER_SURFACE_COMMAND_FILL_RECT, makeRect(0, 0, 1, 1), 0)};
    var retires = [_]Retire{.{ .resource = resource, .retire_seq = 2 }};
    var surface = testSurface(1, 1);
    surface.creates = createSpan(&creates);
    surface.commands = commandSpan(&commands);
    surface.retires = retireSpan(&retires);
    try expectReject(&surface, error.RetiredResource);
}

test "render-surface surface realizer accepts glyph atlas use before same surface retire" {
    const resource = glyphAtlasAlphaResource(101, 1);
    var creates = [_]Create{createGlyphAtlasAlpha(resource)};
    var bytes = [_]u8{255};
    var uploads = [_]Upload{uploadResource(resource, makeRect(0, 0, 1, 1), &bytes, 1)};
    var glyphs = [_]GlyphRef{glyphRef(resource, makeRect(0, 0, 1, 1), 0, 0, 0xffffffff)};
    var commands = [_]Command{glyphCommand(&glyphs)};
    var retires = [_]Retire{.{ .resource = resource, .retire_seq = 1 }};
    var pixels: [4]u8 = undefined;
    var surface = testSurface(1, 1);
    surface.creates = createSpan(&creates);
    surface.uploads = uploadSpan(&uploads, bytes.len);
    surface.commands = commandSpan(&commands);
    surface.retires = retireSpan(&retires);
    try realize(&surface, &pixels, null);
    try expectPixel(&pixels, 0, .{ .r = 255, .g = 255, .b = 255, .a = 255 });
}

test "render-surface surface realizer rejects glyph atlas use after same surface retire" {
    const resource = glyphAtlasAlphaResource(102, 1);
    var creates = [_]Create{createGlyphAtlasAlpha(resource)};
    var bytes = [_]u8{255};
    var uploads = [_]Upload{uploadResource(resource, makeRect(0, 0, 1, 1), &bytes, 1)};
    var glyphs = [_]GlyphRef{glyphRef(resource, makeRect(0, 0, 1, 1), 0, 0, 0xffffffff)};
    var commands = [_]Command{glyphCommand(&glyphs)};
    var retires = [_]Retire{.{ .resource = resource, .retire_seq = 0 }};
    var surface = testSurface(1, 1);
    surface.creates = createSpan(&creates);
    surface.uploads = uploadSpan(&uploads, bytes.len);
    surface.commands = commandSpan(&commands);
    surface.retires = retireSpan(&retires);
    try expectReject(&surface, error.RetiredResource);
}

test "render-surface surface rejects upload byte total mismatch" {
    const resource = spriteAlphaResource(85, 1);
    var bytes = [_]u8{255};
    var creates = [_]Create{createResource(resource, 1, 1, c.HOWL_RENDER_UPLOAD_ALPHA8)};
    var uploads = [_]Upload{uploadResource(resource, makeRect(0, 0, 1, 1), &bytes, 1)};
    var surface = testSurface(1, 1);
    surface.creates = createSpan(&creates);
    surface.uploads = uploadSpan(&uploads, bytes.len + 1);
    try expectReject(&surface, error.InvalidSpan);
}

test "render-surface surface rejects upload byte total overflow" {
    const resource = spriteAlphaResource(86, 1);
    var bytes = [_]u8{255};
    var creates = [_]Create{createResource(resource, 1, 1, c.HOWL_RENDER_UPLOAD_ALPHA8)};
    var uploads = [_]Upload{uploadResource(resource, makeRect(0, 0, 1, 1), &bytes, 1)};
    uploads[0].bytes_count = c.HOWL_RENDER_SURFACE_UPLOAD_BYTES_MAX + 1;
    var surface = testSurface(1, 1);
    surface.creates = createSpan(&creates);
    surface.uploads = uploadSpan(&uploads, uploads[0].bytes_count);
    try expectReject(&surface, error.InvalidSpan);
}

test "render-surface surface rejects nonzero sprite upload origin" {
    const resource = spriteAlphaResource(87, 1);
    var bytes = [_]u8{255};
    var creates = [_]Create{createResource(resource, 1, 1, c.HOWL_RENDER_UPLOAD_ALPHA8)};
    var uploads = [_]Upload{uploadResource(resource, makeRect(1, 0, 1, 1), &bytes, 1)};
    try expectRejectWithCreatesUploads(&creates, &uploads, bytes.len, error.InvalidUpload);
}

test "render-surface surface realizer clips fill coordinate overflow" {
    var commands = [_]Command{
        fillCommand(
            c.HOWL_RENDER_SURFACE_COMMAND_FILL_RECT,
            makeRect(std.math.maxInt(i32), std.math.maxInt(i32), 2, 2),
            0xffffffff,
        ),
    };
    var pixels: [4]u8 = undefined;
    var surface = testSurface(1, 1);
    surface.commands = commandSpan(&commands);
    try realize(&surface, &pixels, null);
    try expectPixel(&pixels, 0, .{ .r = 0, .g = 0, .b = 0, .a = 255 });
}

test "render-surface surface realizer clips sprite coordinate overflow" {
    const resource = spriteAlphaResource(88, 1);
    var bytes = [_]u8{ 255, 255, 255, 255 };
    var creates = [_]Create{createResource(resource, 2, 2, c.HOWL_RENDER_UPLOAD_ALPHA8)};
    var uploads = [_]Upload{uploadResource(resource, makeRect(0, 0, 2, 2), &bytes, 2)};
    var commands = [_]Command{
        spriteCommand(resource, makeRect(std.math.maxInt(i32), 0, 2, 2), 0xffffffff),
    };
    var pixels: [4]u8 = undefined;
    var surface = testSurface(1, 1);
    surface.creates = createSpan(&creates);
    surface.uploads = uploadSpan(&uploads, bytes.len);
    surface.commands = commandSpan(&commands);
    try realize(&surface, &pixels, null);
    try expectPixel(&pixels, 0, .{ .r = 0, .g = 0, .b = 0, .a = 255 });
}

fn testSurface(width: u16, height: u16) Surface {
    return .{
        .surface_version = c.HOWL_RENDER_SURFACE_VERSION,
        .reserved0 = 0,
        .token = .{ .snapshot_seq = 0, .surface_seq = 0, .geometry_epoch = 0, .resource_epoch = 0 },
        .render_px = .{ .width = width, .height = height },
        .cell_px = .{ .width = 1, .height = 1 },
        .grid = .{ .cols = 1, .rows = 1 },
        .damage = .{ .ptr = null, .count = 0, .count_max = c.HOWL_RENDER_SURFACE_DAMAGE_ITEMS_MAX },
        .creates = .{ .ptr = null, .count = 0, .count_max = c.HOWL_RENDER_SURFACE_CREATES_MAX },
        .uploads = .{
            .ptr = null,
            .count = 0,
            .count_max = c.HOWL_RENDER_SURFACE_UPLOADS_MAX,
            .bytes_count_total = 0,
            .bytes_count_max = c.HOWL_RENDER_SURFACE_UPLOAD_BYTES_MAX,
        },
        .commands = .{ .ptr = null, .count = 0, .count_max = c.HOWL_RENDER_SURFACE_COMMANDS_MAX },
        .retires = .{ .ptr = null, .count = 0, .count_max = c.HOWL_RENDER_SURFACE_RETIRES_MAX },
    };
}

fn makeRect(x_px: i32, y_px: i32, width_px: u16, height_px: u16) c.HowlRenderSurfaceRect {
    return .{ .x_px = x_px, .y_px = y_px, .width_px = width_px, .height_px = height_px };
}

fn spriteAlphaResource(value: u64, generation: u32) ResourceId {
    return .{
        .value = value,
        .generation = generation,
        .kind = c.HOWL_RENDER_RESOURCE_SPRITE_ALPHA,
    };
}

fn spriteColorResource(value: u64, generation: u32) ResourceId {
    return .{
        .value = value,
        .generation = generation,
        .kind = c.HOWL_RENDER_RESOURCE_SPRITE_COLOR,
    };
}

fn glyphAtlasAlphaResource(value: u64, generation: u32) ResourceId {
    return .{
        .value = value,
        .generation = generation,
        .kind = c.HOWL_RENDER_RESOURCE_GLYPH_ATLAS_ALPHA,
    };
}

fn glyphAtlasColorResource(value: u64, generation: u32) ResourceId {
    return .{
        .value = value,
        .generation = generation,
        .kind = c.HOWL_RENDER_RESOURCE_GLYPH_ATLAS_COLOR,
    };
}

fn fillCommand(kind: u8, command_rect: c.HowlRenderSurfaceRect, color_rgba: u32) Command {
    return .{
        .kind = kind,
        .reserved0 = 0,
        .reserved1 = 0,
        .rect = command_rect,
        .color_rgba = color_rgba,
        .resource = .{ .value = 0, .generation = 0, .kind = 0 },
        .glyphs = .{ .ptr = null, .count = 0, .count_max = c.HOWL_RENDER_SURFACE_GLYPHS_PER_RUN_MAX },
    };
}

fn spriteCommand(resource: ResourceId, command_rect: c.HowlRenderSurfaceRect, color_rgba: u32) Command {
    var command = fillCommand(c.HOWL_RENDER_SURFACE_COMMAND_DRAW_SPRITE, command_rect, color_rgba);
    command.resource = resource;
    return command;
}

fn glyphCommand(glyphs: []const GlyphRef) Command {
    var command = fillCommand(c.HOWL_RENDER_SURFACE_COMMAND_DRAW_GLYPH_RUN, makeRect(0, 0, 0, 0), 0);
    command.glyphs = .{
        .ptr = glyphs.ptr,
        .count = @intCast(glyphs.len),
        .count_max = c.HOWL_RENDER_SURFACE_GLYPHS_PER_RUN_MAX,
    };
    return command;
}

fn glyphRef(resource: ResourceId, atlas_rect: c.HowlRenderSurfaceRect, x_px: i32, y_px: i32, color_rgba: u32) GlyphRef {
    return .{
        .atlas_resource = resource,
        .atlas_rect = atlas_rect,
        .x_px = x_px,
        .y_px = y_px,
        .glyph_id = 1,
        .color_rgba = color_rgba,
    };
}

fn createResource(resource: ResourceId, width_px: u32, height_px: u32, format: u32) Create {
    return .{
        .resource = resource,
        .width_px = width_px,
        .height_px = height_px,
        .format = format,
        .create_seq = 0,
    };
}

fn createGlyphAtlasAlpha(resource: ResourceId) Create {
    return createResource(
        resource,
        glyph_atlas_width_px,
        glyph_atlas_height_px,
        c.HOWL_RENDER_UPLOAD_ALPHA8,
    );
}

fn uploadResource(resource: ResourceId, upload_rect: c.HowlRenderSurfaceRect, bytes: []const u8, stride_bytes: u32) Upload {
    return uploadResourceWithFormat(
        resource,
        upload_rect,
        bytes,
        stride_bytes,
        uploadFormatForResource(resource.kind),
    );
}

fn uploadResourceWithFormat(resource: ResourceId, upload_rect: c.HowlRenderSurfaceRect, bytes: []const u8, stride_bytes: u32, format: u32) Upload {
    return .{
        .resource = resource,
        .rect = upload_rect,
        .bytes_ptr = bytes.ptr,
        .bytes_count = @intCast(bytes.len),
        .stride_bytes = stride_bytes,
        .format = format,
        .upload_seq = 0,
    };
}

fn uploadFormatForResource(resource_kind: u32) u32 {
    return switch (resource_kind) {
        c.HOWL_RENDER_RESOURCE_GLYPH_ATLAS_ALPHA,
        c.HOWL_RENDER_RESOURCE_SPRITE_ALPHA,
        => c.HOWL_RENDER_UPLOAD_ALPHA8,
        c.HOWL_RENDER_RESOURCE_SPRITE_COLOR,
        c.HOWL_RENDER_RESOURCE_GLYPH_ATLAS_COLOR,
        => c.HOWL_RENDER_UPLOAD_RGBA8,
        else => 0,
    };
}

fn damageSpan(items: []const DamageItem, count_max: u32) c.HowlRenderSurfaceDamageSpan {
    return .{ .ptr = items.ptr, .count = @intCast(items.len), .count_max = count_max };
}

fn createSpan(items: []const Create) c.HowlRenderResourceCreateSpan {
    return .{
        .ptr = items.ptr,
        .count = @intCast(items.len),
        .count_max = c.HOWL_RENDER_SURFACE_CREATES_MAX,
    };
}

fn uploadSpan(items: []const Upload, bytes_count_total: usize) c.HowlRenderResourceUploadSpan {
    return .{
        .ptr = items.ptr,
        .count = @intCast(items.len),
        .count_max = c.HOWL_RENDER_SURFACE_UPLOADS_MAX,
        .bytes_count_total = @intCast(bytes_count_total),
        .bytes_count_max = c.HOWL_RENDER_SURFACE_UPLOAD_BYTES_MAX,
    };
}

fn commandSpan(items: []const Command) c.HowlRenderSurfaceCommandSpan {
    return .{
        .ptr = items.ptr,
        .count = @intCast(items.len),
        .count_max = c.HOWL_RENDER_SURFACE_COMMANDS_MAX,
    };
}

fn retireSpan(items: []const Retire) c.HowlRenderResourceRetireSpan {
    return .{
        .ptr = items.ptr,
        .count = @intCast(items.len),
        .count_max = c.HOWL_RENDER_SURFACE_RETIRES_MAX,
    };
}

fn expectReject(surface: *const Surface, expected: Error) !void {
    var pixels: [4]u8 = undefined;
    try std.testing.expectError(expected, realize(surface, &pixels, null));
}

fn expectRejectWithCommands(commands: []const Command, expected: Error) !void {
    var surface = testSurface(1, 1);
    surface.commands = commandSpan(commands);
    try expectReject(&surface, expected);
}

fn expectRejectWithCreates(creates: []const Create, expected: Error) !void {
    var surface = testSurface(1, 1);
    surface.creates = createSpan(creates);
    try expectReject(&surface, expected);
}

fn expectRejectWithCreatesCommands(creates: []const Create, commands: []const Command, expected: Error) !void {
    var surface = testSurface(1, 1);
    surface.creates = createSpan(creates);
    surface.commands = commandSpan(commands);
    try expectReject(&surface, expected);
}

fn expectRejectWithCreatesUploads(creates: []const Create, uploads: []const Upload, bytes_count_total: usize, expected: Error) !void {
    var surface = testSurface(1, 1);
    surface.creates = createSpan(creates);
    surface.uploads = uploadSpan(uploads, bytes_count_total);
    try expectReject(&surface, expected);
}

fn expectPixel(pixels: []const u8, pixel: u32, rgba: Rgba) !void {
    const index = pixel * 4;
    try std.testing.expectEqual(rgba.r, pixels[index]);
    try std.testing.expectEqual(rgba.g, pixels[index + 1]);
    try std.testing.expectEqual(rgba.b, pixels[index + 2]);
    try std.testing.expectEqual(rgba.a, pixels[index + 3]);
}
