// CPU-side glyph and icon atlases. The backend uploads the dirty region to the GPU each frame.
//
// Two atlases (see ARCHITECTURE.md, "Rendering backend"): an R8 mask atlas for monochrome
// content (glyphs, icons) and an RGBA8 color atlas (emoji, multi-color SVG). Both keep a white
// texel at (0, 0) so solid rectangles can share the glyph pipeline.
//
// For now each atlas is a single page; paging and eviction come later in M2.
package atlas

Kind :: enum u8 {
	Mask,  // R8
	Color, // RGBA8, straight alpha
}

// Space between packed entries, so nearest sampling never picks up a neighbor.
PADDING :: 1

Atlas :: struct {
	kind:    Kind,
	size:    i32,
	bpp:     i32,
	pixels:  []u8,
	shelves: [dynamic]Shelf,
	// Region written since the last upload, as [x0, y0, x1, y1]; empty when x1 <= x0.
	dirty:   [4]i32,
}

@(private)
Shelf :: struct {
	y, h, x: i32,
}

init :: proc(a: ^Atlas, kind: Kind, size: i32, allocator := context.allocator) {
	a.kind = kind
	a.size = size
	a.bpp = 1 if kind == .Mask else 4
	a.pixels = make([]u8, int(size * size * a.bpp), allocator)
	a.shelves = make([dynamic]Shelf, allocator)
	a.dirty = {0, 0, 0, 0}

	// White texel at (0, 0), used for solid rectangles.
	white := [4]u8{255, 255, 255, 255}
	_, _, ok := alloc(a, 1, 1)
	assert(ok)
	write(a, 0, 0, 1, 1, white[:a.bpp], a.bpp)
}

destroy :: proc(a: ^Atlas) {
	delete(a.pixels)
	delete(a.shelves)
	a^ = {}
}

// Reserves a w×h region with shelf packing. Returns its top-left texel.
alloc :: proc(a: ^Atlas, w, h: i32) -> (x, y: i32, ok: bool) {
	pw := w + PADDING
	ph := h + PADDING

	// Reuse a shelf that is tall enough but not wastefully tall.
	for &s in a.shelves {
		if ph <= s.h && s.h <= ph + ph / 2 + 2 && s.x + pw <= a.size {
			x, y = s.x, s.y
			s.x += pw
			return x, y, true
		}
	}

	// Open a new shelf below the last one.
	top: i32 = 0
	if n := len(a.shelves); n > 0 {
		top = a.shelves[n - 1].y + a.shelves[n - 1].h
	}
	if top + ph > a.size || pw > a.size {
		return 0, 0, false
	}
	append(&a.shelves, Shelf{y = top, h = ph, x = pw})
	return 0, top, true
}

// Copies a w×h image (rows `src_stride` bytes apart) into the atlas at (x, y) and marks it dirty.
write :: proc(a: ^Atlas, x, y, w, h: i32, src: []u8, src_stride: i32) {
	row := w * a.bpp
	for j in 0 ..< h {
		dst := a.pixels[((y + j) * a.size + x) * a.bpp:][:row]
		copy(dst, src[j * src_stride:][:row])
	}
	if a.dirty.z <= a.dirty.x {
		a.dirty = {x, y, x + w, y + h}
	} else {
		a.dirty = {min(a.dirty.x, x), min(a.dirty.y, y), max(a.dirty.z, x + w), max(a.dirty.w, y + h)}
	}
}

// Returns and clears the dirty region as [x0, y0, x1, y1].
take_dirty :: proc(a: ^Atlas) -> (rect: [4]i32, ok: bool) {
	if a.dirty.z <= a.dirty.x {
		return {}, false
	}
	rect = a.dirty
	a.dirty = {0, 0, 0, 0}
	return rect, true
}

// Marks the whole atlas dirty, e.g. after the GPU texture was recreated on device loss.
mark_all_dirty :: proc(a: ^Atlas) {
	a.dirty = {0, 0, a.size, a.size}
}
