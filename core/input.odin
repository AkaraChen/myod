// The input phase (ARCHITECTURE.md, "API design → 2"): before `view` runs, events are hit-tested
// against the layout currently on screen and turned into presentation state (hover, press, focus)
// and interaction results recorded by widget ID. Widgets only read them while `view` declares.
//
// Results are consumed once: they stay readable through ghost passes and are cleared after the
// first pass that can be presented (`consume`), so a rerun of `view` never sees the same click twice.
package core

import "../platform"

Input :: struct {
	mouse:         [2]f32, // logical pixels from the window's top-left
	mouse_inside:  bool,
	mods:          platform.Modifiers,
	hot:           Id, // the topmost node under the mouse that takes the pointer
	active:        Id, // pressed: it captures the pointer until the button is released
	press_pos:     [2]f32,
	focus:         Id,
	focus_visible: bool, // focus came from the keyboard (or an assistive technology): draw the ring
	results:       map[Id]Result,
	// Key presses and text for the focused widget, in order, since the last consumed pass.
	keys:          [dynamic]platform.Event,
	window_focus:  bool,
	// The container each wheel axis is scrolling, and when its last event arrived (scroll.odin).
	scroll_latch:      [2]Id,
	scroll_latch_time: u64,
	// The scrollbar thumb under the mouse, and the drag in progress (scroll.odin).
	bar_hot:    Id,
	bar_drag:   Id,
	bar_axis:   int,
	bar_start:  f32, // the pointer's position along the axis when the drag began
	bar_offset: f32, // the container's offset then
	bar_scale:  f32, // content pixels per pointer pixel
	// Esc was pressed, or a click landed outside the top layer (both closed it; layers.odin).
	escape:        bool,
	click_outside: bool,
	// Left/Right inside a menu layer: the bar that owns the menu steps to another trigger (menubar).
	menu_step:     int,
	// The widget the right button went down on this frame, for context menus.
	secondary:     Id,
}

// What happened to one widget since the last consumed pass.
Result :: struct {
	clicks:       int, // a click completed over it: 1, 2 for a double click, 3 for a triple click
	activated:    bool, // Space or Enter while focused, or an accessibility action
	gained_focus: bool,
	lost_focus:   bool,
}

// A widget's view of the input phase, read while it is declared.
Interaction :: struct {
	hovered:           bool, // under the mouse, and no other widget holds the pointer
	pressed:           bool, // held down with the mouse over it
	held:              bool, // holds the pointer (it may have left the widget)
	press:             [2]f32, // where the press that is holding it began, in root coordinates
	clicked:           bool, // a click, or activation by keyboard or accessibility
	double_clicked:    bool,
	clicks:            int,
	focused:           bool,
	focus_visible:     bool,
	gained_focus:      bool,
	lost_focus:        bool,
	secondary_clicked: bool, // the right button went down on it this frame (context menus)
}

// The interaction state of a widget. Widgets that take the pointer declare their node with `Hit`
// (and `Focusable`, `Activate` as needed); the state applies to the next presented layout.
interact :: proc(ctx: ^Context, id: Id) -> (it: Interaction) {
	in_ := &ctx.input
	it.held = in_.active == id
	it.press = in_.press_pos
	it.hovered = in_.hot == id && (in_.active == 0 || in_.active == id)
	it.pressed = it.held && in_.hot == id
	it.focused = in_.focus == id
	it.focus_visible = it.focused && in_.focus_visible
	it.secondary_clicked = in_.secondary == id
	if r, ok := in_.results[id]; ok {
		it.clicks = r.clicks
		it.clicked = r.clicks == 1 || r.activated
		it.double_clicked = r.clicks == 2
		it.gained_focus = r.gained_focus
		it.lost_focus = r.lost_focus
	}
	return
}

// The key presses and text typed into a widget since the last consumed pass; empty unless it has focus.
keys :: proc(ctx: ^Context, id: Id) -> []platform.Event {
	if ctx.input.focus != id {
		return nil
	}
	return ctx.input.keys[:]
}

// Hands the key and text events to a widget that reads them itself: they are cleared, so an edit is
// applied once even when the pass reruns as a ghost pass. The slice stays valid this frame.
take_keys :: proc(ctx: ^Context, id: Id) -> []platform.Event {
	events := keys(ctx, id)
	if len(events) > 0 {
		clear(&ctx.input.keys)
	}
	return events
}

// Where the pointer is, in the root's coordinates (the same space as node rects).
pointer :: proc(ctx: ^Context) -> [2]f32 {
	return ctx.input.mouse + {ctx.viewport.x, ctx.viewport.y}
}

// `pointer` for widgets: the input phase's cursor position in root coordinates.
pointer_pos :: proc(ctx: ^Context) -> [2]f32 {
	return pointer(ctx)
}

// Applies one event to the input state. Returns whether it may change what is drawn (a pure mouse
// move that changes no hover does not).
handle_event :: proc(ctx: ^Context, e: platform.Event) -> bool {
	in_ := &ctx.input
	#partial switch e.kind {
	case .Mouse_Move:
		in_.mouse = e.pos
		in_.mouse_inside = true
		in_.mods = e.mods
		if in_.bar_drag != 0 {
			scroll_bar_move(ctx, pointer(ctx))
			return true
		}
		if ctx.sel.dragging && in_.active == 0 {
			// A drag selection over body text: hover changes are not what is being tracked.
			selection_drag(ctx)
			return true
		}
		old := in_.hot
		in_.bar_hot = scroll_bar_at(ctx, pointer(ctx))
		if in_.bar_hot != 0 {
			// The area under a thumb takes the pointer first (DESIGN.md, "Scrollbar").
			in_.hot = 0
		} else {
			in_.hot = hit_test(ctx, pointer(ctx))
		}
		return in_.hot != old || in_.active != 0
	case .Mouse_Leave:
		in_.mouse_inside = false
		old := in_.hot
		in_.bar_hot = 0
		if in_.active == 0 && in_.bar_drag == 0 {
			in_.hot = 0
		}
		return in_.hot != old
	case .Mouse_Down:
		in_.mouse = e.pos
		in_.mods = e.mods
		in_.scroll_latch = {}
		if e.button == .Right {
			// The right button opens a context menu on the widget under it, and closes the topmost
			// layer when the click lands outside it (like the left button does).
			p := pointer(ctx)
			if k := top_input_layer(ctx); k >= 0 {
				t := &ctx.trees[ctx.cur]
				if !contains(t.nodes[ctx.layers[k].start].rect, p) {
					in_.click_outside = true
					in_.secondary = 0
					return true
				}
			}
			in_.secondary = hit_test(ctx, p)
			return in_.secondary != 0
		}
		if e.button != .Left {
			return false
		}
		p := pointer(ctx)
		if scroll_bar_press(ctx, p) {
			return true
		}
		// A click outside the top layer closes it, and does not pass through to what is below.
		if k := top_input_layer(ctx); k >= 0 {
			t := &ctx.trees[ctx.cur]
			top := ctx.layers[k]
			if !contains(t.nodes[top.start].rect, p) {
				in_.click_outside = true
				in_.hot = 0
				in_.active = 0
				return true
			}
		}
		in_.hot = hit_test(ctx, pointer(ctx))
		if in_.hot == 0 && top_input_layer(ctx) < 0 {
			// Nothing takes the pointer: a press on body text starts a selection.
			if pos, ok := text_hit(ctx, p); ok {
				set_focus(ctx, 0, false)
				selection_begin(ctx, pos)
				in_.active = 0
				in_.press_pos = e.pos
				return true
			}
		}
		selection_clear(ctx)
		in_.active = in_.hot
		in_.press_pos = e.pos
		node, ok := node_of(ctx, in_.hot)
		if ok && .Focusable in node.flags {
			set_focus(ctx, in_.hot, false)
		} else {
			set_focus(ctx, 0, false)
		}
		return true
	case .Mouse_Up:
		in_.mouse = e.pos
		in_.mods = e.mods
		if in_.bar_drag != 0 {
			in_.bar_drag = 0
			in_.active = 0
			return true
		}
		if e.button != .Left || in_.active == 0 {
			if e.button == .Left && ctx.sel.dragging {
				// The drag ends: a double or triple click then selects a word or a paragraph.
				ctx.sel.dragging = false
				selection_click(ctx, e.clicks)
				return true
			}
			return in_.active != 0
		}
		in_.hot = hit_test(ctx, pointer(ctx))
		if in_.hot == in_.active {
			result(ctx, in_.active).clicks = max(e.clicks, 1)
		}
		in_.active = 0
		return true
	case .Wheel:
		in_.mouse = e.pos
		in_.mouse_inside = true
		in_.mods = e.mods
		return scroll_wheel(ctx, e)
	case .Key_Down:
		in_.mods = e.mods
		if e.key == .Escape && top_input_layer(ctx) >= 0 {
			// Esc acts only on the topmost layer (ARCHITECTURE.md, "API design → 14").
			in_.escape = true
			return true
		}
		if e.key == .Tab && e.mods & {.Ctrl, .Alt, .Super} == {} {
			move_focus(ctx, .Shift in e.mods)
			if in_.focus != 0 {
				ensure_visible(ctx, in_.focus)
			}
			return true
		}
		if in_.focus != 0 {
			// A text field reads the keys itself: arrows, Home/End, Backspace and the shortcuts all
			// belong to the text, not to scrolling or the widget's activation.
			if node, ok := node_of(ctx, in_.focus); ok && .Text_Edit in node.flags {
				append(&in_.keys, e)
				return true
			}
		}
		if e.key == .Char && e.char == 'c' && e.mods & {.Super, .Ctrl} != {} {
			// Copy the body text selection (a text field copied in its own branch above).
			if selection_copy(ctx) {
				return true
			}
		}
		if in_.focus != 0 && (e.key == .Left || e.key == .Right || e.key == .Up || e.key == .Down) {
			// Widgets that walk the arrows themselves (table cells) get them before scrolling.
			if node, ok := node_of(ctx, in_.focus); ok && .Arrows in node.flags {
				append(&in_.keys, e)
				return true
			}
		}
		if in_.focus != 0 && (e.key == .Up || e.key == .Down || e.key == .Left || e.key == .Right) {
			// A menu's arrows move between its items (Left/Right ask its bar to switch menus); inside a
			// list they move the selection.
			if menu_arrows(ctx, e.key) {
				return true
			}
			if (e.key == .Up || e.key == .Down) && focus_move_in_scroll(ctx, e.key == .Up) {
				return true
			}
		}
		if in_.focus != 0 {
			// Widgets that use the arrows themselves (sliders, splitters) get them first.
			if node, ok := node_of(ctx, in_.focus); ok && .Adjust in node.flags && !e.repeat {
				#partial switch e.key {
				case .Left, .Right, .Up, .Down, .Home, .End:
					append(&in_.keys, e)
					return true
				}
			}
		}
		if scroll_key(ctx, e) {
			return true
		}
		if in_.focus == 0 {
			return false
		}
		append(&in_.keys, e)
		if (e.key == .Space || e.key == .Enter) && !e.repeat {
			if node, ok := node_of(ctx, in_.focus); ok && .Activate in node.flags && .Disabled not_in node.flags {
				result(ctx, in_.focus).activated = true
			}
		}
		return true
	case .Key_Up:
		in_.mods = e.mods
		return false
	case .Text_Input, .Text_Editing:
		if in_.focus == 0 {
			return false
		}
		append(&in_.keys, e)
		return true
	case .Focus_Gained:
		in_.window_focus = true
		return true
	case .Focus_Lost:
		in_.window_focus = false
		in_.active = 0
		in_.scroll_latch = {}
		return true
	}
	return false
}

// An accessibility action (or a test) clicking a widget: the same result as Space on it.
activate :: proc(ctx: ^Context, id: Id) {
	result(ctx, id).activated = true
}

// Moves keyboard focus to a widget (0 clears it). `visible`: draw the focus ring.
set_focus :: proc(ctx: ^Context, id: Id, visible: bool) {
	in_ := &ctx.input
	if in_.focus != id {
		if in_.focus != 0 {
			result(ctx, in_.focus).lost_focus = true
		}
		if id != 0 {
			result(ctx, id).gained_focus = true
		}
		in_.focus = id
	}
	in_.focus_visible = visible && id != 0
}

// Tab and Shift+Tab: the next or previous focusable node in document order. Inside a modal layer they
// cycle within it (the focus trap).
move_focus :: proc(ctx: ^Context, backwards: bool) {
	t := &ctx.trees[ctx.cur]
	from, to := i32(0), i32(len(t.nodes))
	if k := top_modal(ctx); k >= 0 {
		from, to = ctx.layers[k].start, ctx.layers[k].end
	}
	move_focus_range(ctx, from, to, backwards, true)
}

// Moves focus to the next focusable node in [from, to). With `wrap`, cycles; without, stops at the
// edges and returns false.
@(private)
move_focus_range :: proc(ctx: ^Context, from, to: i32, backwards, wrap: bool) -> bool {
	t := &ctx.trees[ctx.cur]
	focusable := make([dynamic]Id, 0, 32, context.temp_allocator)
	current := -1
	for i := int(from); i < int(to); i += 1 {
		n := &t.nodes[i]
		if is_disabled(t, i32(i)) || .Culled in n.flags {
			i = int(n.end) - 1
			continue
		}
		if .Focusable in n.flags {
			if n.id == ctx.input.focus {
				current = len(focusable)
			}
			append(&focusable, n.id)
		}
	}
	if len(focusable) == 0 {
		return false
	}
	next: int
	switch {
	case current < 0:
		next = len(focusable) - 1 if backwards else 0
	case backwards:
		next = current - 1
		if next < 0 {
			if !wrap {
				return false
			}
			next = len(focusable) - 1
		}
	case:
		next = current + 1
		if next >= len(focusable) {
			if !wrap {
				return false
			}
			next = 0
		}
	}
	set_focus(ctx, focusable[next], true)
	return true
}

// Moves focus inside a layer's range (menu arrows); no wrap.
@(private)
move_focus_within :: proc(ctx: ^Context, from, to: i32, backwards: bool) -> bool {
	return move_focus_range(ctx, from, to, backwards, false)
}

// Recomputes what is under the mouse against the layout on screen (it may have moved since the
// last mouse event). Returns whether the hovered widget changed.
refresh_hot :: proc(ctx: ^Context) -> bool {
	in_ := &ctx.input
	if !in_.mouse_inside {
		return false
	}
	old := in_.hot
	in_.bar_hot = scroll_bar_at(ctx, pointer(ctx))
	in_.hot = 0 if in_.bar_hot != 0 else hit_test(ctx, pointer(ctx))
	return in_.hot != old
}

// Clears the results after the pass that read them was accepted. Focus on a widget that is no
// longer declared is dropped.
consume :: proc(ctx: ^Context) {
	clear(&ctx.input.results)
	clear(&ctx.input.keys)
	ctx.input.escape = false
	ctx.input.click_outside = false
	ctx.input.menu_step = 0
	ctx.input.secondary = 0
	if ctx.input.focus != 0 {
		if _, ok := node_of(ctx, ctx.input.focus); !ok {
			ctx.input.focus = 0
			ctx.input.focus_visible = false
		}
	}
	if ctx.input.active != 0 {
		if _, ok := node_of(ctx, ctx.input.active); !ok {
			ctx.input.active = 0
		}
	}
}

// Whether there are results no pass has consumed yet.
has_results :: proc(ctx: ^Context) -> bool {
	return len(ctx.input.results) > 0 || len(ctx.input.keys) > 0
}

// The topmost node that takes the pointer at `p` (root coordinates), inside every clipping ancestor
// and not inside a disabled one. Layers are tested from the top down; a modal layer blocks
// everything below it (ARCHITECTURE.md, "API design → 14").
hit_test :: proc(ctx: ^Context, p: [2]f32) -> Id {
	if len(ctx.layers) > 0 {
		lowest := top_modal(ctx)
		for k := len(ctx.layers) - 1; k >= max(lowest, 0); k -= 1 {
			layer := ctx.layers[k]
			if id := hit_range(ctx, layer.start, layer.end, p); id != 0 {
				return id
			}
			if layer.modal {
				return 0
			}
		}
	}
	return hit_base(ctx, p)
}

// Hit testing inside one layer's node range.
@(private)
hit_range :: proc(ctx: ^Context, from, end: i32, p: [2]f32) -> Id {
	t := &ctx.trees[ctx.cur]
	for i := int(end) - 1; i >= int(from); i -= 1 {
		n := &t.nodes[i]
		if .Hit not_in n.flags || .Disabled in n.flags || !contains(n.rect, p) {
			continue
		}
		inside := true
		for a := n.parent; a >= from; a = t.nodes[a].parent {
			anc := &t.nodes[a]
			if .Culled in anc.flags || .Disabled in anc.flags || (.Clip in anc.flags && !contains(anc.rect, p)) {
				inside = false
				break
			}
		}
		if inside {
			return n.id
		}
	}
	return 0
}

// Hit testing the base content, skipping layer subtrees.
@(private)
hit_base :: proc(ctx: ^Context, p: [2]f32) -> Id {
	t := &ctx.trees[ctx.cur]
	#reverse for &n in t.nodes {
		if .Layer in n.flags || .Hit not_in n.flags || .Disabled in n.flags || !contains(n.rect, p) {
			continue
		}
		inside := true
		for a := n.parent; a >= 0; a = t.nodes[a].parent {
			anc := &t.nodes[a]
			if .Culled in anc.flags || .Disabled in anc.flags || .Layer in anc.flags || (.Clip in anc.flags && !contains(anc.rect, p)) {
				inside = false
				break
			}
		}
		if inside {
			return n.id
		}
	}
	return 0
}

// The node of a widget in the last pass, if it was declared there.
node_of :: proc(ctx: ^Context, id: Id) -> (^Node, bool) {
	if id == 0 {
		return nil, false
	}
	slot, ok := ctx.slot_of[id]
	if !ok {
		return nil, false
	}
	s := &ctx.slots[slot]
	t := &ctx.trees[ctx.cur]
	if s.seen != ctx.stamp || s.index < 0 || int(s.index) >= len(t.nodes) || t.nodes[s.index].id != id {
		return nil, false
	}
	return &t.nodes[s.index], true
}

contains :: proc(r: Rect, p: [2]f32) -> bool {
	return p.x >= r.x && p.x < r.x + r.w && p.y >= r.y && p.y < r.y + r.h
}

// Whether a node or any of its ancestors is disabled.
is_disabled :: proc(t: ^Tree, index: i32) -> bool {
	for i := index; i >= 0; i = t.nodes[i].parent {
		if .Disabled in t.nodes[i].flags {
			return true
		}
	}
	return false
}

@(private)
result :: proc(ctx: ^Context, id: Id) -> ^Result {
	if id not_in ctx.input.results {
		ctx.input.results[id] = {}
	}
	return &ctx.input.results[id]
}

@(private)
input_destroy :: proc(in_: ^Input) {
	delete(in_.results)
	delete(in_.keys)
}
