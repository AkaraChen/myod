// A thin, flat C API over FreeType for myod's text backend.
//
// FreeType's public structs (FT_FaceRec, FT_GlyphSlotRec, …) are large and nested; mirroring them in
// Odin would be fragile. This shim exposes only plain functions and one small struct instead.

#include <ft2build.h>
#include FT_FREETYPE_H
#include FT_MULTIPLE_MASTERS_H
#include FT_TRUETYPE_TABLES_H

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

// Opens a font by path, letting FreeType read only what it needs (large fallback fonts such as
// Apple Color Emoji are hundreds of megabytes).
int myod_ft_new_face_file(FT_Library lib, const char *path, long index, FT_Face *out) {
	return FT_New_Face(lib, path, index, out);
}

void myod_ft_done_face(FT_Face face) {
	FT_Done_Face(face);
}

// Sets the size in pixels. Color bitmap fonts (sbix, CBDT) only come in fixed strikes: the smallest
// strike at least `px` tall (or the largest) is selected, and *scale is set to the factor that maps
// the strike to `px`. Glyph bitmaps and metrics then come at strike size and must be scaled by it.
int myod_ft_set_pixel_size(FT_Face face, unsigned int px, double *scale) {
	*scale = 1.0;
	if (FT_HAS_FIXED_SIZES(face) && FT_HAS_COLOR(face)) {
		int best = -1;
		for (int i = 0; i < face->num_fixed_sizes; i++) {
			FT_Pos ppem = face->available_sizes[i].y_ppem;
			if (ppem >= (FT_Pos)px * 64) {
				if (best < 0 || ppem < face->available_sizes[best].y_ppem) best = i;
			}
		}
		if (best < 0) {
			for (int i = 0; i < face->num_fixed_sizes; i++) {
				if (best < 0 || face->available_sizes[i].y_ppem > face->available_sizes[best].y_ppem) best = i;
			}
		}
		if (best >= 0) {
			int err = FT_Select_Size(face, best);
			if (err) return err;
			*scale = (double)px / (face->available_sizes[best].y_ppem / 64.0);
			return 0;
		}
	}
	return FT_Set_Pixel_Sizes(face, 0, px);
}

// Ascender, descender (positive, below the baseline) and line height for the current size, in pixels
// (at strike size for color bitmap fonts). Ascender and descender come from the OS/2 typo values
// when the font has them, unrounded, so both text backends agree (see text/text.odin); otherwise
// from FreeType's size metrics.
void myod_ft_metrics(FT_Face face, double *ascender, double *descender, double *height) {
	FT_Size_Metrics m = face->size->metrics;
	*ascender = m.ascender / 64.0;
	*descender = -m.descender / 64.0;
	*height = m.height / 64.0;
	TT_OS2 *os2 = (TT_OS2 *)FT_Get_Sfnt_Table(face, FT_SFNT_OS2);
	if (os2 && os2->version != 0xFFFF && FT_IS_SCALABLE(face)) {
		*ascender = FT_MulFix(os2->sTypoAscender, m.y_scale) / 64.0;
		*descender = -FT_MulFix(os2->sTypoDescender, m.y_scale) / 64.0;
	}
}

// The glyph index for a code point, or 0 if the font lacks it.
unsigned int myod_ft_char_index(FT_Face face, unsigned int codepoint) {
	return FT_Get_Char_Index(face, codepoint);
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

// Sets variation axes by tag (design coordinates); axes not listed keep their defaults.
// Returns 0 on success, or non-zero if the face is not a variable font.
int myod_ft_set_variations(FT_Face face, const unsigned int *tags, const double *values, int count) {
	FT_MM_Var *mm = NULL;
	if (FT_Get_MM_Var(face, &mm)) return 1;
	FT_Fixed coords[32];
	unsigned int n = mm->num_axis < 32 ? mm->num_axis : 32;
	for (unsigned int i = 0; i < n; i++) {
		coords[i] = mm->axis[i].def;
		for (int j = 0; j < count; j++) {
			if (mm->axis[i].tag == tags[j]) coords[i] = (FT_Fixed)(values[j] * 65536.0);
		}
	}
	int err = FT_Set_Var_Design_Coordinates(face, n, coords);
	FT_Done_MM_Var(face->glyph->library, mm);
	return err;
}
