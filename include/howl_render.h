#ifndef HOWL_RENDER_H
#define HOWL_RENDER_H

#include <stdint.h>
#include <stddef.h>
#include <howl_vt.h>
#ifdef __cplusplus
extern "C" {
#endif

#define HOWL_RENDER_MAX_FALLBACK_FONTS 24

#define HOWL_RENDER_SURFACE_FRAME_VERSION 0
#define HOWL_RENDER_SURFACE_FRAME_IN_FLIGHT_MAX 2
#define HOWL_RENDER_SURFACE_FRAME_SNAPSHOTS_IN_FLIGHT_MAX 2
#define HOWL_RENDER_SURFACE_FRAME_DAMAGE_ITEMS_MAX 1024
#define HOWL_RENDER_SURFACE_FRAME_UPLOADS_MAX 256
#define HOWL_RENDER_SURFACE_FRAME_COMMANDS_MAX 8192
#define HOWL_RENDER_SURFACE_FRAME_GLYPHS_PER_RUN_MAX 256
#define HOWL_RENDER_SURFACE_FRAME_UPLOAD_BYTES_MAX 8388608
#define HOWL_RENDER_SURFACE_ATLAS_PAGES_MAX 64
#define HOWL_RENDER_SURFACE_RESOURCES_MAX 4096
#define HOWL_RENDER_SURFACE_FRAME_CREATES_MAX 256
#define HOWL_RENDER_SURFACE_FRAME_RETIRES_MAX 256
#define HOWL_RENDER_SURFACE_FRAME_HOST_ACKS_MAX 256
#define HOWL_RENDER_CURSOR_TRAIL_RECTS_MAX 16

#define HOWL_RENDER_SURFACE_FRAME_DAMAGE_RECT 1
#define HOWL_RENDER_SURFACE_FRAME_DAMAGE_FULL 2
#define HOWL_RENDER_RESOURCE_GLYPH_ATLAS_ALPHA 1
#define HOWL_RENDER_RESOURCE_GLYPH_ATLAS_COLOR 2
#define HOWL_RENDER_RESOURCE_SPRITE_ALPHA 3
#define HOWL_RENDER_RESOURCE_SPRITE_COLOR 4
#define HOWL_RENDER_UPLOAD_ALPHA8 1
#define HOWL_RENDER_UPLOAD_RGBA8 2
#define HOWL_RENDER_SURFACE_FRAME_COMMAND_CLEAR_RECT 1
#define HOWL_RENDER_SURFACE_FRAME_COMMAND_FILL_RECT 2
#define HOWL_RENDER_SURFACE_FRAME_COMMAND_DRAW_GLYPH_RUN 3
#define HOWL_RENDER_SURFACE_FRAME_COMMAND_DRAW_SPRITE 4

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
} HowlRenderCellGrid;

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
    HowlRenderCellGrid grid;
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

typedef struct HowlRenderSurfaceFrameToken {
    uint64_t snapshot_seq;
    uint64_t frame_seq;
    uint64_t geometry_epoch;
    uint64_t resource_epoch;
} HowlRenderSurfaceFrameToken;

typedef struct HowlRenderSurfaceRect {
    int32_t x_px;
    int32_t y_px;
    uint16_t width_px;
    uint16_t height_px;
} HowlRenderSurfaceRect;

typedef struct HowlRenderSurfaceFrameDamageItem {
    uint8_t kind;
    uint8_t reserved0;
    uint16_t reserved1;
    HowlRenderSurfaceRect rect;
} HowlRenderSurfaceFrameDamageItem;

typedef struct HowlRenderSurfaceFrameDamageSpan {
    const HowlRenderSurfaceFrameDamageItem *ptr;
    uint32_t count;
    uint32_t count_max;
} HowlRenderSurfaceFrameDamageSpan;

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

typedef struct HowlRenderSurfaceFrameCommand {
    uint8_t kind;
    uint8_t reserved0;
    uint16_t reserved1;
    HowlRenderSurfaceRect rect;
    uint32_t color_rgba;
    HowlRenderResourceId resource;
    HowlRenderGlyphRunSpan glyphs;
} HowlRenderSurfaceFrameCommand;

typedef struct HowlRenderSurfaceFrameCommandSpan {
    const HowlRenderSurfaceFrameCommand *ptr;
    uint32_t count;
    uint32_t count_max;
} HowlRenderSurfaceFrameCommandSpan;

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

typedef struct HowlRenderSurfaceFrame {
    uint32_t frame_version;
    uint32_t reserved0;
    HowlRenderSurfaceFrameToken token;
    HowlRenderPixelSize render_px;
    HowlRenderCellSize cell_px;
    HowlRenderCellGrid grid;
    HowlRenderSurfaceFrameDamageSpan damage;
    HowlRenderResourceCreateSpan creates;
    HowlRenderResourceUploadSpan uploads;
    HowlRenderSurfaceFrameCommandSpan commands;
    HowlRenderResourceRetireSpan retires;
} HowlRenderSurfaceFrame;

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
    uint64_t host_texture_id;
    uint16_t width;
    uint16_t height;
} HowlRenderHostTexture;

typedef struct HowlRenderText HowlRenderText;
typedef HowlRenderText *HowlRenderTextHandle;

typedef struct {
    uint16_t font_size_px;
    uint16_t fallback_font_path_count;
    uint32_t reserved0;
    const char *primary_font_path;
    const char *const *fallback_font_paths;
} HowlRenderTextConfig;

typedef struct {
    HowlVtRenderStateHandle render_state;
    HowlRenderPixelSize render_px;
    HowlRenderPixelSize grid_px;
    HowlRenderCellSize cell_px;
    HowlRenderCellGrid grid;
    uint64_t geometry_epoch;
    uint8_t focused;
    uint8_t cursor_opacity;
    uint8_t text_blink_opacity;
    uint8_t effective_shape;
    HowlVtColor cursor_color;
    HowlVtColor cursor_text_color;
    float cursor_beam_thickness;
    float cursor_underline_thickness;
} HowlRenderTextPrepare;

typedef struct {
    int32_t status;
    uint32_t surface_frame_status;
    uint32_t reserved0;
    uint64_t snapshot_seq;
    HowlRenderPixelSize render_px;
    const HowlRenderSurfaceFrame *surface_frame;
} HowlRenderTextPreparedUpload;

HowlRenderCallStatus howl_render_text_init(HowlRenderTextHandle *out_handle, const HowlRenderTextConfig *config);
void howl_render_text_deinit(HowlRenderTextHandle handle);
HowlRenderCallStatus howl_render_text_prepare(HowlRenderTextHandle handle, const HowlRenderTextPrepare *prepare, HowlRenderTextPreparedUpload *out_upload);
HowlRenderCallStatus howl_render_text_submit(HowlRenderTextHandle handle, HowlRenderHostTexture host_texture, HowlRenderHostTexture *out_host_texture);

#ifdef __cplusplus
}
#endif

#endif
