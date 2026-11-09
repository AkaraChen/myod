// FreeType + HarfBuzz text backend: Linux's backend (as in Ghostty), and the backend tests use on
// every platform. FreeType rasterizes through myod's small C shim; HarfBuzz shapes through hb-ft.
//
// Font fallback (Fontconfig on Linux) is not wired in yet: characters a font lacks shape to .notdef.
package text

import "core:math"

import hb "../third_party/odin/harfbuzz"
import ft "../third_party/odin/myod_ft"

FreeType_Backend :: struct {
	lib:    ft.Library,
	fonts:  [dynamic][]u8, // font file data; FreeType faces read from it, so it must outlive them
	faces:  [dynamic]FreeType_Face,
	buffer: ^hb.Buffer,
}

@(private)
FreeType_Face :: struct {
	face:    ft.Face, // each face has its own FT_Face, since an FT_Face has one current size
	hb_font: ^hb.Font,
	size:    f32,
	base:    Font_Id,
	color:   bool,
	ascent:  f32,
	descent: f32,
}

freetype_init :: proc(b: ^FreeType_Backend) -> bool {
	if ft.init(&b.lib) != 0 {
		return false
	}
	b.buffer = hb.buffer_create()
	return b.buffer != nil
}

freetype_destroy :: proc(b: ^FreeType_Backend) {
	for f in b.faces {
		hb.font_destroy(f.hb_font)
		ft.done_face(f.face)
	}
	for data in b.fonts {
		delete(data)
	}
	delete(b.faces)
	delete(b.fonts)
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
	append(&b.fonts, owned)
	return Font_Id(len(b.fonts) - 1), true
}

freetype_face :: proc(b: ^FreeType_Backend, font: Font_Id, size: f32) -> Face_Id {
	for f, i in b.faces {
		if f.base == font && f.size == size {
			return Face_Id(i)
		}
	}
	data := b.fonts[font]
	f := FreeType_Face{size = size, base = font}
	if ft.new_face(b.lib, raw_data(data), i64(len(data)), &f.face) != 0 {
		panic("myod: FreeType failed to open a font it opened before")
	}
	ft.set_pixel_size(f.face, u32(size))
	f.hb_font = hb.ft_font_create_referenced(rawptr(f.face))
	f.color = ft.has_color(f.face) != 0
	asc, desc, height: f64
	ft.metrics(f.face, &asc, &desc, &height)
	f.ascent = f32(asc)
	f.descent = f32(desc)
	append(&b.faces, f)
	return Face_Id(len(b.faces) - 1)
}

freetype_shape :: proc(b: ^FreeType_Backend, face: Face_Id, s: string, allocator := context.allocator) -> Shaped {
	f := b.faces[face]
	out := Shaped{ascent = f.ascent, descent = f.descent}
	if len(s) == 0 {
		return out
	}

	hb.buffer_reset(b.buffer)
	hb.buffer_add_utf8(b.buffer, raw_data(s), i32(len(s)), 0, i32(len(s)))
	hb.buffer_guess_segment_properties(b.buffer)
	hb.shape(f.hb_font, b.buffer, nil, 0) // HarfBuzz's defaults include `liga` and `calt`

	n: u32
	infos := hb.buffer_get_glyph_infos(b.buffer, &n)
	positions := hb.buffer_get_glyph_positions(b.buffer, &n)

	glyphs := make([]Shaped_Glyph, int(n), allocator)
	pen: f32 = 0
	for i in 0 ..< int(n) {
		p := positions[i]
		glyphs[i] = Shaped_Glyph {
			face    = face,
			glyph   = infos[i].codepoint,
			x       = pen + f32(p.x_offset) / 64,
			y       = -f32(p.y_offset) / 64,
			cluster = infos[i].cluster, // a UTF-8 byte offset
		}
		pen += f32(p.x_advance) / 64
	}
	out.glyphs = glyphs
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
		// Premultiplied BGRA → straight RGBA
		pixels := make([]u8, int(bm.w * bm.h * 4), allocator)
		for y in 0 ..< bm.h {
			row := src.buffer[y * pitch:]
			for x in 0 ..< bm.w {
				o := (y * bm.w + x) * 4
				pixels[o + 0], pixels[o + 1], pixels[o + 2], pixels[o + 3] = row[x * 4 + 2], row[x * 4 + 1], row[x * 4 + 0], row[x * 4 + 3]
			}
		}
		unpremultiply_rgba(pixels)
		bm.pixels = pixels
		bm.color = true
	case:
		return {}
	}
	return
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
