// A thin, flat C API over FreeType for myod's text backend.
//
// FreeType's public structs (FT_FaceRec, FT_GlyphSlotRec, …) are large and nested; mirroring them in
// Odin would be fragile. This shim exposes only plain functions and one small struct instead.

#include <ft2build.h>
#include FT_FREETYPE_H

#include <string.h>

typedef struct {
	int width, rows, pitch;
	int left, top;        // bitmap_left / bitmap_top: offset from the pen position, top measured up
	int pixel_mode;       // 2 = 8-bit gray, 7 = BGRA
	const unsigned char *buffer;
} myod_ft_bitmap;

int myod_ft_init(FT_Library *out) {
	return FT_Init_FreeType(out);
}

void myod_ft_done(FT_Library lib) {
	FT_Done_FreeType(lib);
}

// `data` must outlive the face.
int myod_ft_new_face(FT_Library lib, const unsigned char *data, long size, FT_Face *out) {
	return FT_New_Memory_Face(lib, data, size, 0, out);
}

void myod_ft_done_face(FT_Face face) {
	FT_Done_Face(face);
}

int myod_ft_set_pixel_size(FT_Face face, unsigned int px) {
	return FT_Set_Pixel_Sizes(face, 0, px);
}

// Ascender, descender (positive, below the baseline) and line height for the current size, in pixels.
void myod_ft_metrics(FT_Face face, double *ascender, double *descender, double *height) {
	FT_Size_Metrics m = face->size->metrics;
	*ascender = m.ascender / 64.0;
	*descender = -m.descender / 64.0;
	*height = m.height / 64.0;
}

// Load flags matching Ghostty's FreeType defaults: hinting on, light auto-hinter.
static FT_Int32 load_flags(int color) {
	FT_Int32 flags = FT_LOAD_DEFAULT | FT_LOAD_TARGET_LIGHT | FT_LOAD_FORCE_AUTOHINT;
	if (color) flags |= FT_LOAD_COLOR;
	return flags;
}

// Renders one glyph shifted right by `subpixel_64` (in 1/64 px). The bitmap stays valid until
// the next call on this face.
int myod_ft_render(FT_Face face, unsigned int glyph, int subpixel_64, int color, myod_ft_bitmap *out) {
	FT_Vector delta = {subpixel_64, 0};
	FT_Set_Transform(face, NULL, &delta);
	int err = FT_Load_Glyph(face, glyph, load_flags(color));
	FT_Set_Transform(face, NULL, NULL);
	if (err) return err;

	FT_GlyphSlot slot = face->glyph;
	if (slot->format != FT_GLYPH_FORMAT_BITMAP) {
		err = FT_Render_Glyph(slot, FT_RENDER_MODE_LIGHT);
		if (err) return err;
	}
	memset(out, 0, sizeof(*out));
	out->width = (int)slot->bitmap.width;
	out->rows = (int)slot->bitmap.rows;
	out->pitch = slot->bitmap.pitch;
	out->left = slot->bitmap_left;
	out->top = slot->bitmap_top;
	out->pixel_mode = slot->bitmap.pixel_mode;
	out->buffer = slot->bitmap.buffer;
	return 0;
}

int myod_ft_has_color(FT_Face face) {
	return FT_HAS_COLOR(face) ? 1 : 0;
}
