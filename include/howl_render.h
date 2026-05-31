#ifndef HOWL_RENDER_H
#define HOWL_RENDER_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct HowlRenderTextSession HowlRenderTextSession;
typedef struct HowlRenderPreparedSurfaceObject HowlRenderPreparedSurfaceObject;

typedef HowlRenderTextSession *HowlRenderTextSessionHandle;
typedef HowlRenderPreparedSurfaceObject *HowlRenderPreparedSurfaceHandle;

#define HOWL_RENDER_MAX_FALLBACK_FONTS 24

#define HOWL_RENDER_PROTOCOL_V0_VERSION 0
#define HOWL_RENDER_V0_FRAMES_IN_FLIGHT_MAX 2
#define HOWL_RENDER_V0_SNAPSHOTS_IN_FLIGHT_MAX 2
#define HOWL_RENDER_V0_DAMAGE_ITEMS_MAX 1024
#define HOWL_RENDER_V0_UPLOADS_MAX 256
#define HOWL_RENDER_V0_COMMANDS_MAX 8192
#define HOWL_RENDER_V0_GLYPHS_PER_RUN_MAX 256
#define HOWL_RENDER_V0_UPLOAD_BYTES_MAX 8388608
#define HOWL_RENDER_V0_ATLAS_PAGES_MAX 64
#define HOWL_RENDER_V0_RESOURCES_MAX 4096
#define HOWL_RENDER_V0_CREATES_MAX 256
#define HOWL_RENDER_V0_RETIRES_MAX 256
#define HOWL_RENDER_V0_HOST_ACKS_MAX 256

#define HOWL_RENDER_V0_DAMAGE_RECT 1
#define HOWL_RENDER_V0_DAMAGE_FULL 2
#define HOWL_RENDER_V0_RESOURCE_GLYPH_ATLAS_ALPHA 1
#define HOWL_RENDER_V0_RESOURCE_GLYPH_ATLAS_COLOR 2
#define HOWL_RENDER_V0_RESOURCE_SPRITE_ALPHA 3
#define HOWL_RENDER_V0_RESOURCE_SPRITE_COLOR 4
#define HOWL_RENDER_V0_RESOURCE_FALLBACK_RGBA 5
#define HOWL_RENDER_V0_UPLOAD_ALPHA8 1
#define HOWL_RENDER_V0_UPLOAD_RGBA8 2
#define HOWL_RENDER_V0_COMMAND_CLEAR_RECT 1
#define HOWL_RENDER_V0_COMMAND_FILL_RECT 2
#define HOWL_RENDER_V0_COMMAND_DRAW_GLYPH_RUN 3
#define HOWL_RENDER_V0_COMMAND_DRAW_SPRITE 4

typedef enum {
    HOWL_RENDER_CALL_OK = 0,
    HOWL_RENDER_CALL_MISSING_HANDLE = -1,
    HOWL_RENDER_CALL_INVALID_ARGUMENT = -2,
    HOWL_RENDER_CALL_FAILED = -3,
} HowlRenderCallStatus;

typedef enum {
    HOWL_RENDER_PREPARE_IDLE = 0,
    HOWL_RENDER_PREPARE_READY = 1,
    HOWL_RENDER_PREPARE_FAILED = -3,
} HowlRenderPrepareStatus;

typedef enum {
    HOWL_RENDER_SUBMIT_IDLE = 0,
    HOWL_RENDER_SUBMIT_RENDERED = 1,
    HOWL_RENDER_SUBMIT_STALE = 2,
    HOWL_RENDER_SUBMIT_NEEDS_PREPARE = 3,
    HOWL_RENDER_SUBMIT_FAILED = -3,
} HowlRenderSubmitStatus;

typedef enum {
    HOWL_RENDER_SUBMIT_DECISION_IDLE = 0,
    HOWL_RENDER_SUBMIT_DECISION_SUBMIT = 1,
    HOWL_RENDER_SUBMIT_DECISION_STALE = 2,
    HOWL_RENDER_SUBMIT_DECISION_NEEDS_PREPARE = 3,
    HOWL_RENDER_SUBMIT_DECISION_FAILED = -3,
} HowlRenderSubmitDecisionStatus;

typedef enum {
    HOWL_RENDER_DAMAGE_NONE = 0,
    HOWL_RENDER_DAMAGE_PARTIAL = 1,
    HOWL_RENDER_DAMAGE_FULL = 3,
} HowlRenderDamageKind;

typedef struct {
    uint16_t width;
    uint16_t height;
} HowlRenderPixelSize;

typedef struct {
    uint16_t width;
    uint16_t height;
} HowlRenderCellSize;

typedef struct {
    uint8_t r;
    uint8_t g;
    uint8_t b;
    uint8_t a;
} HowlRenderRgba8;

typedef struct {
    uint16_t cols;
    uint16_t rows;
} HowlRenderGridSize;

typedef struct {
    int32_t x_px;
    int32_t y_px;
    uint16_t width_px;
    uint16_t height_px;
    HowlRenderRgba8 color;
} HowlRenderColorDraw;

typedef struct {
    uint8_t kind;
    uint8_t reserved0;
    uint16_t reserved1;
    int32_t x_px;
    int32_t y_px;
    uint16_t width_px;
    uint16_t height_px;
    HowlRenderRgba8 color;
} HowlRenderDecorationDraw;

typedef struct {
    uint16_t x_px;
    uint16_t y_px;
    uint16_t width_px;
    uint16_t height_px;
} HowlRenderRasterBounds;

typedef struct {
    const HowlRenderColorDraw *ptr;
    size_t len;
} HowlRenderColorDrawSpan;

typedef struct {
    const HowlRenderDecorationDraw *ptr;
    size_t len;
} HowlRenderDecorationDrawSpan;

typedef struct {
    const uint8_t *ptr;
    size_t len;
} HowlRenderByteSpan;

typedef struct {
    const uint16_t *ptr;
    size_t len;
} HowlRenderU16Span;

typedef struct {
    int status;
    HowlRenderCellSize cell_px;
    HowlRenderGridSize grid;
} HowlRenderLayoutResult;

typedef struct {
    uint8_t *ptr;
    size_t len;
} HowlRenderByteWriteSpan;

typedef struct {
    uint16_t *ptr;
    size_t len;
} HowlRenderU16WriteSpan;

typedef struct {
    HowlRenderPixelSize render_px;
    HowlRenderPixelSize grid_px;
} HowlRenderGeometry;

typedef struct HowlRenderV0Token {
    uint64_t snapshot_seq;
    uint64_t frame_seq;
    uint64_t geometry_epoch;
    uint64_t resource_epoch;
} HowlRenderV0Token;

typedef struct HowlRenderV0Rect {
    int32_t x_px;
    int32_t y_px;
    uint16_t width_px;
    uint16_t height_px;
} HowlRenderV0Rect;

typedef struct HowlRenderV0DamageItem {
    uint8_t kind;
    uint8_t reserved0;
    uint16_t reserved1;
    HowlRenderV0Rect rect;
} HowlRenderV0DamageItem;

typedef struct HowlRenderV0DamageSpan {
    const HowlRenderV0DamageItem *ptr;
    uint32_t count;
    uint32_t count_max;
} HowlRenderV0DamageSpan;

typedef struct HowlRenderV0ResourceId {
    uint64_t value;
    uint32_t generation;
    uint32_t kind;
} HowlRenderV0ResourceId;

typedef struct HowlRenderV0Upload {
    HowlRenderV0ResourceId resource;
    HowlRenderV0Rect rect;
    const uint8_t *bytes_ptr;
    uint32_t bytes_count;
    uint32_t stride_bytes;
    uint32_t format;
    uint32_t upload_seq;
} HowlRenderV0Upload;

typedef struct HowlRenderV0UploadSpan {
    const HowlRenderV0Upload *ptr;
    uint32_t count;
    uint32_t count_max;
    uint32_t bytes_count_total;
    uint32_t bytes_count_max;
} HowlRenderV0UploadSpan;

typedef struct HowlRenderV0Create {
    HowlRenderV0ResourceId resource;
    uint32_t width_px;
    uint32_t height_px;
    uint32_t format;
    uint64_t create_seq;
} HowlRenderV0Create;

typedef struct HowlRenderV0CreateSpan {
    const HowlRenderV0Create *ptr;
    uint32_t count;
    uint32_t count_max;
} HowlRenderV0CreateSpan;

typedef struct HowlRenderV0GlyphRef {
    HowlRenderV0ResourceId atlas_resource;
    HowlRenderV0Rect atlas_rect;
    int32_t x_px;
    int32_t y_px;
    uint32_t glyph_id;
    uint32_t color_rgba;
} HowlRenderV0GlyphRef;

typedef struct HowlRenderV0GlyphRunSpan {
    const HowlRenderV0GlyphRef *ptr;
    uint32_t count;
    uint32_t count_max;
} HowlRenderV0GlyphRunSpan;

typedef struct HowlRenderV0Command {
    uint8_t kind;
    uint8_t reserved0;
    uint16_t reserved1;
    HowlRenderV0Rect rect;
    uint32_t color_rgba;
    HowlRenderV0ResourceId resource;
    HowlRenderV0GlyphRunSpan glyphs;
} HowlRenderV0Command;

typedef struct HowlRenderV0CommandSpan {
    const HowlRenderV0Command *ptr;
    uint32_t count;
    uint32_t count_max;
} HowlRenderV0CommandSpan;

typedef struct HowlRenderV0Retire {
    HowlRenderV0ResourceId resource;
    uint64_t retire_seq;
} HowlRenderV0Retire;

typedef struct HowlRenderV0RetireSpan {
    const HowlRenderV0Retire *ptr;
    uint32_t count;
    uint32_t count_max;
} HowlRenderV0RetireSpan;

typedef struct HowlRenderV0HostAck {
    HowlRenderV0ResourceId resource;
    uint64_t ack_seq;
} HowlRenderV0HostAck;

typedef struct HowlRenderV0HostAckSpan {
    const HowlRenderV0HostAck *ptr;
    uint32_t count;
    uint32_t count_max;
} HowlRenderV0HostAckSpan;

typedef struct HowlRenderV0Frame {
    uint32_t protocol_version;
    uint32_t reserved0;
    HowlRenderV0Token token;
    HowlRenderPixelSize render_px;
    HowlRenderCellSize cell_px;
    HowlRenderGridSize grid;
    HowlRenderV0DamageSpan damage;
    HowlRenderV0CreateSpan creates;
    HowlRenderV0UploadSpan uploads;
    HowlRenderV0CommandSpan commands;
    HowlRenderV0RetireSpan retires;
} HowlRenderV0Frame;

typedef struct {
    int32_t status;
    uint8_t changed;
    uint8_t reserved0;
    uint8_t reserved1;
    uint8_t reserved2;
    uint32_t reserved3;
    HowlRenderPixelSize render_px;
    HowlRenderPixelSize grid_px;
    HowlRenderCellSize cell_px;
    uint64_t geometry_epoch;
} HowlRenderGeometryResponse;

typedef struct {
    int32_t status;
    uint8_t source_pending;
    uint8_t prepare_pending;
    uint8_t submit_pending;
    uint8_t reserved0;
} HowlRenderSessionWorkState;

typedef struct {
    uint64_t snapshot_seq;
    uint64_t dirty_epoch;
    uint64_t geometry_epoch;
    uint64_t damage_base_seq;
    uint8_t damage_kind;
    uint8_t reserved0;
    uint16_t reserved1;
} HowlRenderPrepareRequest;

typedef struct {
    uint64_t snapshot_seq;
    uint64_t dirty_epoch;
    uint64_t geometry_epoch;
    uint64_t damage_base_seq;
    uint64_t required_base_seq;
    uint8_t damage_kind;
    uint8_t reserved0;
    uint16_t reserved1;
} HowlRenderPreparedSurfaceToken;

typedef struct {
    int32_t status;
    uint8_t published;
    uint8_t queued;
    uint8_t damage_kind;
    uint8_t reserved0;
    uint64_t snapshot_seq;
    uint64_t geometry_epoch;
} HowlRenderVtSurfacePublishResult;

typedef struct {
    uint8_t r;
    uint8_t g;
    uint8_t b;
} HowlRenderSourceRgb;

typedef struct {
    uint8_t kind;
    uint8_t reserved0;
    uint8_t reserved1;
    uint8_t reserved2;
    uint32_t value;
} HowlRenderSourceColor;

typedef struct {
    uint8_t continuation;
    uint8_t reserved0;
    uint8_t reserved1;
    uint8_t reserved2;
} HowlRenderSourceCellFlags;

typedef struct {
    uint8_t bold;
    uint8_t dim;
    uint8_t italic;
    uint8_t underline;
    uint8_t underline_color_set;
    uint8_t blink;
    uint8_t inverse;
    uint8_t invisible;
    uint8_t strikethrough;
    uint8_t selected;
} HowlRenderSourceCellAttrs;

typedef struct {
    uint32_t codepoint;
    uint8_t combining_len;
    uint8_t reserved0;
    uint8_t reserved1;
    uint8_t reserved2;
    uint32_t combining[3];
    HowlRenderSourceCellFlags flags;
    HowlRenderSourceColor fg_color;
    HowlRenderSourceColor bg_color;
    HowlRenderSourceColor underline_color;
    uint8_t underline_style;
    uint8_t reserved3;
    uint8_t reserved4;
    uint8_t reserved5;
    HowlRenderSourceCellAttrs attrs;
    uint32_t link_id;
} HowlRenderSourceCell;

typedef struct {
    HowlRenderSourceRgb foreground;
    HowlRenderSourceRgb background;
    HowlRenderSourceRgb cursor;
    HowlRenderSourceRgb palette[256];
} HowlRenderSourceColors;

typedef struct {
    int32_t row;
    uint16_t col;
    uint16_t reserved0;
} HowlRenderSourceSelectionPos;

typedef struct {
    uint8_t active;
    uint8_t selecting;
    uint16_t reserved0;
    HowlRenderSourceSelectionPos start;
    HowlRenderSourceSelectionPos end;
} HowlRenderSourceSelection;

typedef struct {
    uint16_t row;
    uint16_t col;
    uint8_t visible;
    uint8_t shape;
    uint8_t blink;
    uint8_t reserved0;
} HowlRenderSourceCursor;

typedef struct {
    HowlRenderSourceCell *ptr;
    size_t len;
} HowlRenderVtCellWriteSpan;

typedef struct {
    HowlRenderVtCellWriteSpan cells;
    HowlRenderByteWriteSpan dirty_rows;
    HowlRenderU16WriteSpan dirty_cols_start;
    HowlRenderU16WriteSpan dirty_cols_end;
} HowlRenderVtSurfaceSlot;

typedef struct {
    uint64_t history_count;
    uint64_t scroll_row;
    uint64_t snapshot_seq;
    uint8_t is_alternate_screen;
    uint8_t reserved0;
    uint16_t reserved1;
    HowlRenderSourceCursor cursor;
    HowlRenderSourceColors colors;
    HowlRenderSourceSelection selection;
} HowlRenderVtSurfaceCommit;

typedef struct {
    uint64_t sync_us;
    uint64_t copy_us;
    uint64_t render_us;
    uint64_t glyphs;
    uint64_t fills;
    uint64_t clear_fills;
    uint64_t background_fills;
    uint64_t decoration_fills;
    uint64_t cursor_fills;
    uint64_t uploads;
    uint64_t face_checks;
    uint64_t face_cache_hits;
    uint64_t shape_requests;
    uint64_t shape_cache_hits;
    uint64_t fallback_hits;
    uint64_t fallback_misses;
    uint64_t missing_glyphs;
} HowlRenderMetrics;

typedef struct {
    uint64_t host_surface_id;
    uint16_t width;
    uint16_t height;
} HowlRenderHostSurface;

typedef struct {
    int32_t status;
    uint64_t snapshot_seq;
    uint64_t dirty_epoch;
    uint64_t geometry_epoch;
    uint64_t required_base_seq;
    HowlRenderPixelSize render_px;
    HowlRenderCellSize cell_px;
    HowlRenderGridSize grid;
    HowlRenderMetrics prepare_metrics;
    uint8_t damage_kind;
    uint8_t reserved0;
    uint16_t reserved1;
} HowlRenderPreparedSurfaceInfo;

typedef struct {
    int32_t status;
    HowlRenderByteSpan rgba_pixels;
    uint64_t uploads_committed;
} HowlRenderPreparedSurfaceBuffer;

typedef struct {
    int32_t status;
    uint64_t missing_glyphs;
    HowlRenderMetrics resolve_metrics;
} HowlRenderPreparedSurfaceDiagnostics;

typedef struct {
    HowlRenderHostSurface host_surface;
    uint64_t uploads_committed;
    uint64_t render_us;
} HowlRenderSubmitExecution;

typedef struct {
    int32_t status;
    uint8_t damage_kind;
    uint8_t reserved0;
    uint16_t reserved1;
    HowlRenderHostSurface host_surface;
    HowlRenderMetrics metrics;
} HowlRenderSubmitResult;

typedef struct {
    HowlRenderPixelSize surface_px;
    uint16_t font_size_px;
    uint16_t reserved0;
} HowlRenderTextConfig;

HowlRenderTextSessionHandle howl_render_text_session_init(HowlRenderTextConfig config);
void howl_render_text_session_deinit(HowlRenderTextSessionHandle handle);
int howl_render_text_session_set_font_size_px(
    HowlRenderTextSessionHandle handle,
    uint16_t font_size_px
);
int howl_render_text_session_set_font_path(
    HowlRenderTextSessionHandle handle,
    const uint8_t *ptr,
    size_t len
);
int howl_render_text_session_set_fallback_font_paths(
    HowlRenderTextSessionHandle handle,
    const uint8_t *const *ptrs,
    size_t count
);
int howl_render_text_session_set_cursor_blink_visible(
    HowlRenderTextSessionHandle handle,
    uint8_t visible
);
int howl_render_text_session_is_valid_font(HowlRenderTextSessionHandle handle);
HowlRenderLayoutResult howl_render_text_session_derive_layout(
    HowlRenderTextSessionHandle handle,
    HowlRenderPixelSize render_px,
    HowlRenderPixelSize grid_px
);
HowlRenderGeometryResponse howl_render_text_session_sync_geometry(
    HowlRenderTextSessionHandle handle,
    HowlRenderGeometry geometry
);
int howl_render_text_session_reserve_vt_surface_slot(
    HowlRenderTextSessionHandle handle,
    uint16_t cols,
    uint16_t rows,
    HowlRenderVtSurfaceSlot *slot_out
);
HowlRenderVtSurfacePublishResult howl_render_text_session_commit_vt_surface(
    HowlRenderTextSessionHandle handle,
    HowlRenderVtSurfaceCommit commit
);
HowlRenderVtSurfacePublishResult howl_render_text_session_reject_vt_surface(
    HowlRenderTextSessionHandle handle,
    uint64_t snapshot_seq
);
void howl_render_text_session_cancel_vt_surface(HowlRenderTextSessionHandle handle);
HowlRenderPrepareStatus howl_render_text_session_prepare_handle(
    HowlRenderTextSessionHandle text_session_handle,
    HowlRenderPrepareRequest prepare_request,
    HowlRenderPreparedSurfaceHandle *prepared_handle_out
);
HowlRenderPrepareStatus howl_render_text_session_take_prepare_request(
    HowlRenderTextSessionHandle handle,
    HowlRenderPrepareRequest *prepare_request_out
);
int howl_render_text_session_publish_prepared(
    HowlRenderTextSessionHandle handle,
    HowlRenderPreparedSurfaceToken prepared_token
);
int howl_render_text_session_publish_prepared_handle(
    HowlRenderTextSessionHandle handle,
    HowlRenderPreparedSurfaceHandle prepared_surface_handle
);
HowlRenderSubmitDecisionStatus howl_render_text_session_take_submit_decision(
    HowlRenderTextSessionHandle handle,
    HowlRenderPreparedSurfaceToken *prepared_token_out
);
HowlRenderSubmitDecisionStatus howl_render_text_session_take_submit_handle(
    HowlRenderTextSessionHandle handle,
    HowlRenderPreparedSurfaceHandle *prepared_surface_handle_out
);
int howl_render_text_session_accept_submitted(
    HowlRenderTextSessionHandle handle,
    HowlRenderPreparedSurfaceToken prepared_token
);
HowlRenderSubmitStatus howl_render_text_session_submit(
    HowlRenderTextSessionHandle text_session_handle,
    HowlRenderPreparedSurfaceHandle prepared_surface_handle,
    HowlRenderPreparedSurfaceToken prepared_token,
    const HowlRenderSubmitExecution *execution_in,
    HowlRenderSubmitResult *result_out
);
HowlRenderSubmitStatus howl_render_text_session_submit_handle(
    HowlRenderTextSessionHandle text_session_handle,
    HowlRenderPreparedSurfaceHandle prepared_surface_handle,
    const HowlRenderSubmitExecution *execution_in,
    HowlRenderSubmitResult *result_out
);
int howl_render_text_session_work_state(
    HowlRenderTextSessionHandle handle,
    HowlRenderSessionWorkState *work_state_out
);

void howl_render_prepared_surface_release(
    HowlRenderPreparedSurfaceHandle prepared_surface_handle
);
int howl_render_prepared_surface_describe(
    HowlRenderPreparedSurfaceHandle prepared_surface_handle,
    HowlRenderPreparedSurfaceInfo *info_out
);
int howl_render_prepared_surface_buffer(
    HowlRenderPreparedSurfaceHandle prepared_surface_handle,
    HowlRenderPreparedSurfaceBuffer *buffer_out
);
int howl_render_prepared_surface_protocol_v0(
    HowlRenderPreparedSurfaceHandle prepared_surface_handle,
    const HowlRenderV0Frame **frame_out
);
int howl_render_prepared_surface_diagnostics(
    HowlRenderPreparedSurfaceHandle prepared_surface_handle,
    HowlRenderPreparedSurfaceDiagnostics *diagnostics_out
);

#ifdef __cplusplus
}
#endif

#endif
