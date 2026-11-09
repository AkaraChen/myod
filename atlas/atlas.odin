// CPU-side glyph and icon atlases. The backend uploads dirty regions to the GPU each frame.
//
// Two atlases (see ARCHITECTURE.md, "Rendering backend"): an R8 mask atlas for monochrome content
// (glyphs, icons, sprites) and an RGBA8 color atlas (emoji, multi-color SVG). Each atlas is a set of
// square pages; the GPU side is a texture array with one layer per page.
//
// When every page is full and the page budget is reached, the least recently used page is evicted
// as a whole (unless it was drawn this frame: then the atlas grows past the budget): its generation is bumped, so every location that pointed into it becomes invalid and
// its content gets re-rasterized on next use. Every page keeps a white texel at (0, 0) for solid
// rectangles.
package atlas

Kind :: enum u8 {
	Mask,  // R8
	Color, // RGBA8, straight alpha
}

// Space between packed entries, so nearest sampling never picks up a neighbor.
PADDING :: 1

Atlas :: struct {
	kind:      Kind,
	size:      i32,
	bpp:       i32,
	max_pages: int,
	pages:     [dynamic]Page,
	frame:     u64,
	evictions: int, // total pages evicted, for the debug overlay
}

Page :: struct {
	pixels:     []u8,
	shelves:    [dynamic]Shelf,
	// Region written since the last upload, as [x0, y0, x1, y1]; empty when x1 <= x0.
	dirty:      [4]i32,
	generation: u32,
	last_used:  u64,
}

// Where an entry lives. It stays valid while its page keeps the same generation.
Location :: struct {
	page:       i32,
	x, y:       i32,
	generation: u32,
}

@(private)
Shelf :: struct {
	y, h, x: i32,
}

init :: proc(a: ^Atlas, kind: Kind, size: i32, max_pages: int, allocator := context.allocator) {
	a.kind = kind
	a.size = size
	a.bpp = 1 if kind == .Mask else 4
	a.max_pages = max(1, max_pages)
	a.pages = make([dynamic]Page, allocator)
	add_page(a)
}

destroy :: proc(a: ^Atlas) {
	for &p in a.pages {
		delete(p.pixels)
		delete(p.shelves)
	}
	delete(a.pages)
	a^ = {}
}

// Call once per frame, before drawing: page recency is tracked per frame.
begin_frame :: proc(a: ^Atlas) {
	a.frame += 1
}

// Records that an entry on `page` was drawn this frame.
touch :: proc(a: ^Atlas, page: i32) {
	a.pages[page].last_used = a.frame
}

valid :: proc(a: ^Atlas, loc: Location) -> bool {
	return int(loc.page) < len(a.pages) && a.pages[loc.page].generation == loc.generation
}

// Reserves a w×h region: in an existing page, in a new page within the budget, or by evicting the
// least recently used page.
alloc :: proc(a: ^Atlas, w, h: i32) -> (loc: Location, ok: bool) {
	if w + PADDING > a.size || h + PADDING > a.size {
		return {}, false
	}
	for &p, i in a.pages {
		if x, y, found := page_alloc(a, &p, w, h); found {
			return {page = i32(i), x = x, y = y, generation = p.generation}, true
		}
	}
	// Evicting a page drawn this frame would corrupt quads already emitted, so a frame that needs
	// more than the budget gets an extra page instead (the budget is soft; pages are never freed).
	index := lru_page(a)
	if len(a.pages) < a.max_pages || a.pages[index].last_used == a.frame {
		add_page(a)
		index = len(a.pages) - 1
	} else {
		reset_page(a, &a.pages[index])
		a.evictions += 1
	}
	p := &a.pages[index]
	x, y, found := page_alloc(a, p, w, h)
	if !found {
		return {}, false
	}
	return {page = i32(index), x = x, y = y, generation = p.generation}, true
}

// Copies a w×h image (rows `src_stride` bytes apart) into the atlas and marks it dirty.
write :: proc(a: ^Atlas, loc: Location, w, h: i32, src: []u8, src_stride: i32) {
	p := &a.pages[loc.page]
	row := w * a.bpp
	for j in 0 ..< h {
		dst := p.pixels[((loc.y + j) * a.size + loc.x) * a.bpp:][:row]
		copy(dst, src[j * src_stride:][:row])
	}
	mark_dirty(p, {loc.x, loc.y, loc.x + w, loc.y + h})
}

// Returns and clears a page's dirty region as [x0, y0, x1, y1].
take_dirty :: proc(a: ^Atlas, page: int) -> (rect: [4]i32, ok: bool) {
	p := &a.pages[page]
	if p.dirty.z <= p.dirty.x {
		return {}, false
	}
	rect = p.dirty
	p.dirty = {0, 0, 0, 0}
	return rect, true
}

// Marks every page fully dirty, e.g. after the GPU textures were recreated.
mark_all_dirty :: proc(a: ^Atlas) {
	for &p in a.pages {
		p.dirty = {0, 0, a.size, a.size}
	}
}

@(private)
add_page :: proc(a: ^Atlas) {
	p := Page {
		pixels  = make([]u8, int(a.size * a.size * a.bpp)),
		shelves = make([dynamic]Shelf),
	}
	reset_page(a, &p)
	p.generation = 0
	append(&a.pages, p)
}

// Empties a page, keeping only the white texel at (0, 0).
@(private)
reset_page :: proc(a: ^Atlas, p: ^Page) {
	clear(&p.shelves)
	p.generation += 1
	p.last_used = a.frame
	_, _, ok := page_alloc(a, p, 1, 1)
	assert(ok)
	for i in 0 ..< a.bpp {
		p.pixels[i] = 255
	}
	p.dirty = {0, 0, a.size, a.size}
}

// The page used least recently.
@(private)
lru_page :: proc(a: ^Atlas) -> int {
	best := 0
	for p, i in a.pages {
		if p.last_used < a.pages[best].last_used {
			best = i
		}
	}
	return best
}

// Shelf packing within one page.
@(private)
page_alloc :: proc(a: ^Atlas, p: ^Page, w, h: i32) -> (x, y: i32, ok: bool) {
	pw := w + PADDING
	ph := h + PADDING
	// Reuse a shelf that is tall enough but not wastefully tall.
	for &s in p.shelves {
		if ph <= s.h && s.h <= ph + ph / 2 + 2 && s.x + pw <= a.size {
			x, y = s.x, s.y
			s.x += pw
			return x, y, true
		}
	}
	// Open a new shelf below the last one.
	top: i32 = 0
	if n := len(p.shelves); n > 0 {
		top = p.shelves[n - 1].y + p.shelves[n - 1].h
	}
	if top + ph > a.size {
		return 0, 0, false
	}
	append(&p.shelves, Shelf{y = top, h = ph, x = pw})
	return 0, top, true
}

@(private)
mark_dirty :: proc(p: ^Page, r: [4]i32) {
	if p.dirty.z <= p.dirty.x {
		p.dirty = r
	} else {
		p.dirty = {min(p.dirty.x, r.x), min(p.dirty.y, r.y), max(p.dirty.z, r.z), max(p.dirty.w, r.w)}
	}
}
