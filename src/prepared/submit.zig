const text = @import("../text/text.zig");
const tokens = @import("../render/tokens.zig");

pub fn markRendered(atlas: *text.AtlasCache.OwnedAtlasCache, outputs: []const text.Rasterizer.RasterSpriteOutput) void {
    for (outputs) |output| {
        _ = atlas.storeRendered(output) catch {
            _ = atlas.markRendered(output.key);
            continue;
        };
    }
}

pub fn damageKind(prepared: anytype) tokens.DamageKind {
    if (prepared.text_frame.scene.scene.full_redraw) return .full;
    return .partial;
}
