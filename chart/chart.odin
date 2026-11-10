// Charts for the shadcn/ui set: bar, line, area, pie and radar.
//
// The marks are nanosvg shapes built in code (no SVG source is ever concatenated) and rasterized
// into an RGBA8 texture that is drawn as one image. Axis labels, tick values, legends and the hover
// tooltip go through the text system; grid lines are 1px rectangles. Hovering draws a crosshair and
// a value tooltip over the texture: it never re-rasterizes.
//
// The texture cache is keyed by (data version, physical pixel size). While the window is being
// resized the previous texture is stretched; once the size has held still for RESIZE_SETTLE_MS the
// chart rasterizes at the new size. A data change rasterizes at once.
package chart

import "core:fmt"
import "core:math"
import "core:time"

import "../core"
import "../layout"
import "../platform"
import ui "../ui"
import ns "../third_party/odin/myod_svg"

// One series: its label, its values (one per category), and an optional color token. The default
// palette is used when `color` is `.None`.
Series :: struct {
	label:  string,
	values: []f32,
	color:  core.Token,
}

// The options shared by bar, line and area charts.
Chart_Options :: struct {
	id:            ui.Key,
	labels:        []string, // one per category, for the x axis and the tooltip
	series:        []Series,
	width, height: ui.Size,
	min, max:      f32, // 0, 0: derived from the data
	ticks:         int, // grid lines and y labels; 0: 4
	version:       u64, // change when the data changes
	legend:        bool,
	no_grid:       bool,
	stacked:       bool, // bars stack, areas stack
}

// What a chart reports back: the node's interaction and what the pointer is over.
Chart_Result :: struct {
	res:    ui.Response,
	hover:  int, // the category under the pointer, -1 when none
	series: int, // the series under the pointer for pie/radar, -1 when not applicable
}

@(private)
RESIZE_SETTLE_MS :: u64(120)

@(private)
PALETTE := [6]core.Token{.Fg, .Info, .Success, .Warning, .Error, .Muted}

@(private)
Chart_State :: struct {
	pixels:          []u8,
	pw, ph:          int,
	cache_version:   u64,
	texture_version: u64,
	pending_pw:      int,
	pending_ph:      int,
	settle_at:       u64,
	// The category the keyboard is on, when the plot has focus (the pointer's hover stands in
	// otherwise). A screen-reader user reads the values by moving it with the arrows.
	index:        int,
	key_active:   bool, // the keyboard owns the hover; moving the pointer over the plot ends it
	last_pointer: [2]f32,
	pointer_seen: bool,
}

@(private)
chart_state_free :: proc(p: rawptr) {
	st := (^Chart_State)(p)
	delete(st.pixels)
}

// RGBA (0xRRGGBBAA) for a token, as nanosvg wants it.
@(private)
rgba :: proc(ctx: ^core.Context, tok: core.Token, alpha := u8(255)) -> u32 {
	c := core.color(ctx, tok, false)
	a := u8(u32(c[3]) * u32(alpha) / 255)
	return u32(c[0]) << 24 | u32(c[1]) << 16 | u32(c[2]) << 8 | u32(a)
}

@(private)
series_tok :: proc(o: Chart_Options, i: int) -> core.Token {
	if i < len(o.series) && o.series[i].color != .None {
		return o.series[i].color
	}
	return PALETTE[i % len(PALETTE)]
}

@(private)
value_range :: proc(o: Chart_Options) -> (mn, mx: f32) {
	if o.min != 0 || o.max != 0 {
		return o.min, o.max
	}
	first := true
	for s in o.series {
		total: f32 = 0
		for v in s.values {
			if first {
				mn, mx = v, v
				first = false
			}
			mn = min(mn, v)
			mx = max(mx, v)
			total += v
		}
		if o.stacked {
			mx = max(mx, total)
			mn = min(mn, total if total < 0 else 0)
		}
	}
	if first {
		return 0, 1
	}
	mn = min(mn, 0)
	if mx <= mn {
		mx = mn + 1
	}
	mx += (mx - mn) * 0.08
	return
}

@(private)
y_of :: proc(v, mn, mx, h, s: f32) -> f32 {
	if mx <= mn {
		return h / 2
	}
	t := (v - mn) / (mx - mn)
	return (1 - t) * (h - 8 * s) + 4 * s
}


// ---- Small helpers mirrored from the ui package ----

// A ui.Key (an int or a string) as a node ID in the current scope.
@(private)
chart_id :: proc(ctx: ^core.Context, key: ui.Key) -> core.Id {
	switch k in key {
	case int:
		return core.key_id_int(ctx, k)
	case string:
		return core.key_id(ctx, k)
	}
	return core.auto_id(ctx)
}

// The ui.Response of a finished node (its interaction was read with `core.interact`).
@(private)
chart_response :: proc(ctx: ^core.Context, id: core.Id) -> ui.Response {
	r, _ := core.last_rect(ctx, id)
	return {id = id, rect = r}
}

// The keyboard's category while the plot has focus, or -1. Left/Right (and Up/Down) step through
// the categories; Home/End jump to the first and last. The keyboard owns the hover while it has
// focus; moving the pointer over the plot gives it back to the pointer, and focusing the plot from
// the keyboard shows the first category at once.
@(private)
chart_key_index :: proc(ctx: ^core.Context, id: core.Id, st: ^Chart_State, count: int, it: core.Interaction) -> int {
	if count == 0 || !it.focused {
		st.key_active = false
		return -1
	}
	st.index = clamp(st.index, 0, count - 1)
	p := core.pointer(ctx)
	if it.hovered && st.pointer_seen && p != st.last_pointer {
		st.key_active = false
	}
	st.last_pointer = p
	st.pointer_seen = true
	if !it.hovered {
		// Focus came from Tab or an assistive technology: read the first category right away.
		st.key_active = true
	}
	for e in core.take_keys(ctx, id) {
		if e.kind != .Key_Down || e.repeat {
			continue
		}
		st.key_active = true
		#partial switch e.key {
		case .Left, .Up:
			st.index = max(st.index - 1, 0)
		case .Right, .Down:
			st.index = min(st.index + 1, count - 1)
		case .Home:
			st.index = 0
		case .End:
			st.index = count - 1
		}
	}
	return st.index if st.key_active else -1
}

// What a screen reader hears for the category under the keyboard or the pointer: its label and every
// series' value. Empty when no category is selected.
@(private)
chart_summary :: proc(o: Chart_Options, index: int) -> string {
	if index < 0 || index >= len(o.labels) {
		return ""
	}
	if len(o.series) == 0 {
		return o.labels[index]
	}
	out := o.labels[index]
	for s, i in o.series {
		v: f32 = 0
		if index < len(s.values) {
			v = s.values[index]
		}
		sep := ", " if i == 0 else "; "
		out = fmt.tprintf("%s%s%s %s", out, sep, s.label, tick_value(v))
	}
	return out
}

// Turns a ui.Size into the node's flex properties, in the parent's direction (`ui.item` does the same
// inside the package).
@(private)
apply_item :: proc(ctx: ^core.Context, ln: ^layout.Node, width, height: ui.Size) {
	dir, in_grid := core.parent_direction(ctx)
	main_axis := 0 if dir == .Row else 1
	sizes := [2]ui.Size{width, height}
	for s, axis in sizes {
		main := !in_grid && axis == main_axis
		switch s.kind {
		case .Fit:
			if main {
				ln.flex_shrink = 1
			}
		case .Grow:
			if main {
				ln.flex_grow = s.value if s.value > 0 else 1
				ln.flex_shrink = 1
				ln.flex_basis = {0, .Px}
			} else if s.max > 0 {
				ln.size[axis] = {1, .Percent}
			} else if axis == 0 && in_grid {
				ln.justify_self = .Stretch
			} else {
				ln.align_self = .Stretch
			}
		case .Fixed:
			ln.size[axis] = {s.value, .Px}
		case .Percent:
			ln.size[axis] = {s.value, .Percent}
		}
		if s.min > 0 {
			ln.min_size[axis] = {s.min, .Px}
		}
		if s.max > 0 {
			ln.max_size[axis] = {s.max, .Px}
		}
	}
}

// ---- Texture cache ----

// Whether the texture must be rasterized this pass. While a new size is settling, asks for a frame
// when the time comes and keeps the old texture (stretched by the caller).
@(private)
need_raster :: proc(st: ^Chart_State, version: u64, pw, ph: int) -> bool {
	now := platform.ticks_ms()
	if st.pixels == nil || st.cache_version != version {
		return true
	}
	if pw != st.pw || ph != st.ph {
		if st.pending_pw != pw || st.pending_ph != ph {
			st.pending_pw, st.pending_ph = pw, ph
			st.settle_at = now + RESIZE_SETTLE_MS
			ui.request_redraw(time.Duration(RESIZE_SETTLE_MS) * time.Millisecond)
			return false
		}
		if now >= st.settle_at {
			return true
		}
		ui.request_redraw(time.Duration(st.settle_at - now) * time.Millisecond)
		return false
	}
	return false
}

@(private)
rasterize :: proc(st: ^Chart_State, sc: ns.Scene, pw, ph: int, version: u64) {
	if sc == nil {
		return
	}
	need := pw * ph * 4
	if len(st.pixels) != need {
		delete(st.pixels)
		st.pixels = make([]u8, need)
	}
	ns.scene_rasterize(sc, i32(pw), i32(ph), raw_data(st.pixels))
	st.pw, st.ph = pw, ph
	st.cache_version = version
	st.texture_version += 1
	st.pending_pw, st.pending_ph = 0, 0
	ns.scene_free(sc)
}

@(private)
chart_image :: proc(st: ^Chart_State) -> ui.Image {
	return {pixels = st.pixels, w = st.pw, h = st.ph, version = st.texture_version}
}

// ---- Cartesian marks ----

@(private)
Chart_Kind :: enum {
	Bar,
	Line,
	Area,
}

@(private)
build_cartesian :: proc(
	sc: ns.Scene,
	o: Chart_Options,
	kind: Chart_Kind,
	w, h, s, mn, mx: f32,
	colors: []u32,
) {
	n := len(o.labels)
	if n == 0 || len(o.series) == 0 {
		return
	}
	slot := w / f32(n)
	base := y_of(clamp(0, mn, mx), mn, mx, h, s)
	switch kind {
	case .Bar:
		group := slot * 0.66
		count := f32(len(o.series))
		bw := group / count
		stacks := make([]f32, n, context.temp_allocator)
		for si in 0 ..< len(o.series) {
			vals := o.series[si].values
			for i in 0 ..< min(n, len(vals)) {
				v := vals[i]
				x0 := f32(i) * slot + (slot - group) / 2 + f32(si) * bw
				if o.stacked {
					y0 := y_of(stacks[i], mn, mx, h, s)
					stacks[i] += v
					y1 := y_of(stacks[i], mn, mx, h, s)
					bar(sc, colors[si], x0 + 1 * s, min(y0, y1), bw - 2 * s, abs(y1 - y0))
				} else {
					y1 := y_of(v, mn, mx, h, s)
					bar(sc, colors[si], x0 + 1 * s, min(base, y1), bw - 2 * s, abs(base - y1))
				}
			}
		}
	case .Line, .Area:
		area_stack := make([]f32, n, context.temp_allocator)
		for si in 0 ..< len(o.series) {
			vals := o.series[si].values
			count := min(n, len(vals))
			if count == 0 {
				continue
			}
			if kind == .Area {
				// The filled area first, under the line.
				ns.begin(sc, rgba_tok(colors[si], 60), 0, 0, 0, 1)
				first_y := y_of(vals[0], mn, mx, h, s)
				ns.move(sc, slot/2, base)
				ns.line(sc, slot/2, first_y)
				for i in 1 ..< count {
					v := vals[i]
					y := y_of(v, mn, mx, h, s)
					if o.stacked {
						y = y_of(area_stack[i] + v, mn, mx, h, s)
					}
					ns.line(sc, (f32(i)+0.5)*slot, y)
				}
				if o.stacked {
					for i := count - 1; i >= 0; i -= 1 {
						ns.line(sc, (f32(i)+0.5)*slot, y_of(area_stack[i], mn, mx, h, s))
					}
				} else {
					ns.line(sc, (f32(count-1)+0.5)*slot, base)
				}
				ns.close(sc)
			}
			ns.begin(sc, 0, colors[si], 2 * s, 0, 1)
			for i in 0 ..< count {
				v := vals[i]
				y := y_of(v, mn, mx, h, s)
				if o.stacked {
					y = y_of(area_stack[i] + v, mn, mx, h, s)
				}
				x := (f32(i) + 0.5) * slot
				if i == 0 {
					ns.move(sc, x, y)
				} else {
					ns.line(sc, x, y)
				}
			}
			if o.stacked {
				for i in 0 ..< count {
					area_stack[i] += vals[i]
				}
			}
		}
	}
}

// The 0xRRGGBBAA form of an already-resolved color, with a scaled alpha.
@(private)
rgba_tok :: proc(c: u32, alpha: u8) -> u32 {
	a := u8(u32(c & 0xff) * u32(alpha) / 255)
	return (c & 0xffffff00) | u32(a)
}

@(private)
bar :: proc(sc: ns.Scene, color: u32, x, y, w, h: f32) {
	if w <= 0 || h <= 0 {
		return
	}
	ns.begin(sc, color, 0, 0, 0, 1)
	ns.move(sc, x, y)
	ns.line(sc, x + w, y)
	ns.line(sc, x + w, y + h)
	ns.line(sc, x, y + h)
	ns.close(sc)
}

// ---- Chart chrome ----

@(private)
tick_value :: proc(v: f32) -> string {
	if abs(v) >= 100 {
		return fmt.tprintf("%.0f", v)
	}
	if abs(v) >= 10 {
		return fmt.tprintf("%.1f", v)
	}
	return fmt.tprintf("%.2f", v)
}

@(private)
legend_row :: proc(ctx: ^core.Context, o: Chart_Options) {
	if !ui.row({width = ui.grow(), wrap = true, gap = 12, align_y = .Center}) {
		return
	}
	for i in 0 ..< len(o.series) {
		tok := series_tok(o, i)
		if ui.row({width = ui.fit(), align_y = .Center, gap = 5}) {
			g := layout.Node{size = {{10, .Px}, {10, .Px}}}
			core.leaf(ctx, core.auto_id(ctx), g, core.Paint_Box{fill = tok})
			ui.text(o.series[i].label, .Metadata, .Muted, wrap = false)
		}
	}
}

// A tooltip panel absolutely placed at (x, y) inside the plot. The caller has already opened the
// panel and declares its rows.
@(private)
tooltip :: proc(ctx: ^core.Context, x, y, w: f32) -> bool {
	ln := layout.Node {
		position       = 1,
		flex_direction = .Column,
		gap            = {3, 3},
		padding        = {8, 8, 8, 8},
		size           = {{w, .Px}, {0, .Auto}},
	}
	ln.inset[0] = {x, .Px}
	ln.inset[1] = {y, .Px}
	return core.open(ctx, core.auto_id(ctx), ln, core.Paint_Box{fill = .Bg_Solid, border = .Border_Strong, border_width = 1}, flags = {})
}

// ---- Bar / line / area ----

// The shared body of the three cartesian charts.
@(private)
cartesian :: proc(o: Chart_Options, kind: Chart_Kind) -> Chart_Result {
	ctx := core.current()
	id := chart_id(ctx, o.id)
	st, created := core.state(ctx, id, Chart_State)
	if created {
		core.set_state_free(ctx, id, chart_state_free)
	}
	out := Chart_Result{res = ui.Response{id = id}, hover = -1, series = -1}
	mn, mx := value_range(o)
	ticks := o.ticks if o.ticks > 0 else 4

	colors := make([]u32, len(o.series), context.temp_allocator)
	for i in 0 ..< len(o.series) {
		colors[i] = rgba(ctx, series_tok(o, i))
	}

	outer := layout.Node {
		flex_direction = .Column,
		gap            = {6, 6},
		align_self     = .Stretch,
	}
	apply_item(ctx, &outer, o.width, o.height)
	if core.open(ctx, id, outer, nil, label = "Chart") {
		core.set_a11y_role(ctx, id, .Group)
		if o.legend {
			legend_row(ctx, o)
		}
		body := layout.Node {
			flex_direction = .Row,
			gap            = {8, 8},
			align_items    = .Stretch,
			flex_grow      = 1,
		}
		if core.open(ctx, core.auto_id(ctx), body, nil) {
			yid := core.key_id(ctx, "y-axis")
			yaxis := layout.Node {
				flex_direction = .Column,
				size           = {{44, .Px}, {1, .Percent}},
				flex_shrink    = 0,
			}
			yrect, yok := core.last_rect(ctx, yid)
			if core.open(ctx, yid, yaxis, nil) {
				if yok && yrect.h > 1 {
					for i in 0 ..= ticks {
						t := f32(i) / f32(ticks)
						v := mx - (mx - mn) * t
						y := t * yrect.h
						ln := layout.Node {
							position        = 1,
							flex_direction  = .Row,
							justify_content = .End,
							align_items     = .Center,
							size            = {{44, .Px}, {14, .Px}},
						}
						ln.inset[1] = {y - 7, .Px}
						if core.open(ctx, core.key_id_int(ctx, i), ln, nil) {
							core.leaf(ctx, core.auto_id(ctx), layout.Node{}, core.Paint_Text {
								s     = tick_value(v),
								style = ui.text_style(.Metadata),
								color = .Faint,
								wrap  = false,
							}, measured = true)
						}
						core.close(ctx)
					}
				}
			}
			core.close(ctx)

			if ui.column({width = ui.grow(), height = ui.grow(), gap = 4}) {
				plot_id := core.key_id(ctx, "plot")
				it := core.interact(ctx, plot_id)
				plot := layout.Node {
					flex_direction = .Row,
					align_items    = .Stretch,
					flex_grow      = 1,
					flex_basis     = {0, .Px},
				}
				rect, ok := core.last_rect(ctx, plot_id)
				k := chart_key_index(ctx, plot_id, st, len(o.labels), it)
				hover := -1
				if ok && it.hovered && !st.key_active && len(o.labels) > 0 && rect.w > 1 {
					p := core.pointer(ctx)
					slot := rect.w / f32(len(o.labels))
					hover = clamp(int((p[0] - rect.x) / slot), 0, len(o.labels) - 1)
				}
				// The keyboard's category stands in for the pointer's while the plot has focus.
				if hover < 0 && k >= 0 {
					hover = k
				}
				if core.open(ctx, plot_id, plot, nil, label = "Chart plot", flags = {.Hit, .Focusable, .Arrows}) {
					if hover >= 0 {
						core.set_a11y_value(ctx, plot_id, chart_summary(o, hover))
					}
					if ok && rect.w > 1 && rect.h > 1 {
						// Grid lines, as rectangles, under the marks.
						if !o.no_grid {
							for i in 0 ..= ticks {
								ln := layout.Node {
									position = 1,
									size     = {{0, .Auto}, {1, .Px}},
								}
								ln.inset[0] = {0, .Px}
								ln.inset[2] = {0, .Px}
								ln.inset[1] = {f32(i) / f32(ticks) * rect.h, .Px}
								core.leaf(ctx, core.key_id_int(ctx, 100 + i), ln, core.Paint_Box{fill = .Border})
							}
						}
						scale := platform.display_scale(ui.current_window().p)
						pw := max(1, int(rect.w * scale + 0.5))
						ph := max(1, int(rect.h * scale + 0.5))
						if need_raster(st, o.version, pw, ph) {
							sc := ns.scene_new(f32(pw), f32(ph))
							build_cartesian(sc, o, kind, f32(pw), f32(ph), scale, mn, mx, colors)
							rasterize(st, sc, pw, ph, o.version)
						}
						if st.pixels != nil {
							ui.image(chart_image(st), ui.grow(), ui.grow(), .Stretch)
						}
						// The hover crosshair, over the marks and never in the texture.
						if hover >= 0 {
							slot := rect.w / f32(len(o.labels))
							cx := (f32(hover) + 0.5) * slot
							ln := layout.Node{position = 1, size = {{1, .Px}, {0, .Auto}}}
							ln.inset[0] = {cx, .Px}
							ln.inset[1] = {0, .Px}
							ln.inset[3] = {0, .Px}
							core.leaf(ctx, core.key_id(ctx, "crosshair"), ln, core.Paint_Box{fill = .Border_Strong})
							// The tooltip: the category and every series' value.
							tw: f32 = 150
							tx := clamp(cx + 10, 0, max(rect.w - tw - 4, 0))
							if tooltip(ctx, tx, 8, tw) {
								ui.text(o.labels[hover], .Label, .Fg, wrap = false)
								for si in 0 ..< len(o.series) {
									s := o.series[si]
									v: f32 = 0
									if hover < len(s.values) {
										v = s.values[hover]
									}
									if ui.row({width = ui.grow(), align_y = .Center, gap = 6}) {
										sw := layout.Node{size = {{8, .Px}, {8, .Px}}}
										core.leaf(ctx, core.auto_id(ctx), sw, core.Paint_Box{fill = series_tok(o, si)})
										lbl := layout.Node{flex_grow = 1, flex_shrink = 1, flex_basis = {0, .Px}}
										core.leaf(ctx, core.auto_id(ctx), lbl, core.Paint_Text {
											s     = s.label,
											style = ui.text_style(.Metadata),
											color = .Muted,
											wrap  = false,
										}, measured = true)
										core.leaf(ctx, core.auto_id(ctx), layout.Node{}, core.Paint_Text {
											s     = tick_value(v),
											style = ui.text_style(.Metadata),
											color = .Fg,
											wrap  = false,
										}, measured = true)
									}
								}
							}
							core.close(ctx)
							out.hover = hover
						}
					} else {
						ui.request_redraw()
					}
					// A hover changes the tooltip on the next frame, not just the pointer.
					if it.hovered {
						ui.request_redraw()
					}
				}
				core.close(ctx)
				// The x labels, under the plot, each centered on its category's slot.
				xid := core.key_id(ctx, "x-axis")
				xl := layout.Node {
					flex_direction = .Row,
					size           = {{0, .Auto}, {16, .Px}},
					flex_shrink    = 0,
				}
				if core.open(ctx, xid, xl, nil) {
					if xr, xok := core.last_rect(ctx, plot_id); xok && xr.w > 1 && len(o.labels) > 0 {
						slot := xr.w / f32(len(o.labels))
						step := max(1, int(math.ceil(f32(len(o.labels)) / max(xr.w / 64, 1))))
						for i := 0; i < len(o.labels); i += step {
							cx := (f32(i) + 0.5) * slot
							ln := layout.Node {
								position       = 1,
								flex_direction = .Row,
								justify_content = .Center,
								align_items    = .Center,
								size           = {{80, .Px}, {16, .Px}},
							}
							ln.inset[0] = {max(cx - 40, 0), .Px}
							if core.open(ctx, core.key_id_int(ctx, i), ln, nil) {
								core.leaf(ctx, core.auto_id(ctx), layout.Node{}, core.Paint_Text {
									s     = o.labels[i],
									style = ui.text_style(.Metadata),
									color = .Faint,
									wrap  = false,
								}, measured = true)
							}
							core.close(ctx)
						}
					}
				}
				core.close(ctx)
			}
		}
		core.close(ctx)
	}
	core.close(ctx)
	out.res = chart_response(ctx, id)
	return out
}

bar_chart :: proc(o: Chart_Options) -> Chart_Result {
	return cartesian(o, .Bar)
}

line_chart :: proc(o: Chart_Options) -> Chart_Result {
	return cartesian(o, .Line)
}

area_chart :: proc(o: Chart_Options) -> Chart_Result {
	return cartesian(o, .Area)
}
