// Scroll container behavior that has no visible face of its own: anchoring, and the identity an
// explicit key gives a container (core/scroll.odin, core/core.odin "scroll_anchor").
package ui

import "core:fmt"
import "core:testing"

import "../core"

Anchor_State :: struct {
	prelude: f32, // a block above the container: changes where it sits on the page
	above:   f32, // a block above the visible part, inside the container
}

anchor_update :: proc(s: ^Anchor_State, msg: struct{}, fx: ^Effects(struct{})) {}

anchor_view :: proc(s: Anchor_State, d: Dispatch(struct{})) {
	if s.prelude > 0 {
		if column({height = fixed(s.prelude), width = grow()}) {}
	}
	if scroll({id = "anchor", width = grow(), height = fixed(200)}) {
		if column({height = fixed(s.above), width = grow()}) {}
		if column({height = fixed(300), width = grow()}) {
			text("above the viewport", .Body)
		}
		for i in 0 ..< 10 {
			if column({height = fixed(40), width = grow()}) {
				text(fmt.tprintf("row %d", i), .Body)
			}
		}
	}
}

// The ID of the test's one scroll container, from the last pass's tree.
anchor_scroll_id :: proc(t: ^Test_Harness(Anchor_State, struct{})) -> core.Id {
	ctx := &t.window.ctx
	for &n in ctx.trees[ctx.cur].nodes {
		if .Scroll in n.flags {
			return n.id
		}
	}
	return 0
}

anchor_offset :: proc(t: ^Test_Harness(Anchor_State, struct{})) -> f32 {
	ctx := &t.window.ctx
	if slot, ok := ctx.slot_of[anchor_scroll_id(t)]; ok {
		return ctx.slots[slot].scroll.y
	}
	return 0
}

@(test)
scroll_anchoring_holds_the_content_still :: proc(t: ^testing.T) {
	h := test_harness(Anchor_State{}, anchor_update, anchor_view)
	defer test_destroy(h)

	id := anchor_scroll_id(h)
	testing.expect(t, id != 0, "the scroll container should be declared")
	testing.expect(t, core.set_scroll(&h.window.ctx, id, {0, 400}), "scroll to 400")
	test_frame(h)
	testing.expect_value(t, anchor_offset(h), f32(400))

	// The block above the viewport grows by 60: the offset follows it by 60, so the rows do not
	// move on screen.
	h.store.state.above = 60
	test_frame(h)
	testing.expect_value(t, anchor_offset(h), f32(460))
}

@(test)
scroll_anchoring_yields_to_the_user :: proc(t: ^testing.T) {
	h := test_harness(Anchor_State{}, anchor_update, anchor_view)
	defer test_destroy(h)

	id := anchor_scroll_id(h)
	core.set_scroll(&h.window.ctx, id, {0, 400})
	test_frame(h)

	// A reflow and a user move in the same frame: the user's offset wins.
	h.store.state.above = 60
	core.set_scroll(&h.window.ctx, id, {0, 390})
	test_frame(h)
	testing.expect_value(t, anchor_offset(h), f32(390))
}

@(test)
scroll_keyed_container_keeps_its_offset :: proc(t: ^testing.T) {
	h := test_harness(Anchor_State{}, anchor_update, anchor_view)
	defer test_destroy(h)

	id := anchor_scroll_id(h)
	core.set_scroll(&h.window.ctx, id, {0, 120})
	test_frame(h)

	// A block appears above the container, which moves down the page; the container itself is
	// unchanged, and its key keeps both its identity and its offset.
	h.store.state.prelude = 30
	test_frame(h)
	testing.expect(t, anchor_scroll_id(h) == id, "the explicit key keeps the container's identity")
	testing.expect_value(t, anchor_offset(h), f32(120))
}
