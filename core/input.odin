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
	hovered:        bool, // under the mouse, and no other widget holds the pointer
	pressed:        bool, // held down with the mouse over it
	held:           bool, // holds the pointer (it may have left the widget)
	clicked:        bool, // a click, or activation by keyboard or accessibility
	double_clicked: bool,
	clicks:         int,
	focused:        bool,
	focus_visible:  bool,
	gained_focus:   bool,
	lost_focus:     bool,
}

// The interaction state of a widget. Widgets that take the pointer declare their node with `Hit`
// (and `Focusable`, `Activate` as needed); the state applies to the next presented layout.
interact :: proc(ctx: ^Context, id: Id) -> (it: Interaction) {
	in_ := &ctx.input
	it.held = in_.active == id
	it.hovered = in_.hot == id && (in_.active == 0 || in_.active == id)
	it.pressed = it.held && in_.hot == id
	it.focused = in_.focus == id
	it.focus_visible = it.focused && in_.focus_visible
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

// Where the pointer is, in the root's coordinates (the same space as node rects).
pointer :: proc(ctx: ^Context) -> [2]f32 {
	return ctx.input.mouse + {ctx.viewport.x, ctx.viewport.y}
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
		old := in_.hot
		in_.hot = hit_test(ctx, pointer(ctx))
		return in_.hot != old || in_.active != 0
	case .Mouse_Leave:
		in_.mouse_inside = false
		old := in_.hot
		if in_.active == 0 {
			in_.hot = 0
		}
		return in_.hot != old
	case .Mouse_Down:
		in_.mouse = e.pos
		in_.mods = e.mods
		in_.scroll_latch = {}
		if e.button != .Left {
			return false
		}
		in_.hot = hit_test(ctx, pointer(ctx))
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
		if e.button != .Left || in_.active == 0 {
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
		if e.key == .Tab && e.mods & {.Ctrl, .Alt, .Super} == {} {
			move_focus(ctx, .Shift in e.mods)
			if in_.focus != 0 {
				ensure_visible(ctx, in_.focus)
			}
			return true
		}
		if in_.focus != 0 && (e.key == .Up || e.key == .Down) {
			// Inside a list, the arrows move the selection; the list scrolls it into view.
			if focus_move_in_scroll(ctx, e.key == .Up) {
				return true
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

// Tab and Shift+Tab: the next or previous focusable node in document order, wrapping around.
move_focus :: proc(ctx: ^Context, backwards: bool) {
	t := &ctx.trees[ctx.cur]
	focusable := make([dynamic]Id, 0, 32, context.temp_allocator)
	current := -1
	for i := 0; i < len(t.nodes); i += 1 {
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
		return
	}
	next: int
	switch {
	case current < 0:
		next = len(focusable) - 1 if backwards else 0
	case backwards:
		next = (current + len(focusable) - 1) % len(focusable)
	case:
		next = (current + 1) % len(focusable)
	}
	set_focus(ctx, focusable[next], true)
}

// Recomputes what is under the mouse against the layout on screen (it may have moved since the
// last mouse event). Returns whether the hovered widget changed.
refresh_hot :: proc(ctx: ^Context) -> bool {
	in_ := &ctx.input
	if !in_.mouse_inside {
		return false
	}
	old := in_.hot
	in_.hot = hit_test(ctx, pointer(ctx))
	return in_.hot != old
}

// Clears the results after the pass that read them was accepted. Focus on a widget that is no
// longer declared is dropped.
consume :: proc(ctx: ^Context) {
	clear(&ctx.input.results)
	clear(&ctx.input.keys)
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
// and not inside a disabled one.
hit_test :: proc(ctx: ^Context, p: [2]f32) -> Id {
	t := &ctx.trees[ctx.cur]
	#reverse for &n in t.nodes {
		if .Hit not_in n.flags || .Disabled in n.flags || !contains(n.rect, p) {
			continue
		}
		inside := true
		for a := n.parent; a >= 0; a = t.nodes[a].parent {
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
