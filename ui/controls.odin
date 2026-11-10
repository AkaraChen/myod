// Controls: the widgets that take input. They declare their node with the interaction flags and read
// the input phase while declaring, so hover, press and focus are drawn on the very pass that sees
// them (ARCHITECTURE.md, "API design → 3"; DESIGN.md, "Components").
package ui

import "core:fmt"

import ph "../icons/phosphor"
import "../core"
import "../layout"

// The button variants of DESIGN.md, "Components": outline is the default, primary the main action,
// ghost for toolbars, danger for destructive actions.
Button_Variant :: enum {
	Outline,
	Primary,
	Ghost,
	Danger,
}

// Components share a height of 28px (24px for small), so buttons and inputs line up
// (DESIGN.md, "Components").
Control_Size :: enum {
	Default,
	Small,
}

// A button with a label, and optionally an icon before it. Returns the pass's interaction.
button :: proc(
	label: string,
	icon: Icon = {},
	variant: Button_Variant = .Outline,
	size: Control_Size = .Default,
	disabled := false,
) -> Response {
	return button_impl(label, icon, false, variant, size, disabled)
}

// A square, icon-only button (28×28, 24×24 for small). `label` is its accessible name.
icon_button :: proc(
	icon: Icon,
	label: string,
	variant: Button_Variant = .Outline,
	size: Control_Size = .Default,
	disabled := false,
) -> Response {
	return button_impl(label, icon, true, variant, size, disabled)
}

@(private)
button_impl :: proc(
	label: string,
	glyph: Icon,
	icon_only: bool,
	variant: Button_Variant,
	size: Control_Size,
	disabled: bool,
) -> Response {
	ctx := core.current()
	id, display := core.label_id(ctx, label)
	core.register_name(ctx, label, id)

	it := core.interact(ctx, id)
	hovered := it.hovered && !disabled
	pressed := it.pressed && !disabled
	height: f32 = 24 if size == .Small else 28
	pad_x: f32 = 8 if size == .Small else 12
	icon_size: f32 = 14 if size == .Small else 16
	gap: f32 = 4 if size == .Small else 6

	ln := layout.Node {
		flex_direction  = .Row,
		align_items     = .Center,
		justify_content = .Center,
		gap             = {gap, gap},
		size            = {{0, .Auto}, {height, .Px}},
	}
	if icon_only {
		ln.size[0] = {height, .Px}
	} else {
		ln.padding = edges({pad_x, 0, pad_x, 0})
	}

	p := core.Paint_Box{border_width = 1}
	fg_token: core.Token = .Fg
	switch variant {
	case .Outline:
		p.border = .Border
		if pressed {
			p.fill = .Overlay_Hover
		} else if hovered {
			p.fill = .Overlay
		}
	case .Ghost:
		p.border_width = 0
		if pressed {
			p.fill = .Overlay_Hover
		} else if hovered {
			p.fill = .Overlay
		}
	case .Primary:
		p.fill = .Fg
		p.border_width = 0
		fg_token = .Bg
	case .Danger:
		p.fill = .Error
		p.border_width = 0
		fg_token = .Bg
	}

	flags := core.Node_Flags{.Hit, .Focusable, .Activate}
	if disabled {
		flags += {.Disabled}
	}
	opened := core.open(ctx, id, ln, p, label = display, flags = flags)
	if opened {
		if glyph.name != "" {
			leaf := layout.Node{size = {{icon_size, .Px}, {icon_size, .Px}}}
			core.leaf(ctx, core.auto_id(ctx), leaf, core.Paint_Icon {
				icon = glyph,
				weight = .Bold,
				color = fg_token,
			})
		}
		if !icon_only {
			lbl := layout.Node{}
			core.leaf(ctx, core.auto_id(ctx), lbl, core.Paint_Text {
				s = display,
				style = text_style(.Label),
				color = fg_token,
			}, measured = true)
		}
	}
	core.close(ctx)

	return response_interactive(ctx, id, disabled)
}

// A Response carrying the pass's interaction state. Disabled widgets report nothing.
@(private)
response_interactive :: proc(ctx: ^core.Context, id: Id, disabled: bool) -> Response {
	r, _ := core.last_rect(ctx, id)
	it := core.interact(ctx, id)
	res := Response {
		id             = id,
		rect           = r,
		focused        = it.focused,
		lost_focus     = it.lost_focus,
	}
	if disabled {
		return res
	}
	res.hovered = it.hovered
	res.pressed = it.pressed
	res.clicked = it.clicked
	res.double_clicked = it.double_clicked
	res.secondary_clicked = it.secondary_clicked
	return res
}

// The ID of a control with an optional label, and the label to draw (see `label_id`).
@(private)
control_id :: proc(ctx: ^core.Context, label: string, key: string = "") -> (id: Id, display: string) {
	if label == "" && key == "" {
		return core.auto_id(ctx), ""
	}
	if label == "" {
		return core.key_id(ctx, key), ""
	}
	id, display = core.label_id(ctx, label)
	core.register_name(ctx, label, id)
	return
}

// A checkbox: a 16×16 box that fills with fg and a check when on (DESIGN.md, "Checkbox"). The whole
// row (box and label) toggles. `changed` when the user turned it on or off.
checkbox :: proc(checked: bool, label := "", disabled := false) -> Response {
	ctx := core.current()
	id, display := control_id(ctx, label)
	it := core.interact(ctx, id)
	ln := layout.Node {
		flex_direction = .Row,
		align_items    = .Center,
		gap            = {8, 8},
		size           = {{0, .Auto}, {20, .Px}},
	}
	flags := core.Node_Flags{.Hit, .Focusable, .Activate}
	if disabled {
		flags += {.Disabled}
	}
	opened := core.open(ctx, id, ln, nil, label = display, flags = flags)
	if opened {
		p := core.Paint_Box{border = .Border_Strong, border_width = 1}
		if checked {
			p = {fill = .Fg}
		}
		box := layout.Node {
			flex_direction  = .Row,
			align_items     = .Center,
			justify_content = .Center,
			size            = {{16, .Px}, {16, .Px}},
		}
		if core.open(ctx, core.auto_id(ctx), box, p) {
			if checked {
				leaf := layout.Node{size = {{12, .Px}, {12, .Px}}}
				core.leaf(ctx, core.auto_id(ctx), leaf, core.Paint_Icon{icon = ph.CHECK, weight = .Bold, color = .Bg})
			}
		}
		core.close(ctx)
		if display != "" {
			leaf := layout.Node{}
			core.leaf(ctx, core.auto_id(ctx), leaf, core.Paint_Text{s = display, style = text_style(.Compact), color = .Fg}, measured = true)
		}
	}
	core.close(ctx)
	res := response_interactive(ctx, id, disabled)
	res.changed = it.clicked
	return res
}

// A switch: 36×20 square, a 14×14 thumb jumping between the two ends (DESIGN.md, "Switch").
toggle :: proc(on: bool, label := "", disabled := false) -> Response {
	ctx := core.current()
	id, display := control_id(ctx, label)
	it := core.interact(ctx, id)
	ln := layout.Node {
		flex_direction = .Row,
		align_items    = .Center,
		gap            = {8, 8},
		size           = {{0, .Auto}, {20, .Px}},
	}
	flags := core.Node_Flags{.Hit, .Focusable, .Activate}
	if disabled {
		flags += {.Disabled}
	}
	opened := core.open(ctx, id, ln, nil, label = display, flags = flags)
	if opened {
		p := core.Paint_Box{border = .Border_Strong, border_width = 1}
		if on {
			p = {fill = .Success, border = .Success, border_width = 1}
		}
		track := layout.Node{size = {{36, .Px}, {20, .Px}}}
		if core.open(ctx, core.auto_id(ctx), track, p) {
			thumb := layout.Node{position = 1, size = {{14, .Px}, {14, .Px}}}
			thumb.inset[0] = {19 if on else 3, .Px}
			thumb.inset[2] = {2, .Px}
			core.leaf(ctx, core.auto_id(ctx), thumb, core.Paint_Box{fill = .Bg_Solid if on else .Muted})
		}
		core.close(ctx)
		if display != "" {
			leaf := layout.Node{}
			core.leaf(ctx, core.auto_id(ctx), leaf, core.Paint_Text{s = display, style = text_style(.Compact), color = .Fg}, measured = true)
		}
	}
	core.close(ctx)
	res := response_interactive(ctx, id, disabled)
	res.changed = it.clicked
	return res
}

// A radio button: a 16×16 square, an 8×8 fg fill inside when selected (DESIGN.md, "Radio button").
radio :: proc(selected: bool, label := "", disabled := false) -> Response {
	ctx := core.current()
	id, display := control_id(ctx, label)
	it := core.interact(ctx, id)
	ln := layout.Node {
		flex_direction = .Row,
		align_items    = .Center,
		gap            = {8, 8},
		size           = {{0, .Auto}, {20, .Px}},
	}
	flags := core.Node_Flags{.Hit, .Focusable, .Activate}
	if disabled {
		flags += {.Disabled}
	}
	opened := core.open(ctx, id, ln, nil, label = display, flags = flags)
	if opened {
		box := layout.Node {
			flex_direction  = .Row,
			align_items     = .Center,
			justify_content = .Center,
			size            = {{16, .Px}, {16, .Px}},
		}
		if core.open(ctx, core.auto_id(ctx), box, core.Paint_Box{border = .Border_Strong, border_width = 1}) {
			if selected {
				inner := layout.Node{size = {{8, .Px}, {8, .Px}}}
				core.leaf(ctx, core.auto_id(ctx), inner, core.Paint_Box{fill = .Fg})
			}
		}
		core.close(ctx)
		if display != "" {
			leaf := layout.Node{}
			core.leaf(ctx, core.auto_id(ctx), leaf, core.Paint_Text{s = display, style = text_style(.Compact), color = .Fg}, measured = true)
		}
	}
	core.close(ctx)
	res := response_interactive(ctx, id, disabled)
	res.changed = it.clicked
	return res
}

// A slider: a 6px hollow track with an 8×14 solid handle (DESIGN.md, "Slider"). Controlled: returns
// the new value (0..1) and `changed` when the user moved it with the pointer or the arrow keys.
slider :: proc(value: f32, width: Size = GROW, disabled := false) -> (Response, f32) {
	ctx := core.current()
	id := core.auto_id(ctx)
	it := core.interact(ctx, id)
	ln := layout.Node {
		flex_direction = .Row,
		align_items    = .Center,
		size           = {{0, .Auto}, {20, .Px}},
	}
	item(ctx, &ln, width, {})
	flags := core.Node_Flags{.Hit, .Focusable, .Adjust}
	if disabled {
		flags += {.Disabled}
	}
	opened := core.open(ctx, id, ln, nil, flags = flags)
	if opened {
		track_id := core.auto_id(ctx)
		track := layout.Node{size = {{0, .Auto}, {6, .Px}}, flex_grow = 1, flex_shrink = 1, flex_basis = {0, .Px}}
		core.leaf(ctx, track_id, track, core.Paint_Box{border = .Border_Strong, border_width = 1})
		// The 8×14 handle, centered on the value along the track (DESIGN.md, "Slider").
		tw := core.measured(ctx, track_id).x
		if tw > 0 {
			handle := layout.Node{position = 1, size = {{8, .Px}, {14, .Px}}}
			handle.inset[0] = {clamp(value, 0, 1) * max(tw - 8, 0), .Px}
			handle.inset[2] = {3, .Px}
			core.leaf(ctx, core.auto_id(ctx), handle, core.Paint_Box{fill = .Fg})
		}
	}
	core.close(ctx)
	res := response_interactive(ctx, id, disabled)
	if disabled {
		return res, value
	}
	r := res.rect
	w := r.w
	v := clamp(value, 0, 1)
	next := v
	if it.held && w > 0 {
		p := core.pointer(ctx)
		next = clamp((p.x - r.x) / w, 0, 1)
	}
	for e in core.keys(ctx, id) {
		step: f32 = 0.02
		#partial switch e.key {
		case .Left, .Down:
			next = clamp(next - step, 0, 1)
		case .Right, .Up:
			next = clamp(next + step, 0, 1)
		case .Home:
			next = 0
		case .End:
			next = 1
		}
	}
	res.changed = next != v
	return res, next
}

// A progress bar: an 8px hollow track filled with fg, and the percentage on the right
// (DESIGN.md, "Progress bar"). No interaction.
progress :: proc(value: f32, width: Size = GROW) -> Response {
	ctx := core.current()
	id := core.auto_id(ctx)
	v := clamp(value, 0, 1)
	ln := layout.Node {
		flex_direction = .Row,
		align_items    = .Center,
		gap            = {8, 8},
	}
	item(ctx, &ln, width, {})
	opened := core.open(ctx, id, ln, nil)
	if opened {
		track_id := core.auto_id(ctx)
		track := layout.Node {
			flex_direction = .Row,
			size           = {{0, .Auto}, {8, .Px}},
			flex_grow      = 1,
			flex_shrink    = 1,
			flex_basis     = {0, .Px},
		}
		if core.open(ctx, track_id, track, core.Paint_Box{border = .Border_Strong, border_width = 1}) {
			tw := core.measured(ctx, track_id).x
			if v > 0 && tw > 0 {
				fill := layout.Node {
					position = 1,
					size     = {{tw * v, .Px}, {8, .Px}},
				}
				fill.inset[0] = {0, .Px}
				fill.inset[2] = {0, .Px}
				core.leaf(ctx, core.auto_id(ctx), fill, core.Paint_Box{fill = .Fg})
			}
		}
		core.close(ctx)
		leaf := layout.Node{size = {{40, .Px}, {20, .Px}}}
		core.leaf(
			ctx,
			core.auto_id(ctx),
			leaf,
			core.Paint_Text{s = fmt.tprintf("%d%%", int(v * 100 + 0.5)), style = text_style(.Compact), color = .Muted, wrap = false},
		)
	}
	core.close(ctx)
	return response(ctx, id)
}

// Tabs bound to an enum: the labels are indexed by the enum, and the second result is the tab the
// user clicked (the current one when nothing was clicked). DESIGN.md, "Tabs".
tabs :: proc(value: $E, labels: [E]string, disabled := false) -> (Response, E) {
	ctx := core.current()
	group := core.auto_id(ctx)
	chosen := value
	changed := false
	res := Response{id = group}
	ln := layout.Node{flex_direction = .Column}
	opened := core.open(ctx, group, ln, nil)
	if opened {
		if row({gap = 0, align_y = .End, width = grow()}) {
			for i in 0 ..< len(labels) {
				e := E(i)
				label := labels[e]
				id, display := core.label_id(ctx, label)
				it := core.interact(ctx, id)
				tab := layout.Node {
					flex_direction  = .Row,
					align_items     = .Center,
					justify_content = .Center,
					size            = {{0, .Auto}, {32, .Px}},
					padding         = {12, 12, 0, 0},
				}
				flags := core.Node_Flags{.Hit, .Focusable, .Activate}
				if disabled {
					flags += {.Disabled}
				}
				if core.open(ctx, id, tab, nil, label = display, flags = flags) {
					if it.hovered {
						core.leaf(ctx, core.auto_id(ctx), layout.Node {
							position = 1,
							size     = {{0, .Auto}, {32, .Px}},
						}, core.Paint_Box{fill = .Overlay})
					}
					active := e == value
					leaf := layout.Node{}
					core.leaf(ctx, core.auto_id(ctx), leaf, core.Paint_Text {
						s = display,
						style = text_style(.Label),
						color = .Fg if active else .Muted,
					}, measured = true)
					if active {
						bar := layout.Node{position = 1, size = {{0, .Auto}, {2, .Px}}}
						bar.inset[3] = {0, .Px}
						core.leaf(ctx, core.auto_id(ctx), bar, core.Paint_Box{fill = .Fg})
					}
					if it.clicked && !disabled {
						chosen = e
						changed = e != value
					}
				}
				core.close(ctx)
			}
		}
		strong_divider()
	}
	core.close(ctx)
	res.changed = changed
	res.clicked = changed
	return res, chosen
}

// A splitter: a 6px hit area with a 1px line in it; dragging follows the pointer 1:1
// (DESIGN.md, "Divider"). The line is vertical between columns and horizontal in a column.
splitter :: proc(disabled := false) -> Response {
	ctx := core.current()
	id := core.auto_id(ctx)
	it := core.interact(ctx, id)
	dir, in_grid := core.parent_direction(ctx)
	vertical := dir == .Row && !in_grid
	ln := layout.Node {
		flex_direction  = .Row,
		align_items     = .Center,
		justify_content = .Center,
		align_self      = .Stretch,
	}
	if vertical {
		ln.size[0] = {6, .Px}
	} else {
		ln.size[1] = {6, .Px}
	}
	flags := core.Node_Flags{.Hit}
	if disabled {
		flags += {.Disabled}
	}
	opened := core.open(ctx, id, ln, core.Paint_Box{fill = .Overlay if it.hovered || it.held else .None}, flags = flags)
	if opened {
		line := layout.Node{align_self = .Stretch, justify_self = .Stretch}
		if vertical {
			line.size[0] = {1, .Px}
		} else {
			line.size[1] = {1, .Px}
		}
		core.leaf(ctx, core.auto_id(ctx), line, core.Paint_Line {
			color = .Fg if it.hovered || it.held else .Border,
			thickness = 1,
			vertical = vertical,
		})
	}
	core.close(ctx)
	res := response_interactive(ctx, id, disabled)
	st, _ := core.state(ctx, id, Splitter_State)
	if !disabled && it.held {
		axis := 0 if vertical else 1
		p := core.pointer(ctx)[axis]
		if !st.dragging {
			st.dragging = true
			st.last = p
		}
		res.drag = p - st.last
		st.last = p
		res.dragging = true
	} else {
		st.dragging = false
	}
	return res
}

@(private)
Splitter_State :: struct {
	last:     f32,
	dragging: bool,
}
