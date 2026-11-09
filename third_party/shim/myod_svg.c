// A thin C API over nanosvg (zlib license, header-only) for myod's SVG icons.

#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define NANOSVG_IMPLEMENTATION
#include "nanosvg.h"
#define NANOSVGRAST_IMPLEMENTATION
#include "nanosvgrast.h"

// Which shapes to draw.
enum {
	MYOD_SVG_ALL = -1,         // every shape, with its own colors and opacity
	MYOD_SVG_TRANSLUCENT = 0,  // only shapes with opacity < 1 (e.g. Phosphor duotone's background)
	MYOD_SVG_OPAQUE = 1,       // only shapes with opacity 1 (e.g. duotone's foreground)
};

// Rasterizes an SVG document into a size×size RGBA8 image (straight alpha), scaling the document's
// width to `size`. `svg` must be NUL-terminated and is modified by the parser. With `mask` set, the
// selected shapes are drawn opaque white, so the alpha channel is pure coverage.
// Returns 0 on success.
int myod_svg_rasterize(char *svg, int size, int layer, int mask, unsigned char *out) {
	NSVGimage *image = nsvgParse(svg, "px", 96.0f);
	if (!image || image->width <= 0) {
		if (image) nsvgDelete(image);
		return 1;
	}
	for (NSVGshape *s = image->shapes; s; s = s->next) {
		int translucent = s->opacity < 0.999f;
		int keep = layer == MYOD_SVG_ALL || (layer == MYOD_SVG_TRANSLUCENT) == translucent;
		if (!keep) {
			s->flags &= ~NSVG_FLAGS_VISIBLE;
			continue;
		}
		if (mask) {
			s->opacity = 1.0f;
			if (s->fill.type != NSVG_PAINT_NONE) {
				s->fill.type = NSVG_PAINT_COLOR;
				s->fill.color = 0xFFFFFFFF;
			}
			if (s->stroke.type != NSVG_PAINT_NONE) {
				s->stroke.type = NSVG_PAINT_COLOR;
				s->stroke.color = 0xFFFFFFFF;
			}
		}
	}
	NSVGrasterizer *rast = nsvgCreateRasterizer();
	if (!rast) {
		nsvgDelete(image);
		return 1;
	}
	float scale = (float)size / image->width;
	memset(out, 0, (size_t)size * size * 4);
	nsvgRasterize(rast, image, 0, 0, scale, out, size, size, size * 4);
	nsvgDeleteRasterizer(rast);
	nsvgDelete(image);
	return 0;
}
