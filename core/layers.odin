// Layers (ARCHITECTURE.md, "API design → 14"): popovers, menus and dialogs are declared where they
// are triggered, but positioned after layout, drawn above the base content, and hit-tested from the
// top down.
//
// The declaration records each layer's node range (core.odin); this file answers the questions the
// input phase, focus movement and drawing ask about them.
package core

import "../layout"
import "../platform"

// Opens a container as a layer. `style` is laid out in place (it must be absolutely positioned so it
// does not disturb its siblings); its rect is replaced after layout by the position derived from
// `anchor`. Returns false when culled; `close` must still be called.
open_layer :: proc(ctx: ^Context, id: Id, style: layout.Node, paint: Paint, o: Layer_Options, flags: Node_Flags = {}, label := "") -> bool {
	f := flags + {.Layer}
	if o.modal {
		f += {.Modal}
	}
	if o.menu {
		f += {.Menu}
	}
	// A sheet or drawer spans the window along its edge; the other axis comes from the style.
	s := style
	switch o.edge {
	case .Left, .Right:
		s.size[1] = {ctx.size.y, .Px}
		s.min_size[1] = {}
		s.max_size[1] = {}
	case .Top, .Bottom:
		s.size[0] = {ctx.size.x, .Px}
		s.min_size[0] = {}
		s.max_size[0] = {}
	case .None:
	}
	opened := open(ctx, id, s, paint, clip = false, cull = false, label = label, flags = f)
	if opened && len(ctx.layers) > 0 {
		layer := &ctx.layers[len(ctx.layers) - 1]
		layer.anchor = o.anchor
		layer.gap = o.gap
		layer.align = o.align
		layer.center = o.center
		layer.above = o.above
		layer.no_input = o.no_input
		layer.bottom_right = o.bottom_right
		layer.edge = o.edge
	}
	return opened
}

Layer_Options :: struct {
	modal:    bool,
	menu:     bool,
	anchor:   Rect, // in root coordinates; zero: centered
	gap:      f32, // between the anchor and the layer
	align:    f32, // 0: the anchor's left edge, 0.5: centered, 1: right edges
	center:   bool,
	above:    bool, // place above the anchor (tooltips); flips below near the top edge
	no_input: bool, // tooltips: no pointer, no Esc or outside-click handling
	bottom_right: bool, // toasts: the window's bottom-right corner
	edge:     Layer_Edge, // sheets and drawers: flush against a window edge
}

// Whether the node at `index` is inside a layer (itself included).
layer_of :: proc(ctx: ^Context, index: i32) -> int {
	t := &ctx.trees[ctx.cur]
	for i := index; i >= 0; i = t.nodes[i].parent {
		if .Layer in t.nodes[i].flags {
			for layer, k in ctx.layers {
				if layer.start == i {
					return k
				}
			}
			return -1
		}
	}
	return -1
}

// The topmost layer, if any is open.
top_layer :: proc(ctx: ^Context) -> (Layer, bool) {
	if len(ctx.layers) == 0 {
		return {}, false
	}
	return ctx.layers[len(ctx.layers) - 1], true
}

// The first modal layer from the top; input below it is blocked.
@(private)
top_modal :: proc(ctx: ^Context) -> int {
	for i := len(ctx.layers) - 1; i >= 0; i -= 1 {
		if ctx.layers[i].modal {
			return i
		}
	}
	return -1
}

// The topmost layer that takes input: tooltips are skipped (they never close on clicks or Esc and
// never block what is below).
@(private)
top_input_layer :: proc(ctx: ^Context) -> int {
	for i := len(ctx.layers) - 1; i >= 0; i -= 1 {
		if !ctx.layers[i].no_input {
			return i
		}
	}
	return -1
}

// The same, for a layer that was open in the previous pass (seen from the pass after it opened).
// The range indexes the previous pass's tree, and on this pass the layer's content has not been
// declared yet when this runs, so the scan has to happen in that tree. `index` picks the nth
// focusable node (0: the first) and is clamped to what the layer holds.
focus_nth_prev :: proc(ctx: ^Context, layer_id: Id, index: int, visible := true) -> bool {
	for &layer in ctx.layers_prev {
		if layer.id != layer_id {
			continue
		}
		t := &ctx.trees[1 - ctx.cur]
		ids := make([dynamic]Id, 0, 16, context.temp_allocator)
		for i := int(layer.start); i < int(layer.end) && i < len(t.nodes); i += 1 {
			n := &t.nodes[i]
			if is_disabled(t, i32(i)) || .Culled in n.flags {
				i = int(n.end) - 1
				continue
			}
			if .Focusable in n.flags {
				append(&ids, n.id)
			}
		}
		if len(ids) == 0 {
			return false
		}
		set_focus(ctx, ids[clamp(index, 0, len(ids) - 1)], visible)
		return true
	}
	return false
}

// Returns focus to the widget that opened the topmost input layer (a menu item was chosen).
restore_layer_focus :: proc(ctx: ^Context) {
	k := top_input_layer(ctx)
	if k >= 0 && ctx.layers[k].opener != 0 {
		set_focus(ctx, ctx.layers[k].opener, true)
	}
}

// Whether a layer with this ID was open in the previous pass (used to detect the opening pass).
layer_was_open :: proc(ctx: ^Context, id: Id) -> bool {
	for l in ctx.layers_prev {
		if l.id == id {
			return true
		}
	}
	return false
}

// Esc was pressed during the input phase: the topmost input layer takes it and closes itself.
take_escape :: proc(ctx: ^Context, layer_id: Id) -> bool {
	if !ctx.input.escape {
		return false
	}
	k := top_input_layer(ctx)
	if k < 0 || ctx.layers[k].id != layer_id {
		return false
	}
	ctx.input.escape = false
	return true
}

// A click landed outside the topmost input layer and was swallowed (it does not reach the content
// below).
take_click_outside :: proc(ctx: ^Context, layer_id: Id) -> bool {
	if !ctx.input.click_outside {
		return false
	}
	k := top_input_layer(ctx)
	if k < 0 || ctx.layers[k].id != layer_id {
		return false
	}
	ctx.input.click_outside = false
	return true
}

// Focuses the first focusable node inside a layer (its first menu item, a dialog's first field).
focus_first :: proc(ctx: ^Context, layer_id: Id, visible := true) -> bool {
	for &layer in ctx.layers {
		if layer.id == layer_id {
			return focus_range(ctx, layer.start, layer.end, visible)
		}
	}
	return false
}

// The same, while the layer's content is still being declared (its end is not known yet).
focus_first_open :: proc(ctx: ^Context, layer_id: Id, visible := true) -> bool {
	t := &ctx.trees[ctx.cur]
	for &layer in ctx.layers {
		if layer.id == layer_id {
			return focus_range(ctx, layer.start, i32(len(t.nodes)), visible)
		}
	}
	return false
}

@(private)
focus_range :: proc(ctx: ^Context, from, to: i32, visible: bool) -> bool {
	t := &ctx.trees[ctx.cur]
	for i := int(from); i < int(to) && i < len(t.nodes); i += 1 {
		n := &t.nodes[i]
		if is_disabled(t, i32(i)) || .Culled in n.flags {
			i = int(n.end) - 1
			continue
		}
		if .Focusable in n.flags {
			set_focus(ctx, n.id, visible)
			return true
		}
	}
	return false
}

// Arrow keys inside a menu layer: Up/Down move focus from item to item, Left/Right ask the bar the
// menu belongs to (a menubar, a navigation menu) to step to another trigger, through `menu_step`.
@(private)
menu_arrows :: proc(ctx: ^Context, key: platform.Key) -> bool {
	in_ := &ctx.input
	if in_.focus == 0 || len(ctx.layers) == 0 {
		return false
	}
	top := ctx.layers[len(ctx.layers) - 1]
	if k := top_input_layer(ctx); k >= 0 {
		top = ctx.layers[k]
	}
	if !top.menu {
		return false
	}
	n, ok := node_of(ctx, in_.focus)
	if !ok || layer_of(ctx, ctx.slots[n.slot].index) < 0 {
		return false
	}
	actual := layer_of(ctx, ctx.slots[n.slot].index)
	if actual >= 0 && !ctx.layers[actual].menu {
		return false
	}
	if key == .Left || key == .Right {
		in_.menu_step = -1 if key == .Left else 1
		return true
	}
	return move_focus_within(ctx, top.start, top.end, key == .Up)
}

// `menu_arrows` with Left or Right: the bar that owns the open menu should show the trigger `step`
// places away (-1: left, 1: right). It is cleared after the accepted pass, so the bar can read it
// from a rerun of the same frame.
menu_step :: proc(ctx: ^Context) -> int {
	return ctx.input.menu_step
}

// Tab either cycles inside the topmost modal layer or leaves it (which closes it).
@(private)
modal_of_focus :: proc(ctx: ^Context) -> (Layer, bool) {
	k := top_modal(ctx)
	if k < 0 {
		return {}, false
	}
	return ctx.layers[k], true
}
