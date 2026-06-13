const undercurl = @import("undercurl.zig");
const generated_special = @import("generated_special.zig");

pub const requestForUndercurl = undercurl.requestForUndercurl;
pub const rasterizeUndercurlAlpha = undercurl.rasterizeUndercurlAlpha;

pub const rasterizeGeneratedSpecialAlpha = generated_special.rasterizeGeneratedSpecialAlpha;
pub const rasterizeGeneratedSpecialAlphaWithMetrics = generated_special.rasterizeGeneratedSpecialAlphaWithMetrics;
