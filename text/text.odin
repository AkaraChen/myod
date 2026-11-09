// Text: fonts, shaping, glyph rasterization into the atlases, measuring and drawing.
//
// The platform-independent part lives here. Each platform provides the backend_* procs
// (see ARCHITECTURE.md, "Technology choices": CoreText on macOS; Fontconfig + FreeType + HarfBuzz
// on Linux).
package text

import "core:math"
import "core:os"
import "core:path/filepath"
import "core:strings"

import "../atlas"
import "../render"
import "../theme"

Weight :: enum u8 {
	Regular,
	Bold,
}

// A text style in logical pixels.
Style :: struct {
	size:        f32,
	line_height: f32,
	weight:      Weight,
	color:       theme.Color,
}

Font_Id :: distinct u32 // a loaded font file
Face_Id :: distinct u32 // a font at one physical pixel size

NO_FONT :: max(Font_Id)

// One shaped glyph. Positions are in physical pixels from the start of the run.
Shaped_Glyph :: struct {
	face:    Face_Id, // may differ from the requested face when a fallback font supplied the glyph
	glyph:   u32,
	x, y:    f32,
	cluster: u32, // UTF-16 index into the source string for now
}

Shaped :: struct {
	glyphs:  []Shaped_Glyph,
	width:   f32, // physical pixels
	ascent:  f32, // of the requested face, physical pixels
	descent: f32,
}

// A rasterized glyph. `left` / `top` place the bitmap's top-left corner relative to the pen
// position on the baseline (top is measured upward).
Bitmap :: struct {
	w, h:      i32,
	left, top: i32,
	pixels:    []u8, // R8 coverage, or RGBA8 straight alpha when `color` is set
	color:     bool,
}

// Subpixel positions per pixel. Glyphs are rasterized at one of these horizontal offsets.
SUBPIXEL_STEPS :: 4

// Shaping results unused for this many frames are evicted.
SHAPE_CACHE_FRAMES :: 120

ATLAS_SIZE :: 2048

Context :: struct {
	backend: Backend,
	atlases: [atlas.Kind]atlas.Atlas,
	dwg:     [Weight]Font_Id,
	glyphs:  map[Glyph_Key]Glyph_Entry,
	shapes:  map[Shape_Key]Shape_Entry,
	frame:   u64,
}

@(private)
Glyph_Key :: struct {
	face:     Face_Id,
	glyph:    u32,
	subpixel: u8,
}

@(private)
Glyph_Entry :: struct {
	kind:   atlas.Kind,
	texel:  [4]i32,
	offset: [2]i32, // bitmap top-left relative to the pen position, y down
	empty:  bool,
}

@(private)
Shape_Key :: struct {
	text: string,
	face: Face_Id,
}

@(private)
Shape_Entry :: struct {
	shaped:    Shaped,
	last_used: u64,
}

// Loads DWG (DESIGN.md, "Typography") from `font_dir`, from $MYOD_FONT_DIR, or from
// third_party/fonts relative to the working directory.
init :: proc(ctx: ^Context, font_dir := "") -> bool {
	if !backend_init(&ctx.backend) {
		return false
	}
	atlas.init(&ctx.atlases[.Mask], .Mask, ATLAS_SIZE)
	atlas.init(&ctx.atlases[.Color], .Color, ATLAS_SIZE)

	dir := font_dir
	if dir == "" {
		dir = os.get_env("MYOD_FONT_DIR", context.temp_allocator)
	}
	if dir == "" {
		dir = "third_party/fonts"
	}
	files := [Weight]string {
		.Regular = "AKRDWGSCNFM-Regular.ttf",
		.Bold    = "AKRDWGSCNFM-Bold.ttf",
	}
	for file, weight in files {
		path, join_err := filepath.join({dir, file}, context.temp_allocator)
		if join_err != nil {
			return false
		}
		data, read_err := os.read_entire_file_from_path(path, context.allocator)
		if read_err != nil {
			return false
		}
		defer delete(data)
		ok: bool
		ctx.dwg[weight], ok = backend_load_font(&ctx.backend, data)
		if !ok {
			return false
		}
	}
	return true
}

destroy :: proc(ctx: ^Context) {
	for key, entry in ctx.shapes {
		delete(key.text)
		delete(entry.shaped.glyphs)
	}
	delete(ctx.shapes)
	delete(ctx.glyphs)
	for &a in ctx.atlases {
		atlas.destroy(&a)
	}
	backend_destroy(&ctx.backend)
}

// Call once per frame: evicts shaping results that have not been used recently.
begin_frame :: proc(ctx: ^Context) {
	ctx.frame += 1
	if ctx.frame % 60 != 0 {
		return
	}
	stale := make([dynamic]Shape_Key, context.temp_allocator)
	for key, entry in ctx.shapes {
		if ctx.frame - entry.last_used > SHAPE_CACHE_FRAMES {
			append(&stale, key)
		}
	}
	for key in stale {
		entry := ctx.shapes[key]
		delete(entry.shaped.glyphs)
		delete_key(&ctx.shapes, key)
		delete(key.text)
	}
}

// Font size in physical pixels, rounded to an even number so DWG's half-width advance is a whole
// number of pixels at any scale (DESIGN.md, "Implementation implications").
physical_size :: proc(size, scale: f32) -> f32 {
	return max(2, math.round(size * scale / 2) * 2)
}

face_for :: proc(ctx: ^Context, style: Style, scale: f32) -> Face_Id {
	return backend_face(&ctx.backend, ctx.dwg[style.weight], physical_size(style.size, scale))
}

// Shapes `s` with the style's face, using the shaping cache.
shape :: proc(ctx: ^Context, s: string, style: Style, scale: f32) -> Shaped {
	face := face_for(ctx, style, scale)
	key := Shape_Key{s, face}
	if entry, found := &ctx.shapes[key]; found {
		entry.last_used = ctx.frame
		return entry.shaped
	}
	shaped := backend_shape(&ctx.backend, face, s, context.allocator)
	ctx.shapes[Shape_Key{strings.clone(s), face}] = {shaped = shaped, last_used = ctx.frame}
	return shaped
}

// Size of a single line of text in logical pixels: its advance width and the style's line height.
measure :: proc(ctx: ^Context, s: string, style: Style, scale: f32) -> [2]f32 {
	sh := shape(ctx, s, style, scale)
	return {sh.width / scale, style.line_height}
}

// Draws a single line of text. `pos` is the top-left of the line box in logical pixels; the font's
// ascent + descent is centered vertically in the line box.
draw :: proc(list: ^render.Command_List, ctx: ^Context, s: string, pos: [2]f32, style: Style, scale: f32) {
	sh := shape(ctx, s, style, scale)
	line_h := style.line_height * scale
	baseline := math.round(pos.y * scale + (line_h - (sh.ascent + sh.descent)) / 2 + sh.ascent)

	quads := make([dynamic]render.Glyph_Quad, 0, len(sh.glyphs), context.temp_allocator)
	for g in sh.glyphs {
		ix := math.floor(g.x)
		step := int(math.round((g.x - ix) * SUBPIXEL_STEPS))
		if step == SUBPIXEL_STEPS {
			ix += 1
			step = 0
		}
		e := glyph_entry(ctx, g.face, g.glyph, u8(step))
		if e.empty {
			continue
		}
		append(&quads, render.Glyph_Quad {
			atlas = e.kind,
			texel = e.texel,
			offset = {i32(ix) + e.offset.x, i32(math.round(g.y)) + e.offset.y},
		})
	}
	append(&list.commands, render.Cmd_Glyph_Run{origin = {pos.x, baseline / scale}, color = style.color, quads = quads[:]})
}

@(private)
glyph_entry :: proc(ctx: ^Context, face: Face_Id, glyph: u32, subpixel: u8) -> Glyph_Entry {
	key := Glyph_Key{face, glyph, subpixel}
	if e, found := ctx.glyphs[key]; found {
		return e
	}
	bm := backend_rasterize(&ctx.backend, face, glyph, f32(subpixel) / SUBPIXEL_STEPS, context.temp_allocator)
	e := Glyph_Entry{empty = true}
	if bm.w > 0 && bm.h > 0 {
		kind := atlas.Kind.Color if bm.color else atlas.Kind.Mask
		a := &ctx.atlases[kind]
		x, y, ok := atlas.alloc(a, bm.w, bm.h)
		if ok {
			atlas.write(a, x, y, bm.w, bm.h, bm.pixels, bm.w * a.bpp)
			e = {kind = kind, texel = {x, y, bm.w, bm.h}, offset = {bm.left, -bm.top}}
		}
		// A full atlas drops the glyph for now; paging and eviction come later in M2.
	}
	ctx.glyphs[key] = e
	return e
}
