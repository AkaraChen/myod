// Pie and radar charts. Both use the same texture pipeline as the cartesian charts (see chart.odin):
// nanosvg marks built in code, rasterized to an RGBA8 image, with the labels, legend and hover
// tooltip drawn by the text system over it.
package chart

import "core:fmt"
import "core:math"

import "../core"
import "../layout"
import "../platform"
import "../ui"
import ns "../third_party/odin/myod_svg"

// ---- Pie ----

Pie_Options :: struct {
	id:            ui.Key,
	labels:        []string,
	values:        []f32,
	colors:        []core.Token, // optional; the default palette is used where `.None`
	width, height: ui.Size,
	version:       u64,
	donut:         f32, // inner radius as a fraction of the outer one, 0 for a pie
	legend:        bool,
}

@(private)
pie_tok :: proc(o: Pie_Options, i: int) -> core.Token {
	if i < len(o.colors) && o.colors[i] != .None {
		return o.colors[i]
	}
	return PALETTE[i % len(PALETTE)]
}

// An arc from a0 to a1 (radians, clockwise on screen) as cubic segments, continuing from the current
// point, which must be at a0.
@(private)
arc :: proc(sc: ns.Scene, cx, cy, r, a0, a1: f32) {
	span := a1 - a0
	if abs(span) < 0.0001 {
		return
	}
	segs := max(1, int(math.ceil(abs(span) / (math.PI / 2))))
	step := span / f32(segs)
	k := 4.0 / 3.0 * math.tan(step / 4)
	for i in 0 ..< segs {
		b0 := a0 + step * f32(i)
		b1 := b0 + step
		x0 := cx + r * math.cos(b0)
		y0 := cy + r * math.sin(b0)
		x1 := cx + r * math.cos(b1)
		y1 := cy + r * math.sin(b1)
		ns.cubic(
			sc,
			x0 - k * r * math.sin(b0),
			y0 + k * r * math.cos(b0),
			x1 + k * r * math.sin(b1),
			y1 - k * r * math.cos(b1),
			x1,
			y1,
		)
	}
}

@(private)
build_pie :: proc(
	sc: ns.Scene,
	values: []f32,
	colors: []u32,
	w, h, donut: f32,
) {
	total: f32 = 0
	for v in values {
		total += max(v, 0)
	}
	if total <= 0 {
		return
	}
	cx, cy := w / 2, h / 2
	r := min(w, h) / 2 * 0.92
	ri := r * clamp(donut, 0, 0.9)
	start: f32 = -math.PI / 2
	acc: f32 = 0
	for v, i in values {
		if v <= 0 {
			continue
		}
		acc += v
		end := -math.PI / 2 + acc / total * 2 * math.PI
		color := colors[i % len(colors)]
		ns.begin(sc, color, 0, 0, 0, 1)
		ns.move(sc, cx + r * math.cos(start), cy + r * math.sin(start))
		arc(sc, cx, cy, r, start, end)
		if ri > 0 {
			// Back along the inner edge: an annular sector.
			ns.line(sc, cx + ri * math.cos(end), cy + ri * math.sin(end))
			arc(sc, cx, cy, ri, end, start)
		} else {
			ns.line(sc, cx, cy)
		}
		ns.close(sc)
		start = end
	}
}

@(private)
pie_index :: proc(rect: core.Rect, p: [2]f32, values: []f32, donut: f32) -> int {
	total: f32 = 0
	for v in values {
		total += max(v, 0)
	}
	if total <= 0 {
		return -1
	}
	cx := rect.x + rect.w / 2
	cy := rect.y + rect.h / 2
	r := min(rect.w, rect.h) / 2 * 0.92
	dx := p[0] - cx
	dy := p[1] - cy
	d := math.sqrt(dx * dx + dy * dy)
	if d > r || d < r * clamp(donut, 0, 0.9) {
		return -1
	}
	ang := math.atan2(dy, dx) + math.PI / 2
	if ang < 0 {
		ang += 2 * math.PI
	}
	acc: f32 = 0
	for v, i in values {
		acc += max(v, 0)
		if ang <= acc / total * 2 * math.PI {
			return i
		}
	}
	return len(values) - 1
}

// A pie or donut chart. Hovering a slice reports it and shows a tooltip; the marks are never
// re-rasterized for the hover.
pie_chart :: proc(o: Pie_Options) -> Chart_Result {
	ctx := core.current()
	id := chart_id(ctx, o.id)
	st, created := core.state(ctx, id, Chart_State)
	if created {
		core.set_state_free(ctx, id, chart_state_free)
	}
	out := Chart_Result{res = ui.Response{id = id}, hover = -1, series = -1}
	colors := make([]u32, len(o.values), context.temp_allocator)
	total: f32 = 0
	for v in o.values {
		total += max(v, 0)
	}
	for i in 0 ..< len(o.values) {
		colors[i] = rgba(ctx, pie_tok(o, i))
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
			if ui.row({width = ui.grow(), wrap = true, gap = 12, align_y = .Center}) {
				for i in 0 ..< min(len(o.labels), len(o.values)) {
					if ui.row({width = ui.fit(), align_y = .Center, gap = 5}) {
						g := layout.Node{size = {{10, .Px}, {10, .Px}}}
						core.leaf(ctx, core.auto_id(ctx), g, core.Paint_Box{fill = pie_tok(o, i)})
						ui.text(o.labels[i], .Metadata, .Muted, wrap = false)
					}
				}
			}
		}
		plot_id := core.key_id(ctx, "plot")
		it := core.interact(ctx, plot_id)
		plot := layout.Node {
			flex_direction = .Row,
			flex_grow      = 1,
			flex_basis     = {0, .Px},
		}
		rect, ok := core.last_rect(ctx, plot_id)
		p := core.pointer(ctx)
		k := chart_key_index(ctx, plot_id, st, min(len(o.labels), len(o.values)), it)
		hover := -1
		if ok && it.hovered && !st.key_active {
			hover = pie_index(rect, p, o.values, o.donut)
		}
		// The keyboard's slice stands in for the pointer's while the plot has focus.
		if hover < 0 && k >= 0 {
			hover = k
		}
		if core.open(ctx, plot_id, plot, nil, label = "Chart plot", flags = {.Hit, .Focusable, .Arrows}) {
			if hover >= 0 {
				share: f32 = 0
				if total > 0 {
					share = o.values[hover] / total * 100
				}
				core.set_a11y_value(ctx, plot_id, fmt.tprintf("%s, %s %.1f%%", o.labels[hover], tick_value(o.values[hover]), share))
			}
			if ok && rect.w > 1 && rect.h > 1 {
				scale := platform.display_scale(ui.current_window().p)
				pw := max(1, int(rect.w * scale + 0.5))
				ph := max(1, int(rect.h * scale + 0.5))
				if need_raster(st, o.version, pw, ph) {
					sc := ns.scene_new(f32(pw), f32(ph))
					build_pie(sc, o.values, colors, f32(pw), f32(ph), o.donut * scale)
					rasterize(st, sc, pw, ph, o.version)
				}
				if st.pixels != nil {
					ui.image(chart_image(st), ui.grow(), ui.grow(), .Stretch)
				}
				if hover >= 0 {
					tw: f32 = 160
					px := p[0] - rect.x + 12
					py := p[1] - rect.y + 12
					if !it.hovered {
						// Keyboard hover: the tooltip sits in the chart's corner, the pointer may be
						// anywhere.
						px = 8
						py = 8
					}
					tx := clamp(px, 0, max(rect.w - tw - 4, 0))
					ty := clamp(py, 0, max(rect.h - 64, 0))
					if tooltip(ctx, tx, ty, tw) {
						ui.text(o.labels[hover], .Label, .Fg, wrap = false)
						v := o.values[hover]
						share: f32 = 0
						if total > 0 {
							share = v / total * 100
						}
						ui.text(fmt.tprintf("%s  %.1f%%", tick_value(v), share), .Metadata, .Muted, wrap = false)
					}
					core.close(ctx)
					out.hover = hover
					ui.request_redraw()
				}
			}
		}
		core.close(ctx)
	}
	core.close(ctx)
	out.res = chart_response(ctx, id)
	return out
}

// ---- Radar ----

Radar_Options :: struct {
	id:            ui.Key,
	labels:        []string,
	series:        []Series,
	width, height: ui.Size,
	version:       u64,
	max:           f32, // 0: derived from the data
	rings:         int, // 0: 4
	legend:        bool,
}

@(private)
radar_max :: proc(o: Radar_Options) -> f32 {
	if o.max > 0 {
		return o.max
	}
	mx: f32 = 0
	for s in o.series {
		for v in s.values {
			mx = max(mx, v)
		}
	}
	if mx <= 0 {
		return 1
	}
	return mx * 1.08
}

@(private)
radar_point :: proc(cx, cy, r, t, angle: f32) -> [2]f32 {
	return {cx + math.cos(angle) * r * t, cy + math.sin(angle) * r * t}
}

@(private)
radar_angle :: proc(i, n: int) -> f32 {
	return -math.PI / 2 + f32(i) / f32(n) * 2 * math.PI
}

@(private)
build_radar :: proc(
	sc: ns.Scene,
	o: Radar_Options,
	values_count: int,
	colors: []u32,
	grid_color: u32,
	mx, w, h, s: f32,
) {
	n := len(o.labels)
	if n < 3 {
		return
	}
	cx, cy := w / 2, h / 2
	r := min(w, h) / 2 - 18 * s
	rings := o.rings if o.rings > 0 else 4
	// The rings and the spokes, in the border color.
	for k in 1 ..= rings {
		t := f32(k) / f32(rings)
		ns.begin(sc, 0, grid_color, 1 * s, 0, 1)
		for i in 0 ..< n {
			p := radar_point(cx, cy, r, t, radar_angle(i, n))
			if i == 0 {
				ns.move(sc, p[0], p[1])
			} else {
				ns.line(sc, p[0], p[1])
			}
		}
		ns.close(sc)
	}
	for i in 0 ..< n {
		p := radar_point(cx, cy, r, 1, radar_angle(i, n))
		ns.begin(sc, 0, grid_color, 1 * s, 0, 1)
		ns.move(sc, cx, cy)
		ns.line(sc, p[0], p[1])
	}
	for si in 0 ..< len(o.series) {
		vals := o.series[si].values
		count := min(n, len(vals))
		if count == 0 {
			continue
		}
		// The fill, then the outline.
		ns.begin(sc, rgba_tok(colors[si], 45), 0, 0, 0, 1)
		for i in 0 ..< count {
			t := clamp(vals[i] / mx, 0, 1)
			p := radar_point(cx, cy, r, t, radar_angle(i, n))
			if i == 0 {
				ns.move(sc, p[0], p[1])
			} else {
				ns.line(sc, p[0], p[1])
			}
		}
		ns.close(sc)
		ns.begin(sc, 0, colors[si], 2 * s, 0, 1)
		for i in 0 ..< count {
			t := clamp(vals[i] / mx, 0, 1)
			p := radar_point(cx, cy, r, t, radar_angle(i, n))
			if i == 0 {
				ns.move(sc, p[0], p[1])
			} else {
				ns.line(sc, p[0], p[1])
			}
		}
		ns.close(sc)
	}
}

// A radar chart: one polygon per series over the shared axes. Hovering a spoke reports that axis and
// lists every series' value there.
radar_chart :: proc(o: Radar_Options) -> Chart_Result {
	ctx := core.current()
	id := chart_id(ctx, o.id)
	st, created := core.state(ctx, id, Chart_State)
	if created {
		core.set_state_free(ctx, id, chart_state_free)
	}
	out := Chart_Result{res = ui.Response{id = id}, hover = -1, series = -1}
	mx := radar_max(o)
	colors := make([]u32, len(o.series), context.temp_allocator)
	for i in 0 ..< len(o.series) {
		colors[i] = rgba(ctx, series_tok(Chart_Options{series = o.series}, i))
	}
	grid_color := rgba(ctx, .Border)
	outer := layout.Node {
		flex_direction = .Column,
		gap            = {6, 6},
		align_self     = .Stretch,
	}
	apply_item(ctx, &outer, o.width, o.height)
	if core.open(ctx, id, outer, nil, label = "Chart") {
		core.set_a11y_role(ctx, id, .Group)
		if o.legend {
			if ui.row({width = ui.grow(), wrap = true, gap = 12, align_y = .Center}) {
				for s, i in o.series {
					if ui.row({width = ui.fit(), align_y = .Center, gap = 5}) {
						g := layout.Node{size = {{10, .Px}, {10, .Px}}}
						core.leaf(ctx, core.auto_id(ctx), g, core.Paint_Box{fill = series_tok(Chart_Options{series = o.series}, i)})
						ui.text(s.label, .Metadata, .Muted, wrap = false)
					}
				}
			}
		}
		plot_id := core.key_id(ctx, "plot")
		it := core.interact(ctx, plot_id)
		plot := layout.Node {
			flex_direction = .Row,
			flex_grow      = 1,
			flex_basis     = {0, .Px},
		}
		rect, ok := core.last_rect(ctx, plot_id)
		p := core.pointer(ctx)
		k := chart_key_index(ctx, plot_id, st, len(o.labels), it)
		hover := -1
		n := len(o.labels)
		if ok && it.hovered && !st.key_active && n >= 3 {
			cx := rect.x + rect.w / 2
			cy := rect.y + rect.h / 2
			dx := p[0] - cx
			dy := p[1] - cy
			if math.sqrt(dx * dx + dy * dy) <= min(rect.w, rect.h) / 2 {
				ang := math.atan2(dy, dx) + math.PI / 2
				if ang < 0 {
					ang += 2 * math.PI
				}
				hover = int(math.round(ang / (2 * math.PI) * f32(n))) % n
			}
		}
		// The keyboard's spoke stands in for the pointer's while the plot has focus.
		if hover < 0 && k >= 0 {
			hover = k
		}
		if core.open(ctx, plot_id, plot, nil, label = "Chart plot", flags = {.Hit, .Focusable, .Arrows}) {
			if hover >= 0 {
				core.set_a11y_value(ctx, plot_id, chart_summary(Chart_Options{labels = o.labels, series = o.series}, hover))
			}
			if ok && rect.w > 1 && rect.h > 1 {
				scale := platform.display_scale(ui.current_window().p)
				pw := max(1, int(rect.w * scale + 0.5))
				ph := max(1, int(rect.h * scale + 0.5))
				if need_raster(st, o.version, pw, ph) {
					sc := ns.scene_new(f32(pw), f32(ph))
					build_radar(sc, o, n, colors, grid_color, mx, f32(pw), f32(ph), scale)
					rasterize(st, sc, pw, ph, o.version)
				}
				if st.pixels != nil {
					ui.image(chart_image(st), ui.grow(), ui.grow(), .Stretch)
				}
				// The axis labels, drawn by the text system around the plot.
				label_r := min(rect.w, rect.h) / 2 - 18
				for i in 0 ..< n {
					a := radar_angle(i, n)
					lx := rect.w / 2 + math.cos(a) * (label_r + 2) - 40
					ly := rect.h / 2 + math.sin(a) * (label_r + 2) - 7
					ln := layout.Node {
						position        = 1,
						flex_direction  = .Row,
						justify_content = .Center,
						align_items     = .Center,
						size            = {{80, .Px}, {14, .Px}},
					}
					ln.inset[0] = {clamp(lx, 0, max(rect.w - 80, 0)), .Px}
					ln.inset[1] = {clamp(ly, 0, max(rect.h - 14, 0)), .Px}
					if core.open(ctx, core.key_id_int(ctx, 300 + i), ln, nil) {
						core.leaf(ctx, core.auto_id(ctx), layout.Node{}, core.Paint_Text {
							s     = o.labels[i],
							style = ui.text_style(.Metadata),
							color = .Faint,
							wrap  = false,
						}, measured = true)
					}
					core.close(ctx)
				}
				if hover >= 0 {
					tw: f32 = 160
					px := p[0] - rect.x + 12
					py := p[1] - rect.y + 12
					if !it.hovered {
						px = 8
						py = 8
					}
					tx := clamp(px, 0, max(rect.w - tw - 4, 0))
					ty := clamp(py, 0, max(rect.h - 80, 0))
					if tooltip(ctx, tx, ty, tw) {
						ui.text(o.labels[hover], .Label, .Fg, wrap = false)
						for si in 0 ..< len(o.series) {
							s := o.series[si]
							v: f32 = 0
							if hover < len(s.values) {
								v = s.values[hover]
							}
							if ui.row({width = ui.grow(), align_y = .Center, gap = 6}) {
								sw := layout.Node{size = {{8, .Px}, {8, .Px}}}
								core.leaf(ctx, core.auto_id(ctx), sw, core.Paint_Box{fill = series_tok(Chart_Options{series = o.series}, si)})
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
					ui.request_redraw()
				}
			}
		}
		core.close(ctx)
	}
	core.close(ctx)
	out.res = chart_response(ctx, id)
	return out
}
