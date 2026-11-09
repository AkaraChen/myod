// FreeType + HarfBuzz text backend: Linux's backend (as in Ghostty), and the backend tests use on
// every platform. FreeType rasterizes through myod's small C shim; HarfBuzz shapes through hb-ft.
//
// Font fallback: before shaping, the text is split into grapheme clusters, and each cluster takes
// the first font in [requested font, fallback fonts…] that has its first character. Consecutive
// clusters with the same font are shaped together. The fallback list is built in for now (macOS
// system fonts, so the backend can be tested on a Mac); on Linux it will come from Fontconfig.
package text

import "core:math"
import "core:os"
import "core:strings"
import "core:unicode/utf8"

import hb "../third_party/odin/harfbuzz"
import ft "../third_party/odin/myod_ft"
import ub "../third_party/odin/unibreak"

FreeType_Backend :: struct {
	lib:      ft.Library,
	fonts:    [dynamic]FreeType_Font,
	faces:    [dynamic]FreeType_Face,
	fallback: [dynamic]Font_Id, // tried in order when a face lacks a character
	buffer:   ^hb.Buffer,
}

// A font is either loaded into memory (its data must outlive its faces) or opened by path.
@(private)
FreeType_Font :: struct {
	data:   []u8,
	path:   string,
	failed: bool, // a path-based font FreeType could not open; skipped from then on
}

@(private)
NO_FACE :: max(Face_Id)

@(private)
FreeType_Face :: struct {
	face:        ft.Face, // each face has its own FT_Face: an FT_Face has one size and one set of axes
	hb_font:     ^hb.Font,
	size:        f32,
	base:        Font_Id,
	color:       bool,
	scale:       f32, // color bitmap fonts render at a fixed strike; this maps it to `size`
	ascent:      f32,
	descent:     f32,
	features:    string,
	variations:  string,
	hb_features: []hb.Feature,
}

// Built-in fallback fonts for macOS. Linux fills the list from Fontconfig instead.
@(private)
MACOS_FALLBACK_FONTS :: [?]string {
	"/System/Library/Fonts/Apple Color Emoji.ttc",
	// Not PingFang: CoreText finds CJK extension characters (e.g. 𪚥) in a PingFang collection in a
	// private framework, but FreeType reports its format as unknown (error 0x2).
	"/System/Library/Fonts/Supplemental/Arial Unicode.ttf",
	"/System/Library/Fonts/LastResort.otf",
}

freetype_init :: proc(b: ^FreeType_Backend) -> bool {
	if ft.init(&b.lib) != 0 {
		return false
	}
	b.buffer = hb.buffer_create()
	if b.buffer == nil {
		return false
	}
	when ODIN_OS == .Darwin {
		for path in MACOS_FALLBACK_FONTS {
			if os.exists(path) {
				append(&b.fonts, FreeType_Font{path = path})
				append(&b.fallback, Font_Id(len(b.fonts) - 1))
			}
		}
	}
	return true
}

freetype_destroy :: proc(b: ^FreeType_Backend) {
	for f in b.faces {
		hb.font_destroy(f.hb_font)
		ft.done_face(f.face)
		delete(f.features)
		delete(f.variations)
		delete(f.hb_features)
	}
	for font in b.fonts {
		delete(font.data)
	}
	delete(b.faces)
	delete(b.fonts)
	delete(b.fallback)
	hb.buffer_destroy(b.buffer)
	ft.done(b.lib)
}

freetype_load_font :: proc(b: ^FreeType_Backend, data: []u8) -> (Font_Id, bool) {
	owned := make([]u8, len(data))
	copy(owned, data)
	// Check that FreeType can open it before accepting it.
	probe: ft.Face
	if ft.new_face(b.lib, raw_data(owned), i64(len(owned)), &probe) != 0 {
		delete(owned)
		return NO_FONT, false
	}
	ft.done_face(probe)
	append(&b.fonts, FreeType_Font{data = owned})
	return Font_Id(len(b.fonts) - 1), true
}

@(private)
open_ft_face :: proc(b: ^FreeType_Backend, font: Font_Id) -> (face: ft.Face, ok: bool) {
	src := b.fonts[font]
	err: i32
	if src.data != nil {
		err = ft.new_face(b.lib, raw_data(src.data), i64(len(src.data)), &face)
	} else {
		err = ft.new_face_file(b.lib, strings.clone_to_cstring(src.path, context.temp_allocator), 0, &face)
	}
	return face, err == 0
}

freetype_face :: proc(b: ^FreeType_Backend, font: Font_Id, size: f32, features, variations: string) -> Face_Id {
	for f, i in b.faces {
		if f.base == font && f.size == size && f.features == features && f.variations == variations {
			return Face_Id(i)
		}
	}
	if b.fonts[font].failed {
		return NO_FACE
	}
	ft_face, ok := open_ft_face(b, font)
	if !ok {
		// Loaded fonts were checked by freetype_load_font; only path-based fallback fonts get here.
		assert(b.fonts[font].data == nil, "myod: FreeType failed to open a font it opened before")
		b.fonts[font].failed = true
		return NO_FACE
	}
	f := FreeType_Face{face = ft_face, size = size, base = font, features = strings.clone(features), variations = strings.clone(variations)}
	strike_scale: f64
	ft.set_pixel_size(f.face, u32(size), &strike_scale)
	f.scale = f32(strike_scale)
	if vars := parse_variations(variations); len(vars) > 0 {
		tags := make([]u32, len(vars), context.temp_allocator)
		values := make([]f64, len(vars), context.temp_allocator)
		for v, i in vars {
			tags[i] = tag_u32(v.tag)
			values[i] = f64(v.value)
		}
		ft.set_variations(f.face, raw_data(tags), raw_data(values), i32(len(vars)))
	}
	f.hb_font = hb.ft_font_create_referenced(rawptr(f.face))
	feats := parse_features(features)
	f.hb_features = make([]hb.Feature, len(feats))
	for feat, i in feats {
		f.hb_features[i] = {tag = tag_u32(feat.tag), value = feat.value, start = 0, end = hb.FEATURE_GLOBAL_END}
	}
	f.color = ft.has_color(f.face) != 0
	asc, desc, height: f64
	ft.metrics(f.face, &asc, &desc, &height)
	f.ascent = f32(asc) * f.scale
	f.descent = f32(desc) * f.scale
	append(&b.faces, f)
	return Face_Id(len(b.faces) - 1)
}

// The face that should render `r`: the requested face if it has the character, otherwise the
// first fallback font that does, otherwise the requested face (which draws .notdef).
@(private)
face_for_rune :: proc(b: ^FreeType_Backend, primary: Face_Id, r: rune) -> Face_Id {
	if ft.char_index(b.faces[primary].face, u32(r)) != 0 {
		return primary
	}
	size := b.faces[primary].size
	for font in b.fallback {
		fb := freetype_face(b, font, size, "", "")
		if fb != NO_FACE && ft.char_index(b.faces[fb].face, u32(r)) != 0 {
			return fb
		}
	}
	return primary
}

freetype_shape :: proc(b: ^FreeType_Backend, face: Face_Id, s: string, allocator := context.allocator) -> Shaped {
	primary := b.faces[face]
	out := Shaped{ascent = primary.ascent, descent = primary.descent}
	if len(s) == 0 {
		return out
	}

	// Split into runs of grapheme clusters that share a face.
	Run :: struct {
		face:       Face_Id,
		start, end: int,
	}
	brks := make([]u8, len(s), context.temp_allocator)
	ub.set_graphemebreaks_utf8(raw_data(s), uint(len(s)), nil, raw_data(brks))
	runs := make([dynamic]Run, context.temp_allocator)
	cluster_start := 0
	for i in 0 ..< len(s) {
		if brks[i] != ub.GRAPHEMEBREAK_BREAK {
			continue
		}
		r, _ := utf8.decode_rune_in_string(s[cluster_start:])
		f := face_for_rune(b, face, r)
		if n := len(runs); n > 0 && runs[n - 1].face == f {
			runs[n - 1].end = i + 1
		} else {
			append(&runs, Run{face = f, start = cluster_start, end = i + 1})
		}
		cluster_start = i + 1
	}

	glyphs := make([dynamic]Shaped_Glyph, allocator)
	pen: f32 = 0
	for run in runs {
		f := b.faces[run.face]
		hb.buffer_reset(b.buffer)
		// The whole string goes in as context; only the run's bytes are shaped. Clusters stay
		// byte offsets into `s`.
		hb.buffer_add_utf8(b.buffer, raw_data(s), i32(len(s)), u32(run.start), i32(run.end - run.start))
		hb.buffer_guess_segment_properties(b.buffer)
		// HarfBuzz's defaults include `liga` and `calt`; the face's features override them.
		hb.shape(f.hb_font, b.buffer, raw_data(f.hb_features), u32(len(f.hb_features)))

		n: u32
		infos := hb.buffer_get_glyph_infos(b.buffer, &n)
		positions := hb.buffer_get_glyph_positions(b.buffer, &n)
		for i in 0 ..< int(n) {
			p := positions[i]
			append(&glyphs, Shaped_Glyph {
				face    = run.face,
				glyph   = infos[i].codepoint,
				x       = pen + f32(p.x_offset) / 64 * f.scale,
				y       = -f32(p.y_offset) / 64 * f.scale,
				cluster = infos[i].cluster, // a UTF-8 byte offset into `s`
			})
			pen += f32(p.x_advance) / 64 * f.scale
		}
	}
	out.glyphs = glyphs[:]
	out.width = pen
	return out
}

freetype_rasterize :: proc(b: ^FreeType_Backend, face: Face_Id, glyph: u32, subpixel: f32, allocator := context.allocator) -> (bm: Bitmap) {
	f := b.faces[face]
	src: ft.Bitmap
	if ft.render(f.face, glyph, i32(math.round(subpixel * 64)), i32(f.color), &src) != 0 {
		return
	}
	if src.width <= 0 || src.rows <= 0 {
		return
	}
	bm.w = src.width
	bm.h = src.rows
	bm.left = src.left
	bm.top = src.top
	pitch := abs(src.pitch)

	switch src.pixel_mode {
	case ft.PIXEL_MODE_GRAY:
		pixels := make([]u8, int(bm.w * bm.h), allocator)
		for y in 0 ..< bm.h {
			copy(pixels[y * bm.w:][:bm.w], src.buffer[y * pitch:][:bm.w])
		}
		bm.pixels = pixels
	case ft.PIXEL_MODE_BGRA:
		// Premultiplied BGRA → premultiplied RGBA, scaled from the strike, then straight alpha.
		pixels := make([]u8, int(bm.w * bm.h * 4), allocator)
		for y in 0 ..< bm.h {
			row := src.buffer[y * pitch:]
			for x in 0 ..< bm.w {
				o := (y * bm.w + x) * 4
				pixels[o + 0], pixels[o + 1], pixels[o + 2], pixels[o + 3] = row[x * 4 + 2], row[x * 4 + 1], row[x * 4 + 0], row[x * 4 + 3]
			}
		}
		bm.pixels = pixels
		bm.color = true
		if f.scale != 1 {
			bm = scale_bitmap(bm, f.scale, allocator)
		}
		unpremultiply_rgba(bm.pixels)
	case:
		return {}
	}
	return
}

// Box-filters a premultiplied RGBA bitmap by `scale` (used to bring color bitmap strikes to size).
@(private)
scale_bitmap :: proc(src: Bitmap, scale: f32, allocator := context.allocator) -> Bitmap {
	dst := src
	dst.w = max(1, i32(math.round(f32(src.w) * scale)))
	dst.h = max(1, i32(math.round(f32(src.h) * scale)))
	dst.left = i32(math.round(f32(src.left) * scale))
	dst.top = i32(math.round(f32(src.top) * scale))
	dst.pixels = make([]u8, int(dst.w * dst.h * 4), allocator)
	sx := f32(src.w) / f32(dst.w)
	sy := f32(src.h) / f32(dst.h)
	for y in 0 ..< dst.h {
		y0 := i32(f32(y) * sy)
		y1 := max(y0 + 1, min(src.h, i32(math.ceil(f32(y + 1) * sy))))
		for x in 0 ..< dst.w {
			x0 := i32(f32(x) * sx)
			x1 := max(x0 + 1, min(src.w, i32(math.ceil(f32(x + 1) * sx))))
			sum: [4]u32
			for yy in y0 ..< y1 {
				for xx in x0 ..< x1 {
					o := (yy * src.w + xx) * 4
					for c in 0 ..< 4 {
						sum[c] += u32(src.pixels[o + i32(c)])
					}
				}
			}
			count := u32((y1 - y0) * (x1 - x0))
			o := (y * dst.w + x) * 4
			for c in 0 ..< 4 {
				dst.pixels[o + i32(c)] = u8((sum[c] + count / 2) / count)
			}
		}
	}
	return dst
}

// Converts premultiplied RGBA to straight alpha; the color atlas stores straight alpha.
@(private)
unpremultiply_rgba :: proc(pixels: []u8) {
	for i := 0; i < len(pixels); i += 4 {
		a := u32(pixels[i + 3])
		if a == 0 || a == 255 {
			continue
		}
		for c in 0 ..< 3 {
			pixels[i + c] = u8(min(255, (u32(pixels[i + c]) * 255 + a / 2) / a))
		}
	}
}
