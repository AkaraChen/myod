// Sprite glyphs: characters drawn by myod instead of the font, at the exact cell size, so adjacent
// cells join with no gaps (as Ghostty's sprite font does): box drawing (U+2500–257F), block elements
// (U+2580–259F), Braille patterns (U+2800–28FF) and Powerline separators (U+E0B0–E0B7).
//
// Straight lines, blocks and Braille dots are whole-pixel rectangles. Arcs, diagonals and Powerline
// shapes are rasterized with 4×4 supersampling.
package sprite

import "core:math"

// Whether `r` is drawn by this package instead of the font.
covers :: proc(r: rune) -> bool {
	switch r {
	case 0x2500 ..= 0x259F, 0x2800 ..= 0x28FF, 0xE0B0 ..= 0xE0B7:
		return true
	}
	return false
}

// Rasterizes `r` into a w×h R8 coverage bitmap covering a whole cell. `thickness` is the light line
// thickness in pixels; heavy lines are twice that, double lines are two light lines one light line
// apart.
rasterize :: proc(r: rune, w, h, thickness: i32, allocator := context.allocator) -> (pixels: []u8, ok: bool) {
	if w <= 0 || h <= 0 || !covers(r) {
		return nil, false
	}
	c := Canvas{w = w, h = h, t = max(1, thickness), px = make([]u8, int(w * h), allocator)}
	switch r {
	case 0x2500 ..= 0x257F:
		box_drawing(&c, r)
	case 0x2580 ..= 0x259F:
		block(&c, r)
	case 0x2800 ..= 0x28FF:
		braille(&c, r)
	case 0xE0B0 ..= 0xE0B7:
		powerline(&c, r)
	}
	return c.px, true
}

@(private)
Canvas :: struct {
	w, h, t: i32,
	px:      []u8,
}

@(private)
fill :: proc(c: ^Canvas, x0, y0, x1, y1: i32, v: u8 = 255) {
	for y in max(y0, 0) ..< min(y1, c.h) {
		for x in max(x0, 0) ..< min(x1, c.w) {
			c.px[y * c.w + x] = max(c.px[y * c.w + x], v)
		}
	}
}

// ---- Box drawing ----

// Arm weights.
@(private)
N :: 0 // none
@(private)
L :: 1 // light
@(private)
H :: 2 // heavy
@(private)
D :: 3 // double

// Arms for U+2500–U+257F as "URDL" (up, right, down, left): '.' none, 'l' light, 'h' heavy,
// 'd' double. Empty entries (dashes, arcs, diagonals) are drawn separately.
@(private)
ARMS := [128]string {
	".l.l", ".h.h", "l.l.", "h.h.", "", "", "", "", "", "", "", "", // 2500–250B
	".ll.", ".hl.", ".lh.", ".hh.", "..ll", "..lh", "..hl", "..hh", // 250C–2513
	"ll..", "lh..", "hl..", "hh..", "l..l", "l..h", "h..l", "h..h", // 2514–251B
	"lll.", "lhl.", "hll.", "llh.", "hlh.", "hhl.", "lhh.", "hhh.", // 251C–2523
	"l.ll", "l.lh", "h.ll", "l.hl", "h.hl", "h.lh", "l.hh", "h.hh", // 2524–252B
	".lll", ".llh", ".hll", ".hlh", ".lhl", ".lhh", ".hhl", ".hhh", // 252C–2533
	"ll.l", "ll.h", "lh.l", "lh.h", "hl.l", "hl.h", "hh.l", "hh.h", // 2534–253B
	"llll", "lllh", "lhll", "lhlh", "hlll", "llhl", "hlhl", "hllh", // 253C–2543
	"hhll", "llhh", "lhhl", "hhlh", "lhhh", "hlhh", "hhhl", "hhhh", // 2544–254B
	"", "", "", "", // 254C–254F
	".d.d", "d.d.", ".dl.", ".ld.", ".dd.", "..ld", "..dl", "..dd", // 2550–2557
	"ld..", "dl..", "dd..", "l..d", "d..l", "d..d", "ldl.", "dld.", // 2558–255F
	"ddd.", "l.ld", "d.dl", "d.dd", ".dld", ".ldl", ".ddd", "ld.d", // 2560–2567
	"dl.l", "dd.d", "ldld", "dldl", "dddd", // 2568–256C
	"", "", "", "", "", "", "", // 256D–2573
	"...l", "l...", ".l..", "..l.", "...h", "h...", ".h..", "..h.", // 2574–257B
	".h.l", "l.h.", ".l.h", "h.l.", // 257C–257F
}

@(private)
box_drawing :: proc(c: ^Canvas, r: rune) {
	switch r {
	case 0x2504, 0x2505:
		dashes(c, true, 3, r == 0x2505)
	case 0x2506, 0x2507:
		dashes(c, false, 3, r == 0x2507)
	case 0x2508, 0x2509:
		dashes(c, true, 4, r == 0x2509)
	case 0x250A, 0x250B:
		dashes(c, false, 4, r == 0x250B)
	case 0x254C, 0x254D:
		dashes(c, true, 2, r == 0x254D)
	case 0x254E, 0x254F:
		dashes(c, false, 2, r == 0x254F)
	case 0x256D ..= 0x2570:
		arc(c, r)
	case 0x2571 ..= 0x2573:
		diagonals(c, r)
	case:
		spec := ARMS[r - 0x2500]
		arms: [4]int // up, right, down, left
		for i in 0 ..< 4 {
			switch spec[i] {
			case 'l': arms[i] = L
			case 'h': arms[i] = H
			case 'd': arms[i] = D
			}
		}
		draw_arms(c, arms)
	}
}

// Thickness of a light or heavy arm.
@(private)
weight :: proc(c: ^Canvas, w: int) -> i32 {
	return c.t * 2 if w == H else c.t
}

// Draws up to four arms meeting at the cell center.
@(private)
draw_arms :: proc(c: ^Canvas, arms: [4]int) {
	up, right, down, left := arms[0], arms[1], arms[2], arms[3]
	t := c.t
	// Single strokes are centered; double lines are two light strokes with a light gap between.
	vx := proc(c: ^Canvas, k: i32) -> i32 { return (c.w - k) / 2 }
	hy := proc(c: ^Canvas, k: i32) -> i32 { return (c.h - k) / 2 }
	dl := (c.w - 3 * t) / 2 // left line of a vertical double
	dt := (c.h - 3 * t) / 2 // top line of a horizontal double

	// Extent of the perpendicular strokes, used to make joins solid.
	extent :: proc(c: ^Canvas, a, b: int) -> i32 {
		e: i32 = 0
		for w in ([2]int{a, b}) {
			switch w {
			case L, H: e = max(e, weight(c, w))
			case D: e = max(e, 3 * c.t)
			}
		}
		return e
	}
	h_ext := extent(c, left, right) // vertical thickness of the horizontal strokes
	v_ext := extent(c, up, down)    // horizontal thickness of the vertical strokes
	h_double := left == D || right == D
	v_double := up == D || down == D

	// Up and down arms.
	for dir in 0 ..< 2 {
		arm := up if dir == 0 else down
		opposite := down if dir == 0 else up
		if arm == N {
			continue
		}
		// [y0, y1) of a stroke from the cell edge to the center region.
		span :: proc(c: ^Canvas, dir: int, near_end, far_start: i32) -> (i32, i32) {
			if dir == 0 {
				return 0, near_end
			}
			return far_start, c.h
		}
		if arm != D {
			k := weight(c, arm)
			x0 := vx(c, k)
			// Default: cover the horizontal strokes (or reach the center of a lone arm).
			hk := h_ext if h_ext > 0 else k
			near_end := hy(c, hk) + hk
			far_start := hy(c, hk)
			if h_double && opposite == N {
				// Stop at the nearer line of a horizontal double instead of poking into its gap.
				near_end = dt + t
				far_start = dt + 2 * t
			}
			y0, y1 := span(c, dir, near_end, far_start)
			fill(c, x0, y0, x0 + k, y1)
		} else {
			// Two light lines; each one stops at an inner corner or runs to an outer corner.
			for side in 0 ..< 2 { // 0 = left line, 1 = right line
				x0 := dl if side == 0 else dl + 2 * t
				h_side := left if side == 0 else right
				near_end, far_start: i32
				switch {
				case h_side == D:
					near_end, far_start = dt + t, dt + 2 * t // inner corner
				case h_side != N:
					near_end, far_start = hy(c, h_ext) + h_ext, hy(c, h_ext)
				case h_double:
					near_end, far_start = dt + 3 * t, dt // outer corner
				case h_ext > 0:
					near_end, far_start = hy(c, h_ext) + h_ext, hy(c, h_ext)
				case:
					near_end, far_start = hy(c, t) + t, hy(c, t)
				}
				if opposite == D && h_side == N && !h_double {
					near_end, far_start = c.h, 0 // a straight ║ runs through
				}
				y0, y1 := span(c, dir, near_end, far_start)
				fill(c, x0, y0, x0 + t, y1)
			}
		}
	}

	// Left and right arms (the same rules, transposed).
	for dir in 0 ..< 2 {
		arm := left if dir == 0 else right
		opposite := right if dir == 0 else left
		if arm == N {
			continue
		}
		span :: proc(c: ^Canvas, dir: int, near_end, far_start: i32) -> (i32, i32) {
			if dir == 0 {
				return 0, near_end
			}
			return far_start, c.w
		}
		if arm != D {
			k := weight(c, arm)
			y0 := hy(c, k)
			vk := v_ext if v_ext > 0 else k
			near_end := vx(c, vk) + vk
			far_start := vx(c, vk)
			if v_double && opposite == N {
				near_end = dl + t
				far_start = dl + 2 * t
			}
			x0, x1 := span(c, dir, near_end, far_start)
			fill(c, x0, y0, x1, y0 + k)
		} else {
			for side in 0 ..< 2 { // 0 = top line, 1 = bottom line
				y0 := dt if side == 0 else dt + 2 * t
				v_side := up if side == 0 else down
				near_end, far_start: i32
				switch {
				case v_side == D:
					near_end, far_start = dl + t, dl + 2 * t
				case v_side != N:
					near_end, far_start = vx(c, v_ext) + v_ext, vx(c, v_ext)
				case v_double:
					near_end, far_start = dl + 3 * t, dl
				case v_ext > 0:
					near_end, far_start = vx(c, v_ext) + v_ext, vx(c, v_ext)
				case:
					near_end, far_start = vx(c, t) + t, vx(c, t)
				}
				if opposite == D && v_side == N && !v_double {
					near_end, far_start = c.w, 0 // a straight ═ runs through
				}
				x0, x1 := span(c, dir, near_end, far_start)
				fill(c, x0, y0, x1, y0 + t)
			}
		}
	}
}

@(private)
dashes :: proc(c: ^Canvas, horizontal: bool, n: int, heavy: bool) {
	k := c.t * 2 if heavy else c.t
	length := c.w if horizontal else c.h
	segment := f32(length) / f32(n)
	gap := max(1, math.round(segment * 0.3))
	for i in 0 ..< n {
		a := i32(math.round(f32(i) * segment + gap / 2))
		b := i32(math.round(f32(i + 1) * segment - gap / 2))
		if horizontal {
			y0 := (c.h - k) / 2
			fill(c, a, y0, b, y0 + k)
		} else {
			x0 := (c.w - k) / 2
			fill(c, x0, a, x0 + k, b)
		}
	}
}

// ---- Supersampled shapes ----

@(private)
SS :: 4

@(private)
Shape :: union {
	Ring_Quadrant, // a stroked quarter circle
	Segment,       // a stroked line segment
	Triangle,      // a filled triangle
	Half_Ellipse,  // a filled or stroked half ellipse
}

@(private)
Ring_Quadrant :: struct {
	center: [2]f32,
	radius: f32,
	half:   f32, // half the stroke width
	sx, sy: f32, // the quadrant: points with (x - cx) * sx >= 0 and (y - cy) * sy >= 0
}

@(private)
Segment :: struct {
	a, b: [2]f32,
	half: f32,
}

@(private)
Triangle :: struct {
	p: [3][2]f32,
}

@(private)
Half_Ellipse :: struct {
	center: [2]f32,
	radii:  [2]f32,
	dir:    f32, // +1: the half with x >= cx, -1: x <= cx
	half:   f32, // > 0: stroked with this half width; 0: filled
}

@(private)
inside :: proc(s: Shape, p: [2]f32) -> bool {
	switch v in s {
	case Ring_Quadrant:
		d := p - v.center
		if d.x * v.sx < 0 || d.y * v.sy < 0 {
			return false
		}
		return abs(math.sqrt(d.x * d.x + d.y * d.y) - v.radius) <= v.half
	case Segment:
		ab := v.b - v.a
		u := clamp(((p.x - v.a.x) * ab.x + (p.y - v.a.y) * ab.y) / (ab.x * ab.x + ab.y * ab.y), 0, 1)
		q := v.a + ab * u
		return math.sqrt((p.x - q.x) * (p.x - q.x) + (p.y - q.y) * (p.y - q.y)) <= v.half
	case Triangle:
		edge :: proc(a, b, p: [2]f32) -> f32 {
			return (b.x - a.x) * (p.y - a.y) - (b.y - a.y) * (p.x - a.x)
		}
		e0 := edge(v.p[0], v.p[1], p)
		e1 := edge(v.p[1], v.p[2], p)
		e2 := edge(v.p[2], v.p[0], p)
		return (e0 >= 0 && e1 >= 0 && e2 >= 0) || (e0 <= 0 && e1 <= 0 && e2 <= 0)
	case Half_Ellipse:
		d := p - v.center
		if d.x * v.dir < 0 {
			return false
		}
		n := math.sqrt((d.x / v.radii.x) * (d.x / v.radii.x) + (d.y / v.radii.y) * (d.y / v.radii.y))
		if v.half == 0 {
			return n <= 1
		}
		// Approximate distance to the ellipse outline, in pixels.
		return abs(n - 1) * min(v.radii.x, v.radii.y) <= v.half
	}
	return false
}

@(private)
draw_shape :: proc(c: ^Canvas, s: Shape) {
	for y in 0 ..< c.h {
		for x in 0 ..< c.w {
			hits := 0
			for sy in 0 ..< SS {
				for sx in 0 ..< SS {
					p := [2]f32{f32(x) + (f32(sx) + 0.5) / SS, f32(y) + (f32(sy) + 0.5) / SS}
					if inside(s, p) {
						hits += 1
					}
				}
			}
			if hits > 0 {
				v := u8(hits * 255 / (SS * SS))
				c.px[y * c.w + x] = max(c.px[y * c.w + x], v)
			}
		}
	}
}

// ╭ ╮ ╯ ╰: a quarter circle joining two edge midpoints, extended straight to the edges.
@(private)
arc :: proc(c: ^Canvas, r: rune) {
	t := c.t
	x0 := (c.w - t) / 2
	y0 := (c.h - t) / 2
	cx := f32(x0) + f32(t) / 2 // stroke centers
	cy := f32(y0) + f32(t) / 2
	radius := min(cx, cy)
	// Which way the arms go: right (+1) / left (-1), down (+1) / up (-1).
	hx, vy: f32
	switch r {
	case 0x256D: hx, vy = 1, 1   // ╭ down and right
	case 0x256E: hx, vy = -1, 1  // ╮ down and left
	case 0x256F: hx, vy = -1, -1 // ╯ up and left
	case 0x2570: hx, vy = 1, -1  // ╰ up and right
	}
	center := [2]f32{cx + hx * radius, cy + vy * radius}
	draw_shape(c, Ring_Quadrant{center = center, radius = radius, half = f32(t) / 2, sx = -hx, sy = -vy})
	// Straight extensions from the arc's ends to the cell edges.
	if hx > 0 {
		fill(c, i32(center.x), y0, c.w, y0 + t)
	} else {
		fill(c, 0, y0, i32(math.ceil(center.x)), y0 + t)
	}
	if vy > 0 {
		fill(c, x0, i32(center.y), x0 + t, c.h)
	} else {
		fill(c, x0, 0, x0 + t, i32(math.ceil(center.y)))
	}
}

@(private)
diagonals :: proc(c: ^Canvas, r: rune) {
	half := f32(c.t) / 2
	w, h := f32(c.w), f32(c.h)
	if r == 0x2571 || r == 0x2573 {
		draw_shape(c, Segment{a = {w, 0}, b = {0, h}, half = half})
	}
	if r == 0x2572 || r == 0x2573 {
		draw_shape(c, Segment{a = {0, 0}, b = {w, h}, half = half})
	}
}

// ---- Block elements ----

@(private)
block :: proc(c: ^Canvas, r: rune) {
	w, h := c.w, c.h
	ey :: proc(c: ^Canvas, eighths: i32) -> i32 { return i32(math.round(f32(c.h) * f32(eighths) / 8)) }
	ex :: proc(c: ^Canvas, eighths: i32) -> i32 { return i32(math.round(f32(c.w) * f32(eighths) / 8)) }
	hw, hh := w / 2, h / 2
	switch r {
	case 0x2580: fill(c, 0, 0, w, hh) // ▀ upper half
	case 0x2581 ..= 0x2588: fill(c, 0, h - ey(c, i32(r - 0x2580)), w, h) // ▁ … █ lower eighths
	case 0x2589 ..= 0x258F: fill(c, 0, 0, ex(c, i32(0x2590 - r)), h) // ▉ … ▏ left eighths
	case 0x2590: fill(c, hw, 0, w, h) // ▐ right half
	case 0x2591: fill(c, 0, 0, w, h, 64)  // ░ light shade
	case 0x2592: fill(c, 0, 0, w, h, 128) // ▒ medium shade
	case 0x2593: fill(c, 0, 0, w, h, 191) // ▓ dark shade
	case 0x2594: fill(c, 0, 0, w, ey(c, 1)) // ▔ upper eighth
	case 0x2595: fill(c, w - ex(c, 1), 0, w, h) // ▕ right eighth
	case:
		// Quadrants ▖ ▗ ▘ ▙ ▚ ▛ ▜ ▝ ▞ ▟ as bits: upper-left, upper-right, lower-left, lower-right.
		QUADRANTS := [10]u8{0b0010, 0b0001, 0b1000, 0b1011, 0b1001, 0b1110, 0b1101, 0b0100, 0b0110, 0b0111}
		q := QUADRANTS[r - 0x2596]
		if q & 0b1000 != 0 { fill(c, 0, 0, hw, hh) }
		if q & 0b0100 != 0 { fill(c, hw, 0, w, hh) }
		if q & 0b0010 != 0 { fill(c, 0, hh, hw, h) }
		if q & 0b0001 != 0 { fill(c, hw, hh, w, h) }
	}
}

// ---- Braille ----

// Square dots on a 2 × 4 grid. Bits: 0–2 left column top to bottom, 3–5 right column, 6 bottom
// left, 7 bottom right.
@(private)
braille :: proc(c: ^Canvas, r: rune) {
	bits := u32(r - 0x2800)
	s := max(1, i32(math.round(min(f32(c.w) / 4, f32(c.h) / 8))))
	DOTS := [8][2]i32{{0, 0}, {0, 1}, {0, 2}, {1, 0}, {1, 1}, {1, 2}, {0, 3}, {1, 3}}
	for d, i in DOTS {
		if bits & (1 << u32(i)) == 0 {
			continue
		}
		cx := f32(c.w) * (f32(2 * d.x) + 1) / 4
		cy := f32(c.h) * (f32(2 * d.y) + 1) / 8
		x0 := i32(math.round(cx - f32(s) / 2))
		y0 := i32(math.round(cy - f32(s) / 2))
		fill(c, x0, y0, x0 + s, y0 + s)
	}
}

// ---- Powerline ----

@(private)
powerline :: proc(c: ^Canvas, r: rune) {
	w, h := f32(c.w), f32(c.h)
	half := f32(c.t) / 2
	switch r {
	case 0xE0B0: draw_shape(c, Triangle{{{0, 0}, {w, h / 2}, {0, h}}}) // solid right triangle
	case 0xE0B1: // thin right chevron
		draw_shape(c, Segment{a = {0, 0}, b = {w, h / 2}, half = half})
		draw_shape(c, Segment{a = {w, h / 2}, b = {0, h}, half = half})
	case 0xE0B2: draw_shape(c, Triangle{{{w, 0}, {0, h / 2}, {w, h}}}) // solid left triangle
	case 0xE0B3: // thin left chevron
		draw_shape(c, Segment{a = {w, 0}, b = {0, h / 2}, half = half})
		draw_shape(c, Segment{a = {0, h / 2}, b = {w, h}, half = half})
	case 0xE0B4: draw_shape(c, Half_Ellipse{center = {0, h / 2}, radii = {w, h / 2}, dir = 1}) // solid right half circle
	case 0xE0B5: draw_shape(c, Half_Ellipse{center = {0, h / 2}, radii = {w - half, h / 2 - half}, dir = 1, half = half})
	case 0xE0B6: draw_shape(c, Half_Ellipse{center = {w, h / 2}, radii = {w, h / 2}, dir = -1}) // solid left half circle
	case 0xE0B7: draw_shape(c, Half_Ellipse{center = {w, h / 2}, radii = {w - half, h / 2 - half}, dir = -1, half = half})
	}
}
