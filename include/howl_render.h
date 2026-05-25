#ifndef HOWL_RENDER_H
#define HOWL_RENDER_H

#include <stdint.h>
#include <stddef.h>
#include "howl_vt.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef struct HowlRenderSurfaceText HowlRenderSurfaceText;
typedef struct HowlRenderPreparedSurfaceObject HowlRenderPreparedSurfaceObject;

typedef HowlRenderSurfaceText *HowlRenderSurfaceTextHandle;
typedef HowlRenderPreparedSurfaceObject *HowlRenderPreparedSurfaceHandle;

#define HOWL_RENDER_MAX_FALLBACK_FONTS 24

typedef enum {
  HOWL_RENDER_CALL_OK = 0,
  HOWL_RENDER_CALL_MISSING_HANDLE = -1,
  HOWL_RENDER_CALL_INVALID_ARGUMENT = -2,
  HOWL_RENDER_CALL_FAILED = -3,
} HowlRenderCallStatus;

typedef enum {
  HOWL_RENDER_DAMAGE_NONE = 0,
  HOWL_RENDER_DAMAGE_PARTIAL = 1,
  HOWL_RENDER_DAMAGE_FULL = 3,
} HowlRenderDamageKind;

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
} HowlRenderFrameLayoutResult;

typedef struct {
  uint8_t continuation;
  uint8_t reserved0;
  uint8_t reserved1;
  uint8_t reserved2;
} HowlRenderCellFlags;

typedef struct {
  uint8_t kind;
  uint32_t value;
} HowlRenderColor;

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
} HowlRenderCellAttrs;

typedef struct {
  uint32_t codepoint;
  HowlRenderCellFlags flags;
  HowlRenderColor fg_color;
  HowlRenderColor bg_color;
  HowlRenderColor underline_color;
  uint8_t underline_style;
  uint8_t reserved0;
  uint8_t reserved1;
  uint8_t reserved2;
  HowlRenderCellAttrs attrs;
  uint32_t link_id;
} HowlRenderCell;

typedef struct {
  uint8_t *ptr;
  size_t len;
} HowlRenderByteWriteSpan;

typedef struct {
  uint16_t *ptr;
  size_t len;
} HowlRenderU16WriteSpan;

typedef struct {
  uint16_t row;
  uint16_t col;
  uint8_t visible;
  uint8_t shape;
  uint8_t blink;
} HowlRenderCursor;

typedef struct {
  HowlRenderPixelSize render_px;
  HowlRenderPixelSize grid_px;
} HowlRenderGeometry;

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
  uint8_t present_pending;
  uint32_t reserved0;
} HowlRenderPendingState;

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
} HowlRenderPreparedFrame;

typedef struct {
  int32_t status;
  uint8_t published;
  uint8_t queued;
  uint8_t damage_kind;
  uint8_t reserved0;
  uint64_t snapshot_seq;
  uint64_t geometry_epoch;
} HowlRenderVtPublishResult;

typedef struct {
  HowlVtSurfaceCell *ptr;
  size_t len;
} HowlRenderVtCellWriteSpan;

typedef struct {
  HowlRenderVtCellWriteSpan cells;
  HowlRenderByteWriteSpan dirty_rows;
  HowlRenderU16WriteSpan dirty_cols_start;
  HowlRenderU16WriteSpan dirty_cols_end;
} HowlRenderPublishSlot;

typedef struct {
  uint32_t image_count;
  uint32_t placement_count;
  uint32_t virtual_placement_count;
  uint8_t is_alternate_screen;
  uint8_t reserved0;
  uint64_t publication_seq;
  uint64_t dirty_generation;
} HowlRenderVtGraphicsMeta;

typedef struct {
  const HowlVtGraphicsImage *ptr;
  size_t len;
} HowlRenderVtGraphicsImageSpan;

typedef struct {
  const HowlVtGraphicsPlacement *ptr;
  size_t len;
} HowlRenderVtGraphicsPlacementSpan;

typedef struct {
  const HowlVtGraphicsVirtualPlacement *ptr;
  size_t len;
} HowlRenderVtGraphicsVirtualPlacementSpan;

typedef struct {
  uint64_t history_count;
  uint64_t scroll_row;
  uint64_t snapshot_seq;
  uint8_t is_alternate_screen;
  uint8_t reserved0;
  uint16_t reserved1;
  HowlVtCursor cursor;
  HowlVtRenderColorState colors;
  HowlVtSelection selection;
  HowlRenderVtGraphicsMeta graphics;
  HowlRenderVtGraphicsImageSpan graphics_images;
  HowlRenderVtGraphicsPlacementSpan graphics_placements;
  HowlRenderVtGraphicsVirtualPlacementSpan graphics_virtual_placements;
  HowlRenderByteSpan graphics_payload_bytes;
} HowlRenderPublishSlotCommit;

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
} HowlRenderSurfaceMetrics;

typedef struct {
  int32_t status;
  uint64_t snapshot_seq;
} HowlRenderPresentedRetire;

typedef struct {
  uint64_t host_surface_id;
  uint16_t width;
  uint16_t height;
} HowlRenderSurfaceHandle;

typedef struct {
  int32_t status;
  uint64_t snapshot_seq;
  uint64_t dirty_epoch;
  uint64_t geometry_epoch;
  uint64_t required_base_seq;
  HowlRenderPixelSize render_px;
  HowlRenderCellSize cell_px;
  HowlRenderGridSize grid;
  HowlRenderSurfaceMetrics prepare_metrics;
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
  HowlRenderSurfaceMetrics resolve_metrics;
} HowlRenderPreparedSurfaceDiagnostics;

typedef struct {
  HowlRenderSurfaceHandle surface;
  uint64_t uploads_committed;
  uint64_t render_us;
} HowlRenderSurfaceExecutionInput;

typedef struct {
  HowlVtSurfaceCellSpan cells;
  uint16_t cols;
  uint16_t rows;
  uint64_t history_count;
  uint64_t scroll_row;
  uint64_t snapshot_seq;
  uint8_t is_alternate_screen;
  uint8_t reserved0;
  uint16_t reserved1;
  HowlVtByteSpan dirty_rows;
  HowlVtU16Span dirty_cols_start;
  HowlVtU16Span dirty_cols_end;
  HowlVtCursor cursor;
  HowlVtRenderColorState colors;
  HowlVtSelection selection;
  HowlRenderVtGraphicsMeta graphics;
  HowlRenderVtGraphicsImageSpan graphics_images;
  HowlRenderVtGraphicsPlacementSpan graphics_placements;
  HowlRenderByteSpan graphics_payload_bytes;
} HowlRenderVtSurface;

typedef struct {
  int32_t status;
  uint8_t damage_kind;
  uint8_t reserved0;
  uint16_t reserved1;
  HowlRenderSurfaceHandle surface;
  HowlRenderSurfaceMetrics metrics;
} HowlRenderSurfaceFeedback;

typedef struct {
  HowlRenderPixelSize surface_px;
  uint16_t font_size_px;
  uint16_t reserved0;
} HowlRenderSurfaceTextConfig;

HowlRenderFrameLayoutResult howl_render_surface_text_derive_frame_layout(HowlRenderSurfaceTextHandle handle, HowlRenderPixelSize render_px, HowlRenderPixelSize grid_px);

HowlRenderSurfaceTextHandle howl_render_surface_text_init(HowlRenderSurfaceTextConfig config);
void howl_render_surface_text_deinit(HowlRenderSurfaceTextHandle handle);
int howl_render_surface_text_is_valid_font(HowlRenderSurfaceTextHandle handle);
int howl_render_surface_text_set_font_size_px(HowlRenderSurfaceTextHandle handle, uint16_t font_size_px);
int howl_render_surface_text_set_font_path(HowlRenderSurfaceTextHandle handle, const uint8_t *ptr, size_t len);
int howl_render_surface_text_set_fallback_font_paths(HowlRenderSurfaceTextHandle handle, const uint8_t *const *ptrs, size_t count);
int howl_render_surface_text_set_cursor_blink_visible(HowlRenderSurfaceTextHandle handle, uint8_t visible);
HowlRenderGeometryResponse howl_render_surface_text_sync_geometry(HowlRenderSurfaceTextHandle handle, HowlRenderGeometry geometry);
HowlRenderVtPublishResult howl_render_surface_text_publish_vt_source(HowlRenderSurfaceTextHandle handle, HowlRenderVtSurface source);
int howl_render_surface_text_reserve_publish_slot(HowlRenderSurfaceTextHandle handle, uint16_t cols, uint16_t rows, HowlRenderPublishSlot *slot_out);
HowlRenderVtPublishResult howl_render_surface_text_commit_publish_slot(HowlRenderSurfaceTextHandle handle, HowlRenderPublishSlotCommit commit);
HowlRenderVtPublishResult howl_render_surface_text_reject_publish_slot(HowlRenderSurfaceTextHandle handle, uint64_t snapshot_seq);
void howl_render_surface_text_cancel_publish_slot(HowlRenderSurfaceTextHandle handle);
HowlRenderPrepareStatus howl_render_surface_text_take_prepare_request(HowlRenderSurfaceTextHandle handle, HowlRenderPrepareRequest *prepare_request_out);
int howl_render_surface_text_publish_prepared(HowlRenderSurfaceTextHandle handle, HowlRenderPreparedFrame prepared_frame);
int howl_render_surface_text_publish_prepared_handle(HowlRenderSurfaceTextHandle handle, HowlRenderPreparedSurfaceHandle prepared_surface_handle);
HowlRenderSubmitDecisionStatus howl_render_surface_text_take_submit_decision(HowlRenderSurfaceTextHandle handle, HowlRenderPreparedFrame *prepared_frame_out);
HowlRenderSubmitDecisionStatus howl_render_surface_text_take_submit_handle(HowlRenderSurfaceTextHandle handle, HowlRenderPreparedSurfaceHandle *prepared_surface_handle_out);
int howl_render_surface_text_accept_submitted(HowlRenderSurfaceTextHandle handle, HowlRenderPreparedFrame prepared_frame);
int howl_render_surface_text_retire_presented(HowlRenderSurfaceTextHandle handle, HowlRenderPresentedRetire *retire_out);
int howl_render_surface_text_pending_state(HowlRenderSurfaceTextHandle handle, HowlRenderPendingState *pending_out);

/* Owned prepared-surface ABI target. */
HowlRenderPrepareStatus howl_render_surface_text_prepare_handle(HowlRenderSurfaceTextHandle surface_text_handle, HowlRenderPrepareRequest prepare_request, HowlRenderPreparedSurfaceHandle *prepared_handle_out);
void howl_render_prepared_surface_release(HowlRenderPreparedSurfaceHandle prepared_surface_handle);
int howl_render_prepared_surface_describe(HowlRenderPreparedSurfaceHandle prepared_surface_handle, HowlRenderPreparedSurfaceInfo *info_out);
int howl_render_prepared_surface_buffer(HowlRenderPreparedSurfaceHandle prepared_surface_handle, HowlRenderPreparedSurfaceBuffer *buffer_out);
int howl_render_prepared_surface_diagnostics(HowlRenderPreparedSurfaceHandle prepared_surface_handle, HowlRenderPreparedSurfaceDiagnostics *diagnostics_out);
HowlRenderSubmitStatus howl_render_surface_text_submit(HowlRenderSurfaceTextHandle surface_text_handle, HowlRenderPreparedSurfaceHandle prepared_surface_handle, HowlRenderPreparedFrame prepared_frame, const HowlRenderSurfaceExecutionInput *execution_in, HowlRenderSurfaceFeedback *feedback_out);
HowlRenderSubmitStatus howl_render_surface_text_submit_handle(HowlRenderSurfaceTextHandle surface_text_handle, HowlRenderPreparedSurfaceHandle prepared_surface_handle, const HowlRenderSurfaceExecutionInput *execution_in, HowlRenderSurfaceFeedback *feedback_out);

#ifdef __cplusplus
}
#endif

#endif
