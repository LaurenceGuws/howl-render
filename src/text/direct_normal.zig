const std = @import("std");
const builtin = @import("builtin");
const atlas_cache = @import("raster/atlas.zig");
const cluster = @import("shape/cluster.zig");
const contract = @import("contract.zig");
const direct_scene = @import("direct_scene.zig");
const font_session = @import("session.zig");
const lane = @import("lane.zig");
const prepare_counters = @import("prepare_counters.zig");
const provider = @import("provider.zig");
const raster_operation = @import("raster/operation.zig");
const rasterizer = @import("raster/rasterizer.zig");
const scene = @import("scene.zig");
const scene_damage = @import("scene_damage.zig");
const scene_rects = @import("scene_rects.zig");
const sprite_key = @import("raster/key.zig");
const source_vt = @import("../vt_publication/abi.zig");
const source_theme = @import("../vt_publication/theme.zig");

const RenderableCell = contract.RenderableCell;
const CellText = contract.CellText;
const FontSession = font_session.FontSession;
const FontFaceRecord = font_session.FontFaceRecord;
const LookupGlyphResult = provider.LookupGlyphResult;

pub const Product = struct {
    damage: direct_scene.Damage,
    outputs: []rasterizer.RasterSpriteOutput = &.{},
    outputs_owned: bool = false,

    pub fn deinit(self: *Product, allocator: std.mem.Allocator) void {
        if (!self.outputs_owned) return;
        for (self.outputs) |*out| out.deinit();
        allocator.free(self.outputs);
        self.outputs = &.{};
        self.outputs_owned = false;
    }
};

pub const Policy = enum {
    require_all_normal,
    skip_complex,
};

pub const Source = union(enum) {
    raw_cells: []const contract.CellInput,
    publication: struct {
        cells: []const source_vt.SourceCell,
        theme: source_theme.SurfaceTheme,
    },
    inputs: []const cluster.CellTextInput,
    prepared: struct {
        cells: []const contract.RenderableCell,
        text_cache: contract.LineTextCache,
    },
};

pub const Scratch = struct {
    missing: std.ArrayListUnmanaged(contract.MissingGlyph) = .{ .items = &.{}, .capacity = 0 },
    sprite_draws: std.ArrayListUnmanaged(contract.TextSpriteDraw) = .{ .items = &.{}, .capacity = 0 },
    background_draws: std.ArrayListUnmanaged(contract.TextBackgroundDraw) = .{ .items = &.{}, .capacity = 0 },
    clear_draws: std.ArrayListUnmanaged(contract.TextClearDraw) = .{ .items = &.{}, .capacity = 0 },
    decoration_draws: std.ArrayListUnmanaged(contract.TextDecorationDraw) = .{ .items = &.{}, .capacity = 0 },
    cursor_draws: std.ArrayListUnmanaged(contract.TextCursorDraw) = .{ .items = &.{}, .capacity = 0 },
    raster_reqs: std.ArrayListUnmanaged(raster_operation.RasterizeRequest) = .{ .items = &.{}, .capacity = 0 },
    clear_row_colors: std.ArrayListUnmanaged(contract.Rgba8) = .{ .items = &.{}, .capacity = 0 },
    clear_row_matches: std.ArrayListUnmanaged(bool) = .{ .items = &.{}, .capacity = 0 },
    background_merge_live: bool = false,
    background_merge_end_cell: u32 = 0,

    pub fn deinit(self: *Scratch, allocator: std.mem.Allocator) void {
        self.clear_row_matches.deinit(allocator);
        self.clear_row_colors.deinit(allocator);
        self.raster_reqs.deinit(allocator);
        self.cursor_draws.deinit(allocator);
        self.decoration_draws.deinit(allocator);
        self.clear_draws.deinit(allocator);
        self.background_draws.deinit(allocator);
        self.sprite_draws.deinit(allocator);
        self.missing.deinit(allocator);
        self.* = undefined;
    }

    pub fn reset(self: *Scratch, allocator: std.mem.Allocator, visible_count: u32, cell_count: u32, rows: u16) !void {
        std.debug.assert(cell_count >= visible_count);
        try self.missing.ensureTotalCapacity(allocator, @intCast(cell_count));
        try self.sprite_draws.ensureTotalCapacity(allocator, @intCast(cell_count));
        try self.background_draws.ensureTotalCapacity(allocator, @intCast(cell_count));
        try self.clear_draws.ensureTotalCapacity(allocator, @intCast(rows));
        try self.decoration_draws.ensureTotalCapacity(allocator, @intCast(cell_count * 2));
        try self.cursor_draws.ensureTotalCapacity(allocator, 4);
        try self.raster_reqs.ensureTotalCapacity(allocator, @intCast(cell_count));
        try self.clear_row_colors.ensureTotalCapacity(allocator, @intCast(rows));
        try self.clear_row_matches.ensureTotalCapacity(allocator, @intCast(rows));
        self.missing.clearRetainingCapacity();
        self.sprite_draws.clearRetainingCapacity();
        self.background_draws.clearRetainingCapacity();
        self.clear_draws.clearRetainingCapacity();
        self.decoration_draws.clearRetainingCapacity();
        self.cursor_draws.clearRetainingCapacity();
        self.raster_reqs.clearRetainingCapacity();
        self.clear_row_colors.items.len = rows;
        self.clear_row_matches.items.len = rows;
        for (self.clear_row_colors.items) |*color| color.* = .{ .r = 0, .g = 0, .b = 0, .a = 255 };
        @memset(self.clear_row_matches.items, false);
        self.background_merge_live = false;
        self.background_merge_end_cell = 0;
    }
};

pub const Driver = struct {
    allocator: std.mem.Allocator,
    atlas: *atlas_cache.OwnedAtlasCache,
    glyph_lookup: provider.LookupGlyphOp,
    glyph_raster: raster_operation.RasterizeGlyphOp,
    scratch: *Scratch,
};

pub fn prepare(
    driver: Driver,
    source: Source,
    policy: Policy,
    grid_metrics: contract.GridMetrics,
    session: font_session.FontSession,
    damage_input: scene_damage.DamageInput,
    cursor: ?contract.CursorPresentation,
    lane_report: *lane.LaneReport,
    rejected_complex_cells_out: ?*u64,
) !?Product {
    const prepare_start_ns = timeNowNs();
    const damage = direct_scene.Damage.init(damage_input, grid_metrics.rows);
    const decoration_layout = scene_rects.rectDecorationLayout(session.metrics, grid_metrics);
    const source_len = sourceLen(source);
    var rejected_complex_cells: u64 = 0;
    try driver.scratch.reset(driver.allocator, source_len, source_len, grid_metrics.rows);
    proof.prepare_calls += 1;
    const appended_visible = try appendVisible(driver, source, damage, grid_metrics, decoration_layout, session, policy, lane_report, &rejected_complex_cells);
    if (!appended_visible) {
        std.debug.assert(policy == .require_all_normal);
        std.debug.assert(rejected_complex_cells != 0);
        proof.fallback_reject_calls += 1;
        proof.direct_normal_prepare_ns += elapsedSinceNs(prepare_start_ns);
        logProofMaybe();
        if (rejected_complex_cells_out) |out| out.* = rejected_complex_cells;
        assertNoPartialDrawState(driver.scratch);
        lane_report.assertValid();
        return null;
    }
    std.debug.assert(rejected_complex_cells == 0);
    if (rejected_complex_cells_out) |out| out.* = 0;
    const append_scene_rects_start_ns = timeNowNs();
    direct_scene.appendClears(
        &driver.scratch.clear_draws,
        driver.scratch.clear_row_colors.items,
        driver.scratch.clear_row_matches.items,
        session.metrics,
        grid_metrics,
        damage,
    );
    direct_scene.appendCursor(&driver.scratch.cursor_draws, cursor, session.metrics, damage);
    proof.append_scene_rects_ns += elapsedSinceNs(append_scene_rects_start_ns);
    const finish_scene_start_ns = timeNowNs();
    const product = try finishScene(driver, damage, lane_report);
    proof.finish_scene_ns += elapsedSinceNs(finish_scene_start_ns);
    proof.direct_success_calls += 1;
    proof.raster_req_count_total += @intCast(driver.scratch.raster_reqs.items.len);
    proof.direct_normal_prepare_ns += elapsedSinceNs(prepare_start_ns);
    logProofMaybe();
    return product;
}

pub fn counters(scratch: *const Scratch, lane_report: lane.LaneReport, direct: Product) prepare_counters.TextPrepareCounters {
    return .{
        .cell_texts = lane_report.visible_cells,
        .clusters = lane_report.normal_clusters,
        .sprite_cache_hits = @intCast(scratch.sprite_draws.items.len - scratch.raster_reqs.items.len),
        .sprite_cache_misses = @intCast(scratch.raster_reqs.items.len),
        .rasterized_sprites = @intCast(direct.outputs.len),
        .missing_glyphs = @intCast(scratch.missing.items.len),
    };
}

const Decision = enum { include, skip, reject };

const actions = [2][6]Decision{
    .{ .include, .reject, .reject, .reject, .reject, .reject },
    .{ .include, .skip, .skip, .skip, .skip, .skip },
};

const Candidate = struct {
    item: cluster.RenderableText,
    choice: lane.LaneClass,
};

const PublicationCandidate = union(enum) {
    candidate: Candidate,
    skip,
    unsupported,
};

const ascii_codepoints = initAsciiCodepoints();

const proof_log_period: u64 = 32;
const append_renderable_proof_session_id = "coder-2026-06-14-ascii-rain-performance-proof-29";

const AppendRenderableProofMode = enum {
    renderable_append,
    append_resolved_glyph,
    blank_fast_return,
    resolve_face,
    lookup_glyph,
    key_derivation,
    atlas_reserve,
    raster_enqueue,
    sprite_append,
    lane_report_update,
};

const append_renderable_proof_mode_env = "HOWL_APPEND_RENDERABLE_PROOF_MODE";

const Proof = struct {
    prepare_calls: u64 = 0,
    direct_normal_prepare_ns: u64 = 0,
    publication_renderable_text_ns: u64 = 0,
    publication_cell_supported_ns: u64 = 0,
    publication_damage_include_ns: u64 = 0,
    source_candidate_ns: u64 = 0,
    append_renderable_ns: u64 = 0,
    renderable_append_ns: u64 = 0,
    append_resolved_glyph_ns: u64 = 0,
    inline_background_ns: u64 = 0,
    inline_clear_note_ns: u64 = 0,
    inline_decoration_ns: u64 = 0,
    blank_fast_return_ns: u64 = 0,
    resolve_face_ns: u64 = 0,
    lookup_glyph_ns: u64 = 0,
    key_derivation_ns: u64 = 0,
    atlas_reserve_ns: u64 = 0,
    raster_enqueue_ns: u64 = 0,
    sprite_append_ns: u64 = 0,
    lane_report_update_ns: u64 = 0,
    append_visible_ns: u64 = 0,
    append_scene_rects_ns: u64 = 0,
    finish_scene_ns: u64 = 0,
    visible_cells_scanned: u64 = 0,
    included_normal_cells: u64 = 0,
    direct_success_calls: u64 = 0,
    fallback_reject_calls: u64 = 0,
    append_renderable_calls: u64 = 0,
    raster_req_count_total: u64 = 0,
};

var proof: Proof = .{};
var append_renderable_proof_mode: ?AppendRenderableProofMode = null;
var append_renderable_proof_log_header_written = false;

fn timeNowNs() u64 {
    var timespec: std.c.timespec = undefined;
    switch (std.c.errno(std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &timespec))) {
        .SUCCESS => {},
        else => unreachable,
    }
    const seconds_ns = @as(u64, @intCast(timespec.sec)) * std.time.ns_per_s;
    return seconds_ns + @as(u64, @intCast(timespec.nsec));
}

fn elapsedSinceNs(start_ns: u64) u64 {
    const end_ns = timeNowNs();
    std.debug.assert(end_ns >= start_ns);
    return end_ns - start_ns;
}

fn nsToMs(ns: u64) f64 {
    return @as(f64, @floatFromInt(ns)) / @as(f64, std.time.ns_per_ms);
}

fn appendRenderableProofMode() AppendRenderableProofMode {
    if (append_renderable_proof_mode) |mode| return mode;
    const env_value = std.c.getenv(append_renderable_proof_mode_env) orelse {
        append_renderable_proof_mode = .lookup_glyph;
        return .lookup_glyph;
    };
    const mode = std.meta.stringToEnum(AppendRenderableProofMode, std.mem.span(env_value)) orelse @panic("invalid HOWL_APPEND_RENDERABLE_PROOF_MODE");
    append_renderable_proof_mode = mode;
    return mode;
}

fn recordAppendRenderableProof(mode: AppendRenderableProofMode, field: *u64, start_ns: u64) void {
    const selected_mode = appendRenderableProofMode();
    if (selected_mode != mode and selected_mode != .renderable_append and selected_mode != .append_resolved_glyph) return;
    field.* += elapsedSinceNs(start_ns);
}

fn recordRenderableAppendInnerProof(field: *u64, start_ns: u64) void {
    if (appendRenderableProofMode() != .renderable_append) return;
    field.* += elapsedSinceNs(start_ns);
}

fn logProofMaybe() void {
    if (builtin.is_test) return;
    if (proof.prepare_calls == 0 or proof.prepare_calls % proof_log_period != 0) return;
    if (!append_renderable_proof_log_header_written) {
        append_renderable_proof_log_header_written = true;
        std.log.warn(
            "ascii-rain-proof session={s} fresh-section-begin append_renderable_mode={s}",
            .{ append_renderable_proof_session_id, @tagName(appendRenderableProofMode()) },
        );
    }
    std.log.warn(
        "ascii-rain-proof direct_normal append_renderable_mode={s} prepare calls={} direct_normal_prepare_ms={d:.3} source_candidate_ms={d:.3} publication_cell_supported_ms={d:.3} publication_renderable_text_ms={d:.3} publication_damage_include_ms={d:.3} append_renderable_ms={d:.3} renderable_append_ms={d:.3} inline_background_ms={d:.3} inline_clear_note_ms={d:.3} inline_decoration_ms={d:.3}",
        .{
            @tagName(appendRenderableProofMode()),
            proof.prepare_calls,
            nsToMs(proof.direct_normal_prepare_ns),
            nsToMs(proof.source_candidate_ns),
            nsToMs(proof.publication_cell_supported_ns),
            nsToMs(proof.publication_renderable_text_ns),
            nsToMs(proof.publication_damage_include_ns),
            nsToMs(proof.append_renderable_ns),
            nsToMs(proof.renderable_append_ns),
            nsToMs(proof.inline_background_ns),
            nsToMs(proof.inline_clear_note_ns),
            nsToMs(proof.inline_decoration_ns),
        },
    );
    std.log.warn(
        "ascii-rain-proof direct_normal append_renderable_mode={s} inline_background_ns={} inline_clear_note_ns={} inline_decoration_ns={} append_renderable_calls={} fallback_reject_calls={} append_scene_rects_ms={d:.3} direct_normal_prepare_ms={d:.3}",
        .{
            @tagName(appendRenderableProofMode()),
            proof.inline_background_ns,
            proof.inline_clear_note_ns,
            proof.inline_decoration_ns,
            proof.append_renderable_calls,
            proof.fallback_reject_calls,
            nsToMs(proof.append_scene_rects_ns),
            nsToMs(proof.direct_normal_prepare_ns),
        },
    );
    std.log.warn(
        "ascii-rain-proof direct_normal append_renderable_mode={s} append_resolved_glyph_ms={d:.3} blank_fast_return_ms={d:.3} resolve_face_ms={d:.3} lookup_glyph_ms={d:.3} key_derivation_ms={d:.3} atlas_reserve_ms={d:.3} raster_enqueue_ms={d:.3} sprite_append_ms={d:.3} lane_report_update_ms={d:.3} append_visible_ms={d:.3} append_scene_rects_ms={d:.3} finish_scene_ms={d:.3} visible_cells_scanned={} included_normal_cells={} direct_success_calls={} fallback_reject_calls={} append_renderable_calls={} raster_req_count_total={}",
        .{
            @tagName(appendRenderableProofMode()),
            nsToMs(proof.append_resolved_glyph_ns),
            nsToMs(proof.blank_fast_return_ns),
            nsToMs(proof.resolve_face_ns),
            nsToMs(proof.lookup_glyph_ns),
            nsToMs(proof.key_derivation_ns),
            nsToMs(proof.atlas_reserve_ns),
            nsToMs(proof.raster_enqueue_ns),
            nsToMs(proof.sprite_append_ns),
            nsToMs(proof.lane_report_update_ns),
            nsToMs(proof.append_visible_ns),
            nsToMs(proof.append_scene_rects_ns),
            nsToMs(proof.finish_scene_ns),
            proof.visible_cells_scanned,
            proof.included_normal_cells,
            proof.direct_success_calls,
            proof.fallback_reject_calls,
            proof.append_renderable_calls,
            proof.raster_req_count_total,
        },
    );
}

const ScratchCheckpoint = struct {
    missing_len: usize,
    sprite_draws_len: usize,
    background_draws_len: usize,
    clear_draws_len: usize,
    decoration_draws_len: usize,
    cursor_draws_len: usize,
    raster_reqs_len: usize,
};

fn appendVisible(
    driver: Driver,
    source: Source,
    damage: direct_scene.Damage,
    grid_metrics: contract.GridMetrics,
    decoration_layout: scene_rects.RectDecorationLayout,
    session: font_session.FontSession,
    policy: Policy,
    lane_report: *lane.LaneReport,
    rejected_complex_cells: *u64,
) !bool {
    const append_visible_start_ns = timeNowNs();
    defer proof.append_visible_ns += elapsedSinceNs(append_visible_start_ns);
    rejected_complex_cells.* = 0;
    const lane_report_start = lane_report.*;
    const scratch_start = checkpointScratch(driver.scratch);
    var rejecting = false;

    if (source == .publication and policy == .require_all_normal) {
        const publication = source.publication;
        var idx_publication: u32 = 0;
        while (idx_publication < sourceLen(source)) : (idx_publication += 1) {
            proof.visible_cells_scanned += 1;
            const cell = publication.cells[@intCast(idx_publication)];
            const supported = publicationCellSupported(publication.cells, idx_publication, cell);
            if (supported) {
                const item = publicationRenderableText(publication.theme, idx_publication, cell);
                const include_start_ns = timeNowNs();
                const included = cluster.includeDamage(grid_metrics, damageInput(damage), item.renderable);
                proof.publication_damage_include_ns += elapsedSinceNs(include_start_ns);
                if (!included) continue;

                if (rejecting) continue;
                proof.included_normal_cells += 1;
                recordLane(lane_report, item.text);
                try appendRenderable(driver, item.renderable, item.text, damage, grid_metrics, decoration_layout, session, lane_report);
                continue;
            }

            const candidate = sourceCandidate(source, idx_publication, damage, grid_metrics);
            const candidate_value = candidate orelse continue;
            std.debug.assert(candidateValuePublicationFallback(source, idx_publication, publication.cells, candidate_value));
            if (rejecting) {
                if (candidate_value.choice.renderableClass() != .normal) rejected_complex_cells.* += 1;
                continue;
            }
            switch (candidateDecision(policy, lane_report, candidate_value)) {
                .include => {
                    try appendRenderable(driver, candidate_value.item.renderable, candidate_value.item.text, damage, grid_metrics, decoration_layout, session, lane_report);
                },
                .skip => continue,
                .reject => {
                    rejected_complex_cells.* = 1;
                    lane_report.* = lane_report_start;
                    restoreScratch(driver.scratch, scratch_start);
                    std.debug.assert(scratchEmpty(driver.scratch));
                    lane_report.assertValid();
                    rejecting = true;
                },
            }
        }
        if (rejecting) {
            std.debug.assert(rejected_complex_cells.* != 0);
            std.debug.assert(scratchEmpty(driver.scratch));
            lane_report.assertValid();
            return false;
        }
        std.debug.assert(rejected_complex_cells.* == 0);
        lane_report.assertValid();
        return true;
    }

    var idx: u32 = 0;
    while (idx < sourceLen(source)) : (idx += 1) {
        const candidate = sourceCandidate(source, idx, damage, grid_metrics);
        const candidate_value = candidate orelse continue;
        if (rejecting) {
            if (candidate_value.choice.renderableClass() != .normal) rejected_complex_cells.* += 1;
            continue;
        }
        switch (candidateDecision(policy, lane_report, candidate_value)) {
            .include => {
                try appendRenderable(driver, candidate_value.item.renderable, candidate_value.item.text, damage, grid_metrics, decoration_layout, session, lane_report);
            },
            .skip => continue,
            .reject => {
                std.debug.assert(policy == .require_all_normal);
                rejected_complex_cells.* = 1;
                lane_report.* = lane_report_start;
                restoreScratch(driver.scratch, scratch_start);
                std.debug.assert(scratchEmpty(driver.scratch));
                lane_report.assertValid();
                rejecting = true;
            },
        }
    }
    if (rejecting) {
        std.debug.assert(rejected_complex_cells.* != 0);
        std.debug.assert(scratchEmpty(driver.scratch));
        lane_report.assertValid();
        return false;
    }
    std.debug.assert(rejected_complex_cells.* == 0);
    lane_report.assertValid();
    return true;
}

fn candidateValuePublicationFallback(source: Source, idx: u32, publication_cells: []const source_vt.SourceCell, candidate: Candidate) bool {
    std.debug.assert(source == .publication);
    const cell = publication_cells[@intCast(idx)];
    if (!publicationCellSupported(publication_cells, idx, cell)) return true;
    return candidate.item.renderable.first_cell == idx and candidate.choice.renderableClass() == .normal;
}

fn candidateDecision(policy: Policy, lane_report: *lane.LaneReport, candidate: Candidate) Decision {
    const class = candidate.choice.renderableClass();
    const action = actions[@intFromEnum(policy)][@intFromEnum(class)];
    if (action == .include and policy == .require_all_normal) recordLane(lane_report, candidate.item.text);
    return action;
}

fn sourceCandidate(source: Source, idx: u32, damage: direct_scene.Damage, grid_metrics: contract.GridMetrics) ?Candidate {
    const source_candidate_start_ns = timeNowNs();
    defer proof.source_candidate_ns += elapsedSinceNs(source_candidate_start_ns);
    if (source == .publication) {
        const publication = source.publication;
        switch (publicationCandidate(publication.cells, publication.theme, idx, damage, grid_metrics)) {
            .candidate => |candidate| return candidate,
            .skip => return null,
            .unsupported => {},
        }
    }
    const item = sourceItem(source, idx) orelse return null;
    if (!cluster.includeDamage(grid_metrics, damageInput(damage), item.renderable)) return null;
    return .{ .item = item, .choice = lane.classifyRenderableCell(item.renderable, item.text) };
}

fn publicationCandidate(cells: []const source_vt.SourceCell, theme: source_theme.SurfaceTheme, idx: u32, damage: direct_scene.Damage, grid_metrics: contract.GridMetrics) PublicationCandidate {
    std.debug.assert(idx < count32(cells));
    const cell = cells[@intCast(idx)];
    const supported = publicationCellSupported(cells, idx, cell);
    if (!supported) return .unsupported;

    const item = publicationRenderableText(theme, idx, cell);
    const include_start_ns = timeNowNs();
    if (!cluster.includeDamage(grid_metrics, damageInput(damage), item.renderable)) {
        proof.publication_damage_include_ns += elapsedSinceNs(include_start_ns);
        return .skip;
    }
    proof.publication_damage_include_ns += elapsedSinceNs(include_start_ns);
    const choice = lane.LaneClass.normal();
    choice.assertValid();
    std.debug.assert(lane.classifyRenderableCell(item.renderable, item.text).renderableClass() == .normal);
    return .{ .candidate = .{ .item = item, .choice = choice } };
}

fn publicationCellSupported(cells: []const source_vt.SourceCell, idx: u32, cell: source_vt.SourceCell) bool {
    const supported_start_ns = timeNowNs();
    defer proof.publication_cell_supported_ns += elapsedSinceNs(supported_start_ns);
    if (!publicationCodepointSupported(cell.codepoint)) return false;
    if (cell.combining_len != 0) return false;
    if (cell.flags.continuation != 0) return false;
    if (publicationCellSpan(cells, idx) != 1) return false;
    if (cell.link_id != 0) return false;
    if (!publicationColorSupported(cell.fg_color)) return false;
    if (!publicationColorSupported(cell.bg_color)) return false;
    if (cell.attrs.selected != 0) return false;
    if (cell.attrs.invisible != 0) return false;
    if (cell.attrs.strikethrough != 0) return false;
    if (cell.attrs.underline_color_set != 0) return false;
    if (cell.underline_style != 0) return false;
    return true;
}

fn publicationRenderableText(theme: source_theme.SurfaceTheme, idx: u32, cell: source_vt.SourceCell) cluster.RenderableText {
    const renderable_text_start_ns = timeNowNs();
    defer proof.publication_renderable_text_ns += elapsedSinceNs(renderable_text_start_ns);
    std.debug.assert(publicationCodepointSupported(cell.codepoint));
    std.debug.assert(cell.combining_len == 0);
    std.debug.assert(cell.flags.continuation == 0);
    std.debug.assert(publicationColorSupported(cell.fg_color));
    std.debug.assert(publicationColorSupported(cell.bg_color));
    std.debug.assert(cell.underline_style == 0);

    const text = contract.CellText{
        .id = .{ .value = 0 },
        .first_cp = cell.codepoint,
        .codepoints = ascii_codepoints[@intCast(cell.codepoint)][0..1],
    };
    if (cell.attrs.inverse == 0 and
        cell.attrs.bold == 0 and
        cell.attrs.italic == 0 and
        cell.attrs.dim == 0 and
        cell.attrs.underline == 0 and
        cell.fg_color.kind == 0 and
        cell.bg_color.kind == 0)
    {
        const item = cluster.RenderableText{
            .renderable = .{
                .text_id = .{ .value = 0 },
                .first_cell = idx,
                .cell_span = 1,
                .style = .regular,
                .presentation = .any,
                .fg = theme.default_fg,
                .bg = theme.default_bg,
            },
            .text = text,
        };
        std.debug.assert(item.text.codepoints.len == 1);
        std.debug.assert(item.text.codepoints[0] == item.text.first_cp);
        if (cell.codepoint == 0) {
            std.debug.assert(item.text.first_cp == 0);
        } else {
            std.debug.assert(cell.codepoint >= 0x21 and cell.codepoint < 0x7f);
        }
        std.debug.assert(item.renderable.cell_span == 1);
        return item;
    }

    var fg = theme.default_fg;
    var bg = theme.default_bg;
    var semantic_fg: contract.SemanticColor = .{};
    var semantic_bg: contract.SemanticColor = .{};

    switch (cell.fg_color.kind) {
        0 => {},
        1 => {
            fg = theme.palette[@intCast(cell.fg_color.value)];
            semantic_fg = .{ .kind = .indexed, .value = cell.fg_color.value };
        },
        else => unreachable,
    }
    switch (cell.bg_color.kind) {
        0 => {},
        1 => {
            bg = theme.palette[@intCast(cell.bg_color.value)];
            semantic_bg = .{ .kind = .indexed, .value = cell.bg_color.value };
        },
        else => unreachable,
    }
    if (cell.attrs.inverse != 0) std.mem.swap(contract.Rgba8, &fg, &bg);

    const item = cluster.RenderableText{
        .renderable = .{
            .text_id = .{ .value = 0 },
            .first_cell = idx,
            .cell_span = 1,
            .style = @enumFromInt(@as(u2, @truncate(cell.attrs.bold | (cell.attrs.italic << 1)))),
            .presentation = .any,
            .dim = cell.attrs.dim != 0,
            .semantic_fg = semantic_fg,
            .semantic_bg = semantic_bg,
            .fg = fg,
            .bg = bg,
            .underline = cell.attrs.underline != 0,
        },
        .text = text,
    };
    std.debug.assert(item.text.codepoints.len == 1);
    std.debug.assert(item.text.codepoints[0] == item.text.first_cp);
    if (cell.codepoint == 0) {
        std.debug.assert(item.text.first_cp == 0);
    } else {
        std.debug.assert(cell.codepoint >= 0x21 and cell.codepoint < 0x7f);
    }
    std.debug.assert(item.renderable.cell_span == 1);
    return item;
}

fn publicationCodepointSupported(codepoint: u32) bool {
    if (codepoint == 0) return true;
    return codepoint >= 0x21 and codepoint < 0x7f;
}

fn publicationColorSupported(color: source_vt.SourceColor) bool {
    return switch (color.kind) {
        0 => true,
        1 => color.value <= std.math.maxInt(u8),
        else => false,
    };
}

fn publicationColorRgba(color: source_vt.SourceColor, foreground: bool, theme: source_theme.SurfaceTheme) contract.Rgba8 {
    std.debug.assert(publicationColorSupported(color));
    return switch (color.kind) {
        0 => if (foreground) theme.default_fg else theme.default_bg,
        1 => theme.palette[@intCast(color.value)],
        else => unreachable,
    };
}

fn publicationSemanticColor(color: source_vt.SourceColor) contract.SemanticColor {
    std.debug.assert(publicationColorSupported(color));
    return switch (color.kind) {
        0 => .{ .kind = .default },
        1 => .{ .kind = .indexed, .value = color.value },
        else => unreachable,
    };
}

fn publicationFontStyle(bold: bool, italic: bool) contract.FontStyle {
    if (bold and italic) return .bold_italic;
    if (bold) return .bold;
    if (italic) return .italic;
    return .regular;
}

fn publicationCellSpan(cells: []const source_vt.SourceCell, idx: u32) u8 {
    var span: u32 = 1;
    const total = count32(cells);
    while (idx + span < total and cells[@intCast(idx + span)].flags.continuation != 0) : (span += 1) {}
    return @intCast(@min(span, std.math.maxInt(u8)));
}

fn initAsciiCodepoints() [128][1]u32 {
    var table: [128][1]u32 = undefined;
    for (&table, 0..) |*entry, idx| entry[0] = @intCast(idx);
    return table;
}

fn sourceLen(source: Source) u32 {
    return switch (source) {
        .raw_cells => |cells| @intCast(cells.len),
        .publication => |publication| @intCast(publication.cells.len),
        .inputs => |inputs| @intCast(inputs.len),
        .prepared => |prepared| @intCast(prepared.cells.len),
    };
}

fn sourceItem(source: Source, idx: u32) ?cluster.RenderableText {
    return switch (source) {
        .raw_cells => |cells| cluster.sourceRenderableTextFromCells(cells, idx),
        .publication => |publication| cluster.sourceRenderableTextFromPublication(publication.cells, publication.theme, idx),
        .inputs => |inputs| cluster.sourceRenderableTextFromInputs(inputs, idx),
        .prepared => |prepared| cluster.sourceRenderableTextFromPrepared(prepared.cells, prepared.text_cache, idx),
    };
}

fn damageInput(damage: direct_scene.Damage) scene_damage.DamageInput {
    return .{
        .full = damage.full,
        .dirty_rows = damage.dirty_rows,
        .dirty_cols_start = damage.dirty_cols_start,
        .dirty_cols_end = damage.dirty_cols_end,
    };
}

fn recordLane(lane_report: *lane.LaneReport, text: contract.CellText) void {
    lane_report.visible_cells += 1;
    lane_report.normal_cells += 1;
    if (!blankText(text)) lane_report.normal_clusters += 1;
}

fn appendRenderable(
    driver: Driver,
    renderable: contract.RenderableCell,
    text: contract.CellText,
    damage: direct_scene.Damage,
    grid_metrics: contract.GridMetrics,
    decoration_layout: scene_rects.RectDecorationLayout,
    session: font_session.FontSession,
    lane_report: *lane.LaneReport,
) !void {
    const append_renderable_start_ns = timeNowNs();
    defer proof.append_renderable_ns += elapsedSinceNs(append_renderable_start_ns);
    proof.append_renderable_calls += 1;

    direct_scene.appendRenderableRects(
        &driver.scratch.background_draws,
        &driver.scratch.background_merge_live,
        &driver.scratch.background_merge_end_cell,
        driver.scratch.clear_row_colors.items,
        driver.scratch.clear_row_matches.items,
        &driver.scratch.decoration_draws,
        &proof.inline_background_ns,
        &proof.inline_clear_note_ns,
        &proof.inline_decoration_ns,
        renderable,
        session.metrics,
        grid_metrics,
        decoration_layout,
        damage,
    );

    const renderable_append_start_ns = timeNowNs();
    try renderableAppend(driver, renderable, text, grid_metrics, session, lane_report);
    recordAppendRenderableProof(.renderable_append, &proof.renderable_append_ns, renderable_append_start_ns);
}

fn renderableAppend(
    driver: Driver,
    renderable: contract.RenderableCell,
    text: contract.CellText,
    grid_metrics: contract.GridMetrics,
    session: font_session.FontSession,
    lane_report: *lane.LaneReport,
) !void {
    if (blankFastReturn(driver, text)) return;

    const face = resolveFaceOrAppendMissing(driver, renderable, text, session) orelse return;
    appendResolvedGlyph(driver, renderable, text, grid_metrics, session, lane_report, face);
}

fn resolveFaceOrAppendMissing(driver: Driver, renderable: contract.RenderableCell, text: contract.CellText, session: font_session.FontSession) ?font_session.FontFaceRecord {
    const resolve_face_start_ns = timeNowNs();
    const face = resolveFace(session, renderable, text) orelse {
        recordAppendRenderableProof(.resolve_face, &proof.resolve_face_ns, resolve_face_start_ns);
        driver.scratch.missing.appendAssumeCapacity(.{ .codepoint = text.first_cp, .style = renderable.style, .presentation = renderable.presentation, .reason = .no_fallback_face });
        return null;
    };
    recordAppendRenderableProof(.resolve_face, &proof.resolve_face_ns, resolve_face_start_ns);
    return face;
}

const ResolvedGlyphKey = struct {
    lookup: provider.LookupGlyphResult,
    span: u8,
    key: contract.SpriteKey,
};

fn appendResolvedGlyph(
    driver: Driver,
    renderable: contract.RenderableCell,
    text: contract.CellText,
    grid_metrics: contract.GridMetrics,
    session: font_session.FontSession,
    lane_report: *lane.LaneReport,
    face: font_session.FontFaceRecord,
) void {
    const append_resolved_glyph_start_ns = timeNowNs();
    const lookup = lookupGlyph(driver, text, session, face);
    const resolved = deriveResolvedGlyphKey(renderable, session, face, lookup);
    const residency = reserveAtlasOrAppendPendingRaster(driver, session, face, resolved);
    spriteAppend(driver, renderable, grid_metrics, session, lane_report, resolved.lookup, residency, resolved.span);
    recordAppendRenderableProof(.append_resolved_glyph, &proof.append_resolved_glyph_ns, append_resolved_glyph_start_ns);
}

fn lookupGlyph(driver: Driver, text: CellText, session: FontSession, face: FontFaceRecord) LookupGlyphResult {
    const lookup_glyph_start_ns = timeNowNs();
    const lookup = driver.glyph_lookup.lookupGlyph(face.id, text.first_cp, session.metrics);
    recordAppendRenderableProof(.lookup_glyph, &proof.lookup_glyph_ns, lookup_glyph_start_ns);
    return lookup;
}

fn deriveResolvedGlyphKey(renderable: RenderableCell, session: FontSession, face: FontFaceRecord, lookup: LookupGlyphResult) ResolvedGlyphKey {
    const span = @max(renderable.cell_span, 1);
    const key_derivation_start_ns = timeNowNs();
    const key = sprite_key.hashGlyphLocal(face.id, lookup.glyph_id, span, session.metrics);
    recordAppendRenderableProof(.key_derivation, &proof.key_derivation_ns, key_derivation_start_ns);
    return .{ .lookup = lookup, .span = span, .key = key };
}

fn reserveAtlasOrAppendPendingRaster(driver: Driver, session: font_session.FontSession, face: font_session.FontFaceRecord, resolved: ResolvedGlyphKey) atlas_cache.ReserveResult {
    const atlas_reserve_start_ns = timeNowNs();
    const residency = driver.atlas.reserve(resolved.key, false);
    recordAppendRenderableProof(.atlas_reserve, &proof.atlas_reserve_ns, atlas_reserve_start_ns);
    if (residency.pending) {
        const raster_enqueue_start_ns = timeNowNs();
        driver.scratch.raster_reqs.appendAssumeCapacity(.{
            .face_id = face.id.value,
            .glyph_id = resolved.lookup.glyph_id,
            .atlas_key = resolved.key.value,
            .cell_metrics = session.metrics,
            .cell_span = resolved.span,
        });
        recordAppendRenderableProof(.raster_enqueue, &proof.raster_enqueue_ns, raster_enqueue_start_ns);
    }
    return residency;
}

fn blankFastReturn(driver: Driver, text: contract.CellText) bool {
    const sprite_draw_count = driver.scratch.sprite_draws.items.len;
    const blank_fast_return_start_ns = timeNowNs();
    if (text.first_cp == 0 or text.first_cp == '\t') {
        recordAppendRenderableProof(.blank_fast_return, &proof.blank_fast_return_ns, blank_fast_return_start_ns);
        std.debug.assert(driver.scratch.sprite_draws.items.len == sprite_draw_count);
        return true;
    }
    recordAppendRenderableProof(.blank_fast_return, &proof.blank_fast_return_ns, blank_fast_return_start_ns);
    return false;
}

fn spriteAppend(
    driver: Driver,
    renderable: contract.RenderableCell,
    grid_metrics: contract.GridMetrics,
    session: font_session.FontSession,
    lane_report: *lane.LaneReport,
    lookup: provider.LookupGlyphResult,
    residency: atlas_cache.ReserveResult,
    span: u8,
) void {
    const sprite_append_start_ns = timeNowNs();
    const cols = @max(@as(u32, grid_metrics.cols), 1);
    const col = renderable.first_cell % cols;
    const row = renderable.first_cell / cols;
    driver.scratch.sprite_draws.appendAssumeCapacity(.{
        .sprite = residency.position,
        .x_px = @as(i32, @intCast(col * @as(u32, session.metrics.cell_w_px))),
        .y_px = @as(i32, @intCast(row * @as(u32, session.metrics.cell_h_px))),
        .width_px = @intCast(@as(u32, span) * @as(u32, session.metrics.cell_w_px)),
        .height_px = session.metrics.cell_h_px,
        .placement = .{ .advance_px = @max(lookup.advance_px, @as(f32, @floatFromInt(@as(u32, span) * @as(u32, session.metrics.cell_w_px)))) },
        .color = scene.spriteDrawColor(renderable),
        .first_cell = renderable.first_cell,
        .cell_span = span,
    });
    recordAppendRenderableProof(.sprite_append, &proof.sprite_append_ns, sprite_append_start_ns);
    const lane_report_update_start_ns = timeNowNs();
    lane_report.direct_normal_draws += 1;
    recordAppendRenderableProof(.lane_report_update, &proof.lane_report_update_ns, lane_report_update_start_ns);
}

fn assertNoPartialDrawState(scratch: *const Scratch) void {
    std.debug.assert(scratchEmpty(scratch));
}

fn checkpointScratch(scratch: *const Scratch) ScratchCheckpoint {
    return .{
        .missing_len = scratch.missing.items.len,
        .sprite_draws_len = scratch.sprite_draws.items.len,
        .background_draws_len = scratch.background_draws.items.len,
        .clear_draws_len = scratch.clear_draws.items.len,
        .decoration_draws_len = scratch.decoration_draws.items.len,
        .cursor_draws_len = scratch.cursor_draws.items.len,
        .raster_reqs_len = scratch.raster_reqs.items.len,
    };
}

fn restoreScratch(scratch: *Scratch, checkpoint: ScratchCheckpoint) void {
    scratch.missing.items.len = checkpoint.missing_len;
    scratch.sprite_draws.items.len = checkpoint.sprite_draws_len;
    scratch.background_draws.items.len = checkpoint.background_draws_len;
    scratch.clear_draws.items.len = checkpoint.clear_draws_len;
    scratch.decoration_draws.items.len = checkpoint.decoration_draws_len;
    scratch.cursor_draws.items.len = checkpoint.cursor_draws_len;
    scratch.raster_reqs.items.len = checkpoint.raster_reqs_len;
    scratch.background_merge_live = false;
    scratch.background_merge_end_cell = 0;
    @memset(scratch.clear_row_matches.items, false);
    for (scratch.clear_row_colors.items) |*color| color.* = .{ .r = 0, .g = 0, .b = 0, .a = 255 };
}

fn scratchEmpty(scratch: *const Scratch) bool {
    std.debug.assert(scratch.missing.items.len == 0);
    std.debug.assert(scratch.sprite_draws.items.len == 0);
    std.debug.assert(scratch.background_draws.items.len == 0);
    std.debug.assert(scratch.clear_draws.items.len == 0);
    std.debug.assert(scratch.decoration_draws.items.len == 0);
    std.debug.assert(scratch.cursor_draws.items.len == 0);
    std.debug.assert(scratch.raster_reqs.items.len == 0);
    return true;
}

fn finishScene(driver: Driver, damage: direct_scene.Damage, lane_report: *lane.LaneReport) !Product {
    var outputs: []rasterizer.RasterSpriteOutput = &.{};
    var outputs_owned = false;
    if (driver.scratch.raster_reqs.items.len > 0) {
        lane_report.direct_normal_raster_misses = @intCast(driver.scratch.raster_reqs.items.len);
        outputs = try driver.allocator.alloc(rasterizer.RasterSpriteOutput, driver.scratch.raster_reqs.items.len);
        outputs_owned = true;
        var filled: u32 = 0;
        errdefer {
            for (outputs[0..@intCast(filled)]) |*out| out.deinit();
            driver.allocator.free(outputs);
        }
        for (driver.scratch.raster_reqs.items, 0..) |req, idx| {
            var raster = try driver.glyph_raster.rasterize(driver.allocator, req);
            outputs[idx] = .{ .allocator = raster.allocator, .key = .{ .value = req.atlas_key }, .width_px = raster.width_px, .height_px = raster.height_px, .pixels = raster.alpha_mask };
            raster.alpha_mask = &.{};
            filled += 1;
        }
    }
    return .{ .damage = damage, .outputs = outputs, .outputs_owned = outputs_owned };
}

fn resolveFace(session: font_session.FontSession, cell: contract.RenderableCell, text: contract.CellText) ?font_session.FontFaceRecord {
    if (isPlainAsciiText(text)) return session.primary();
    return session.findStyle(cell.style, cell.presentation, text) orelse session.findFallback(cell.style, cell.presentation, text);
}

fn isPlainAsciiText(text: contract.CellText) bool {
    const cps = if (text.codepoints.len == 0) &[_]u32{text.first_cp} else text.codepoints;
    for (cps) |cp| {
        if (cp == ' ' or cp == '\t') continue;
        if (cp < 0x20 or cp >= 0x7f) return false;
    }
    return true;
}

fn count32(items: anytype) u32 {
    std.debug.assert(items.len <= std.math.maxInt(u32));
    return @intCast(items.len);
}

fn blankText(text: contract.CellText) bool {
    for (text.codepoints) |cp| {
        if (cp != 0 and cp != ' ') return false;
    }
    return true;
}

fn testPublicationCell(codepoint: u32) source_vt.SourceCell {
    return .{
        .codepoint = codepoint,
        .flags = .{ .continuation = 0 },
        .fg_color = .{ .kind = 0, .value = 0 },
        .bg_color = .{ .kind = 0, .value = 0 },
        .underline_color = .{ .kind = 0, .value = 0 },
        .underline_style = 0,
        .attrs = .{ .bold = 0, .dim = 0, .italic = 0, .underline = 0, .underline_color_set = 0, .blink = 0, .inverse = 0, .invisible = 0, .strikethrough = 0, .selected = 0 },
        .link_id = 0,
    };
}

fn testPublicationTheme() source_theme.SurfaceTheme {
    return source_theme.themeFromPublicationColors(std.mem.zeroes(source_vt.SourceColors));
}

fn testRenderableCell(first_cell: u32) contract.RenderableCell {
    return .{
        .text_id = .{ .value = 1 },
        .first_cell = first_cell,
        .cell_span = 1,
        .style = .regular,
        .presentation = .any,
        .fg = .{ .r = 1, .g = 2, .b = 3, .a = 255 },
        .bg = .{ .r = 4, .g = 5, .b = 6, .a = 255 },
    };
}

fn testCellText(codepoint: u32, codepoints: []const u32) contract.CellText {
    return .{
        .id = .{ .value = 1 },
        .first_cp = codepoint,
        .codepoints = codepoints,
    };
}

fn testFontSession(faces: []const font_session.FontFaceRecord) font_session.FontSession {
    return .{
        .faces = faces,
        .metrics = .{ .cell_w_px = 8, .cell_h_px = 16, .baseline_px = 12 },
    };
}

test "direct normal publication zero codepoint is a fast candidate" {
    const cells = [_]source_vt.SourceCell{testPublicationCell(0)};
    const decision = publicationCandidate(cells[0..], testPublicationTheme(), 0, direct_scene.Damage.init(.{}, 1), .{ .cols = 1, .rows = 1 });

    switch (decision) {
        .candidate => |candidate| {
            try std.testing.expectEqual(@as(u32, 0), candidate.item.text.first_cp);
            try std.testing.expectEqual(@as(usize, 1), candidate.item.text.codepoints.len);
            try std.testing.expectEqual(@as(u32, 0), candidate.item.text.codepoints[0]);
            try std.testing.expectEqual(lane.RenderableClass.normal, candidate.choice.renderableClass());
        },
        else => return error.TestUnexpectedResult,
    }
}

test "direct normal publication keeps unsupported non-printables on generic fallback" {
    const cases = [_]u32{ '\t', 0x1f };
    for (cases) |codepoint| {
        const cells = [_]source_vt.SourceCell{testPublicationCell(codepoint)};
        const decision = publicationCandidate(cells[0..], testPublicationTheme(), 0, direct_scene.Damage.init(.{}, 1), .{ .cols = 1, .rows = 1 });
        try std.testing.expectEqual(PublicationCandidate.unsupported, decision);
    }
}

test "direct normal renderable append tab fast return leaves sprite raster missing and lane state unchanged" {
    var scratch = Scratch{};
    defer scratch.deinit(std.testing.allocator);
    try scratch.reset(std.testing.allocator, 1, 1, 1);

    var atlas = try atlas_cache.OwnedAtlasCache.init(std.testing.allocator, 4);
    defer atlas.deinit();

    var lane_report = lane.LaneReport{};
    const tab = [_]u32{'\t'};
    const driver = Driver{
        .allocator = std.testing.allocator,
        .atlas = &atlas,
        .glyph_lookup = provider.defaultLookupGlyph(),
        .glyph_raster = provider.defaultGlyphRaster(),
        .scratch = &scratch,
    };

    try renderableAppend(driver, testRenderableCell(0), testCellText('\t', tab[0..]), .{ .cols = 1, .rows = 1 }, testFontSession(&.{}), &lane_report);

    try std.testing.expectEqual(@as(usize, 0), scratch.sprite_draws.items.len);
    try std.testing.expectEqual(@as(usize, 0), scratch.raster_reqs.items.len);
    try std.testing.expectEqual(@as(usize, 0), scratch.missing.items.len);
    try std.testing.expectEqual(@as(u64, 0), lane_report.direct_normal_draws);
}

test "direct normal renderable append zero codepoint fast return leaves sprite raster missing and lane state unchanged" {
    var scratch = Scratch{};
    defer scratch.deinit(std.testing.allocator);
    try scratch.reset(std.testing.allocator, 1, 1, 1);

    var atlas = try atlas_cache.OwnedAtlasCache.init(std.testing.allocator, 4);
    defer atlas.deinit();

    var lane_report = lane.LaneReport{};
    const zero = [_]u32{0};
    const faces = [_]font_session.FontFaceRecord{
        .{ .id = .{ .value = 1 }, .role = .primary, .coverage = .{ .range = .{ .first = 'a', .last = 'z' } } },
    };
    const driver = Driver{
        .allocator = std.testing.allocator,
        .atlas = &atlas,
        .glyph_lookup = provider.defaultLookupGlyph(),
        .glyph_raster = provider.defaultGlyphRaster(),
        .scratch = &scratch,
    };

    try renderableAppend(driver, testRenderableCell(0), testCellText(0, zero[0..]), .{ .cols = 1, .rows = 1 }, testFontSession(&faces), &lane_report);

    try std.testing.expectEqual(@as(usize, 0), scratch.sprite_draws.items.len);
    try std.testing.expectEqual(@as(usize, 0), scratch.raster_reqs.items.len);
    try std.testing.expectEqual(@as(usize, 0), scratch.missing.items.len);
    try std.testing.expectEqual(@as(u64, 0), lane_report.direct_normal_draws);
}

test "direct normal renderable append missing face appends no fallback glyph and returns early" {
    var scratch = Scratch{};
    defer scratch.deinit(std.testing.allocator);
    try scratch.reset(std.testing.allocator, 1, 1, 1);

    var atlas = try atlas_cache.OwnedAtlasCache.init(std.testing.allocator, 4);
    defer atlas.deinit();

    var lane_report = lane.LaneReport{};
    const snowman = [_]u32{0x2603};
    const faces = [_]font_session.FontFaceRecord{
        .{ .id = .{ .value = 1 }, .role = .primary, .coverage = .{ .range = .{ .first = 'a', .last = 'z' } } },
    };
    const driver = Driver{
        .allocator = std.testing.allocator,
        .atlas = &atlas,
        .glyph_lookup = provider.defaultLookupGlyph(),
        .glyph_raster = provider.defaultGlyphRaster(),
        .scratch = &scratch,
    };

    try renderableAppend(driver, testRenderableCell(0), testCellText(0x2603, snowman[0..]), .{ .cols = 1, .rows = 1 }, testFontSession(&faces), &lane_report);

    try std.testing.expectEqual(@as(usize, 1), scratch.missing.items.len);
    try std.testing.expectEqual(contract.MissingGlyphReason.no_fallback_face, scratch.missing.items[0].reason);
    try std.testing.expectEqual(@as(usize, 0), scratch.sprite_draws.items.len);
    try std.testing.expectEqual(@as(usize, 0), scratch.raster_reqs.items.len);
    try std.testing.expectEqual(@as(u64, 0), lane_report.direct_normal_draws);
}

test "direct normal renderable append pending atlas reserve appends matching raster request and sprite draw" {
    var scratch = Scratch{};
    defer scratch.deinit(std.testing.allocator);
    try scratch.reset(std.testing.allocator, 4, 4, 1);

    var atlas = try atlas_cache.OwnedAtlasCache.init(std.testing.allocator, 4);
    defer atlas.deinit();

    var lane_report = lane.LaneReport{};
    const ascii = [_]u32{'a'};
    const faces = [_]font_session.FontFaceRecord{
        .{ .id = .{ .value = 7 }, .role = .primary, .coverage = .{ .range = .{ .first = 'a', .last = 'z' } } },
    };
    const renderable = testRenderableCell(0);
    const text = testCellText('a', ascii[0..]);
    const session = testFontSession(&faces);
    const driver = Driver{
        .allocator = std.testing.allocator,
        .atlas = &atlas,
        .glyph_lookup = provider.defaultLookupGlyph(),
        .glyph_raster = provider.defaultGlyphRaster(),
        .scratch = &scratch,
    };

    try renderableAppend(driver, renderable, text, .{ .cols = 1, .rows = 1 }, session, &lane_report);

    const lookup = driver.glyph_lookup.lookupGlyph(faces[0].id, text.first_cp, session.metrics);
    const span = @max(renderable.cell_span, 1);
    const key = sprite_key.hashGlyphLocal(faces[0].id, lookup.glyph_id, span, session.metrics);

    try std.testing.expectEqual(@as(usize, 1), scratch.sprite_draws.items.len);
    try std.testing.expectEqual(@as(usize, 1), scratch.raster_reqs.items.len);
    try std.testing.expectEqual(@as(usize, 0), scratch.missing.items.len);
    try std.testing.expectEqual(@as(u64, 1), lane_report.direct_normal_draws);
    try std.testing.expectEqual(faces[0].id.value, scratch.raster_reqs.items[0].face_id);
    try std.testing.expectEqual(lookup.glyph_id, scratch.raster_reqs.items[0].glyph_id);
    try std.testing.expectEqual(key.value, scratch.raster_reqs.items[0].atlas_key);
    try std.testing.expectEqualDeep(session.metrics, scratch.raster_reqs.items[0].cell_metrics);
    try std.testing.expectEqual(span, scratch.raster_reqs.items[0].cell_span);
}

test "direct normal renderable append widened span preserves key raster request and sprite draw span" {
    var scratch = Scratch{};
    defer scratch.deinit(std.testing.allocator);
    try scratch.reset(std.testing.allocator, 4, 4, 1);

    var atlas = try atlas_cache.OwnedAtlasCache.init(std.testing.allocator, 4);
    defer atlas.deinit();

    var lane_report = lane.LaneReport{};
    const ascii = [_]u32{'a'};
    const faces = [_]font_session.FontFaceRecord{
        .{ .id = .{ .value = 7 }, .role = .primary, .coverage = .{ .range = .{ .first = 'a', .last = 'z' } } },
    };
    var renderable = testRenderableCell(0);
    renderable.cell_span = 3;
    const text = testCellText('a', ascii[0..]);
    const session = testFontSession(&faces);
    const driver = Driver{
        .allocator = std.testing.allocator,
        .atlas = &atlas,
        .glyph_lookup = provider.defaultLookupGlyph(),
        .glyph_raster = provider.defaultGlyphRaster(),
        .scratch = &scratch,
    };

    const lookup = lookupGlyph(driver, text, session, faces[0]);
    const resolved = deriveResolvedGlyphKey(renderable, session, faces[0], lookup);
    const expected_key = sprite_key.hashGlyphLocal(faces[0].id, lookup.glyph_id, renderable.cell_span, session.metrics);

    try std.testing.expectEqual(@as(u8, 3), resolved.span);
    try std.testing.expectEqual(expected_key.value, resolved.key.value);

    appendResolvedGlyph(driver, renderable, text, .{ .cols = 1, .rows = 1 }, session, &lane_report, faces[0]);

    try std.testing.expectEqual(@as(usize, 1), scratch.raster_reqs.items.len);
    try std.testing.expectEqual(@as(u8, 3), scratch.raster_reqs.items[0].cell_span);
    try std.testing.expectEqual(@as(usize, 1), scratch.sprite_draws.items.len);
    try std.testing.expectEqual(@as(u8, 3), scratch.sprite_draws.items[0].cell_span);
    try std.testing.expectEqual(@as(u32, 24), scratch.sprite_draws.items[0].width_px);
}

test "direct normal renderable append rendered atlas hit appends sprite draw without raster request" {
    var scratch = Scratch{};
    defer scratch.deinit(std.testing.allocator);
    try scratch.reset(std.testing.allocator, 4, 4, 1);

    var atlas = try atlas_cache.OwnedAtlasCache.init(std.testing.allocator, 4);
    defer atlas.deinit();

    var lane_report = lane.LaneReport{};
    const ascii = [_]u32{'a'};
    const faces = [_]font_session.FontFaceRecord{
        .{ .id = .{ .value = 7 }, .role = .primary, .coverage = .{ .range = .{ .first = 'a', .last = 'z' } } },
    };
    const renderable = testRenderableCell(0);
    const text = testCellText('a', ascii[0..]);
    const session = testFontSession(&faces);
    const driver = Driver{
        .allocator = std.testing.allocator,
        .atlas = &atlas,
        .glyph_lookup = provider.defaultLookupGlyph(),
        .glyph_raster = provider.defaultGlyphRaster(),
        .scratch = &scratch,
    };

    try renderableAppend(driver, renderable, text, .{ .cols = 1, .rows = 1 }, session, &lane_report);

    const lookup = driver.glyph_lookup.lookupGlyph(faces[0].id, text.first_cp, session.metrics);
    const span = @max(renderable.cell_span, 1);
    const key = sprite_key.hashGlyphLocal(faces[0].id, lookup.glyph_id, span, session.metrics);

    try std.testing.expectEqual(@as(usize, 1), scratch.raster_reqs.items.len);
    try std.testing.expectEqual(@as(usize, 1), scratch.sprite_draws.items.len);
    try std.testing.expect(atlas.markRendered(key));

    try renderableAppend(driver, renderable, text, .{ .cols = 1, .rows = 1 }, session, &lane_report);

    try std.testing.expectEqual(@as(usize, 2), scratch.sprite_draws.items.len);
    try std.testing.expectEqual(@as(usize, 1), scratch.raster_reqs.items.len);
    try std.testing.expectEqual(@as(usize, 0), scratch.missing.items.len);
    try std.testing.expectEqual(@as(u64, 2), lane_report.direct_normal_draws);
}

test "direct normal renderable append updates direct normal draws only on sprite append" {
    var scratch = Scratch{};
    defer scratch.deinit(std.testing.allocator);
    try scratch.reset(std.testing.allocator, 4, 4, 1);

    var atlas = try atlas_cache.OwnedAtlasCache.init(std.testing.allocator, 4);
    defer atlas.deinit();

    var lane_report = lane.LaneReport{};
    const ascii = [_]u32{'a'};
    const zero = [_]u32{0};
    const tab = [_]u32{'\t'};
    const snowman = [_]u32{0x2603};
    const faces = [_]font_session.FontFaceRecord{
        .{ .id = .{ .value = 1 }, .role = .primary, .coverage = .{ .range = .{ .first = 'a', .last = 'z' } } },
    };
    const driver = Driver{
        .allocator = std.testing.allocator,
        .atlas = &atlas,
        .glyph_lookup = provider.defaultLookupGlyph(),
        .glyph_raster = provider.defaultGlyphRaster(),
        .scratch = &scratch,
    };

    try renderableAppend(driver, testRenderableCell(0), testCellText('a', ascii[0..]), .{ .cols = 1, .rows = 1 }, testFontSession(&faces), &lane_report);
    try std.testing.expectEqual(@as(u64, 1), lane_report.direct_normal_draws);

    try renderableAppend(driver, testRenderableCell(1), testCellText(0, zero[0..]), .{ .cols = 1, .rows = 1 }, testFontSession(&faces), &lane_report);
    try std.testing.expectEqual(@as(u64, 1), lane_report.direct_normal_draws);

    try renderableAppend(driver, testRenderableCell(2), testCellText('\t', tab[0..]), .{ .cols = 1, .rows = 1 }, testFontSession(&faces), &lane_report);
    try std.testing.expectEqual(@as(u64, 1), lane_report.direct_normal_draws);

    try renderableAppend(driver, testRenderableCell(3), testCellText(0x2603, snowman[0..]), .{ .cols = 1, .rows = 1 }, testFontSession(&faces), &lane_report);
    try std.testing.expectEqual(@as(u64, 1), lane_report.direct_normal_draws);
}
