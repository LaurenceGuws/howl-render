pub const TextPrepareCounters = struct {
    cell_texts: u64 = 0,
    clusters: u64 = 0,
    resolved_runs: u64 = 0,
    shaped_runs: u64 = 0,
    shaped_glyphs: u64 = 0,
    glyph_groups: u64 = 0,
    sprite_cache_hits: u64 = 0,
    sprite_cache_misses: u64 = 0,
    rasterized_sprites: u64 = 0,
    missing_glyphs: u64 = 0,
};
