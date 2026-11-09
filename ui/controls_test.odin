// Tests of the interactive controls' pointer math (ARCHITECTURE.md, "Testing"). The windowed
// examples show the same gestures to a person; here the pointer is driven through the input phase
// so a drag can be checked without a window.
package ui

import "core:fmt"
import "core:testing"

import "../core"
import "../platform"

// ---- Splitter ----

Split_State :: struct {
	left: f32,
	// Where the splitter was in the last layout; the splitter has no semantic role to look up,
	// since it is a pointer-only control.
	rect: ^Rect,
}

Resize :: struct {
	width: f32,
}

Split_Msg :: union {
	Resize,
}

split_update :: proc(s: ^Split_State, msg: Split_Msg, fx: ^Effects(Split_Msg)) {
	switch m in msg {
	case Resize:
		s.left = clamp(m.width, 80, 400)
	}
}

split_view :: proc(s: Split_State, d: Dispatch(Split_Msg)) {
	if row({width = grow(), height = grow()}) {
		if column({width = fixed(s.left), height = grow()}) {
			text("left")
		}
		r := splitter()
		if s.rect != nil {
			s.rect^ = r.rect
		}
		if r.dragging && r.drag != 0 {
			dispatch(d, Resize{s.left + r.drag})
		}
		if column({width = grow(), height = grow()}) {
			text("right")
		}
	}
}

// The harness's first frame only declares; a widget's last-layout rect is readable from the second
// frame on. A move at the window origin starts that frame without touching anything.
split_settle :: proc(t: ^Test_Harness(Split_State, Split_Msg)) {
	append(&t.window.events, platform.Event{kind = .Mouse_Move, pos = {0, 0}})
	test_frame(t)
}

split_drag :: proc(t: ^Test_Harness(Split_State, Split_Msg), p: [2]f32) {
	append(&t.window.events, platform.Event{kind = .Mouse_Move, pos = p})
	test_frame(t)
}

split_press :: proc(t: ^Test_Harness(Split_State, Split_Msg), p: [2]f32) {
	append(&t.window.events, platform.Event{kind = .Mouse_Move, pos = p})
	append(&t.window.events, platform.Event{kind = .Mouse_Down, pos = p, button = .Left})
	test_frame(t)
}

split_release :: proc(t: ^Test_Harness(Split_State, Split_Msg), p: [2]f32) {
	append(&t.window.events, platform.Event{kind = .Mouse_Up, pos = p, button = .Left, clicks = 1})
	test_frame(t)
}

@(test)
splitter_drag_follows_pointer :: proc(t: ^testing.T) {
	rect: Rect
	h := test_harness(Split_State{left = 200, rect = &rect}, split_update, split_view)
	defer test_destroy(h)
	split_settle(h)

	p := [2]f32{rect.x + rect.w / 2, rect.y + rect.h / 2}
	testing.expect(t, rect.w > 0 && p.x > 0, "the splitter was not laid out")
	split_press(h, p)
	testing.expect_value(t, h.store.state.left, 200)

	// Holding still does not move the panel.
	split_drag(h, p)
	testing.expect_value(t, h.store.state.left, 200)

	// The panel follows the pointer 1:1.
	split_drag(h, {p.x + 40, p.y})
	testing.expect_value(t, h.store.state.left, 240)
	split_drag(h, {p.x + 60, p.y})
	testing.expect_value(t, h.store.state.left, 260)

	// After the release the pointer no longer resizes anything.
	split_release(h, {p.x + 60, p.y})
	split_drag(h, {p.x + 200, p.y})
	testing.expect_value(t, h.store.state.left, 260)
}

@(test)
splitter_clamps_to_its_limits :: proc(t: ^testing.T) {
	rect: Rect
	h := test_harness(Split_State{left = 380, rect = &rect}, split_update, split_view)
	defer test_destroy(h)
	split_settle(h)

	p := [2]f32{rect.x + rect.w / 2, rect.y + rect.h / 2}
	split_press(h, p)
	split_drag(h, {p.x + 200, p.y})
	testing.expect_value(t, h.store.state.left, 400)
}

// ---- scroll_events ----

Scroll_Test_State :: struct {
	hits: int,
	id:   ^Id,
}

Reached_End :: struct{}

Scroll_Test_Msg :: union {
	Reached_End,
}

scroll_update :: proc(s: ^Scroll_Test_State, msg: Scroll_Test_Msg, fx: ^Effects(Scroll_Test_Msg)) {
	switch m in msg {
	case Reached_End:
		s.hits += 1
	}
}

@(private)
scroll_view :: proc(s: Scroll_Test_State, d: Dispatch(Scroll_Test_Msg)) {
	if s.id != nil {
		s.id^ = key_id(core.current(), "page")
	}
	if scroll_events(d, Reached_End{}, {id = "page", width = grow(), height = grow()}) {
		if column({height = fixed(2_000)}) {
			text(fmt.tprintf("hits %d", s.hits))
		}
	}
}

@(test)
scroll_events_reports_the_end_once :: proc(t: ^testing.T) {
	id := Id(0)
	h := test_harness(Scroll_Test_State{id = &id}, scroll_update, scroll_view)
	defer test_destroy(h)

	ctx := &h.window.ctx
	_, max, ok := core.scroll_limits(ctx, id)
	testing.expect(t, ok, "the scroll container was laid out")
	core.set_scroll(ctx, id, {0, max.y})
	test_frame(h)
	testing.expect_value(t, h.store.state.hits, 1)

	// Staying at the bottom does not report again; scrolling away and back does.
	test_frame(h)
	testing.expect_value(t, h.store.state.hits, 1)
	core.set_scroll(ctx, id, {0, 0})
	test_frame(h)
	core.set_scroll(ctx, id, {0, max.y})
	test_frame(h)
	testing.expect_value(t, h.store.state.hits, 2)
}
