#+build darwin
// macOS text backend: CoreText for font loading, shaping and rasterization, as Ghostty's default
// macOS backend does. CoreText's line layout also performs font fallback: each glyph run carries
// the font that actually supplied its glyphs.
package text

import "core:math"

import CF "core:sys/darwin/CoreFoundation"
import CG "core:sys/darwin/CoreGraphics"
import CT "core:sys/darwin/CoreText"

CoreText_Backend :: struct {
	fonts: [dynamic]CT.FontDescriptorRef,
	faces: [dynamic]Darwin_Face,
}

@(private)
Darwin_Face :: struct {
	font: CT.FontRef,
	size: f32,
	base: Font_Id, // NO_FONT for fallback faces chosen by CoreText
}

coretext_init :: proc(b: ^CoreText_Backend) -> bool {
	return true
}

coretext_destroy :: proc(b: ^CoreText_Backend) {
	for f in b.faces {
		CF.Release(CF.TypeRef(f.font))
	}
	for d in b.fonts {
		CF.Release(CF.TypeRef(d))
	}
	delete(b.faces)
	delete(b.fonts)
}

coretext_load_font :: proc(b: ^CoreText_Backend, data: []u8) -> (Font_Id, bool) {
	cf_data := CF.DataCreate(nil, raw_data(data), CF.Index(len(data)))
	if cf_data == nil {
		return NO_FONT, false
	}
	defer CF.Release(CF.TypeRef(cf_data))
	desc := CT.FontManagerCreateFontDescriptorFromData(cf_data)
	if desc == nil {
		return NO_FONT, false
	}
	append(&b.fonts, desc)
	return Font_Id(len(b.fonts) - 1), true
}

coretext_face :: proc(b: ^CoreText_Backend, font: Font_Id, size: f32) -> Face_Id {
	for f, i in b.faces {
		if f.base == font && f.size == size {
			return Face_Id(i)
		}
	}
	ct_font := CT.FontCreateWithFontDescriptor(b.fonts[font], CG.Float(size), nil)
	append(&b.faces, Darwin_Face{font = ct_font, size = size, base = font})
	return Face_Id(len(b.faces) - 1)
}

// Finds or registers the face for a CTFont that CoreText picked for a run.
@(private)
face_for_ct_font :: proc(b: ^CoreText_Backend, font: CT.FontRef, size: f32) -> Face_Id {
	for f, i in b.faces {
		if f.font == font || CF.Equal(CF.TypeRef(f.font), CF.TypeRef(font)) {
			return Face_Id(i)
		}
	}
	CF.Retain(CF.TypeRef(font))
	append(&b.faces, Darwin_Face{font = font, size = size, base = NO_FONT})
	return Face_Id(len(b.faces) - 1)
}

coretext_shape :: proc(b: ^CoreText_Backend, face: Face_Id, s: string, allocator := context.allocator) -> Shaped {
	f := b.faces[face]
	out := Shaped {
		ascent  = f32(CT.FontGetAscent(f.font)),
		descent = f32(CT.FontGetDescent(f.font)),
	}
	if len(s) == 0 {
		return out
	}

	str := CF.StringCreateWithBytes(nil, raw_data(s), CF.Index(len(s)), CF.StringEncoding(CF.StringBuiltInEncodings.UTF8), false)
	if str == nil {
		return out
	}
	defer CF.Release(CF.TypeRef(str))

	keys := [1]rawptr{rawptr(CT.kFontAttributeName)}
	values := [1]rawptr{rawptr(f.font)}
	attrs := CF.DictionaryCreate(nil, &keys[0], &values[0], 1, &CF.kTypeDictionaryKeyCallBacks, &CF.kTypeDictionaryValueCallBacks)
	defer CF.Release(CF.TypeRef(attrs))
	astr := CF.AttributedStringCreate(nil, str, attrs)
	defer CF.Release(CF.TypeRef(astr))
	line := CT.LineCreateWithAttributedString(astr)
	defer CF.Release(CF.TypeRef(line))

	ascent, descent, leading: CG.Float
	out.width = f32(CT.LineGetTypographicBounds(line, &ascent, &descent, &leading))

	glyphs := make([dynamic]Shaped_Glyph, allocator)
	runs := CT.LineGetGlyphRuns(line)
	for i in 0 ..< CF.ArrayGetCount(runs) {
		run := CT.RunRef(CF.ArrayGetValueAtIndex(runs, i))
		count := CT.RunGetGlyphCount(run)
		if count <= 0 {
			continue
		}
		ids := make([]CG.Glyph, count, context.temp_allocator)
		positions := make([]CG.Point, count, context.temp_allocator)
		indices := make([]CF.Index, count, context.temp_allocator)
		CT.RunGetGlyphs(run, {0, 0}, &ids[0])
		CT.RunGetPositions(run, {0, 0}, &positions[0])
		CT.RunGetStringIndices(run, {0, 0}, &indices[0])

		run_font := CT.FontRef(CF.DictionaryGetValue(CT.RunGetAttributes(run), rawptr(CT.kFontAttributeName)))
		run_face := face if run_font == nil else face_for_ct_font(b, run_font, f.size)
		for j in 0 ..< count {
			append(&glyphs, Shaped_Glyph {
				face    = run_face,
				glyph   = u32(ids[j]),
				x       = f32(positions[j].x),
				y       = -f32(positions[j].y), // CoreText's y points up
				cluster = u32(indices[j]),
			})
		}
	}
	out.glyphs = glyphs[:]
	return out
}

coretext_rasterize :: proc(b: ^CoreText_Backend, face: Face_Id, glyph: u32, subpixel: f32, allocator := context.allocator) -> (bm: Bitmap) {
	font := b.faces[face].font
	g := CG.Glyph(glyph)
	bounds: CG.Rect
	CT.FontGetBoundingRectsForGlyphs(font, .Default, &g, &bounds, 1)
	if bounds.size.width <= 0 || bounds.size.height <= 0 {
		return
	}

	// Bitmap bounds relative to the pen position, with one pixel of padding for anti-aliasing.
	x0 := math.floor(f64(bounds.origin.x) + f64(subpixel)) - 1
	x1 := math.ceil(f64(bounds.origin.x + bounds.size.width) + f64(subpixel)) + 1
	y0 := math.floor(f64(bounds.origin.y)) - 1
	y1 := math.ceil(f64(bounds.origin.y + bounds.size.height)) + 1
	bm.w = i32(x1 - x0)
	bm.h = i32(y1 - y0)
	bm.left = i32(x0)
	bm.top = i32(y1)
	bm.color = .ColorGlyphs in CT.FontGetSymbolicTraits(font)

	bpp := 4 if bm.color else 1
	pixels := make([]u8, int(bm.w * bm.h) * bpp, allocator)
	space := CG.ColorSpaceCreateDeviceRGB() if bm.color else CG.ColorSpaceCreateDeviceGray()
	defer CG.ColorSpaceRelease(space)
	info := CG.BitmapInfo(CG.ImageAlphaInfo.PremultipliedLast) if bm.color else CG.BitmapInfo(CG.ImageAlphaInfo.None)
	ctx := CG.BitmapContextCreate(raw_data(pixels), uint(bm.w), uint(bm.h), 8, uint(bm.w) * uint(bpp), space, info)
	if ctx == nil {
		return {}
	}
	defer CG.ContextRelease(ctx)

	CG.ContextSetShouldAntialias(ctx, true)
	CG.ContextSetAllowsFontSmoothing(ctx, false)
	CG.ContextSetShouldSmoothFonts(ctx, false)
	CG.ContextSetAllowsFontSubpixelPositioning(ctx, true)
	CG.ContextSetShouldSubpixelPositionFonts(ctx, true)
	// Grayscale: draw white on black, so the gray value is the coverage.
	CG.ContextSetGrayFillColor(ctx, 1, 1)

	pos := CG.Point{CG.Float(f64(subpixel) - x0), CG.Float(-y0)}
	CT.FontDrawGlyphs(font, &g, &pos, 1, ctx)

	if bm.color {
		unpremultiply_rgba(pixels) // CoreGraphics renders premultiplied alpha
	}
	bm.pixels = pixels
	return
}
