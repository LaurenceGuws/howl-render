#ifndef HOWL_RENDER_H
#define HOWL_RENDER_H

#include <stdint.h>
#include <stddef.h>
#include <howl_vt.h>
#ifdef __cplusplus
extern "C" {
#endif

#define HOWL_RENDER_MAX_FALLBACK_FONTS 24

#define HOWL_RENDER_TERM_SURFACE_PREPARED_VERSION 0
#define HOWL_RENDER_TAB_BAR_SURFACE_PREPARED_VERSION 0
#define HOWL_RENDER_TERM_SURFACE_PREPARED_IN_FLIGHT_MAX 2
#define HOWL_RENDER_TERM_SURFACE_PREPARED_SNAPSHOTS_IN_FLIGHT_MAX 2
#define HOWL_RENDER_TERM_SURFACE_DAMAGE_ITEMS_MAX 1024
#define HOWL_RENDER_TAB_BAR_SURFACE_DAMAGE_ITEMS_MAX 1024
#define HOWL_RENDER_TERM_SURFACE_PREPARED_UPLOADS_MAX 256
#define HOWL_RENDER_TAB_BAR_SURFACE_PREPARED_UPLOADS_MAX 256
#define HOWL_RENDER_TERM_SURFACE_PREPARED_COMMANDS_MAX 8192
#define HOWL_RENDER_TAB_BAR_SURFACE_PREPARED_COMMANDS_MAX 8192
#define HOWL_RENDER_TERM_SURFACE_PREPARED_GLYPHS_PER_RUN_MAX 256
#define HOWL_RENDER_TAB_BAR_SURFACE_PREPARED_GLYPHS_PER_RUN_MAX 256
#define HOWL_RENDER_TERM_SURFACE_PREPARED_UPLOAD_BYTES_MAX 8388608
#define HOWL_RENDER_TAB_BAR_SURFACE_PREPARED_UPLOAD_BYTES_MAX 8388608
#define HOWL_RENDER_TEXT_ATLAS_PAGES_MAX 64
#define HOWL_RENDER_TEXT_RESOURCES_MAX 4096
#define HOWL_RENDER_TERM_SURFACE_PREPARED_CREATES_MAX 256
#define HOWL_RENDER_TAB_BAR_SURFACE_PREPARED_CREATES_MAX 256
#define HOWL_RENDER_TERM_SURFACE_PREPARED_RETIRES_MAX 256
#define HOWL_RENDER_TAB_BAR_SURFACE_PREPARED_RETIRES_MAX 256
#define HOWL_RENDER_TERM_SURFACE_PREPARED_HOST_ACKS_MAX 256
#define HOWL_RENDER_CURSOR_TRAIL_RECTS_MAX 16
#define HOWL_RENDER_TAB_BAR_SURFACE_CELLS_MAX 4096
#define HOWL_RENDER_CELL_TEXT_COMBINING_MAX 3

#define HOWL_RENDER_TERM_SURFACE_DAMAGE_RECT 1
#define HOWL_RENDER_TERM_SURFACE_DAMAGE_FULL 2
#define HOWL_RENDER_TAB_BAR_SURFACE_DAMAGE_RECT 1
#define HOWL_RENDER_TAB_BAR_SURFACE_DAMAGE_FULL 2
#define HOWL_RENDER_RESOURCE_GLYPH_ATLAS_ALPHA 1
#define HOWL_RENDER_RESOURCE_GLYPH_ATLAS_COLOR 2
#define HOWL_RENDER_RESOURCE_SPRITE_ALPHA 3
#define HOWL_RENDER_RESOURCE_SPRITE_COLOR 4
#define HOWL_RENDER_UPLOAD_ALPHA8 1
#define HOWL_RENDER_UPLOAD_RGBA8 2
#define HOWL_RENDER_TERM_SURFACE_COMMAND_CLEAR_RECT 1
#define HOWL_RENDER_TERM_SURFACE_COMMAND_FILL_RECT 2
#define HOWL_RENDER_TERM_SURFACE_COMMAND_DRAW_GLYPH_RUN 3
#define HOWL_RENDER_TERM_SURFACE_COMMAND_DRAW_SPRITE 4
#define HOWL_RENDER_TAB_BAR_SURFACE_COMMAND_CLEAR_RECT 1
#define HOWL_RENDER_TAB_BAR_SURFACE_COMMAND_FILL_RECT 2
#define HOWL_RENDER_TAB_BAR_SURFACE_COMMAND_DRAW_GLYPH_RUN 3
#define HOWL_RENDER_TAB_BAR_SURFACE_COMMAND_DRAW_SPRITE 4
#define HOWL_RENDER_FONT_STYLE_REGULAR 0
#define HOWL_RENDER_FONT_STYLE_BOLD 1
#define HOWL_RENDER_FONT_STYLE_ITALIC 2
#define HOWL_RENDER_FONT_STYLE_BOLD_ITALIC 3
#define HOWL_RENDER_TEXT_PRESENTATION_ANY 0
#define HOWL_RENDER_TEXT_PRESENTATION_TEXT 1
#define HOWL_RENDER_TEXT_PRESENTATION_EMOJI 2
#define HOWL_RENDER_CELL_TEXT_UNDERLINE 0x01
#define HOWL_RENDER_CELL_TEXT_STRIKETHROUGH 0x02
#define HOWL_RENDER_CELL_TEXT_CONTINUATION 0x04
#define HOWL_RENDER_CELL_TEXT_EMPTY 0x08

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
    int32_t x_px;
    int32_t y_px;
} HowlRenderTermSurfacePoint;

typedef struct {
    uint16_t row;
    uint16_t col;
    uint16_t rows;
    uint16_t cols;
    uint8_t opacity;
    uint8_t pixel_rect;
    uint16_t reserved0;
    HowlVtRgb8 color;
    int32_t x_px;
    int32_t y_px;
    uint16_t width_px;
    uint16_t height_px;
} HowlRenderCursorTrailRect;

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
    HowlRenderCellSize cell_px;
    uint16_t baseline_px;
    uint16_t underline_y_px;
    uint16_t underline_height_px;
    uint16_t strikethrough_y_px;
    uint16_t strikethrough_height_px;
    uint16_t sprite_slot_height_px;
} HowlRenderCellLayout;

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
    int32_t status;
    uint8_t inside;
    uint8_t reserved0;
    uint16_t reserved1;
    uint16_t row;
    uint16_t col;
} HowlRenderTermSurfacePointCell;

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
} HowlRenderLayout;

typedef struct HowlRenderTermSurfacePreparedToken {
    uint64_t snapshot_seq;
    uint64_t prepare_seq;
    uint64_t layout_epoch;
    uint64_t resource_epoch;
} HowlRenderTermSurfacePreparedToken;

typedef struct HowlRenderTermSurfaceRect {
    int32_t x_px;
    int32_t y_px;
    uint16_t width_px;
    uint16_t height_px;
} HowlRenderTermSurfaceRect;

typedef struct HowlRenderTermSurfaceDamageItem {
    uint8_t kind;
    uint8_t reserved0;
    uint16_t reserved1;
    HowlRenderTermSurfaceRect rect;
} HowlRenderTermSurfaceDamageItem;

typedef struct HowlRenderTermSurfaceDamageSpan {
    const HowlRenderTermSurfaceDamageItem *ptr;
    uint32_t count;
    uint32_t count_max;
} HowlRenderTermSurfaceDamageSpan;

typedef struct HowlRenderResourceId {
    uint64_t value;
    uint32_t generation;
    uint32_t kind;
} HowlRenderResourceId;

typedef struct HowlRenderResourceUpload {
    HowlRenderResourceId resource;
    HowlRenderTermSurfaceRect rect;
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
    HowlRenderTermSurfaceRect atlas_rect;
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

typedef struct HowlRenderTermSurfaceCommand {
    uint8_t kind;
    uint8_t reserved0;
    uint16_t reserved1;
    HowlRenderTermSurfaceRect rect;
    uint32_t color_rgba;
    HowlRenderResourceId resource;
    HowlRenderGlyphRunSpan glyphs;
} HowlRenderTermSurfaceCommand;

typedef struct HowlRenderTermSurfaceCommandSpan {
    const HowlRenderTermSurfaceCommand *ptr;
    uint32_t count;
    uint32_t count_max;
} HowlRenderTermSurfaceCommandSpan;

typedef struct HowlRenderTabBarSurfacePreparedToken {
    uint64_t snapshot_seq;
    uint64_t prepare_seq;
    uint64_t layout_epoch;
    uint64_t resource_epoch;
} HowlRenderTabBarSurfacePreparedToken;

typedef struct HowlRenderTabBarSurfaceRect {
    int32_t x_px;
    int32_t y_px;
    uint16_t width_px;
    uint16_t height_px;
} HowlRenderTabBarSurfaceRect;

typedef struct HowlRenderTabBarSurfaceDamageItem {
    uint8_t kind;
    uint8_t reserved0;
    uint16_t reserved1;
    HowlRenderTabBarSurfaceRect rect;
} HowlRenderTabBarSurfaceDamageItem;

typedef struct HowlRenderTabBarSurfaceDamageSpan {
    const HowlRenderTabBarSurfaceDamageItem *ptr;
    uint32_t count;
    uint32_t count_max;
} HowlRenderTabBarSurfaceDamageSpan;

typedef struct HowlRenderTabBarResourceUpload {
    HowlRenderResourceId resource;
    HowlRenderTabBarSurfaceRect rect;
    const uint8_t *bytes_ptr;
    uint32_t bytes_count;
    uint32_t stride_bytes;
    uint32_t format;
    uint32_t upload_seq;
} HowlRenderTabBarResourceUpload;

typedef struct HowlRenderTabBarResourceUploadSpan {
    const HowlRenderTabBarResourceUpload *ptr;
    uint32_t count;
    uint32_t count_max;
    uint32_t bytes_count_total;
    uint32_t bytes_count_max;
} HowlRenderTabBarResourceUploadSpan;

typedef struct HowlRenderTabBarGlyphRef {
    HowlRenderResourceId atlas_resource;
    HowlRenderTabBarSurfaceRect atlas_rect;
    int32_t x_px;
    int32_t y_px;
    uint32_t glyph_id;
    uint32_t color_rgba;
} HowlRenderTabBarGlyphRef;

typedef struct HowlRenderTabBarGlyphRunSpan {
    const HowlRenderTabBarGlyphRef *ptr;
    uint32_t count;
    uint32_t count_max;
} HowlRenderTabBarGlyphRunSpan;

typedef struct HowlRenderTabBarSurfaceCommand {
    uint8_t kind;
    uint8_t reserved0;
    uint16_t reserved1;
    HowlRenderTabBarSurfaceRect rect;
    uint32_t color_rgba;
    HowlRenderResourceId resource;
    HowlRenderTabBarGlyphRunSpan glyphs;
} HowlRenderTabBarSurfaceCommand;

typedef struct HowlRenderTabBarSurfaceCommandSpan {
    const HowlRenderTabBarSurfaceCommand *ptr;
    uint32_t count;
    uint32_t count_max;
} HowlRenderTabBarSurfaceCommandSpan;

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

typedef struct HowlRenderTermSurfacePrepared {
    uint32_t prepared_version;
    uint32_t reserved0;
    HowlRenderTermSurfacePreparedToken token;
    HowlRenderPixelSize render_px;
    HowlRenderCellSize cell_px;
    HowlRenderCellGrid grid;
    HowlRenderTermSurfaceDamageSpan damage;
    HowlRenderResourceCreateSpan creates;
    HowlRenderResourceUploadSpan uploads;
    HowlRenderTermSurfaceCommandSpan commands;
    HowlRenderResourceRetireSpan retires;
} HowlRenderTermSurfacePrepared;

typedef struct HowlRenderTabBarSurfacePrepared {
    uint32_t prepared_version;
    uint32_t reserved0;
    HowlRenderTabBarSurfacePreparedToken token;
    HowlRenderPixelSize render_px;
    HowlRenderCellSize cell_px;
    HowlRenderCellGrid grid;
    HowlRenderTabBarSurfaceDamageSpan damage;
    HowlRenderResourceCreateSpan creates;
    HowlRenderTabBarResourceUploadSpan uploads;
    HowlRenderTabBarSurfaceCommandSpan commands;
    HowlRenderResourceRetireSpan retires;
} HowlRenderTabBarSurfacePrepared;

typedef struct {
    int32_t status;
    uint8_t changed;
    uint8_t reserved0;
    uint8_t reserved1;
    uint8_t reserved2;
    uint32_t reserved3;
    HowlRenderPixelSize render_px;
    HowlRenderPixelSize grid_px;
    HowlRenderCellGrid grid;
    HowlRenderCellLayout cell_layout;
    uint64_t layout_epoch;
} HowlRenderLayoutResponse;

typedef struct {
    uint64_t term_surface_id;
    uint16_t width;
    uint16_t height;
} HowlRenderTermSurface;

typedef struct {
    uint64_t tab_bar_surface_id;
    uint16_t width;
    uint16_t height;
} HowlRenderTabBarSurface;

/* Owns font resolution, shaping, raster cache, and text resources for terminal text and tab_bar_surface preparation. */
typedef struct HowlRenderText HowlRenderText;
typedef HowlRenderText *HowlRenderTextHandle;

typedef struct {
    uint32_t codepoint;
    uint32_t combining[HOWL_RENDER_CELL_TEXT_COMBINING_MAX];
    uint8_t combining_len;
    uint8_t style;
    uint8_t presentation;
    uint8_t flags;
    HowlRenderRgba8 foreground;
    HowlRenderRgba8 background;
    HowlRenderRgba8 underline_color;
    uint8_t underline_style;
    uint8_t reserved0;
    uint16_t reserved1;
} HowlRenderCellText;

typedef struct {
    const HowlRenderCellText *ptr;
    uint32_t count;
    uint32_t count_max;
} HowlRenderCellTextSpan;

typedef struct {
    uint16_t font_size_px;
    uint16_t fallback_font_path_count;
    uint32_t reserved0;
    const char *primary_font_path;
    const char *const *fallback_font_paths;
    double cursor_blink_interval_s;
    double cursor_blink_inactivity_s;
    double cursor_trail_delay_s;
    double cursor_trail_decay_fast_s;
    double cursor_trail_decay_slow_s;
    uint16_t cursor_trail_start_threshold;
    uint16_t reserved1;
    HowlVtColor cursor_color;
    HowlVtColor cursor_text_color;
    HowlVtColor cursor_trail_color;
    float cursor_beam_thickness;
    float cursor_underline_thickness;
    uint8_t cursor_unfocused_shape;
    uint8_t reserved2[7];
} HowlRenderTextConfig;

typedef struct {
    HowlVtRenderStateHandle render_state;
    HowlRenderPixelSize render_px;
    uint64_t layout_epoch;
    uint64_t now_ns;
    uint64_t activity_seq;
    uint8_t focused;
    uint8_t reserved0[7];
} HowlRenderTextPrepare;

typedef struct {
    int32_t status;
    uint32_t term_surface_status;
    uint32_t reserved0;
    uint64_t snapshot_seq;
    HowlRenderPixelSize render_px;
    const HowlRenderTermSurfacePrepared *term_surface_prepared;
} HowlRenderTextPreparedUpload;

typedef struct {
    HowlRenderPixelSize render_px;
    HowlRenderPixelSize grid_px;
    HowlRenderCellSize cell_px;
    HowlRenderCellGrid grid;
    uint64_t layout_epoch;
    HowlRenderCellTextSpan cells;
} HowlRenderTabBarSurfacePrepare;

typedef struct {
    int32_t status;
    uint32_t tab_bar_surface_status;
    uint32_t reserved0;
    uint64_t snapshot_seq;
    HowlRenderPixelSize render_px;
    const HowlRenderTabBarSurfacePrepared *tab_bar_surface_prepared;
} HowlRenderTabBarSurfacePreparedUpload;

HowlRenderCallStatus howl_render_text_init(HowlRenderTextHandle *out_handle, const HowlRenderTextConfig *config);
void howl_render_text_deinit(HowlRenderTextHandle handle);
HowlRenderCallStatus howl_render_term_surface_layout(HowlRenderTextHandle handle, HowlRenderPixelSize term_surface_px, HowlRenderLayoutResponse *out_layout);
HowlRenderCallStatus howl_render_term_surface_point_cell(HowlRenderTextHandle handle, HowlRenderPixelSize term_surface_px, HowlRenderTermSurfacePoint point, HowlRenderTermSurfacePointCell *out_cell);
HowlRenderCallStatus howl_render_text_prepare(HowlRenderTextHandle handle, const HowlRenderTextPrepare *prepare, HowlRenderTextPreparedUpload *out_upload);
HowlRenderCallStatus howl_render_tab_bar_surface_prepare(HowlRenderTextHandle handle, const HowlRenderTabBarSurfacePrepare *prepare, HowlRenderTabBarSurfacePreparedUpload *out_upload);
HowlRenderCallStatus howl_render_text_submit_term_surface(HowlRenderTextHandle handle, HowlRenderTermSurface term_surface, HowlRenderTermSurface *out_term_surface);

#ifdef __cplusplus
}
#endif

#endif
