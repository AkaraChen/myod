// Text: fonts, shaping, glyph rasterization into the atlases, measuring, wrapping and drawing.
//
// The platform-independent part lives here. Each platform provides the backend_* procs
// (see ARCHITECTURE.md, "Technology choices": CoreText on macOS; Fontconfig + FreeType + HarfBuzz
// on Linux). `text/backend.odin` picks one at compile time.
package text

import "core:math"
import "core:os"
import "core:strconv"
import "core:path/filepath"
import "core:strings"
import "core:unicode"
import "core:unicode/utf8"

import "../atlas"
import "../icons"
import "../render"
import "../sprite"
import "../theme"
import svg "../third_party/odin/myod_svg"
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
	// A font from load_font. Zero means DWG, in the style's weight.
	font:           Font_Ref,
	// OpenType features, CSS-like: "ss19 -calt frac=1". `tag` turns a feature on, `-tag` off.
	features:       string,
	// Variable font axes: "wght=450 wdth=90". Axes not listed keep their defaults.
	variations:     string,
	underline:      bool,
	// Uppercase Latin letters before shaping; Chinese and other scripts are left alone.
	uppercase:      bool,
	// Extra space after each Latin character, in em. Rounded to whole physical pixels so glyphs
	// stay on the pixel grid; never applied to Chinese characters.
	letter_spacing: f32,
}

Font_Id :: distinct u32 // a font loaded into the backend
Face_Id :: distinct u32 // a font at one physical pixel size, with one set of features and axes
Font_Ref :: distinct u32 // a font from load_font, for Style.font; 0 means DWG

Feature :: struct {
	tag:   [4]u8,
	value: u32,
}

Variation :: struct {
	tag:   [4]u8,
	value: f32,
}

NO_FONT :: max(Font_Id)

// One shaped glyph. Positions are in physical pixels from the start of the run.
Shaped_Glyph :: struct {
	face:    Face_Id, // may differ from the requested face when a fallback font supplied the glyph
	glyph:   u32,     // a glyph index, or the code point when face is SPRITE_FACE
	x, y:    f32,
	advance: f32,     // distance to the next glyph (the cell width, for sprite glyphs)
	cluster: u32,     // UTF-8 byte offset of the cluster in the source string
}

// The face of glyphs drawn by the sprite package (box drawing, blocks, Braille, Powerline).
SPRITE_FACE :: max(Face_Id) - 1

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

// Atlas pages are ATLAS_SIZE × ATLAS_SIZE. The budget follows ARCHITECTURE.md, "Rendering backend":
// 4 mask pages (16MB) and 2 color pages (32MB).
ATLAS_SIZE :: 2048
MASK_PAGES :: 4
COLOR_PAGES :: 2

Context :: struct {
	backend: Backend,
	atlases: [atlas.Kind]atlas.Atlas,
	dwg:     [Weight]Font_Id,
	fonts:   [dynamic]Font_Id, // Font_Ref → Font_Id; index 0 is unused (it means DWG)
	glyphs:  map[Glyph_Key]Glyph_Entry,
	icons:   map[Icon_Key]Glyph_Entry,
	shapes:  map[Shape_Key]Shape_Entry,
	frame:   u64,
}

@(private)
Glyph_Key :: struct {
	face:     Face_Id,
	glyph:    u32,
	subpixel: u8,
	cell:     [2]i32, // sprite glyphs only: the cell size they were drawn for
}

@(private)
Icon_Key :: struct {
	name:   string, // icon names are static strings from icons/phosphor
	weight: icons.Weight,
	layer:  i8,
	size:   i32, // physical pixels
}

@(private)
Glyph_Entry :: struct {
	kind:   atlas.Kind,
	loc:    atlas.Location,
	size:   [2]i32,
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
// third_party/fonts relative to the working directory. The atlas parameters exist for tests that
// need to force page eviction.
init :: proc(ctx: ^Context, font_dir := "", atlas_size: i32 = ATLAS_SIZE, mask_pages := MASK_PAGES, color_pages := COLOR_PAGES) -> bool {
	if !backend_init(&ctx.backend) {
		return false
	}
	append(&ctx.fonts, NO_FONT)
	ub.init_linebreak()
	ub.init_graphemebreak()
	ub.init_wordbreak()
	atlas.init(&ctx.atlases[.Mask], .Mask, atlas_size, mask_pages)
	atlas.init(&ctx.atlases[.Color], .Color, atlas_size, color_pages)

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
	delete(ctx.icons)
	delete(ctx.fonts)
	for &a in ctx.atlases {
		atlas.destroy(&a)
	}
	backend_destroy(&ctx.backend)
}

// Call once per frame: tracks atlas page use and evicts shaping results not used recently.
begin_frame :: proc(ctx: ^Context) {
	ctx.frame += 1
	for &a in ctx.atlases {
		atlas.begin_frame(&a)
	}
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

// Loads a font file (TrueType / OpenType) for use through Style.font.
load_font :: proc(ctx: ^Context, path: string) -> (Font_Ref, bool) {
	data, err := os.read_entire_file_from_path(path, context.allocator)
	if err != nil {
		return 0, false
	}
	defer delete(data)
	id, ok := backend_load_font(&ctx.backend, data)
	if !ok {
		return 0, false
	}
	append(&ctx.fonts, id)
	return Font_Ref(len(ctx.fonts) - 1), true
}

face_for :: proc(ctx: ^Context, style: Style, scale: f32) -> Face_Id {
	font := ctx.fonts[style.font] if style.font != 0 else ctx.dwg[style.weight]
	return backend_face(&ctx.backend, font, physical_size(style.size, scale), style.features, style.variations)
}

// Parses "ss19 -calt frac=1" into features. Unknown syntax is skipped.
parse_features :: proc(s: string, allocator := context.temp_allocator) -> []Feature {
	out := make([dynamic]Feature, allocator)
	rest := s
	for item in strings.fields_iterator(&rest) {
		f := Feature{value = 1}
		name := item
		if strings.has_prefix(name, "-") {
			f.value = 0
			name = name[1:]
		}
		if eq := strings.index_byte(name, '='); eq >= 0 {
			v, ok := strconv.parse_uint(name[eq + 1:])
			if !ok {
				continue
			}
			f.value = u32(v)
			name = name[:eq]
		}
		if len(name) != 4 {
			continue
		}
		copy(f.tag[:], name)
		append(&out, f)
	}
	return out[:]
}

// Parses "wght=450 wdth=90" into variation axis settings. Unknown syntax is skipped.
parse_variations :: proc(s: string, allocator := context.temp_allocator) -> []Variation {
	out := make([dynamic]Variation, allocator)
	rest := s
	for item in strings.fields_iterator(&rest) {
		eq := strings.index_byte(item, '=')
		if eq != 4 {
			continue
		}
		v, ok := strconv.parse_f32(item[eq + 1:])
		if !ok {
			continue
		}
		var := Variation{value = v}
		copy(var.tag[:], item[:4])
		append(&out, var)
	}
	return out[:]
}

// An OpenType tag as a 32-bit big-endian integer, the form CoreText, FreeType and HarfBuzz use.
tag_u32 :: proc(tag: [4]u8) -> u32 {
	return u32(tag[0]) << 24 | u32(tag[1]) << 16 | u32(tag[2]) << 8 | u32(tag[3])
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
	finish_glyphs(&shaped, s)
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
	draw_glyphs(list, ctx, sh, 0, len(s), 0, sh.width, pos, style, scale)
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
		draw_glyphs(list, ctx, sh, l.start, l.end, l.x0, l.width, {pos.x, pos.y + f32(i) * style.line_height}, style, scale)
	}
}

// Emits the glyphs of `sh` whose clusters fall in [start, end), shifted left by `x0`; `width` is the
// line's width in physical pixels (for the underline).
@(private)
draw_glyphs :: proc(list: ^render.Command_List, ctx: ^Context, sh: Shaped, start, end: int, x0, width: f32, pos: [2]f32, style: Style, scale: f32) {
	line_top := math.round(pos.y * scale)
	line_bottom := math.round((pos.y + style.line_height) * scale)
	baseline := math.round(pos.y * scale + (line_bottom - line_top - (sh.ascent + sh.descent)) / 2 + sh.ascent)
	phys := physical_size(style.size, scale)

	quads := make([dynamic]render.Glyph_Quad, 0, len(sh.glyphs), context.temp_allocator)
	for g in sh.glyphs {
		if int(g.cluster) < start || int(g.cluster) >= end {
			continue
		}
		x := g.x - x0
		if g.face == SPRITE_FACE {
			// Sprites fill the whole cell: the glyph's advance by the line box, on whole pixels, so
			// cells join with no gaps horizontally and line boxes join vertically.
			ix := math.round(x)
			cell := [2]i32{i32(math.round(x + g.advance) - ix), i32(line_bottom - line_top)}
			e := sprite_entry(ctx, rune(g.glyph), cell, i32(max(1, math.round(phys / 16))))
			if e.empty {
				continue
			}
			append(&quads, quad(e, {i32(ix), i32(line_top - baseline)}))
			continue
		}
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
		y := i32(math.round(g.y)) + e.offset.y
		if e.kind == .Color {
			// Emoji bitmaps carry inconsistent vertical placement across fonts and backends
			// (Apple's sbix relies on another table that FreeType ignores). Center them on the
			// midpoint of the primary font's ascent and descent instead, as Ghostty centers emoji.
			y = i32(math.round(-(sh.ascent - sh.descent) / 2 - f32(e.size.y) / 2))
		}
		append(&quads, quad(e, {i32(ix) + e.offset.x, y}))
	}
	append(&list.commands, render.Cmd_Glyph_Run{origin = {pos.x, baseline / scale}, color = style.color, quads = quads[:]})

	if style.underline && width > 0 {
		thickness := max(1, math.round(phys / 16))
		y := baseline + max(1, math.round(phys * 0.08))
		render.line(list, {pos.x, y / scale, width / scale, thickness / scale}, style.color)
	}
}

@(private)
quad :: proc(e: Glyph_Entry, offset: [2]i32) -> render.Glyph_Quad {
	return {atlas = e.kind, page = e.loc.page, texel = {e.loc.x, e.loc.y, e.size.x, e.size.y}, offset = offset}
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

// Fills in each glyph's advance and swaps characters the sprite package draws for sprite glyphs.
@(private)
finish_glyphs :: proc(sh: ^Shaped, s: string) {
	for i in 0 ..< len(sh.glyphs) {
		g := &sh.glyphs[i]
		next := sh.width if i + 1 == len(sh.glyphs) else sh.glyphs[i + 1].x
		g.advance = next - g.x
		r, _ := utf8.decode_rune_in_string(s[g.cluster:])
		if sprite.covers(r) {
			g.face = SPRITE_FACE
			g.glyph = u32(r)
		}
	}
}

// Looks up or rasterizes a glyph. Entries whose atlas page was evicted are rasterized again.
@(private)
glyph_entry :: proc(ctx: ^Context, face: Face_Id, glyph: u32, subpixel: u8) -> Glyph_Entry {
	key := Glyph_Key{face = face, glyph = glyph, subpixel = subpixel}
	if e, found := ctx.glyphs[key]; found && (e.empty || atlas.valid(&ctx.atlases[e.kind], e.loc)) {
		atlas.touch(&ctx.atlases[e.kind], e.loc.page)
		return e
	}
	bm := backend_rasterize(&ctx.backend, face, glyph, f32(subpixel) / SUBPIXEL_STEPS, context.temp_allocator)
	e := store(ctx, bm)
	ctx.glyphs[key] = e
	return e
}

@(private)
sprite_entry :: proc(ctx: ^Context, r: rune, cell: [2]i32, thickness: i32) -> Glyph_Entry {
	key := Glyph_Key{face = SPRITE_FACE, glyph = u32(r), cell = cell}
	if e, found := ctx.glyphs[key]; found && (e.empty || atlas.valid(&ctx.atlases[e.kind], e.loc)) {
		atlas.touch(&ctx.atlases[e.kind], e.loc.page)
		return e
	}
	pixels, ok := sprite.rasterize(r, cell.x, cell.y, thickness, context.temp_allocator)
	bm := Bitmap{w = cell.x, h = cell.y, pixels = pixels} if ok else Bitmap{}
	e := store(ctx, bm)
	ctx.glyphs[key] = e
	return e
}

// Copies a bitmap into the right atlas. A bitmap that does not fit at all yields an empty entry.
@(private)
store :: proc(ctx: ^Context, bm: Bitmap) -> Glyph_Entry {
	if bm.w <= 0 || bm.h <= 0 {
		return {empty = true}
	}
	kind := atlas.Kind.Color if bm.color else atlas.Kind.Mask
	a := &ctx.atlases[kind]
	loc, ok := atlas.alloc(a, bm.w, bm.h)
	if !ok {
		return {empty = true}
	}
	atlas.write(a, loc, bm.w, bm.h, bm.pixels, bm.w * a.bpp)
	atlas.touch(a, loc.page)
	return {kind = kind, loc = loc, size = {bm.w, bm.h}, offset = {bm.left, -bm.top}}
}

// ---- Icons ----

// Draws an SVG icon `size` logical pixels square with its top-left at `pos`, in mask mode so it takes
// `color`. Rasterized at a whole number of physical pixels and placed on whole pixels
// (DESIGN.md, "Icons"). Duotone's background layer uses `secondary`, or `color` at 20% opacity.
draw_icon :: proc(list: ^render.Command_List, ctx: ^Context, icon: icons.Icon, weight: icons.Weight, pos: [2]f32, size: f32, color: theme.Color, scale: f32, secondary := theme.Color{}) {
	px := i32(math.round(size * scale))
	if weight == .Duotone {
		back := secondary if secondary.a > 0 else theme.with_alpha(color, 0.2)
		icon_run(list, ctx, icon, weight, svg.LAYER_TRANSLUCENT, px, pos, back)
		icon_run(list, ctx, icon, weight, svg.LAYER_OPAQUE, px, pos, color)
	} else {
		icon_run(list, ctx, icon, weight, svg.LAYER_ALL, px, pos, color)
	}
}

@(private)
icon_run :: proc(list: ^render.Command_List, ctx: ^Context, icon: icons.Icon, weight: icons.Weight, layer: i32, px: i32, pos: [2]f32, color: theme.Color) {
	e := icon_entry(ctx, icon, weight, layer, px)
	if e.empty {
		return
	}
	quads := make([]render.Glyph_Quad, 1, context.temp_allocator)
	quads[0] = quad(e, {0, 0})
	append(&list.commands, render.Cmd_Glyph_Run{origin = pos, color = color, quads = quads})
}

@(private)
icon_entry :: proc(ctx: ^Context, icon: icons.Icon, weight: icons.Weight, layer: i32, px: i32) -> Glyph_Entry {
	key := Icon_Key{name = icon.name, weight = weight, layer = i8(layer), size = px}
	if e, found := ctx.icons[key]; found && (e.empty || atlas.valid(&ctx.atlases[e.kind], e.loc)) {
		atlas.touch(&ctx.atlases[e.kind], e.loc.page)
		return e
	}
	source := icon.svg[weight]
	e := Glyph_Entry{empty = true}
	if len(source) > 0 && px > 0 {
		doc := make([]u8, len(source) + 1, context.temp_allocator) // NUL-terminated, parsed in place
		copy(doc, source)
		rgba := make([]u8, int(px * px * 4), context.temp_allocator)
		if svg.rasterize(raw_data(doc), px, layer, 1, raw_data(rgba)) == 0 {
			coverage := make([]u8, int(px * px), context.temp_allocator)
			for i in 0 ..< len(coverage) {
				coverage[i] = rgba[i * 4 + 3]
			}
			e = store(ctx, Bitmap{w = px, h = px, pixels = coverage})
		}
	}
	ctx.icons[key] = e
	return e
}

// ---- Lines mixing text and icons ----

Inline_Icon :: struct {
	icon:   icons.Icon,
	weight: icons.Weight,
}

// A piece of a line: text in the line's style, or an icon sized to the style's font size.
Item :: union {
	string,
	Inline_Icon,
}

// Gap between an inline icon and its neighbors, in em.
INLINE_ICON_GAP :: 0.25

// Size of a single line of items in logical pixels.
measure_items :: proc(ctx: ^Context, items: []Item, style: Style, scale: f32) -> [2]f32 {
	width: f32 = 0
	for item, i in items {
		width += item_width(ctx, item, i, len(items), style, scale)
	}
	return {width / scale, style.line_height}
}

// Draws a single line of items; icons are vertically centered on the line, like emoji.
draw_items :: proc(list: ^render.Command_List, ctx: ^Context, items: []Item, pos: [2]f32, style: Style, scale: f32) {
	x: f32 = math.round(pos.x * scale)
	for item, i in items {
		switch v in item {
		case string:
			draw(list, ctx, v, {x / scale, pos.y}, style, scale)
		case Inline_Icon:
			sh := shape(ctx, "", style, scale)
			px := math.round(style.size * scale)
			line_top := math.round(pos.y * scale)
			line_h := math.round((pos.y + style.line_height) * scale) - line_top
			baseline := math.round(line_top + (line_h - (sh.ascent + sh.descent)) / 2 + sh.ascent)
			top := math.round(baseline - (sh.ascent - sh.descent) / 2 - px / 2)
			gap := math.round(INLINE_ICON_GAP * physical_size(style.size, scale))
			left := x + (gap if i > 0 else 0)
			draw_icon(list, ctx, v.icon, v.weight, {left / scale, top / scale}, style.size, style.color, scale)
		}
		x += item_width(ctx, item, i, len(items), style, scale)
	}
}

@(private)
item_width :: proc(ctx: ^Context, item: Item, index, count: int, style: Style, scale: f32) -> f32 {
	switch v in item {
	case string:
		return math.round(shape(ctx, v, style, scale).width)
	case Inline_Icon:
		gap := math.round(INLINE_ICON_GAP * physical_size(style.size, scale))
		w := math.round(style.size * scale)
		if index > 0 {
			w += gap
		}
		if index + 1 < count {
			w += gap
		}
		return w
	}
	return 0
}
