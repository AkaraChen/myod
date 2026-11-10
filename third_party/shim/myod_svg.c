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

// ---- Scenes built in code ----
//
// Charts build their marks as nanosvg shapes directly, with no SVG text in between: a scene is a
// list of shapes, each a list of subpaths. Points follow nanosvg's own path format (a start point,
// then three points per cubic segment), so the rasterizer needs nothing else.

typedef struct MyodSvgScene {
	NSVGimage *image;
	NSVGshape *shape;   // the shape being built
	NSVGpath *path;     // the subpath being built
	NSVGpath *path_tail;
} MyodSvgScene;

static void myod_svg__finalize_path(MyodSvgScene *sc) {
	NSVGpath *path = sc->path;
	if (!path) return;
	if (path->npts >= 4) {
		// The same bounds nsvg__addPath computes.
		float bounds[4];
		int i;
		for (i = 0; i < path->npts - 1; i += 3) {
			float *curve = &path->pts[i * 2];
			nsvg__curveBounds(bounds, curve);
			if (i == 0) {
				path->bounds[0] = bounds[0];
				path->bounds[1] = bounds[1];
				path->bounds[2] = bounds[2];
				path->bounds[3] = bounds[3];
			} else {
				path->bounds[0] = nsvg__minf(path->bounds[0], bounds[0]);
				path->bounds[1] = nsvg__minf(path->bounds[1], bounds[1]);
				path->bounds[2] = nsvg__maxf(path->bounds[2], bounds[2]);
				path->bounds[3] = nsvg__maxf(path->bounds[3], bounds[3]);
			}
		}
	} else {
		path->bounds[0] = path->bounds[1] = path->bounds[2] = path->bounds[3] = 0.0f;
	}
	sc->path = NULL;
}

static void myod_svg__finalize_shape(MyodSvgScene *sc) {
	NSVGshape *shape = sc->shape;
	if (!shape) return;
	myod_svg__finalize_path(sc);
	if (shape->paths) {
		NSVGpath *p;
		shape->bounds[0] = shape->paths->bounds[0];
		shape->bounds[1] = shape->paths->bounds[1];
		shape->bounds[2] = shape->paths->bounds[2];
		shape->bounds[3] = shape->paths->bounds[3];
		for (p = shape->paths->next; p; p = p->next) {
			shape->bounds[0] = nsvg__minf(shape->bounds[0], p->bounds[0]);
			shape->bounds[1] = nsvg__minf(shape->bounds[1], p->bounds[1]);
			shape->bounds[2] = nsvg__maxf(shape->bounds[2], p->bounds[2]);
			shape->bounds[3] = nsvg__maxf(shape->bounds[3], p->bounds[3]);
		}
	}
	sc->shape = NULL;
	sc->path_tail = NULL;
}

MyodSvgScene *myod_svg_scene_new(float width, float height) {
	MyodSvgScene *sc = (MyodSvgScene*)calloc(1, sizeof(MyodSvgScene));
	if (!sc) return NULL;
	sc->image = (NSVGimage*)calloc(1, sizeof(NSVGimage));
	if (!sc->image) {
		free(sc);
		return NULL;
	}
	sc->image->width = width;
	sc->image->height = height;
	return sc;
}

void myod_svg_scene_free(MyodSvgScene *sc) {
	if (!sc) return;
	myod_svg__finalize_shape(sc);
	nsvgDelete(sc->image);
	free(sc);
}

// Starts a shape. Colors are 0xRRGGBBAA; `stroke_width` 0 draws no stroke. `even_odd` picks the
// even-odd fill rule, otherwise non-zero.
void myod_svg_begin(MyodSvgScene *sc, unsigned int fill, unsigned int stroke, float stroke_width, int even_odd, float opacity) {
	if (!sc) return;
	myod_svg__finalize_shape(sc);
	NSVGshape *shape = (NSVGshape*)calloc(1, sizeof(NSVGshape));
	if (!shape) return;
	shape->fill.type = NSVG_PAINT_COLOR;
	shape->fill.color = fill;
	shape->stroke.type = stroke_width > 0.0f ? NSVG_PAINT_COLOR : NSVG_PAINT_NONE;
	shape->stroke.color = stroke;
	shape->strokeWidth = stroke_width;
	shape->strokeLineJoin = NSVG_JOIN_ROUND;
	shape->strokeLineCap = NSVG_CAP_ROUND;
	shape->miterLimit = 4.0f;
	shape->fillRule = even_odd ? NSVG_FILLRULE_EVENODD : NSVG_FILLRULE_NONZERO;
	shape->opacity = opacity;
	shape->flags = NSVG_FLAGS_VISIBLE;
	if (!sc->image->shapes) {
		sc->image->shapes = shape;
	} else {
		NSVGshape *tail = sc->image->shapes;
		while (tail->next) tail = tail->next;
		tail->next = shape;
	}
	sc->shape = shape;
}

// Starts a subpath at (x, y).
void myod_svg_move(MyodSvgScene *sc, float x, float y) {
	if (!sc || !sc->shape) return;
	myod_svg__finalize_path(sc);
	NSVGpath *path = (NSVGpath*)calloc(1, sizeof(NSVGpath));
	if (!path) return;
	path->pts = (float*)malloc(2 * sizeof(float));
	if (!path->pts) {
		free(path);
		return;
	}
	path->pts[0] = x;
	path->pts[1] = y;
	path->npts = 1;
	if (!sc->shape->paths) {
		sc->shape->paths = path;
	} else {
		sc->path_tail->next = path;
	}
	sc->path_tail = path;
	sc->path = path;
}

static void myod_svg__add_points(MyodSvgScene *sc, float ax, float ay, float bx, float by, float cx, float cy) {
	NSVGpath *path = sc->path;
	if (!path) return;
	float *pts = (float*)realloc(path->pts, (size_t)(path->npts + 3) * 2 * sizeof(float));
	if (!pts) return;
	path->pts = pts;
	path->pts[path->npts * 2 + 0] = ax;
	path->pts[path->npts * 2 + 1] = ay;
	path->pts[path->npts * 2 + 2] = bx;
	path->pts[path->npts * 2 + 3] = by;
	path->pts[path->npts * 2 + 4] = cx;
	path->pts[path->npts * 2 + 5] = cy;
	path->npts += 3;
}

void myod_svg_line(MyodSvgScene *sc, float x, float y) {
	if (!sc || !sc->path) return;
	NSVGpath *path = sc->path;
	float px = path->pts[(path->npts - 1) * 2 + 0];
	float py = path->pts[(path->npts - 1) * 2 + 1];
	float dx = x - px, dy = y - py;
	myod_svg__add_points(sc, px + dx / 3.0f, py + dy / 3.0f, x - dx / 3.0f, y - dy / 3.0f, x, y);
}

void myod_svg_cubic(MyodSvgScene *sc, float c1x, float c1y, float c2x, float c2y, float x, float y) {
	myod_svg__add_points(sc, c1x, c1y, c2x, c2y, x, y);
}

void myod_svg_quad(MyodSvgScene *sc, float cx, float cy, float x, float y) {
	if (!sc || !sc->path) return;
	NSVGpath *path = sc->path;
	float px = path->pts[(path->npts - 1) * 2 + 0];
	float py = path->pts[(path->npts - 1) * 2 + 1];
	// The cubic equivalent of a quadratic: control points two thirds of the way to the handle.
	myod_svg_cubic(sc, px + 2.0f / 3.0f * (cx - px), py + 2.0f / 3.0f * (cy - py),
		x + 2.0f / 3.0f * (cx - x), y + 2.0f / 3.0f * (cy - y), x, y);
}

void myod_svg_close(MyodSvgScene *sc) {
	if (!sc || !sc->path) return;
	sc->path->closed = 1;
}

// Rasterizes the finished scene into a width×height RGBA8 image (straight alpha). Returns 0 on
// success. The scene can be rasterized more than once (at another size).
int myod_svg_scene_rasterize(MyodSvgScene *sc, int width, int height, unsigned char *out) {
	if (!sc || width <= 0 || height <= 0) return 1;
	myod_svg__finalize_shape(sc);
	NSVGrasterizer *rast = nsvgCreateRasterizer();
	if (!rast) return 1;
	memset(out, 0, (size_t)width * height * 4);
	nsvgRasterize(rast, sc->image, 0, 0, 1.0f, out, width, height, width * 4);
	nsvgDeleteRasterizer(rast);
	return 0;
}
