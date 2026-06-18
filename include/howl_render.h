#ifndef HOWL_RENDER_H
#define HOWL_RENDER_H

#include <stdint.h>
#include <stddef.h>
#ifdef __cplusplus
extern "C" {
#endif

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
    uint64_t host_surface_id;
    uint16_t width;
    uint16_t height;
} HowlRenderHostSurface;

#ifdef __cplusplus
}
#endif

#endif
