// Scroll containers (ARCHITECTURE.md, "API design → 15"): an offset per container ID, applied to
// every descendant's origin in `resolve`, and clamped against the content extent the layout reports
// (or an extent the widget sets itself, for virtual lists).
//
// The wheel and the keyboard move offsets in the input phase, before the pass they affect, so a
// scroll never needs a ghost pass. `ensure_visible` does the same for focus movement, which is how a
// row scrolled out of a list comes back into view when it is focused.
package core

import "core:math"

import "../platform"

// How far one wheel notch scrolls: three lines of 24px, for wheels that report notches rather than
// pixels (ARCHITECTURE.md, "API design → 15").
WHEEL_NOTCH :: 72

// A wheel gesture keeps scrolling the container it started on this long after its last event, so
// diagonal or edge-of-container movement does not hand the gesture to another container.
@(private)
WHEEL_LATCH_MS :: 150

// The keyboard's line and page steps.
SCROLL_LINE :: 24
@(private)
SCROLL_PAGE_MARGIN :: 24

// The scroll offset of a node, in logical pixels (zero for anything that is not a scroll container).
scroll_offset :: proc(ctx: ^Context, id: Id) -> [2]f32 {
	if slot, ok := ctx.slot_of[id]; ok {
		return ctx.slots[slot].scroll
	}
	return {}
}

// The viewport and the largest offset of a container, from its last layout.
scroll_limits :: proc(ctx: ^Context, id: Id) -> (view, max: [2]f32, ok: bool) {
	slot, found := ctx.slot_of[id]
	if !found || !ctx.slots[slot].has_rect {
		return {}, {}, false
	}
	s := &ctx.slots[slot]
	return s.scroll_view, s.scroll_max, true
}

// Moves a container's content to `offset` (clamped by the next layout). Returns whether it moved.
set_scroll :: proc(ctx: ^Context, id: Id, offset: [2]f32) -> bool {
	slot, ok := ctx.slot_of[id]
	if !ok {
		return false
	}
	s := &ctx.slots[slot]
	next := [2]f32{max(offset.x, 0), max(offset.y, 0)}
	if s.scroll == next {
		return false
	}
	s.scroll = next
	return true
}

// Sets the content extent of a scroll container for this pass. A virtual list declares only the
// visible rows, so the layout's extent covers just those; this says how tall the whole list is.
set_scroll_content :: proc(ctx: ^Context, id: Id, content: [2]f32) {
	slot, ok := ctx.slot_of[id]
	if !ok {
		return
	}
	s := &ctx.slots[slot]
	s.scroll_content = content
	s.scroll_override = true
}

// Asks the widget with this ID (a virtual list) to scroll to `index` the next time it is declared.
// The request is consumed by the widget (`take_scroll_to_index`); it survives until then.
request_scroll_to_index :: proc(ctx: ^Context, id: Id, index: int) {
	ctx.scroll_requests[id] = index
}

// Takes the pending scroll request of `id`, if any.
take_scroll_to_index :: proc(ctx: ^Context, id: Id) -> (index: int, ok: bool) {
	index, ok = ctx.scroll_requests[id]
	if ok {
		delete_key(&ctx.scroll_requests, id)
	}
	return
}

// Scrolls `id`'s nearest scroll ancestors so that it lies fully inside them. Returns whether any
// offset changed. Uses the last laid-out rects: call it in the input or message phase.
ensure_visible :: proc(ctx: ^Context, id: Id) -> bool {
	t := &ctx.trees[ctx.cur]
	node, ok := node_of(ctx, id)
	if !ok {
		return false
	}
	// Node pointers may be invalidated by nothing here; walk from the node's index.
	index := -1
	for i := 0; i < len(t.nodes); i += 1 {
		if &t.nodes[i] == node {
			index = i
			break
		}
	}
	if index < 0 {
		return false
	}
	changed := false
	// The node's projected position, as inner containers are scrolled.
	pos := [2]f32{t.nodes[index].rect.x, t.nodes[index].rect.y}
	size := [2]f32{t.nodes[index].rect.w, t.nodes[index].rect.h}
	for a := t.nodes[index].parent; a >= 0; a = t.nodes[a].parent {
		anc := &t.nodes[a]
		if .Scroll not_in anc.flags {
			continue
		}
		s := &ctx.slots[anc.slot]
		for axis in 0 ..< 2 {
			lo := anc.rect.x if axis == 0 else anc.rect.y
			hi := lo + (anc.rect.w if axis == 0 else anc.rect.h)
			start := pos[axis]
			end := start + (size.x if axis == 0 else size.y)
			want: f32
			switch {
			case start < lo:
				// Too far up/left: move the content down/right (a smaller offset).
				want = start - lo
			case end > hi:
				want = end - hi
			case:
				continue
			}
			before := s.scroll[axis]
			s.scroll[axis] = clamp(before + want, 0, s.scroll_max[axis])
			moved := s.scroll[axis] - before
			pos[axis] -= moved
			changed = changed || moved != 0
		}
	}
	return changed
}

// ---- Scrollbars (DESIGN.md, "Scrollbar") ----

// The scroll container whose thumb is under `p`, topmost first. The thumb is drawn over the content
// and takes the pointer before it; only the thumb responds, never the empty track.
@(private)
scroll_bar_at :: proc(ctx: ^Context, p: [2]f32) -> Id {
	t := &ctx.trees[ctx.cur]
	#reverse for &n in t.nodes {
		if .Scroll not_in n.flags || .Disabled in n.flags {
			continue
		}
		slot := &ctx.slots[n.slot]
		for axis in 0 ..< 2 {
			if slot.bar[axis].w > 0 && contains(slot.bar[axis], p) {
				return n.id
			}
		}
	}
	return 0
}

// Starts dragging the thumb under `p`, 1:1 with the pointer.
@(private)
scroll_bar_press :: proc(ctx: ^Context, p: [2]f32) -> bool {
	id := scroll_bar_at(ctx, p)
	if id == 0 {
		return false
	}
	slot, ok := ctx.slot_of[id]
	if !ok {
		return false
	}
	s := &ctx.slots[slot]
	axis := 0
	for a in 0 ..< 2 {
		if s.bar[a].w > 0 && contains(s.bar[a], p) {
			axis = a
			break
		}
	}
	thumb := s.bar[axis]
	span := s.scroll_view[axis] - (thumb.h if axis == 1 else thumb.w)
	in_ := &ctx.input
	in_.bar_drag = id
	in_.bar_axis = axis
	in_.bar_start = p[axis]
	in_.bar_offset = s.scroll[axis]
	in_.bar_scale = s.scroll_max[axis] / max(span, 1)
	in_.bar_hot = id
	in_.active = 0
	in_.hot = 0
	return true
}

// Moves the dragged container with the pointer.
@(private)
scroll_bar_move :: proc(ctx: ^Context, p: [2]f32) {
	in_ := &ctx.input
	slot, ok := ctx.slot_of[in_.bar_drag]
	if !ok {
		in_.bar_drag = 0
		return
	}
	s := &ctx.slots[slot]
	axis := in_.bar_axis
	s.scroll[axis] = clamp(in_.bar_offset + (p[axis] - in_.bar_start) * in_.bar_scale, 0, s.scroll_max[axis])
}

// ---- The wheel ----

@(private)
wheel_pixels :: proc(w: platform.Wheel_Info) -> [2]f32 {
	if w.precise {
		return w.delta
	}
	return {w.delta.x * WHEEL_NOTCH, w.delta.y * WHEEL_NOTCH}
}

@(private)
can_scroll :: proc(ctx: ^Context, id: Id, axis: int, want: f32) -> bool {
	slot, ok := ctx.slot_of[id]
	if !ok {
		return false
	}
	s := &ctx.slots[slot]
	if s.scroll_max[axis] <= 0 {
		return false
	}
	if want > 0 {
		return s.scroll[axis] < s.scroll_max[axis] - 0.01
	}
	return s.scroll[axis] > 0.01
}

// The topmost scroll container under `p` that can move by `want` along `axis`, inside every
// clipping ancestor and outside disabled subtrees.
@(private)
scroll_target :: proc(ctx: ^Context, p: [2]f32, axis: int, want: f32) -> Id {
	t := &ctx.trees[ctx.cur]
	modal := top_modal(ctx)
	#reverse for &n in t.nodes {
		if .Scroll not_in n.flags || .Disabled in n.flags || !contains(n.rect, p) {
			continue
		}
		if modal >= 0 && layer_of(ctx, ctx.slots[n.slot].index) < modal {
			continue // a modal layer blocks the wheel below it
		}
		if !can_scroll(ctx, n.id, axis, want) {
			continue
		}
		inside := true
		for a := n.parent; a >= 0; a = t.nodes[a].parent {
			anc := &t.nodes[a]
			if .Culled in anc.flags || .Disabled in anc.flags {
				inside = false
				break
			}
			if .Clip in anc.flags && !contains(anc.rect, p) {
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

// The deepest scroll container under `p` on either axis, for the keyboard when nothing is focused.
@(private)
scroll_target_any :: proc(ctx: ^Context, p: [2]f32) -> Id {
	t := &ctx.trees[ctx.cur]
	#reverse for &n in t.nodes {
		if .Scroll not_in n.flags || .Disabled in n.flags || !contains(n.rect, p) {
			continue
		}
		return n.id
	}
	return 0
}

// Applies a wheel event. Deltas are pixels (a notch is converted); each axis scrolls on its own, so
// a horizontal wheel scrolls a horizontally scrollable container even inside a vertical one.
@(private)
scroll_wheel :: proc(ctx: ^Context, e: platform.Event) -> bool {
	delta := wheel_pixels(e.wheel)
	if delta.x == 0 && delta.y == 0 {
		return false
	}
	in_ := &ctx.input
	now := platform.ticks_ms()
	gesture := e.wheel.phase != .None
	switch e.wheel.phase {
	case .Began, .Ended, .Cancelled, .Momentum_Ended:
		in_.scroll_latch = {}
	case .None, .Changed, .Momentum:
	}
	if !gesture && now - in_.scroll_latch_time > WHEEL_LATCH_MS {
		in_.scroll_latch = {}
	}
	p := pointer(ctx)
	moved := false
	for axis in 0 ..< 2 {
		want := -delta[axis]
		if want == 0 {
			continue
		}
		id := in_.scroll_latch[axis]
		if id == 0 || !can_scroll(ctx, id, axis, want) {
			id = scroll_target(ctx, p, axis, want)
			in_.scroll_latch[axis] = id
		}
		if id == 0 {
			continue
		}
		slot := ctx.slot_of[id]
		s := &ctx.slots[slot]
		before := s.scroll[axis]
		s.scroll[axis] = clamp(before + want, 0, s.scroll_max[axis])
		moved = moved || s.scroll[axis] != before
	}
	in_.scroll_latch_time = now
	return moved
}

// ---- The keyboard ----

// The nearest scroll container strictly inside `id` (the focused widget), if any.
@(private)
scroll_ancestor :: proc(ctx: ^Context, id: Id) -> (Id, bool) {
	t := &ctx.trees[ctx.cur]
	if _, ok := node_of(ctx, id); !ok {
		return 0, false
	}
	for i := 0; i < len(t.nodes); i += 1 {
		if t.nodes[i].id != id {
			continue
		}
		for a := t.nodes[i].parent; a >= 0; a = t.nodes[a].parent {
			if .Scroll in t.nodes[a].flags {
				return t.nodes[a].id, true
			}
		}
		return 0, false
	}
	return 0, false
}

// Up/Down while something inside a scroll container is focused: move focus within that container
// instead of scrolling, then scroll the new focus into view.
@(private)
focus_move_in_scroll :: proc(ctx: ^Context, backwards: bool) -> bool {
	in_ := &ctx.input
	if in_.focus == 0 {
		return false
	}
	anc_id, ok := scroll_ancestor(ctx, in_.focus)
	if !ok {
		return false
	}
	t := &ctx.trees[ctx.cur]
	first, last := -1, -1
	for i := 0; i < len(t.nodes); i += 1 {
		if t.nodes[i].id == anc_id {
			first, last = i, int(t.nodes[i].end)
			break
		}
	}
	if first < 0 {
		return false
	}
	// Document order within the container, skipping disabled and culled subtrees.
	items := make([dynamic]Id, 0, 32, context.temp_allocator)
	current := -1
	for i := first; i < last; i += 1 {
		n := &t.nodes[i]
		if is_disabled(t, i32(i)) || .Culled in n.flags {
			i = int(n.end) - 1
			continue
		}
		if .Focusable in n.flags {
			if n.id == in_.focus {
				current = len(items)
			}
			append(&items, n.id)
		}
	}
	if current < 0 || len(items) == 0 {
		return false
	}
	next := current + 1
	if backwards {
		next = current - 1
	}
	if next < 0 || next >= len(items) {
		// At the edge: scroll one line to reveal more, without moving focus.
		return false
	}
	set_focus(ctx, items[next], true)
	ensure_visible(ctx, items[next])
	return true
}

// Applies a scroll key to the container that owns focus or, with no focus, is under the pointer.
// Returns whether a container took the key.
@(private)
scroll_key :: proc(ctx: ^Context, e: platform.Event) -> bool {
	axis := 0
	vertical := e.key == .Up || e.key == .Down || e.key == .Page_Up || e.key == .Page_Down
	if e.key == .Left || e.key == .Right {
		axis = 0
		vertical = false
	} else if vertical {
		axis = 1
	} else {
		return false
	}
	in_ := &ctx.input
	target := Id(0)
	if in_.focus != 0 {
		target, _ = scroll_ancestor(ctx, in_.focus)
	}
	if target == 0 && in_.mouse_inside {
		target = scroll_target_any(ctx, pointer(ctx))
	}
	if target == 0 {
		return false
	}
	slot, ok := ctx.slot_of[target]
	if !ok {
		return false
	}
	s := &ctx.slots[slot]
	if s.scroll_max[axis] <= 0 && e.key != .Home && e.key != .End {
		return false
	}
	view := s.scroll_view[axis] if s.scroll_view[axis] > 0 else ctx.size[axis]
	want: f32
	#partial switch e.key {
	case .Up, .Left:
		want = -SCROLL_LINE
	case .Down, .Right:
		want = SCROLL_LINE
	case .Page_Up:
		want = -(view - SCROLL_PAGE_MARGIN)
	case .Page_Down:
		want = view - SCROLL_PAGE_MARGIN
	case .Home:
		want = -math.inf_f32(1)
	case .End:
		want = math.inf_f32(1)
	case:
		return false
	}
	s.scroll[axis] = clamp(s.scroll[axis] + want, 0, s.scroll_max[axis])
	return true
}
