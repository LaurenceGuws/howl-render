const atlas_cache = @import("../text/raster/cache.zig");
const rasterizer = @import("../text/raster/rasterizer.zig");
const tokens = @import("../geometry/tokens.zig");

pub fn markRendered(atlas: *atlas_cache.OwnedAtlasCache, outputs: []const rasterizer.RasterSpriteOutput) void {
    for (outputs) |output| {
        _ = atlas.storeRendered(output) catch {
            _ = atlas.markRendered(output.key);
            continue;
        };
    }
}

pub fn damageKind(prepared: anytype) tokens.DamageKind {
    if (prepared.text_surface.scene.scene.full_redraw) return .full;
    return .partial;
}
