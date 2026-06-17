const contract = @import("../text/contract.zig");

pub const SurfaceTheme = struct {
    default_fg: contract.Rgba8,
    default_bg: contract.Rgba8,
    cursor_color: contract.Rgba8,
    palette: [256]contract.Rgba8,
};
