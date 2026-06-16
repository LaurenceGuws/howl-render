#ifndef HOWL_RENDER_H
#define HOWL_RENDER_H

#include <stdint.h>
#include <stddef.h>
#include "howl_vt.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef struct HowlRenderTextSession HowlRenderTextSession;
typedef struct HowlRenderPreparedSurfaceObject HowlRenderPreparedSurfaceObject;

typedef HowlRenderTextSession *HowlRenderTextSessionHandle;
typedef HowlRenderPreparedSurfaceObject *HowlRenderRdrSfcHandle;

#define HOWL_RENDER_MAX_FALLBACK_FONTS 24

#define HOWL_RENDER_SURFACE_VERSION 0
#define HOWL_RENDER_SURFACE_IN_FLIGHT_MAX 2
#define HOWL_RENDER_SURFACE_SNAPSHOTS_IN_FLIGHT_MAX 2
#define HOWL_RENDER_SURFACE_DAMAGE_ITEMS_MAX 1024
#define HOWL_RENDER_SURFACE_UPLOADS_MAX 256
#define HOWL_RENDER_SURFACE_COMMANDS_MAX 8192
#define HOWL_RENDER_SURFACE_GLYPHS_PER_RUN_MAX 256
#define HOWL_RENDER_SURFACE_UPLOAD_BYTES_MAX 8388608
#define HOWL_RENDER_SURFACE_ATLAS_PAGES_MAX 64
#define HOWL_RENDER_SURFACE_RESOURCES_MAX 4096
#define HOWL_RENDER_SURFACE_CREATES_MAX 256
#define HOWL_RENDER_SURFACE_RETIRES_MAX 256
#define HOWL_RENDER_SURFACE_HOST_ACKS_MAX 256
#define HOWL_RENDER_CURSOR_TRAIL_RECTS_MAX 16

#define HOWL_RENDER_SURFACE_DAMAGE_RECT 1
#define HOWL_RENDER_SURFACE_DAMAGE_FULL 2
#define HOWL_RENDER_RESOURCE_GLYPH_ATLAS_ALPHA 1
#define HOWL_RENDER_RESOURCE_GLYPH_ATLAS_COLOR 2
#define HOWL_RENDER_RESOURCE_SPRITE_ALPHA 3
#define HOWL_RENDER_RESOURCE_SPRITE_COLOR 4
#define HOWL_RENDER_UPLOAD_ALPHA8 1
#define HOWL_RENDER_UPLOAD_RGBA8 2
#define HOWL_RENDER_SURFACE_COMMAND_CLEAR_RECT 1
#define HOWL_RENDER_SURFACE_COMMAND_FILL_RECT 2
#define HOWL_RENDER_SURFACE_COMMAND_DRAW_GLYPH_RUN 3
#define HOWL_RENDER_SURFACE_COMMAND_DRAW_SPRITE 4

typedef enum {
    HOWL_RENDER_CALL_OK = 0,
    HOWL_RENDER_CALL_MISSING_HANDLE = -1,
    HOWL_RENDER_CALL_INVALID_ARGUMENT = -2,
    HOWL_RENDER_CALL_FAILED = -3,
} HowlRenderCallStatus;

typedef enum {
    HOWL_RENDER_PREPARED_SURFACE_RENDER_SURFACE_OK = 0,
    HOWL_RENDER_PREPARED_SURFACE_RENDER_SURFACE_MISSING_HANDLE = -1,
    HOWL_RENDER_PREPARED_SURFACE_RENDER_SURFACE_INVALID_ARGUMENT = -2,
    HOWL_RENDER_PREPARED_SURFACE_RENDER_SURFACE_COMMAND_BOUND_OVERFLOW = 1,
    HOWL_RENDER_PREPARED_SURFACE_RENDER_SURFACE_CREATE_BOUND_OVERFLOW = 2,
    HOWL_RENDER_PREPARED_SURFACE_RENDER_SURFACE_DAMAGE_BOUND_OVERFLOW = 3,
    HOWL_RENDER_PREPARED_SURFACE_RENDER_SURFACE_RETIRE_BOUND_OVERFLOW = 4,
    HOWL_RENDER_PREPARED_SURFACE_RENDER_SURFACE_RESOURCE_BOUND_OVERFLOW = 5,
    HOWL_RENDER_PREPARED_SURFACE_RENDER_SURFACE_UPLOAD_BOUND_OVERFLOW = 6,
    HOWL_RENDER_PREPARED_SURFACE_RENDER_SURFACE_UPLOAD_BYTES_OVERFLOW = 7,
    HOWL_RENDER_PREPARED_SURFACE_RENDER_SURFACE_INVALID_PREPARED_SPRITE = 8,
    HOWL_RENDER_PREPARED_SURFACE_RENDER_SURFACE_MISSING_PREPARED_SPRITE = 9,
    HOWL_RENDER_PREPARED_SURFACE_RENDER_SURFACE_ALLOCATION_FAILED = 10,
} HowlRenderPreparedSurfaceRenderSurfaceStatus;

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

typedef struct HowlRenderSurfaceToken {
    uint64_t snapshot_seq;
    uint64_t surface_seq;
    uint64_t geometry_epoch;
    uint64_t resource_epoch;
} HowlRenderSurfaceToken;

typedef struct HowlRenderSurfaceRect {
    int32_t x_px;
    int32_t y_px;
    uint16_t width_px;
    uint16_t height_px;
} HowlRenderSurfaceRect;

typedef struct HowlRenderSurfaceDamageItem {
    uint8_t kind;
    uint8_t reserved0;
    uint16_t reserved1;
    HowlRenderSurfaceRect rect;
} HowlRenderSurfaceDamageItem;

typedef struct HowlRenderSurfaceDamageSpan {
    const HowlRenderSurfaceDamageItem *ptr;
    uint32_t count;
    uint32_t count_max;
} HowlRenderSurfaceDamageSpan;

typedef struct HowlRenderResourceId {
    uint64_t value;
    uint32_t generation;
    uint32_t kind;
} HowlRenderResourceId;

typedef struct HowlRenderResourceUpload {
    HowlRenderResourceId resource;
    HowlRenderSurfaceRect rect;
    const uint8_t *bytes_ptr;
    uint32_t bytes_count;
    uint32_t stride_bytes;
    uint32_t format;
    uint32_t upload_seq;
} HowlRenderResourceUpload;

typedef struct HowlRenderResourceUploadSpan {
    const HowlRenderResourceUpload *ptr;
    uint32_t count;
    uint32_t count_max;
    uint32_t bytes_count_total;
    uint32_t bytes_count_max;
} HowlRenderResourceUploadSpan;

typedef struct HowlRenderResourceCreate {
    HowlRenderResourceId resource;
    uint32_t width_px;
    uint32_t height_px;
    uint32_t format;
    uint64_t create_seq;
} HowlRenderResourceCreate;

typedef struct HowlRenderResourceCreateSpan {
    const HowlRenderResourceCreate *ptr;
    uint32_t count;
    uint32_t count_max;
} HowlRenderResourceCreateSpan;

typedef struct HowlRenderGlyphRef {
    HowlRenderResourceId atlas_resource;
    HowlRenderSurfaceRect atlas_rect;
    int32_t x_px;
    int32_t y_px;
    uint32_t glyph_id;
    uint32_t color_rgba;
} HowlRenderGlyphRef;

typedef struct HowlRenderGlyphRunSpan {
    const HowlRenderGlyphRef *ptr;
    uint32_t count;
    uint32_t count_max;
} HowlRenderGlyphRunSpan;

typedef struct HowlRenderSurfaceCommand {
    uint8_t kind;
    uint8_t reserved0;
    uint16_t reserved1;
    HowlRenderSurfaceRect rect;
    uint32_t color_rgba;
    HowlRenderResourceId resource;
    HowlRenderGlyphRunSpan glyphs;
} HowlRenderSurfaceCommand;

typedef struct HowlRenderSurfaceCommandSpan {
    const HowlRenderSurfaceCommand *ptr;
    uint32_t count;
    uint32_t count_max;
} HowlRenderSurfaceCommandSpan;

typedef struct HowlRenderResourceRetire {
    HowlRenderResourceId resource;
    uint64_t retire_seq;
} HowlRenderResourceRetire;

typedef struct HowlRenderResourceRetireSpan {
    const HowlRenderResourceRetire *ptr;
    uint32_t count;
    uint32_t count_max;
} HowlRenderResourceRetireSpan;

typedef struct HowlRenderResourceAck {
    HowlRenderResourceId resource;
    uint64_t ack_seq;
} HowlRenderResourceAck;

typedef struct HowlRenderResourceAckSpan {
    const HowlRenderResourceAck *ptr;
    uint32_t count;
    uint32_t count_max;
} HowlRenderResourceAckSpan;

typedef struct HowlRenderSurface {
    uint32_t surface_version;
    uint32_t reserved0;
    HowlRenderSurfaceToken token;
    HowlRenderPixelSize render_px;
    HowlRenderCellSize cell_px;
    HowlRenderGridSize grid;
    HowlRenderSurfaceDamageSpan damage;
    HowlRenderResourceCreateSpan creates;
    HowlRenderResourceUploadSpan uploads;
    HowlRenderSurfaceCommandSpan commands;
    HowlRenderResourceRetireSpan retires;
} HowlRenderSurface;

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
    uint8_t animation_pending;
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
    uint16_t row;
    uint16_t col;
    uint16_t rows;
    uint16_t cols;
    uint8_t opacity;
    uint8_t reserved0;
    uint16_t reserved1;
    HowlVtRgb8 color;
} HowlRenderHostCursorTrailRect;

typedef struct {
    uint8_t focused;
    uint8_t cursor_opacity;
    uint8_t text_blink_opacity;
    uint8_t effective_shape;
    HowlVtColor cursor_color;
    HowlVtColor cursor_text_color;
    HowlVtColor cursor_trail_color;
    float cursor_beam_thickness;
    float cursor_underline_thickness;
    float cursor_trail_decay_fast_s;
    float cursor_trail_decay_slow_s;
    uint16_t cursor_trail_count;
    uint16_t reserved0;
    HowlRenderHostCursorTrailRect cursor_trail_rects[HOWL_RENDER_CURSOR_TRAIL_RECTS_MAX];
    uint64_t now_ns;
} HowlRenderHostCursorCadence;

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
    uint8_t damage_kind;
    uint8_t reserved0;
    uint16_t reserved1;
} HowlRenderPreparedSurfaceInfo;

typedef struct {
    HowlRenderHostSurface host_surface;
} HowlRenderSubmitExecution;

typedef struct {
    int32_t status;
    uint8_t damage_kind;
    uint8_t reserved0;
    uint16_t reserved1;
    HowlRenderHostSurface host_surface;
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
int howl_render_text_session_set_cursor_cadence(
    HowlRenderTextSessionHandle handle,
    const HowlRenderHostCursorCadence *cadence
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
HowlRenderPrepareStatus howl_render_text_session_prepare_handle(
    HowlRenderTextSessionHandle text_session_handle,
    HowlRenderPrepareRequest prepare_request,
    HowlRenderRdrSfcHandle *rdr_sfc_handle_out
);
HowlRenderPrepareStatus howl_render_text_session_take_prepare_request(
    HowlRenderTextSessionHandle handle,
    const HowlVtSurfaceResult *vt_surface,
    HowlRenderPrepareRequest *prepare_request_out
);
HowlRenderSubmitDecisionStatus howl_render_text_session_take_submit_handle(
    HowlRenderTextSessionHandle handle,
    HowlRenderRdrSfcHandle *rdr_sfc_handle_out
);
HowlRenderSubmitStatus howl_render_text_session_submit_handle(
    HowlRenderTextSessionHandle text_session_handle,
    HowlRenderRdrSfcHandle rdr_sfc_handle,
    const HowlRenderSubmitExecution *execution_in,
    HowlRenderSubmitResult *result_out
);
int howl_render_text_session_work_state(
    HowlRenderTextSessionHandle handle,
    HowlRenderSessionWorkState *work_state_out
);

void howl_render_rdr_sfc_release(
    HowlRenderRdrSfcHandle rdr_sfc_handle
);
int howl_render_rdr_sfc_describe(
    HowlRenderRdrSfcHandle rdr_sfc_handle,
    HowlRenderPreparedSurfaceInfo *info_out
);
HowlRenderPreparedSurfaceRenderSurfaceStatus howl_render_rdr_sfc_render_surface(
    HowlRenderRdrSfcHandle rdr_sfc_handle,
    const HowlRenderSurface **surface_out
);
#ifdef __cplusplus
}
#endif

#endif
