// Text: fonts, shaping, glyph rasterization into the atlases, measuring, wrapping and drawing.
//
// The platform-independent part lives here. Each platform provides the backend_* procs
// (see ARCHITECTURE.md, "Technology choices": CoreText on macOS; Fontconfig + FreeType + HarfBuzz
// on Linux). `text/backend.odin` picks one at compile time.
package text

import "core:math"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:unicode"
import "core:unicode/utf8"

import "../atlas"
import "../render"
import "../theme"
import ub "../third_party/odin/unibreak"

Weight :: enum u8 {
	Regular,
	Bold,
}

// A text style in logical pixels.
Style :: struct {
	size:           f32,
	line_height:    f32,
	weight:         Weight,
	color:          theme.Color,
	// Uppercase Latin letters before shaping; Chinese and other scripts are left alone.
	uppercase:      bool,
	// Extra space after each Latin character, in em. Rounded to whole physical pixels so glyphs
	// stay on the pixel grid; never applied to Chinese characters.
	letter_spacing: f32,
}

Font_Id :: distinct u32 // a loaded font file
Face_Id :: distinct u32 // a font at one physical pixel size

NO_FONT :: max(Font_Id)

// One shaped glyph. Positions are in physical pixels from the start of the run.
Shaped_Glyph :: struct {
	face:    Face_Id, // may differ from the requested face when a fallback font supplied the glyph
	glyph:   u32,
	x, y:    f32,
	cluster: u32, // UTF-8 byte offset of the cluster in the source string
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

// One line of a wrapped paragraph: a byte range of the source string (trailing whitespace and line
// breaks excluded) and where it sits in the paragraph's single shaped run.
Line :: struct {
	start, end: int,
	x0:         f32, // physical pixels: where the line starts in the shaped run
	width:      f32, // physical pixels
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

// Everything that changes the shaping result.
@(private)
Shape_Key :: struct {
	text:      string,
	face:      Face_Id,
	uppercase: bool,
	spacing:   f32, // physical pixels
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
	ub.init_linebreak()
	ub.init_graphemebreak()
	ub.init_wordbreak()
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

// Shapes `s` as a single run with the style's face, using the shaping cache. Uppercasing and
// letter spacing are applied here; clusters always refer to bytes of `s` itself.
shape :: proc(ctx: ^Context, s: string, style: Style, scale: f32) -> Shaped {
	face := face_for(ctx, style, scale)
	spacing := math.round(style.letter_spacing * physical_size(style.size, scale))
	key := Shape_Key{s, face, style.uppercase, spacing}
	if entry, found := &ctx.shapes[key]; found {
		entry.last_used = ctx.frame
		return entry.shaped
	}

	source := uppercase_latin(s, context.temp_allocator) if style.uppercase else s
	shaped := backend_shape(&ctx.backend, face, source, context.allocator)
	if spacing != 0 {
		apply_letter_spacing(&shaped, s, spacing)
	}
	key.text = strings.clone(s)
	ctx.shapes[key] = {shaped = shaped, last_used = ctx.frame}
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
	draw_glyphs(list, ctx, sh, 0, len(s), 0, pos, style, scale)
}

// Breaks `s` into lines no wider than `max_width` (logical pixels) at UAX #14 break opportunities.
// A word longer than a whole line overflows on its own line. Explicit line breaks are honored.
wrap :: proc(ctx: ^Context, s: string, style: Style, max_width: f32, scale: f32, allocator := context.temp_allocator) -> []Line {
	lines := make([dynamic]Line, allocator)
	if len(s) == 0 {
		return lines[:]
	}
	sh := shape(ctx, s, style, scale)
	x_at := cluster_positions(sh, len(s), context.temp_allocator)
	limit := max_width * scale

	brks := make([]u8, len(s), context.temp_allocator)
	ub.set_linebreaks_utf8(raw_data(s), uint(len(s)), nil, raw_data(brks))

	start := 0
	last_break := -1 // the latest allowed break after `start`
	emit :: proc(lines: ^[dynamic]Line, s: string, x_at: []f32, start, end: int) {
		e := trim_trailing_space(s, start, end)
		append(lines, Line{start = start, end = e, x0 = x_at[start], width = x_at[e] - x_at[start]})
	}
	for i in 0 ..< len(s) {
		b := brks[i]
		if b != ub.LINEBREAK_ALLOWBREAK && b != ub.LINEBREAK_MUSTBREAK {
			continue
		}
		candidate := i + 1
		width := x_at[trim_trailing_space(s, start, candidate)] - x_at[start]
		if width > limit && last_break > start {
			emit(&lines, s, x_at, start, last_break)
			start = last_break
		}
		if b == ub.LINEBREAK_MUSTBREAK {
			emit(&lines, s, x_at, start, candidate)
			start = candidate
			last_break = -1
		} else {
			last_break = candidate
		}
	}
	if start < len(s) {
		emit(&lines, s, x_at, start, len(s))
	}
	return lines[:]
}

// Size of a wrapped paragraph in logical pixels: the widest line and the total height.
measure_wrapped :: proc(ctx: ^Context, s: string, style: Style, max_width: f32, scale: f32) -> [2]f32 {
	lines := wrap(ctx, s, style, max_width, scale)
	widest: f32 = 0
	for l in lines {
		widest = max(widest, l.width)
	}
	return {widest / scale, f32(len(lines)) * style.line_height}
}

// Draws a wrapped paragraph; `pos` is the top-left of the first line box.
draw_wrapped :: proc(list: ^render.Command_List, ctx: ^Context, s: string, pos: [2]f32, style: Style, max_width: f32, scale: f32) {
	sh := shape(ctx, s, style, scale)
	for l, i in wrap(ctx, s, style, max_width, scale) {
		draw_glyphs(list, ctx, sh, l.start, l.end, l.x0, {pos.x, pos.y + f32(i) * style.line_height}, style, scale)
	}
}

// Emits the glyphs of `sh` whose clusters fall in [start, end), shifted left by `x0`.
@(private)
draw_glyphs :: proc(list: ^render.Command_List, ctx: ^Context, sh: Shaped, start, end: int, x0: f32, pos: [2]f32, style: Style, scale: f32) {
	line_h := style.line_height * scale
	baseline := math.round(pos.y * scale + (line_h - (sh.ascent + sh.descent)) / 2 + sh.ascent)

	quads := make([dynamic]render.Glyph_Quad, 0, len(sh.glyphs), context.temp_allocator)
	for g in sh.glyphs {
		if int(g.cluster) < start || int(g.cluster) >= end {
			continue
		}
		x := g.x - x0
		ix := math.floor(x)
		step := int(math.round((x - ix) * SUBPIXEL_STEPS))
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

// x position (physical pixels) at each byte offset of the source, from the shaped run: the start
// of the cluster at that offset, or of the next cluster for offsets inside one.
@(private)
cluster_positions :: proc(sh: Shaped, n: int, allocator := context.temp_allocator) -> []f32 {
	x_at := make([]f32, n + 1, allocator)
	for &x in x_at {
		x = -1
	}
	for g in sh.glyphs {
		c := int(g.cluster)
		if c <= n && (x_at[c] < 0 || g.x < x_at[c]) {
			x_at[c] = g.x
		}
	}
	x_at[n] = sh.width
	for i := n - 1; i >= 0; i -= 1 {
		if x_at[i] < 0 {
			x_at[i] = x_at[i + 1]
		}
	}
	return x_at
}

@(private)
trim_trailing_space :: proc(s: string, start, end: int) -> int {
	e := end
	for e > start {
		c := s[e - 1]
		if c != ' ' && c != '\t' && c != '\n' && c != '\r' {
			break
		}
		e -= 1
	}
	return e
}

// Uppercases Latin letters, keeping each character's UTF-8 length so cluster offsets still refer to
// the original string.
@(private)
uppercase_latin :: proc(s: string, allocator := context.allocator) -> string {
	b := strings.builder_make(0, len(s), allocator)
	for r in s {
		up := r
		if r < 0x0250 { // Basic Latin through Latin Extended-B
			u := unicode.to_upper(r)
			if utf8.rune_size(u) == utf8.rune_size(r) {
				up = u
			}
		}
		strings.write_rune(&b, up)
	}
	return strings.to_string(b)
}

// Adds `spacing` after every non-CJK cluster except the last.
@(private)
apply_letter_spacing :: proc(sh: ^Shaped, s: string, spacing: f32) {
	extra: f32 = 0
	for i in 0 ..< len(sh.glyphs) {
		g := &sh.glyphs[i]
		if i > 0 && g.cluster != sh.glyphs[i - 1].cluster {
			prev := sh.glyphs[i - 1].cluster
			r, _ := utf8.decode_rune_in_string(s[prev:])
			if !is_cjk(r) {
				extra += spacing
			}
		}
		g.x += extra
	}
	sh.width += extra
}

// Characters that take a full-width cell and never get letter spacing.
is_cjk :: proc(r: rune) -> bool {
	switch r {
	case 0x1100 ..= 0x11FF, // Hangul Jamo
	     0x2E80 ..= 0x9FFF, // CJK radicals, punctuation, kana, unified ideographs
	     0xAC00 ..= 0xD7AF, // Hangul syllables
	     0xF900 ..= 0xFAFF, // CJK compatibility ideographs
	     0xFE30 ..= 0xFE4F, // CJK compatibility forms
	     0xFF00 ..= 0xFF60, // fullwidth forms
	     0xFFE0 ..= 0xFFE6,
	     0x20000 ..= 0x3FFFF: // CJK extensions B and later
		return true
	}
	return false
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
