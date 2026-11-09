// Layers the app opens from `view`: popovers, menus and dialogs are declared where they are
// triggered and `open` comes from the app's State. Every close reason (a click outside, Esc, Tab
// out, choosing an item) sends the one close message given at the call site, and the app decides
// what that means (ARCHITECTURE.md, "API design → 14").
//
// Tooltips are the exception: hover belongs to the library, so `tooltip` opens and closes itself.
package ui

import "core:time"

import "../core"
import ph "../icons/phosphor"
import "../layout"
import "../platform"

@(private)
Layer_Style :: struct {
	min_width: f32,
	padding:   Edges,
	gap:       f32,
}

@(private)
layer_style :: proc(s: Layer_Style) -> layout.Node {
	return layout.Node {
		// Absolute, so the layer does not take part in the layout of the widget that declares it.
		position       = 1,
		flex_direction = .Column,
		padding        = s.padding,
		gap            = {s.gap, s.gap},
		min_size       = {{s.min_width, .Px}, {}},
	}
}

// The box of a layer: bg-solid with a 2px border-strong edge, never a shadow (DESIGN.md, "Menu").
// The 2px border is how a layer is separated from what it covers.
@(private)
layer_paint :: proc() -> core.Paint {
	return core.Paint_Box{fill = .Bg_Solid, border = .Border_Strong, border_width = 2}
}

// A popover anchored to a widget: `anchor` is the trigger's Response. It opens below the trigger
// (or above when there is no room), aligned by `align` (0 left, 0.5 center, 1 right), and is kept
// inside the window. Returns whether it is open; the app's state owns `open`.
@(deferred_out = layer_close)
popover :: proc(
	d: Dispatch($M),
	close: M,
	open: bool,
	anchor: Response,
	key := "",
	min_width: f32 = 0,
	align: f32 = 0,
) -> bool {
	ctx := core.current()
	id := layer_id(ctx, key)
	if !open {
		// Balance the deferred close with an invisible absolute node, so `if` works the same way
		// whether the layer is open or not.
		core.open(ctx, id, layout.Node{position = 1}, nil, cull = false)
		return false
	}
	o := core.Layer_Options{anchor = anchor.rect, gap = 4, align = align}
	if !core.open_layer(ctx, id, layer_style({min_width = min_width, padding = 8, gap = 4}), layer_paint(), o) {
		return false
	}
	layer_session(ctx, id)
	layer_close_check(ctx, d, id, close)
	return true
}

// A menu: a popover that arrow keys move through, with `menu_item` children. It focuses its first
// item when it opens and restores focus to the trigger when it closes.
@(deferred_out = layer_close)
menu :: proc(d: Dispatch($M), close: M, open: bool, anchor: Response, key := "") -> bool {
	ctx := core.current()
	id := layer_id(ctx, key)
	if !open {
		core.open(ctx, id, layout.Node{position = 1}, nil, cull = false)
		return false
	}
	o := core.Layer_Options{anchor = anchor.rect, gap = 4, align = 0, menu = true}
	if !core.open_layer(ctx, id, layer_style({min_width = 180, padding = 4, gap = 0}), layer_paint(), o) {
		return false
	}
	layer_session(ctx, id)
	layer_close_check(ctx, d, id, close)
	return true
}

// A modal dialog centered in the window. Its contents are declared inside the `if`; the layer
// blocks input below it, traps Tab, and takes Esc and clicks outside as `close`.
@(deferred_out = layer_close)
dialog :: proc(d: Dispatch($M), close: M, open: bool, title := "", width: f32 = 420) -> bool {
	ctx := core.current()
	id := layer_id(ctx, "dialog")
	if !open {
		core.open(ctx, id, layout.Node{position = 1}, nil, cull = false)
		return false
	}
	o := core.Layer_Options{modal = true, center = true}
	style := layer_style({min_width = width, padding = 16, gap = 12})
	if !core.open_layer(ctx, id, style, layer_paint(), o) {
		return false
	}
	layer_session(ctx, id)
	layer_close_check(ctx, d, id, close)
	if title != "" {
		text(title, .Subsection)
	}
	return true
}

// A menu item: 32px tall, 12px horizontal padding, a divider above every item but the first, and a
// 2px fg bar on the left when it has keyboard focus. `shortcut` is shown on the right in metadata
// type; `danger` uses the error color; `submenu` adds a caret-right.
menu_item :: proc(
	label: string,
	icon: Icon = {},
	shortcut := "",
	danger := false,
	submenu := false,
	disabled := false,
) -> Response {
	ctx := core.current()
	id, display := core.label_id(ctx, label)
	core.register_name(ctx, label, id)
	it := core.interact(ctx, id)
	first := core.child_index(ctx) == 0
	ln := layout.Node {
		flex_direction  = .Row,
		align_items     = .Center,
		gap             = {8, 8},
		size            = {{0, .Auto}, {32, .Px}},
		padding         = {12, 0, 12, 0},
		flex_shrink     = 0,
	}
	flags := core.Node_Flags{.Hit, .Focusable, .Activate}
	if disabled {
		flags += {.Disabled}
	}
	paint: core.Paint
	if it.hovered || it.focused {
		paint = core.Paint_Box{fill = .Overlay}
	}
	opened := core.open(ctx, id, ln, paint, label = display, flags = flags)
	if opened {
		if !first {
			// A divider between items, full width, above this one.
			div := layout.Node{position = 1, size = {{1, .Percent}, {1, .Px}}}
			div.inset[0] = {0, .Px}
			div.inset[1] = {0, .Px}
			div.inset[2] = {0, .Px}
			core.leaf(ctx, core.auto_id(ctx), div, core.Paint_Line{color = .Border, thickness = 1})
		}
		if it.focused {
			bar := layout.Node{position = 1, align_self = .Stretch}
			bar.size[0] = {2, .Px}
			bar.inset[0] = {0, .Px}
			core.leaf(ctx, core.auto_id(ctx), bar, core.Paint_Box{fill = .Fg})
		}
		if icon.name != "" {
			is := layout.Node{size = {{16, .Px}, {16, .Px}}}
			core.leaf(ctx, core.auto_id(ctx), is, core.Paint_Icon{icon = icon, weight = .Bold, color = .Error if danger else .Fg})
		}
		lbl := layout.Node{flex_grow = 1, flex_shrink = 1, flex_basis = {0, .Px}}
		core.leaf(ctx, core.auto_id(ctx), lbl, core.Paint_Text {
			s = display,
			style = text_style(.Label),
			color = .Error if danger else .Fg,
			wrap = false,
		}, measured = true)
		if shortcut != "" {
			core.leaf(ctx, core.auto_id(ctx), layout.Node{}, core.Paint_Text {
				s = shortcut,
				style = text_style(.Metadata),
				color = .Faint,
				wrap = false,
			}, measured = true)
		}
		if submenu {
			core.leaf(ctx, core.auto_id(ctx), layout.Node{size = {{14, .Px}, {14, .Px}}}, core.Paint_Icon {
				icon = ph.CARET_RIGHT,
				weight = .Bold,
				color = .Muted,
			})
		}
	}
	core.close(ctx)
	res := response_interactive(ctx, id, disabled)
	if it.clicked {
		// Choosing an item closes the menu and returns focus to its trigger.
		core.restore_layer_focus(ctx)
	}
	return res
}

// How long the pointer must rest on a widget before its tooltip appears; tools must not flash up
// while the pointer crosses the window.
@(private)
TOOLTIP_DELAY_MS :: u64(600)

@(private)
Tooltip_State :: struct {
	since: u64, // when this hover began; 0: not hovering
}

// A tooltip above `anchor`, shown while it has been hovered for a moment. Inverted: an fg
// background with bg text (DESIGN.md, "Tooltip"). It takes no input and closes itself; the hover
// delay is timed here, so the app never sees it.
tooltip :: proc(anchor: Response, label: string) {
	if label == "" {
		return
	}
	ctx := core.current()
	// The state lives under the label's key, so a tooltip keeps its timer across ghost passes and
	// drops it the moment the pointer leaves.
	st, _ := core.state(ctx, core.key_id(ctx, label), Tooltip_State)
	now := platform.ticks_ms()
	if !anchor.hovered {
		st.since = 0
		return
	}
	if st.since == 0 {
		st.since = now
	}
	waited := now - st.since
	if waited < TOOLTIP_DELAY_MS {
		request_redraw(time.Duration(TOOLTIP_DELAY_MS - waited) * time.Millisecond)
		return
	}
	id := core.auto_id(ctx)
	o := core.Layer_Options{anchor = anchor.rect, gap = 4, align = 0.5, above = true, no_input = true}
	style := layout.Node {
		position       = 1,
		flex_direction = .Row,
		align_items    = .Center,
		padding        = {8, 4, 8, 4},
	}
	if core.open_layer(ctx, id, style, core.Paint_Box{fill = .Fg}, o) {
		lbl := layout.Node{}
		core.leaf(ctx, core.auto_id(ctx), lbl, core.Paint_Text{s = label, style = text_style(.Metadata), color = .Bg}, measured = true)
	}
	core.close(ctx)
}

// A toast: a small panel in the window's bottom-right corner, above everything and taking no input.
// The app owns `open` and decides when it goes away (usually with a `ui.after` timer).
@(deferred_out = layer_close)
toast :: proc(open: bool, label: string, detail := "", key := "toast") -> bool {
	ctx := core.current()
	id := layer_id(ctx, key)
	if !open {
		core.open(ctx, id, layout.Node{position = 1}, nil, cull = false)
		return false
	}
	o := core.Layer_Options{bottom_right = true, no_input = true}
	if !core.open_layer(ctx, id, layer_style({min_width = 280, padding = 12, gap = 4}), layer_paint(), o) {
		return false
	}
	if label != "" {
		text(label, .Label)
	}
	if detail != "" {
		text(detail, .Metadata, .Muted)
	}
	return true
}

// ---- Internals ----

@(private)
layer_close :: proc(ok: bool) {
	core.close(core.current())
}

@(private)
layer_id :: proc(ctx: ^core.Context, key: string) -> Id {
	if key != "" {
		return core.key_id(ctx, key)
	}
	return core.auto_id(ctx)
}

@(private)
Layer_State :: struct {
	opened: bool, // the layer was open in the previous pass
	opener: Id, // the focused widget when it opened
	want_focus: bool,
}

// Tracks an open layer: whether this is its opening pass, which widget had focus before it, and the
// close message shared by Esc and clicks outside.
@(private)
layer_session :: proc(ctx: ^core.Context, id: Id) {
	st, _ := core.state(ctx, id, Layer_State)
	if !st.opened {
		st.opener = ctx.input.focus
		st.want_focus = true
	} else if st.want_focus {
		// On the pass after opening, the previous pass knows the layer's full node range.
		if core.focus_first_prev(ctx, id) {
			st.want_focus = false
		}
	}
	st.opened = true
	for &layer in ctx.layers {
		if layer.id == id {
			layer.opener = st.opener
		}
	}
}

// Sends the close message when Esc or a click outside closed the topmost layer, and restores focus
// to the trigger.
@(private)
layer_close_check :: proc(ctx: ^core.Context, d: Dispatch($M), id: Id, close: M) {
	st, _ := core.state(ctx, id, Layer_State)
	if core.take_escape(ctx, id) || core.take_click_outside(ctx, id) {
		dispatch(d, close)
		if st.opener != 0 {
			core.set_focus(ctx, st.opener, true)
		}
	}
}
